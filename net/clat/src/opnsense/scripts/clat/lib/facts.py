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

import ipaddress
import json
import re
import struct
from ipaddress import IPv6Address, IPv6Network

from . import discovery
from .plan import Plan, effective_mtu6, parse_prefix_file

# Paths, parsers for what the system prints, the snapshot of facts the supervisor decides on, the native
# IPv4 tests and the preflight rows. All access to the system goes through the System object passed in.

TUN = 'tun464'

SETTINGS = '/usr/local/etc/clat/clatd.json'
TAYGA_CONF = '/usr/local/etc/clat/tayga.conf'
SECRET = '/usr/local/etc/clat/secret'
RUN_DIR = '/var/run/clat'
STATUS = '/var/run/clat/status.json'
MARKER = '/var/run/clat/gateway'
DATA_DIR = '/var/run/clat/empty'
PIDFILE = '/var/run/clat.pid'
ROUTER_FILE = '/tmp/tun464_router'
CONFIG_XML = '/conf/config.xml'
TODO_FILE = '/tmp/.interfaces.todo'
RESOLV_CONF = '/etc/resolv.conf'
TAYGA_BIN = '/usr/local/sbin/tayga'
FACTS_PHP = '/usr/local/opnsense/scripts/clat/facts.php'

# clatd.json as rendered from a configuration without the model node
DEFAULT_SETTINGS = {
    'enabled': True,
    'prefix': '',
    'discover_dns': True,
    'keep_with_native': False,
    'prefix_id': '',
    'address': '',
    'manual_nat': False,
    'ipv4_clat': '192.0.0.1',
    'ipv4_tayga': '192.0.0.2',
    'ipv4_mtu': 1500,
    'ipv6_mtu': 0,
    'udp_cksum': 'calc',
    'test_target': '',
    'log_state': True,
}

TESTED_TAYGA = ('0.9.6',)
PHP_TIMEOUT = 30.0

# routing socket (FreeBSD)
RTM_VERSION = 5
RTM_ROUTE_TYPES = (0x1, 0x2, 0x3)           # RTM_ADD, RTM_DELETE, RTM_CHANGE
RTM_LINK_TYPES = (0xc, 0xd, 0xe, 0x11)      # RTM_NEWADDR, RTM_DELADDR, RTM_IFINFO, RTM_IFANNOUNCE
RTF_LLDATA = 0x400


def parse_settings(text: str | None) -> dict | None:
    """ The content of clatd.json: the defaults, updated with the known keys whose value has the right type.
        None when the text is missing or is not a JSON object.
    """
    try:
        data = json.loads(text or '')
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    settings = dict(DEFAULT_SETTINGS)
    for key, default in DEFAULT_SETTINGS.items():
        if key in data and type(data[key]) is type(default):
            settings[key] = data[key]
    return settings


def parse_route_get(text: str) -> tuple[str, IPv6Address | None] | None:
    """ (interface, gateway) from the output of "route -6 -n get default". The gateway is None for a route
        without one or with one that is not an address (link#9); None when there is no interface line.
    """
    dev = ''
    gateway = None
    for line in text.splitlines():
        key, _, value = line.strip().partition(':')
        if key == 'interface':
            dev = value.strip()
        elif key == 'gateway':
            try:
                gateway = discovery.ll_norm(value.strip())
            except ValueError:
                gateway = None
    return (dev, gateway) if dev else None


def _after(tokens: list[str], word: str) -> str | None:
    """ The token that follows word, None when there is none. """
    if word in tokens[:-1]:
        return tokens[tokens.index(word) + 1]
    return None


def _masklen(token: str | None) -> int | None:
    """ Prefix length of a hexadecimal netmask as ifconfig prints it (0xffffff00). """
    try:
        return bin(int(token, 16)).count('1')
    except (TypeError, ValueError):
        return None


def parse_ifconfig(text: str) -> dict[str, dict]:
    """ The output of "ifconfig -a", per device: 'mtu' (int or None), 'flags' (set of names), 'inet' (list of
        (address, peer or None, mask length or None)), 'inet6' (list of (address without zone, prefix length
        or None)) and 'opened_by' (pid holding a tun open, or None). Addresses are text.
    """
    devices = {}
    info = None
    for line in text.splitlines():
        tokens = line.split()
        if not tokens:
            continue
        if not line[0].isspace() and 'flags=' in line:
            names = re.search(r'<([^>]*)>', line)
            mtu = re.search(r' mtu (\d+)', line)
            info = {
                'mtu': int(mtu.group(1)) if mtu else None,
                'flags': set(names.group(1).split(',')) - {''} if names else set(),
                'inet': [],
                'inet6': [],
                'opened_by': None,
            }
            devices[line.split(':', 1)[0]] = info
        elif info is None or len(tokens) < 2:
            continue
        elif tokens[0] == 'inet':
            peer = tokens[3] if len(tokens) > 3 and tokens[2] == '-->' else None
            info['inet'].append((tokens[1], peer, _masklen(_after(tokens, 'netmask'))))
        elif tokens[0] == 'inet6':
            plen = _after(tokens, 'prefixlen')
            info['inet6'].append((tokens[1].split('%')[0], int(plen) if plen and plen.isdigit() else None))
        elif tokens[:3] == ['Opened', 'by', 'PID'] and tokens[3:] and tokens[3].isdigit():
            info['opened_by'] = int(tokens[3])
    return devices


def parse_ndp(text: str) -> tuple[int, int] | None:
    """ (linkmtu, maxmtu) from the output of "ndp -i <dev>"; linkmtu is 0 when no RA MTU was accepted. """
    match = re.search(r'linkmtu=(\d+), maxmtu=(\d+)', text)
    return (int(match.group(1)), int(match.group(2))) if match else None


def first_nameserver(text: str | None) -> str | None:
    """ The first nameserver in the content of resolv.conf. """
    for line in (text or '').splitlines():
        tokens = line.split()
        if len(tokens) >= 2 and tokens[0] == 'nameserver':
            return tokens[1]
    return None


def rtm_relevant(buf: bytes) -> bool:
    """ True when one buffer read from the routing socket holds a message that can change a fact: an address,
        interface or route change. Replies to "route get" (which reach every listener, also for the
        daemon's own command) and neighbour entries (RTF_LLDATA) are not. Never raises.
    """
    off = 0
    while off + 4 <= len(buf):
        msglen, version, mtype = struct.unpack_from('=HBB', buf, off)
        if msglen < 4:
            break
        if version == RTM_VERSION:
            if mtype in RTM_LINK_TYPES:
                return True
            if mtype in RTM_ROUTE_TYPES and off + 12 <= len(buf):
                if not struct.unpack_from('=i', buf, off + 8)[0] & RTF_LLDATA:
                    return True
        off += msglen
    return False


def _line(raw: bytes, limit: int) -> str:
    """ One line of child output as text. """
    return raw.rstrip(b'\r').decode('utf-8', errors='replace')[:limit]


def split_lines(pending: bytes, chunk: bytes, limit: int = 1024) -> tuple[list[str], bytes]:
    """ Output read from the pty to lines. Returns the complete lines (without line end, at most limit
        characters each) and the unfinished rest, which is passed back as pending with the next chunk. A rest
        longer than limit bytes is returned as a line instead, so that nothing accumulates.
    """
    parts = (pending + chunk).split(b'\n')
    rest = parts.pop()
    lines = [_line(part, limit) for part in parts]
    if len(rest) > limit:
        lines.append(_line(rest, limit))
        rest = b''
    return lines, rest


def native_gateways(gw: dict) -> list[str]:
    """ Names of the IPv4 gateways that make the box have native IPv4: enabled, not on the tun or on a tunnel
        device, on a device with an IPv4 address, and marked upstream, at priority 254 or lower, or selected
        in the settings of their interface.
    """
    names = []
    for item in gw['list']:
        if item['if'] == TUN or item['disabled'] or item['tunnel'] or not item['if_has_ipv4']:
            continue
        if item['upstream'] or item['priority'] <= 254 or item['selected']:
            names.append(item['name'])
    return names


def stale_gateways(gw: dict) -> list[str]:
    """ Names of the IPv4 gateways that core ranks above the CLAT gateway although their device has no IPv4
        address: with them core installs no IPv4 default route at all.
    """
    names = []
    for item in gw['list']:
        if item['if'] == TUN or item['disabled'] or item['defunct'] or not item['gateway'] or item['if_has_ipv4']:
            continue
        if item['upstream'] or item['priority'] < 254:
            names.append(item['name'])
    return names


def gateway_report(gw: dict) -> tuple[str, str]:
    """ (code, message) for the IPv4 default gateway core selects; the code is 'default' when it is the
        CLAT gateway, else 'none', 'not_default' or 'stale'.
    """
    default = gw['default']
    if not default:
        return ('none', 'no IPv4 default gateway is selected')
    if default['if'] == TUN:
        return ('default', 'active')
    if default['if_has_ipv4']:
        return ('not_default', 'active, but not the IPv4 default: gateway %s is preferred' % default['name'])
    return ('stale', 'a stale gateway %s on an interface without IPv4 blocks any default route' % default['name'])


def _row(ident: str, effect: str, message: str) -> dict:
    """ One preflight row. """
    return {'id': ident, 'effect': effect, 'message': message}


def _is_number(value) -> bool:
    """ True for a JSON number (and not for true or false). """
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _configured_mtu(facts) -> int | None:
    """ The MTU of the configured uplink as core derives it, lowered by the IPv6 MTU override. """
    uplink = facts.cfg['uplink'] if facts.cfg else None
    if not uplink or not _is_number(uplink['mtu']):
        return None
    override = facts.settings['ipv6_mtu']
    return min(uplink['mtu'], override) if override else uplink['mtu']


def preflight(facts, sysif, tayga_version: str | None = None) -> list[dict]:
    """ The preflight rows that apply: {'id', 'effect' ('block' or 'warn'), 'message'}; an empty list means
        nothing to report. A row whose facts are not known (config facts, gateway facts, runtime uplink,
        tayga version) is left out.
    """
    rows = []
    settings, cfg, gw = facts.settings, facts.cfg, facts.gw
    uplink = cfg['uplink'] if cfg else None
    ppp_ipv4 = bool(uplink and uplink['ppp'] and uplink['ipv4_ppp'])
    native = ppp_ipv4 and facts.uplink_native(sysif)

    if sysif.stat(TAYGA_BIN) is None:
        rows.append(_row('tayga_missing', 'block', 'The tayga package is not installed.'))
    if ppp_ipv4 and not native:
        message = 'IPv6 cannot start with this setting. Set WAN IPv4 Configuration Type to None.'
        rows.append(_row('wan_ipv4_ppp', 'block', message))
    if cfg and cfg['nat_mode'] in ('advanced', 'disabled') and not settings['manual_nat']:
        message = (
            'Outbound NAT mode is %s. Select automatic or hybrid mode, or add an outbound NAT rule on the CLAT '
            'interface and confirm that you manage outbound NAT yourself.'
        )
        rows.append(_row('nat_mode', 'block', message % cfg['nat_mode']))
    if settings['prefix']:
        try:
            prefix = ipaddress.IPv6Network(settings['prefix'], strict=False)
        except ValueError:
            prefix = None
        if prefix is not None and discovery.overlaps(prefix, facts.local_networks(sysif)):
            message = 'The NAT64 prefix %s overlaps a local IPv6 prefix.'
            rows.append(_row('pref64_overlap', 'block', message % prefix))
    stale = stale_gateways(gw) if gw else []
    if stale:
        message = (
            'Gateway %s is on an interface without an IPv4 address and outranks the CLAT gateway; core would '
            'install no IPv4 default route. Disable it.'
        )
        rows.append(_row('stale_gateway', 'block', message % stale[0]))

    if ppp_ipv4 and native:
        message = (
            'If the ISP stops offering IPv4 on this line, IPv6 will not start either and the CLAT cannot take '
            'over. Set IPv4 to None first.'
        )
        rows.append(_row('wan_ipv4_ppp_native', 'warn', message))
    if cfg and cfg['scrub'] is False:
        message = 'Firewall normalisation is disabled; no TCP MSS clamp is active.'
        rows.append(_row('scrub_disabled', 'warn', message))
    if uplink and _is_number(uplink['mss']):
        message = 'The uplink interface has its own MSS value (%d); it also clamps the translated flows.'
        rows.append(_row('wan_mss', 'warn', message % uplink['mss']))
    configured, effective = _configured_mtu(facts), facts.mtu6()
    if configured is not None and effective is not None and configured != effective:
        message = 'The configured uplink MTU (%d) differs from the effective IPv6 MTU (%d).'
        rows.append(_row('mtu_mismatch', 'warn', message % (configured, effective)))
    if uplink and facts.route6 and uplink['if'] != facts.route6[0]:
        message = (
            'The configured uplink (%s) is not the interface that holds the IPv6 default route (%s). Choose the '
            'uplink explicitly.'
        )
        rows.append(_row('uplink_mismatch', 'warn', message % (uplink['if'], facts.route6[0])))
    for item in gw['leftover'] if gw else []:
        message = 'Gateway %s has no address any more but is still used (%s).'
        rows.append(_row('leftover_gateway', 'warn', message % (item['name'], ', '.join(item['refs']))))
    if tayga_version and re.split('[_,]', tayga_version)[0] not in TESTED_TAYGA:
        message = 'tayga %s is installed; the plugin was tested with %s.'
        rows.append(_row('tayga_version', 'warn', message % (tayga_version, ', '.join(TESTED_TAYGA))))
    return rows


def _helper(sysif, member: str) -> dict | None:
    """ One member ('config' or 'gateways') of what facts.php prints; None when the helper fails. """
    code, out, _err = sysif.run([FACTS_PHP, member], timeout=PHP_TIMEOUT)
    if code != 0:
        return None
    try:
        data = json.loads(out)
    except ValueError:
        return None
    if not isinstance(data, dict) or not isinstance(data.get(member), dict):
        return None
    return data[member]


class Facts:
    """ Snapshot of what is known about the box. The attributes are plain data:
        settings   clatd.json (starts as the defaults)
        cfg        'config' object of facts.php, or None; cfg_stat is the config.xml stat it was read at
        route6     (device, default router or None) of the IPv6 default route, or None: the runtime uplink
        ifaces     last parse_ifconfig() result
        ndp        (linkmtu, maxmtu) of the uplink, or None
        gw         'gateways' object of facts.php, or None
    """

    def __init__(self) -> None:
        self.settings = dict(DEFAULT_SETTINGS)
        self.cfg = None
        self.cfg_stat = None
        self.route6 = None
        self.ifaces = {}
        self.ndp = None
        self.gw = None

    def load_settings(self, sysif) -> bool:
        """ Read clatd.json. On failure the old settings are kept and the result is False. """
        settings = parse_settings(sysif.read(SETTINGS))
        if settings is None:
            return False
        self.settings = settings
        return True

    def refresh_config(self, sysif, force: bool = False) -> bool:
        """ Ask facts.php for the config facts when config.xml is not the file they were read from, or when
            forced. When the helper fails the old facts and their stat are kept, so the next call asks
            again. Returns True when the helper ran.
        """
        stat = sysif.stat(CONFIG_XML)
        if not force and stat == self.cfg_stat:
            return False
        cfg = _helper(sysif, 'config')
        if cfg is not None:
            self.cfg = cfg
            self.cfg_stat = stat
        return True

    def refresh_link(self, sysif) -> None:
        """ Runtime uplink (the IPv6 default route) and the interfaces of the box: two commands. A default
            route on a device that is not up is no uplink: when a PPP session ends, mpd5 takes the device
            down and the route stays in the table until the next session.
        """
        code, out, _err = sysif.run(['/sbin/route', '-6', '-n', 'get', 'default'])
        if code not in (124, 127):
            # 124 and 127: the command did not run to an answer, which says nothing about the route
            self.route6 = parse_route_get(out) if code == 0 else None
        code, out, _err = sysif.run(['/sbin/ifconfig', '-a'])
        if code == 0:
            self.ifaces = parse_ifconfig(out)
        if self.route6 and 'UP' not in self.ifaces.get(self.route6[0], {}).get('flags', ()):
            self.route6 = None

    def refresh_activation(self, sysif) -> bool:
        """ The facts needed only once everything else allows an activation: the RA MTU of the uplink and
            core's gateway list. Returns False (and forgets the gateway facts) when the helper fails.
        """
        dev = self.uplink_dev()
        self.ndp = None
        if dev is not None:
            code, out, _err = sysif.run(['/usr/sbin/ndp', '-i', dev])
            if code == 0:
                self.ndp = parse_ndp(out)
        self.gw = _helper(sysif, 'gateways')
        return self.gw is not None

    def drop_activation(self) -> None:
        """ Forget the activation facts. """
        self.ndp = self.gw = None

    def uplink_dev(self) -> str | None:
        """ Device of the runtime uplink. """
        return self.route6[0] if self.route6 else None

    def uplink_router(self) -> IPv6Address | None:
        """ Default router on the runtime uplink. """
        return self.route6[1] if self.route6 else None

    def uplink_native(self, sysif) -> bool:
        """ True when the uplink itself has native IPv4: a non-empty IPv4 router file or an IPv4 address that
            is not link-local. Tested on the runtime uplink, without one on the configured uplink.
        """
        dev = self.uplink_dev()
        if dev is None and self.cfg and self.cfg['uplink']:
            dev = self.cfg['uplink']['if']
        if not dev:
            return False
        if (sysif.read('/tmp/%s_router' % dev) or '').strip():
            return True
        for entry in self.ifaces.get(dev, {}).get('inet', ()):
            try:
                if not ipaddress.IPv4Address(entry[0]).is_link_local:
                    return True
            except ValueError:
                continue
        return False

    def delegated(self, sysif) -> IPv6Network | None:
        """ The delegated prefix of the runtime uplink, from core's prefix file. """
        dev = self.uplink_dev()
        if dev is None:
            return None
        return parse_prefix_file(sysif.read('/tmp/%s_prefixv6' % dev))

    def claims(self) -> list[int]:
        """ The /64 indexes that interfaces claim in the delegation of the runtime uplink. """
        if not self.cfg:
            return []
        return list(self.cfg['interfaces'].get(self.uplink_dev(), {}).get('claims', ()))

    def local_networks(self, sysif) -> list[IPv6Network]:
        """ The IPv6 networks a NAT64 prefix must not overlap: the delegated prefix, the networks of the
            uplink's own addresses (link-local ones left out) and the static IPv6 networks of the box.
        """
        networks = []
        delegated = self.delegated(sysif)
        if delegated is not None:
            networks.append(delegated)
        for entry in self.ifaces.get(self.uplink_dev(), {}).get('inet6', ()):
            addr, plen = entry[0], entry[1]
            try:
                if not ipaddress.IPv6Address(addr).is_link_local:
                    networks.append(ipaddress.IPv6Network((addr, 128 if plen is None else plen), strict=False))
            except ValueError:
                continue
        for text in self.cfg['static_v6'] if self.cfg else ():
            try:
                networks.append(ipaddress.IPv6Network(text, strict=False))
            except ValueError:
                continue
        return networks

    def addresses6(self) -> set[IPv6Address]:
        """ Every IPv6 address configured on the box. """
        found = set()
        for info in self.ifaces.values():
            for entry in info.get('inet6', ()):
                try:
                    found.add(ipaddress.IPv6Address(entry[0]))
                except ValueError:
                    continue
        return found

    def mtu6(self) -> int | None:
        """ The effective IPv6 MTU of the runtime uplink, lowered by the IPv6 MTU override; None when the
            device MTU is unknown.
        """
        mtu = self.ifaces.get(self.uplink_dev(), {}).get('mtu')
        if mtu is None:
            return None
        mtu = effective_mtu6(mtu, *(self.ndp or (0, 0)))
        override = self.settings['ipv6_mtu']
        return min(mtu, override) if override else mtu

    def tun_ok(self, plan: Plan, pid: int | None) -> bool:
        """ True when the tun has the IPv4 addresses of the plan with a /32 mask and is held open by pid. """
        tun = self.ifaces.get(TUN, {})
        wanted = (plan.ipv4_clat, plan.ipv4_tayga, 32)
        return any(tuple(entry) == wanted for entry in tun.get('inet', ())) and tun.get('opened_by') == pid
