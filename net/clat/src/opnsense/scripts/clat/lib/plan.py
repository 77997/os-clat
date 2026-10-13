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

import hashlib
import ipaddress
from collections.abc import Iterable
from dataclasses import dataclass
from ipaddress import IPv6Address, IPv6Network

# What the translator runs with: the address pair, the MTU values and tayga.conf. Nothing in this module
# touches the operating system.


@dataclass(frozen=True)
class Plan:
    """ Everything tayga is started with. Two plans are equal exactly when tayga needs no restart. """
    pref64: IPv6Network
    clat6: IPv6Address      # even address of the /127: "map <ipv4_clat> <clat6>"
    tayga6: IPv6Address     # odd address: "ipv6-addr"
    ipv4_clat: str
    ipv4_tayga: str
    tun_mtu: int
    offlink_mtu: int
    udp_cksum: str          # calc | drop | forward

    @property
    def ipv4_mtu(self) -> int:
        """ The IPv4 MTU presented to the LAN. """
        return self.offlink_mtu - 20

    @property
    def pair(self) -> str:
        """ The /127 that holds both IPv6 addresses, as text. """
        return '%s/127' % self.clat6


class PlanError(Exception):
    """ No plan can be made; code is 'uplink_mtu', 'prefix_id' or 'address'. """

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def effective_mtu6(if_mtu: int, linkmtu: int, maxmtu: int) -> int:
    """ The IPv6 MTU of a link as the kernel computes it (IN6_LINKMTU): the MTU learned from router
        advertisements when it is set and below the device MTU, else the smaller of maxmtu and the device MTU.
    """
    if linkmtu and linkmtu < if_mtu:
        return linkmtu
    if maxmtu and maxmtu < if_mtu:
        return maxmtu
    return if_mtu


def clat_mtus(m: int, v: int = 1500) -> tuple[int, int, int]:
    """ (tun MTU, tayga offlink-mtu, IPv4 MTU presented) for the uplink IPv6 MTU m and the IPv4 MTU v. """
    tun = min(m, v + 28)
    off = min(tun, v + 20)
    return (tun, off, off - 20)


def parse_prefix_file(text: str | None) -> IPv6Network | None:
    """ The delegated prefix in the content of /tmp/<dev>_prefixv6: the first line that is a prefix of at
        most 64 bits. None for missing, empty or unusable content.
    """
    for line in (text or '').splitlines():
        try:
            prefix = ipaddress.IPv6Network(line.strip(), strict=False)
        except ValueError:
            continue
        if prefix.prefixlen <= 64:
            return prefix
    return None


def choose_subnet(delegated: IPv6Network, claims: Iterable[int], prefix_id: str = '') -> IPv6Network:
    """ The /64 of the delegated prefix for the CLAT addresses: the one with index prefix_id (hexadecimal)
        when given, else the highest one that no interface claims, else the highest one.
    """
    count = 2 ** (64 - delegated.prefixlen)
    if prefix_id:
        try:
            index = int(prefix_id, 16)
        except ValueError:
            raise PlanError('prefix_id') from None
        if not 0 <= index < count:
            raise PlanError('prefix_id')
    else:
        claimed = set(claims)
        index = count - 1
        while index >= 0 and index in claimed:
            index -= 1
        if index < 0:
            index = count - 1
    return ipaddress.IPv6Network((int(delegated.network_address) + (index << 64), 64))


def iid_excluded(iid: int) -> bool:
    """ True for interface identifiers that are not used: all-zero and small fixed values, and the reserved
        anycast range of RFC 5453.
    """
    return iid < 0x10000 or 0xFDFFFFFFFFFFFF80 <= iid <= 0xFDFFFFFFFFFFFFFF


def interface_id(subnet: IPv6Network, secret: bytes, in_use: Iterable[IPv6Address] = ()) -> int:
    """ The even interface identifier of the address pair in subnet: a stable hash of the /64 and the
        secret, hashed again while one of the two addresses is excluded or already on the box.
    """
    taken = set(in_use)
    base = subnet.network_address
    for counter in range(256):
        digest = hashlib.sha256(secret + base.packed[:8] + bytes([counter])).digest()
        iid = int.from_bytes(digest[:8], 'big') & ~1
        if iid_excluded(iid) or iid_excluded(iid | 1):
            continue
        if base + iid in taken or base + (iid | 1) in taken:
            continue
        return iid
    raise PlanError('address')


def make_plan(settings: dict, pref64: IPv6Network, delegated: IPv6Network, claims: Iterable[int], secret: bytes,
              in_use: Iterable[IPv6Address], mtu6: int | None) -> Plan:
    """ The plan for these settings and facts. Raises PlanError when the uplink IPv6 MTU is unknown or below
        1280, the prefix ID does not fit in the delegated prefix or the address pair cannot be used.
    """
    if mtu6 is None or mtu6 < 1280:
        raise PlanError('uplink_mtu')
    if settings['address']:
        try:
            clat6 = ipaddress.IPv6Address(int(ipaddress.IPv6Address(settings['address'])) & ~1)
        except ValueError:
            raise PlanError('address') from None
    else:
        subnet = choose_subnet(delegated, claims, settings['prefix_id'])
        clat6 = subnet.network_address + interface_id(subnet, secret, in_use)
    if ipaddress.IPv6Network((int(clat6), 127)).overlaps(pref64):
        raise PlanError('address')
    tun_mtu, offlink_mtu, _ipv4_mtu = clat_mtus(mtu6, settings['ipv4_mtu'])
    return Plan(pref64=pref64, clat6=clat6, tayga6=clat6 + 1, ipv4_clat=settings['ipv4_clat'],
                ipv4_tayga=settings['ipv4_tayga'], tun_mtu=tun_mtu, offlink_mtu=offlink_mtu,
                udp_cksum=settings['udp_cksum'])


def tayga_conf(plan: Plan, data_dir: str) -> str:
    """ The content of tayga.conf: eight directives, all of which exist in tayga 0.9.6. """
    lines = (
        'tun-device tun464',
        'ipv4-addr %s' % plan.ipv4_tayga,
        'ipv6-addr %s' % plan.tayga6,
        'prefix %s' % plan.pref64,
        'map %s %s' % (plan.ipv4_clat, plan.clat6),
        'udp-cksum-mode %s' % plan.udp_cksum,
        'offlink-mtu %d' % plan.offlink_mtu,
        'data-dir %s' % data_dir,
    )
    return '\n'.join(lines) + '\n'


def tayga_argv(conf: str) -> list[str]:
    """ The command line of the supervised tayga: foreground, logging to its standard output, chrooted to
        data-dir and running as nobody.
    """
    return ['/usr/local/sbin/tayga', '-c', conf, '--nodetach', '--stdout', '-u', 'nobody', '-g', 'nobody', '-r']
