"""
    Copyright (C) 2026 os-clat contributors
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES,
    INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
    AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY,
    OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
    INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
    CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
    ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
"""

import collections
import ipaddress
from collections.abc import Iterable
from ipaddress import IPv6Address, IPv6Network

# NAT64 prefix discovery: PREF64 in router advertisements (RFC 8781), ipv4only.arpa (RFC 7050) and the
# bookkeeping of the one prefix each source holds. Nothing in this module touches the operating system.

PLC_TO_LEN = (96, 64, 56, 48, 40, 32)
DNS_NAME = 'ipv4only.arpa.'
DNS_TIMEOUT = 2.0
DNS_MIN_REFRESH = 60.0
DNS_NEGATIVE_MAX = 300.0
DNS_RETRY_STEPS = (10.0, 30.0, 60.0, 300.0)

ND_ROUTER_ADVERT = 134
ND_OPT_PREF64 = 38

# RFC 7050: the two well-known IPv4 addresses of ipv4only.arpa (192.0.0.170 and 192.0.0.171)
WKA = (bytes((192, 0, 0, 170)), bytes((192, 0, 0, 171)))
# RFC 6052 section 2.2: prefix length -> the address octets that carry the IPv4 address (octet 8 is skipped)
V4_OCTETS = {
    32: (4, 5, 6, 7),
    40: (5, 6, 7, 9),
    48: (6, 7, 9, 10),
    56: (7, 9, 10, 11),
    64: (9, 10, 11, 12),
    96: (12, 13, 14, 15),
}

# ifname: str, hoplimit: int, source: IPv6Address (always a result of ll_norm), data: bytes (the ICMPv6 message)
RaPacket = collections.namedtuple('RaPacket', 'ifname hoplimit source data')


def ll_norm(text: str) -> IPv6Address:
    """ Address text to an IPv6Address without zone: the text is cut at '%', and inside fe80::/10 a zone id
        embedded by the kernel (bytes 2 and 3) is cleared. Raises ValueError for anything else.
    """
    raw = bytearray(ipaddress.IPv6Address(text.split('%')[0]).packed)
    if raw[0] == 0xfe and (raw[1] & 0xc0) == 0x80:
        raw[2] = raw[3] = 0
    return ipaddress.IPv6Address(bytes(raw))


def parse_ra_pref64(data: bytes) -> list[tuple[IPv6Network, int]] | None:
    """ PREF64 options of one ICMPv6 message as read from the raw socket.
        None: not a well-formed router advertisement. Else one (prefix, lifetime in seconds) per valid
        option 38; lifetime 0 withdraws the prefix, an empty list carries no PREF64 information.
    """
    if len(data) < 16 or data[0] != ND_ROUTER_ADVERT or data[1] != 0:
        return None
    found = []
    off = 16
    while off < len(data):
        if off + 2 > len(data):
            return None
        otype, olen = data[off], data[off + 1]
        if olen == 0 or off + olen * 8 > len(data):
            return None
        if otype == ND_OPT_PREF64 and olen == 2:
            field = (data[off + 2] << 8) | data[off + 3]
            plc = field & 0x7
            if plc < len(PLC_TO_LEN):
                raw = bytes(data[off + 4:off + 16]) + bytes(4)
                found.append((ipaddress.IPv6Network((raw, PLC_TO_LEN[plc]), strict=False), field & 0xFFF8))
        off += olen * 8
    return found


def accept_ra(pkt: RaPacket, uplink: str | None, router: IPv6Address | None) -> list[tuple[IPv6Network, int]] | None:
    """ None unless the packet arrived on the uplink with hop limit 255 from the link-local address of the
        uplink's default router; else its PREF64 entries (an empty list: accepted, no PREF64 information).
    """
    if not uplink or pkt.ifname != uplink or pkt.hoplimit != 255:
        return None
    if router is None or not pkt.source.is_link_local or pkt.source != router:
        return None
    return parse_ra_pref64(pkt.data)


def pref64_candidates(aaaa: str) -> set[IPv6Network]:
    """ Every RFC 6052 prefix the address can have been synthesised with from 192.0.0.170 or 192.0.0.171.
        Octet 8 must be zero, except for /96 (a /96 that ignores this would otherwise never be found).
    """
    raw = ipaddress.IPv6Address(aaaa).packed
    found = set()
    for plen, octets in V4_OCTETS.items():
        if plen != 96 and raw[8] != 0:
            continue
        if bytes(raw[index] for index in octets) in WKA:
            head = plen // 8
            found.add(ipaddress.IPv6Network((raw[:head] + bytes(16 - head), plen)))
    return found


def pref64_from_answer(addrs: list[str], current: IPv6Network | None = None,
                       reject: Iterable[IPv6Network] = ()) -> IPv6Network | None:
    """ The NAT64 prefix of one AAAA answer for ipv4only.arpa: of the candidates of all records that overlap
        nothing in reject, current when it is still among them, else the lowest; None when there is none.
    """
    reject = list(reject)
    found = set()
    for text in addrs:
        found |= pref64_candidates(text)
    found = {prefix for prefix in found if not overlaps(prefix, reject)}
    if current is not None and current in found:
        return current
    return min(found, key=_order) if found else None


def embed(prefix: IPv6Network, ipv4: str) -> IPv6Address:
    """ RFC 6052 address synthesis for the six allowed prefix lengths. """
    if prefix.prefixlen not in V4_OCTETS:
        raise ValueError('not an RFC 6052 prefix length: %d' % prefix.prefixlen)
    raw = bytearray(prefix.network_address.packed)
    for index, octet in zip(V4_OCTETS[prefix.prefixlen], ipaddress.IPv4Address(ipv4).packed):
        raw[index] = octet
    return ipaddress.IPv6Address(bytes(raw))


def overlaps(prefix: IPv6Network, others: Iterable[IPv6Network]) -> bool:
    """ True when prefix overlaps any of the other networks. """
    return any(prefix.overlaps(other) for other in others)


def _order(prefix: IPv6Network) -> tuple[int, int]:
    """ Sort key for "the lowest prefix". """
    return (int(prefix.network_address), prefix.prefixlen)


class RaPrefix:
    """ The NAT64 prefix learned from router advertisements. It holds one entry: a different prefix is
        ignored while the current one is valid.
    """

    def __init__(self) -> None:
        self._prefix = None
        self._expiry = 0.0

    def update(self, entries: list[tuple[IPv6Network, int]], now: float, reject: Iterable[IPv6Network] = ()) -> bool:
        """ Apply the PREF64 entries of one accepted advertisement, received at monotonic time now.
            Returns True when the selected prefix changed.
        """
        before = self._prefix
        self.expire(now)                    # an entry whose lifetime has run out is not current any more
        for prefix, lifetime in entries:
            if prefix == self._prefix:
                if lifetime > 0:
                    self._expiry = now + lifetime
                else:
                    self._prefix = None
        if self._prefix is None:
            reject = list(reject)
            usable = [entry for entry in entries if entry[1] > 0 and not overlaps(entry[0], reject)]
            if usable:
                self._prefix, lifetime = min(usable, key=lambda entry: _order(entry[0]))
                self._expiry = now + lifetime
        return self._prefix != before

    def expire(self, now: float) -> bool:
        """ Remove the entry when its lifetime has run out. Returns True when it was removed. """
        if self._prefix is not None and self._expiry <= now:
            self._prefix = None
            return True
        return False

    def current(self) -> tuple[IPv6Network, float] | None:
        """ (prefix, monotonic expiry time), or None. """
        if self._prefix is None:
            return None
        return (self._prefix, self._expiry)


class DnsPrefix:
    """ The NAT64 prefix learned from ipv4only.arpa (RFC 7050) and the time of the next query. """

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        """ Forget the prefix; the next query is due at once. """
        self.prefix: IPv6Network | None = None
        self.next_query = 0.0
        self.failures = 0

    def due(self, now: float) -> bool:
        """ True when a query may be sent. """
        return now >= self.next_query

    def result(self, outcome: tuple, now: float, reject: Iterable[IPv6Network] = ()) -> bool:
        """ Apply one System.dns_aaaa() result: ('answer', [aaaa text, ...], ttl or None) or
            ('fail', reason, None). An answer without a usable prefix drops the prefix; a failure is not an
            answer and keeps it. Returns True when the prefix changed.
        """
        before = self.prefix
        kind, value, ttl = outcome
        if kind == 'answer':
            self.prefix = pref64_from_answer(value, self.prefix, reject)
            self.failures = 0
            wait = max(ttl or 0, DNS_MIN_REFRESH)
            if self.prefix is None:
                wait = min(wait, DNS_NEGATIVE_MAX)
            self.next_query = now + wait
        else:
            self.next_query = now + DNS_RETRY_STEPS[min(self.failures, len(DNS_RETRY_STEPS) - 1)]
            self.failures += 1
        return self.prefix != before
