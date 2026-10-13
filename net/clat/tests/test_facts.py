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

import copy
import json
import os
import struct
import sys
import unittest
from ipaddress import IPv6Address, IPv6Network

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'opnsense', 'scripts', 'clat'))

from lib import facts  # noqa: E402
from lib.plan import Plan  # noqa: E402

ROUTE_GET = (
    '   route to: ::\n'
    'destination: ::\n'
    '       mask: ::\n'
    '    gateway: fe80::2a0:a5ff:fe12:3456%pppoe0\n'
    '        fib: 0\n'
    '  interface: pppoe0\n'
    '      flags: <UP,GATEWAY,DONE,STATIC>\n'
    ' recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire\n'
    '       0         0         0         0      1492         1         0\n'
)

IFCONFIG = (
    'igc1: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500\n'
    '\tdescription: LAN (lan)\n'
    '\toptions=4802028<VLAN_MTU,JUMBO_MTU,WOL_MAGIC,HWSTATS,MEXTPG>\n'
    '\tether 00:a0:a5:12:34:57\n'
    '\tinet 192.168.1.1 netmask 0xffffff00 broadcast 192.168.1.255\n'
    '\tinet6 fe80::2a0:a5ff:fe12:3457%igc1 prefixlen 64 scopeid 0x2\n'
    '\tinet6 2001:db8:1200::1 prefixlen 64\n'
    '\tmedia: Ethernet autoselect (1000baseT <full-duplex>)\n'
    '\tstatus: active\n'
    '\tnd6 options=21<PERFORMNUD,AUTO_LINKLOCAL>\n'
    'pppoe0: flags=88d1<UP,POINTOPOINT,RUNNING,NOARP,SIMPLEX,MULTICAST> metric 0 mtu 1492\n'
    '\tdescription: WAN (wan)\n'
    '\tinet6 fe80::2a0:a5ff:fe12:3456%pppoe0 prefixlen 64 scopeid 0x8\n'
    '\tinet6 2001:db8:ffff:1:2a0:a5ff:fe12:3456 prefixlen 64 autoconf pltime 14400 vltime 86400\n'
    '\tnd6 options=23<PERFORMNUD,ACCEPT_RTADV,AUTO_LINKLOCAL>\n'
    'tun464: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> metric 0 mtu 1492\n'
    '\tdescription: CLAT (clat)\n'
    '\toptions=80000<LINKSTATE>\n'
    '\tinet 192.0.0.1 --> 192.0.0.2 netmask 0xffffffff\n'
    '\tinet6 fe80::2a0:a5ff:fe12:3456%tun464 prefixlen 64 scopeid 0x9\n'
    '\tgroups: tun\n'
    '\tnd6 options=21<PERFORMNUD,AUTO_LINKLOCAL>\n'
    '\tOpened by PID 4242\n'
)

NDP = (
    'linkmtu=1480, maxmtu=1492, curhlim=64, basereachable=30s0ms, reachable=22s, retrans=1s0ms\n'
    'Flags: nud accept_rtadv auto_linklocal\n'
)

CONFIG = {
    'uplink': {'key': 'wan', 'if': 'pppoe0', 'ppp': True, 'ipv4_ppp': False, 'mtu': 1492, 'mss': None},
    'mss': 1492,
    'nat_mode': 'automatic',
    'scrub': True,
    'record_ok': True,
    'interfaces': {'pppoe0': {'key': 'wan', 'claims': [0]}, 'igc1': {'key': 'lan', 'claims': []}},
    'static_v6': ['2001:db8:5::1/64'],
}

ROUTER = IPv6Address('fe80::2a0:a5ff:fe12:3456')
ROUTE_CMD = ['/sbin/route', '-6', '-n', 'get', 'default']
IFCONFIG_CMD = ['/sbin/ifconfig', '-a']
NDP_CMD = ['/usr/sbin/ndp', '-i', 'pppoe0']
CONFIG_CMD = [facts.FACTS_PHP, 'config']
GATEWAYS_CMD = [facts.FACTS_PHP, 'gateways']


def gateway(name, **changes):
    """ One record of the gateway list of facts.php: a static gateway that nothing selects. """
    item = {
        'name': name, 'interface': 'opt1', 'if': 'igc2', 'gateway': '198.51.100.1', 'priority': 255,
        'upstream': False, 'disabled': False, 'defunct': False, 'dynamic': False, 'selected': False,
        'tunnel': False, 'if_has_ipv4': True,
    }
    item.update(changes)
    return item


def gateways(*items, default=None, fallback=None, leftover=()):
    return {'default': default, 'fallback': fallback, 'list': list(items), 'leftover': list(leftover)}


CLAT_GW = gateway('CLAT_GW', interface='clat', priority=254, dynamic=True, **{'if': 'tun464', 'gateway': '192.0.0.2'})


class Stub:
    """ The part of System that facts.py uses: read, stat and run. """

    def __init__(self, files=None, replies=None):
        self.files = dict(files or {})
        self.stats = {}
        self.replies = {tuple(argv): reply for argv, reply in (replies or [])}
        self.commands = []
        self.timeouts = []

    def read(self, path):
        return self.files.get(path)

    def stat(self, path):
        if path in self.stats:
            return self.stats[path]
        return (1, len(self.files[path]), 1) if path in self.files else None

    def run(self, argv, timeout=10.0):
        for arg in argv:
            if not isinstance(arg, str):
                raise TypeError('expected str, not %s' % type(arg).__name__)
        self.commands.append(list(argv))
        self.timeouts.append(timeout)
        return self.replies.get(tuple(argv), (0, '', ''))


def world(**cfg_changes):
    """ Facts of a box with a PPPoE uplink, IPv6 only, and the tools that are always there. """
    known = facts.Facts()
    known.cfg = copy.deepcopy(CONFIG)
    known.cfg.update(cfg_changes)
    known.route6 = ('pppoe0', ROUTER)
    known.ifaces = facts.parse_ifconfig(IFCONFIG)
    sysif = Stub({facts.TAYGA_BIN: 'x', '/tmp/pppoe0_prefixv6': '2001:db8:1200::/56\n'})
    return known, sysif


def ids(rows):
    return [row['id'] for row in rows]


class ConstantsTest(unittest.TestCase):
    def test_default_settings_are_the_rendered_defaults(self):
        # the example of SPEC 3.3: clatd.json rendered from a configuration without the model node
        rendered = json.loads(
            '{"enabled": true, "prefix": "", "discover_dns": true, "keep_with_native": false, "prefix_id": "",'
            ' "address": "", "manual_nat": false, "ipv4_clat": "192.0.0.1", "ipv4_tayga": "192.0.0.2",'
            ' "ipv4_mtu": 1500, "ipv6_mtu": 0, "udp_cksum": "calc", "test_target": "", "log_state": true}'
        )
        self.assertEqual(facts.DEFAULT_SETTINGS, rendered)
        self.assertEqual(list(facts.DEFAULT_SETTINGS), list(rendered))


class ParseSettingsTest(unittest.TestCase):
    def test_defaults(self):
        settings = facts.parse_settings('{}')
        self.assertEqual(settings, facts.DEFAULT_SETTINGS)
        self.assertIsNot(settings, facts.DEFAULT_SETTINGS)

    def test_values(self):
        text = json.dumps({'enabled': False, 'prefix': '64:ff9b::/96', 'ipv4_mtu': 1400, 'ipv6_mtu': 1480,
                           'udp_cksum': 'drop', 'test_target': '198.51.100.7', 'log_state': False})
        settings = facts.parse_settings(text)
        self.assertIs(settings['enabled'], False)
        self.assertEqual(settings['prefix'], '64:ff9b::/96')
        self.assertEqual((settings['ipv4_mtu'], settings['ipv6_mtu']), (1400, 1480))
        self.assertEqual(settings['udp_cksum'], 'drop')
        self.assertEqual(settings['test_target'], '198.51.100.7')
        self.assertIs(settings['log_state'], False)
        self.assertEqual(settings['ipv4_clat'], '192.0.0.1')

    def test_wrong_types(self):
        text = json.dumps({'enabled': 'yes', 'manual_nat': 1, 'prefix': 5, 'ipv4_mtu': '1400', 'ipv6_mtu': True,
                           'udp_cksum': None, 'ipv4_clat': ['192.0.0.4'], 'address': '2001:db8::10', 'more': 1})
        settings = facts.parse_settings(text)
        expected = dict(facts.DEFAULT_SETTINGS, address='2001:db8::10')
        self.assertEqual(settings, expected)
        self.assertEqual([type(settings[key]) for key in expected], [type(value) for value in expected.values()])

    def test_invalid(self):
        for text in (None, '', '{', 'enabled', '[1, 2]', '"text"', '5', 'null'):
            self.assertIsNone(facts.parse_settings(text), text)


class ParseRouteGetTest(unittest.TestCase):
    def test_with_zone(self):
        self.assertEqual(facts.parse_route_get(ROUTE_GET), ('pppoe0', ROUTER))

    def test_without_zone(self):
        self.assertEqual(facts.parse_route_get(ROUTE_GET.replace('%pppoe0', '')), ('pppoe0', ROUTER))

    def test_embedded_zone(self):
        text = ROUTE_GET.replace('fe80::2a0', 'fe80:8::2a0')
        self.assertEqual(facts.parse_route_get(text), ('pppoe0', ROUTER))

    def test_without_gateway_line(self):
        lines = [line for line in ROUTE_GET.splitlines() if 'gateway:' not in line]
        self.assertEqual(facts.parse_route_get('\n'.join(lines) + '\n'), ('pppoe0', None))

    def test_gateway_is_not_an_address(self):
        text = ROUTE_GET.replace('fe80::2a0:a5ff:fe12:3456%pppoe0', 'link#9')
        self.assertEqual(facts.parse_route_get(text), ('pppoe0', None))

    def test_no_interface(self):
        self.assertIsNone(facts.parse_route_get(''))
        self.assertIsNone(facts.parse_route_get('    gateway: fe80::1%pppoe0\n'))
        self.assertIsNone(facts.parse_route_get('route: route has not been found\n'))


class ParseIfconfigTest(unittest.TestCase):
    def setUp(self):
        self.ifaces = facts.parse_ifconfig(IFCONFIG)

    def test_devices(self):
        self.assertEqual(list(self.ifaces), ['igc1', 'pppoe0', 'tun464'])
        for info in self.ifaces.values():
            self.assertEqual(sorted(info), ['flags', 'inet', 'inet6', 'mtu', 'opened_by'])

    def test_header(self):
        self.assertEqual(self.ifaces['igc1']['mtu'], 1500)
        self.assertEqual(self.ifaces['pppoe0']['mtu'], 1492)
        self.assertEqual(self.ifaces['tun464']['flags'], {'UP', 'POINTOPOINT', 'RUNNING', 'MULTICAST'})

    def test_inet(self):
        self.assertEqual(self.ifaces['igc1']['inet'], [('192.168.1.1', None, 24)])
        self.assertEqual(self.ifaces['pppoe0']['inet'], [])
        self.assertEqual(self.ifaces['tun464']['inet'], [('192.0.0.1', '192.0.0.2', 32)])

    def test_inet6(self):
        self.assertEqual(self.ifaces['igc1']['inet6'], [('fe80::2a0:a5ff:fe12:3457', 64), ('2001:db8:1200::1', 64)])
        self.assertEqual(self.ifaces['pppoe0']['inet6'],
                         [('fe80::2a0:a5ff:fe12:3456', 64), ('2001:db8:ffff:1:2a0:a5ff:fe12:3456', 64)])
        self.assertEqual(self.ifaces['tun464']['inet6'], [('fe80::2a0:a5ff:fe12:3456', 64)])

    def test_opened_by(self):
        self.assertEqual(self.ifaces['tun464']['opened_by'], 4242)
        self.assertIsNone(self.ifaces['pppoe0']['opened_by'])

    def test_point_to_point_without_mask(self):
        text = (
            'tun464: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> metric 0 mtu 1500\n'
            '\tinet 192.0.0.1 --> 192.0.0.2 netmask 0x0\n'
            '\tinet6 2001:db8::1 --> 2001:db8::2 prefixlen 128\n'
        )
        info = facts.parse_ifconfig(text)['tun464']
        self.assertEqual(info['inet'], [('192.0.0.1', '192.0.0.2', 0)])
        self.assertEqual(info['inet6'], [('2001:db8::1', 128)])
        self.assertIsNone(info['opened_by'])

    def test_indented_flags_lines_start_no_device(self):
        # bridge members and lagg ports are printed with their own flags= on an indented line; what follows
        # such a line still belongs to the device
        text = (
            'bridge0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500\n'
            '\tether 58:9c:fc:00:00:01\n'
            '\tinet 192.168.1.1 netmask 0xffffff00 broadcast 192.168.1.255\n'
            '\tid 00:00:00:00:00:00 priority 32768 hellotime 2 fwddelay 15\n'
            '\tmember: igc1 flags=143<LEARNING,DISCOVER,AUTOEDGE,AUTOPTP>\n'
            '\t        ifmaxaddr 0 port 2 priority 128 path cost 20000\n'
            '\tinet6 2001:db8:1200::1 prefixlen 64\n'
            '\tgroups: bridge\n'
            'lagg0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500\n'
            '\tlaggproto lacp lagghash l2,l3,l4\n'
            '\tlaggport: igc2 flags=1c<ACTIVE,COLLECTING,DISTRIBUTING>\n'
            '\tlaggport: igc3 flags=1c<ACTIVE,COLLECTING,DISTRIBUTING>\n'
            '\tinet 198.51.100.2 netmask 0xfffffffc broadcast 198.51.100.3\n'
            '\tgroups: lagg\n'
        )
        ifaces = facts.parse_ifconfig(text)
        self.assertEqual(list(ifaces), ['bridge0', 'lagg0'])
        self.assertEqual(ifaces['bridge0']['flags'], {'UP', 'BROADCAST', 'RUNNING', 'SIMPLEX', 'MULTICAST'})
        self.assertEqual(ifaces['bridge0']['mtu'], 1500)
        self.assertEqual(ifaces['bridge0']['inet'], [('192.168.1.1', None, 24)])
        self.assertEqual(ifaces['bridge0']['inet6'], [('2001:db8:1200::1', 64)])
        self.assertEqual(ifaces['lagg0']['flags'], {'UP', 'BROADCAST', 'RUNNING', 'SIMPLEX', 'MULTICAST'})
        self.assertEqual(ifaces['lagg0']['inet'], [('198.51.100.2', None, 30)])

    def test_odd_input(self):
        self.assertEqual(facts.parse_ifconfig(''), {})
        self.assertEqual(facts.parse_ifconfig('\tinet 192.0.2.1 netmask 0xffffff00\n'), {})
        text = (
            'lo0: flags=0<> metric 0\n'
            '\tinet 127.0.0.1\n'
            '\tinet 192.0.2.1 netmask garbage\n'
            '\tinet6 ::1 prefixlen\n'
            '\tinet\n'
            '\tOpened by PID\n'
        )
        self.assertEqual(facts.parse_ifconfig(text), {'lo0': {
            'mtu': None, 'flags': set(), 'inet': [('127.0.0.1', None, None), ('192.0.2.1', None, None)],
            'inet6': [('::1', None)], 'opened_by': None,
        }})


class SmallParsersTest(unittest.TestCase):
    def test_parse_ndp(self):
        self.assertEqual(facts.parse_ndp(NDP), (1480, 1492))
        self.assertEqual(facts.parse_ndp('linkmtu=0, maxmtu=1500, curhlim=64\n'), (0, 1500))
        self.assertIsNone(facts.parse_ndp(''))
        self.assertIsNone(facts.parse_ndp('ndp: ioctl (SIOCGIFINFO_IN6): Device not configured\n'))

    def test_first_nameserver(self):
        text = (
            '# Generated for and by OPNsense\n'
            'domain example.net\n'
            'nameserver 127.0.0.1\n'
            'nameserver 2001:db8::53\n'
            'search example.net\n'
        )
        self.assertEqual(facts.first_nameserver(text), '127.0.0.1')
        self.assertEqual(facts.first_nameserver('nameserver\n  nameserver\tfe80::1%pppoe0\n'), 'fe80::1%pppoe0')
        self.assertIsNone(facts.first_nameserver('domain example.net\n# nameserver 192.0.2.1\n'))
        self.assertIsNone(facts.first_nameserver(''))
        self.assertIsNone(facts.first_nameserver(None))


class RtmRelevantTest(unittest.TestCase):
    @staticmethod
    def message(mtype, flags=0, version=5, length=24):
        return struct.pack('=HBBHHi', length, version, mtype, 0, 0, flags).ljust(length, b'\0')

    def test_get_ignored(self):
        self.assertFalse(facts.rtm_relevant(self.message(0x4)))
        self.assertFalse(facts.rtm_relevant(self.message(0x4, flags=0x803)))

    def test_route_messages(self):
        for mtype in (0x1, 0x2, 0x3):
            self.assertTrue(facts.rtm_relevant(self.message(mtype, flags=0x803)), mtype)
            self.assertFalse(facts.rtm_relevant(self.message(mtype, flags=0x405)), mtype)

    def test_link_messages(self):
        for mtype in (0xc, 0xd, 0xe, 0x11):
            self.assertTrue(facts.rtm_relevant(self.message(mtype)), mtype)
            # the flags word of these messages means something else
            self.assertTrue(facts.rtm_relevant(self.message(mtype, flags=0x400)), mtype)

    def test_other_types_ignored(self):
        for mtype in (0x5, 0x6, 0x7, 0x8, 0xb, 0xf, 0x10, 0x12, 0x13):
            self.assertFalse(facts.rtm_relevant(self.message(mtype)), mtype)

    def test_several_messages(self):
        ignored = self.message(0x4) + self.message(0x1, flags=0x405, length=32) + self.message(0xf, length=16)
        self.assertFalse(facts.rtm_relevant(ignored))
        self.assertTrue(facts.rtm_relevant(ignored + self.message(0xe)))
        self.assertTrue(facts.rtm_relevant(ignored + self.message(0x2, flags=0x3)))

    def test_wrong_version(self):
        self.assertFalse(facts.rtm_relevant(self.message(0xe, version=4)))
        self.assertFalse(facts.rtm_relevant(self.message(0x1, version=6)))
        # the walk goes on behind a message of another version
        self.assertTrue(facts.rtm_relevant(self.message(0xe, version=4) + self.message(0xe)))

    def test_truncated(self):
        self.assertFalse(facts.rtm_relevant(b''))
        self.assertFalse(facts.rtm_relevant(b'\x18\x00\x05'))
        self.assertFalse(facts.rtm_relevant(self.message(0x1)[:11]))
        self.assertFalse(facts.rtm_relevant(self.message(0x4) + self.message(0x1)[:8]))
        self.assertTrue(facts.rtm_relevant(self.message(0x1)[:12]))
        self.assertTrue(facts.rtm_relevant(self.message(0xe)[:4]))

    def test_length_below_four(self):
        for length in (0, 3):
            bad = struct.pack('=HBB', length, 5, 0x4)
            self.assertFalse(facts.rtm_relevant(bad + self.message(0xe)), length)


class SplitLinesTest(unittest.TestCase):
    def test_line_ends(self):
        self.assertEqual(facts.split_lines(b'', b'one\r\ntwo\n'), (['one', 'two'], b''))

    def test_several_lines_and_rest(self):
        self.assertEqual(facts.split_lines(b'', b'one\r\ntwo\r\nthr'), (['one', 'two'], b'thr'))

    def test_partial_line_completed(self):
        lines, pending = facts.split_lines(b'', b'Using tun device tun464 ')
        self.assertEqual((lines, pending), ([], b'Using tun device tun464 '))
        lines, pending = facts.split_lines(pending, b'with MTU 1492\r\nTAYGA')
        self.assertEqual((lines, pending), (['Using tun device tun464 with MTU 1492'], b'TAYGA'))
        self.assertEqual(facts.split_lines(pending, b''), ([], b'TAYGA'))

    def test_empty_lines_kept(self):
        self.assertEqual(facts.split_lines(b'', b'\r\n\none\n'), (['', '', 'one'], b''))

    def test_line_cut_to_limit(self):
        self.assertEqual(facts.split_lines(b'', b'abcdefgh\r\nij\n', limit=4), (['abcd', 'ij'], b''))
        lines, pending = facts.split_lines(b'', b'x' * 3000 + b'\n')
        self.assertEqual((lines, pending), (['x' * 1024], b''))

    def test_overlong_rest_emitted(self):
        self.assertEqual(facts.split_lines(b'abc', b'de', limit=4), (['abcd'], b''))
        self.assertEqual(facts.split_lines(b'abc', b'd', limit=4), ([], b'abcd'))
        self.assertEqual(facts.split_lines(b'', b'one\n' + b'y' * 2000), (['one', 'y' * 1024], b''))

    def test_undecodable_bytes(self):
        self.assertEqual(facts.split_lines(b'', b'a\xffb\n'), (['a' + chr(0xFFFD) + 'b'], b''))


class GatewayTest(unittest.TestCase):
    def test_native_gateways(self):
        gw = gateways(
            gateway('UPSTREAM', upstream=True),
            gateway('DYNAMIC', priority=254, dynamic=True),
            gateway('SELECTED', selected=True),
            gateway('LAN_ROUTER'),
            gateway('LOW', priority=1),
            gateway('VPN', priority=254, tunnel=True, **{'if': 'wg0'}),
            gateway('NO_ADDRESS', upstream=True, if_has_ipv4=False),
            gateway('DISABLED', upstream=True, disabled=True),
            CLAT_GW,
        )
        self.assertEqual(facts.native_gateways(gw), ['UPSTREAM', 'DYNAMIC', 'SELECTED', 'LOW'])

    def test_native_gateways_none(self):
        self.assertEqual(facts.native_gateways(gateways()), [])
        self.assertEqual(facts.native_gateways(gateways(CLAT_GW, gateway('LAN_ROUTER'))), [])
        # the own gateway is never native, whatever its flags
        own = dict(CLAT_GW, upstream=True, selected=True, priority=1)
        self.assertEqual(facts.native_gateways(gateways(own)), [])

    def test_stale_gateways(self):
        gw = gateways(
            gateway('UPSTREAM', upstream=True, if_has_ipv4=False),
            gateway('LOW', priority=253, if_has_ipv4=False),
            gateway('AT_254', priority=254, if_has_ipv4=False),
            gateway('AT_255', if_has_ipv4=False),
            gateway('HAS_IPV4', upstream=True),
            gateway('DISABLED', upstream=True, if_has_ipv4=False, disabled=True),
            gateway('DEFUNCT', upstream=True, if_has_ipv4=False, defunct=True),
            gateway('NO_GATEWAY', upstream=True, if_has_ipv4=False, gateway=''),
            dict(CLAT_GW, upstream=True, if_has_ipv4=False),
        )
        self.assertEqual(facts.stale_gateways(gw), ['UPSTREAM', 'LOW'])
        self.assertEqual(facts.stale_gateways(gateways(CLAT_GW)), [])

    def test_gateway_report(self):
        self.assertEqual(facts.gateway_report(gateways()), ('none', 'no IPv4 default gateway is selected'))
        default = {'name': 'CLAT_GW', 'if': 'tun464', 'if_has_ipv4': True}
        self.assertEqual(facts.gateway_report(gateways(default=default)), ('default', 'active'))
        default = {'name': 'WAN2_DHCP', 'if': 'igc2', 'if_has_ipv4': True}
        self.assertEqual(facts.gateway_report(gateways(default=default)),
                         ('not_default', 'active, but not the IPv4 default: gateway WAN2_DHCP is preferred'))
        default = {'name': 'WAN_GW', 'if': 'pppoe0', 'if_has_ipv4': False}
        self.assertEqual(facts.gateway_report(gateways(default=default)),
                         ('stale', 'a stale gateway WAN_GW on an interface without IPv4 blocks any default route'))


class PreflightTest(unittest.TestCase):
    def test_nothing_to_report(self):
        known, sysif = world()
        known.gw = gateways(CLAT_GW, default={'name': 'CLAT_GW', 'if': 'tun464', 'if_has_ipv4': True})
        self.assertEqual(facts.preflight(known, sysif, '0.9.6'), [])
        self.assertEqual(facts.preflight(known, sysif), [])
        self.assertEqual(sysif.commands, [])

    def test_row_format(self):
        known, sysif = world(nat_mode='disabled')
        rows = facts.preflight(known, sysif)
        self.assertEqual(len(rows), 1)
        self.assertEqual(sorted(rows[0]), ['effect', 'id', 'message'])

    def test_tayga_missing(self):
        known, sysif = world()
        del sysif.files[facts.TAYGA_BIN]
        self.assertEqual(facts.preflight(known, sysif), [
            {'id': 'tayga_missing', 'effect': 'block', 'message': 'The tayga package is not installed.'},
        ])

    def test_wan_ipv4_ppp(self):
        known, sysif = world()
        known.cfg['uplink']['ipv4_ppp'] = True
        self.assertEqual(facts.preflight(known, sysif), [{
            'id': 'wan_ipv4_ppp', 'effect': 'block',
            'message': 'IPv6 cannot start with this setting. Set WAN IPv4 Configuration Type to None.',
        }])
        # not a PPP device: the setting does no harm
        known.cfg['uplink']['ppp'] = False
        self.assertEqual(facts.preflight(known, sysif), [])

    def test_wan_ipv4_ppp_native(self):
        known, sysif = world()
        known.cfg['uplink']['ipv4_ppp'] = True
        sysif.files['/tmp/pppoe0_router'] = '203.0.113.1\n'
        self.assertEqual(facts.preflight(known, sysif), [{
            'id': 'wan_ipv4_ppp_native', 'effect': 'warn',
            'message': 'If the ISP stops offering IPv4 on this line, IPv6 will not start either and the CLAT '
                       'cannot take over. Set IPv4 to None first.',
        }])
        known.cfg['uplink']['ipv4_ppp'] = False
        self.assertEqual(facts.preflight(known, sysif), [])

    def test_nat_mode(self):
        for mode in ('advanced', 'disabled'):
            known, sysif = world(nat_mode=mode)
            self.assertEqual(facts.preflight(known, sysif), [{
                'id': 'nat_mode', 'effect': 'block',
                'message': 'Outbound NAT mode is %s. Select automatic or hybrid mode, or add an outbound NAT rule '
                           'on the CLAT interface and confirm that you manage outbound NAT yourself.' % mode,
            }])
            known.settings['manual_nat'] = True
            self.assertEqual(facts.preflight(known, sysif), [])
        for mode in ('automatic', 'hybrid', ''):
            known, sysif = world(nat_mode=mode)
            self.assertEqual(facts.preflight(known, sysif), [])

    def test_pref64_overlap(self):
        expected = [{'id': 'pref64_overlap', 'effect': 'block',
                     'message': 'The NAT64 prefix 2001:db8:1200:64::/96 overlaps a local IPv6 prefix.'}]
        known, sysif = world()
        known.settings['prefix'] = '2001:db8:1200:64::/96'
        self.assertEqual(facts.preflight(known, sysif), expected)
        # without the delegated prefix nothing overlaps
        del sysif.files['/tmp/pppoe0_prefixv6']
        self.assertEqual(facts.preflight(known, sysif), [])
        for prefix in ('2001:db8:ffff:1::/96', '2001:db8:5:0:1::/96', '2001:db8::/32'):
            known.settings['prefix'] = prefix
            self.assertEqual(ids(facts.preflight(known, sysif)), ['pref64_overlap'], prefix)
        for prefix in ('64:ff9b::/96', '2001:db8:64::/96', 'fe80::/64', 'not a prefix', ''):
            known.settings['prefix'] = prefix
            self.assertEqual(facts.preflight(known, sysif), [], prefix)

    def test_stale_gateway(self):
        known, sysif = world()
        known.gw = gateways(CLAT_GW, gateway('WAN_GW', upstream=True, if_has_ipv4=False),
                            gateway('OLD_GW', priority=1, if_has_ipv4=False))
        self.assertEqual(facts.preflight(known, sysif), [{
            'id': 'stale_gateway', 'effect': 'block',
            'message': 'Gateway WAN_GW is on an interface without an IPv4 address and outranks the CLAT gateway; '
                       'core would install no IPv4 default route. Disable it.',
        }])
        known.gw['list'][1]['disabled'] = True
        self.assertIn('Gateway OLD_GW is', facts.preflight(known, sysif)[0]['message'])
        known.gw['list'][2]['disabled'] = True
        self.assertEqual(facts.preflight(known, sysif), [])

    def test_scrub_disabled(self):
        known, sysif = world(scrub=False)
        self.assertEqual(facts.preflight(known, sysif), [{
            'id': 'scrub_disabled', 'effect': 'warn',
            'message': 'Firewall normalisation is disabled; no TCP MSS clamp is active.',
        }])

    def test_wan_mss(self):
        known, sysif = world()
        known.cfg['uplink']['mss'] = 1400
        self.assertEqual(facts.preflight(known, sysif), [{
            'id': 'wan_mss', 'effect': 'warn',
            'message': 'The uplink interface has its own MSS value (1400); it also clamps the translated flows.',
        }])

    def test_mtu_mismatch(self):
        known, sysif = world()
        known.cfg['uplink']['mtu'] = 1500
        self.assertEqual(facts.preflight(known, sysif), [{
            'id': 'mtu_mismatch', 'effect': 'warn',
            'message': 'The configured uplink MTU (1500) differs from the effective IPv6 MTU (1492).',
        }])
        # an RA MTU below the device MTU is the effective one
        known.cfg['uplink']['mtu'] = 1492
        known.ndp = (1480, 1492)
        self.assertEqual(ids(facts.preflight(known, sysif)), ['mtu_mismatch'])
        # the override lowers both sides
        known.settings['ipv6_mtu'] = 1400
        self.assertEqual(facts.preflight(known, sysif), [])

    def test_mtu_mismatch_needs_both_values(self):
        known, sysif = world()
        known.cfg['uplink']['mtu'] = 1500
        known.ifaces = {}
        self.assertEqual(facts.preflight(known, sysif), [])

    def test_uplink_mismatch(self):
        known, sysif = world()
        known.cfg['uplink'].update({'key': 'opt1', 'if': 'igc2', 'ppp': False, 'mtu': 1492})
        self.assertEqual(facts.preflight(known, sysif), [{
            'id': 'uplink_mismatch', 'effect': 'warn',
            'message': 'The configured uplink (igc2) is not the interface that holds the IPv6 default route '
                       '(pppoe0). Choose the uplink explicitly.',
        }])

    def test_leftover_gateway(self):
        known, sysif = world()
        known.gw = gateways(CLAT_GW, leftover=[{'name': 'WAN_PPPOE', 'refs': ['dns', 'rule']},
                                               {'name': 'WAN_OLD', 'refs': ['monitor']}])
        self.assertEqual(facts.preflight(known, sysif), [
            {'id': 'leftover_gateway', 'effect': 'warn',
             'message': 'Gateway WAN_PPPOE has no address any more but is still used (dns, rule).'},
            {'id': 'leftover_gateway', 'effect': 'warn',
             'message': 'Gateway WAN_OLD has no address any more but is still used (monitor).'},
        ])

    def test_tayga_version(self):
        known, sysif = world()
        for version in ('0.9.6', '0.9.6_1', '0.9.6,1', '0.9.6_2,1', None, ''):
            self.assertEqual(facts.preflight(known, sysif, version), [], version)
        self.assertEqual(facts.preflight(known, sysif, '0.9.5_1'), [{
            'id': 'tayga_version', 'effect': 'warn',
            'message': 'tayga 0.9.5_1 is installed; the plugin was tested with 0.9.6.',
        }])
        self.assertEqual(ids(facts.preflight(known, sysif, '0.9.60')), ['tayga_version'])

    def test_table_order(self):
        known, sysif = world(nat_mode='advanced', scrub=False)
        del sysif.files[facts.TAYGA_BIN]
        sysif.files['/tmp/pppoe0_router'] = '203.0.113.1\n'
        known.cfg['uplink'].update({'ipv4_ppp': True, 'mss': 1400, 'mtu': 1500})
        known.settings['prefix'] = '2001:db8:1200:64::/96'
        known.route6 = ('igc2', None)
        known.ifaces['igc2'] = {'mtu': 1400, 'flags': set(), 'inet': [], 'inet6': [], 'opened_by': None}
        sysif.files['/tmp/igc2_router'] = '203.0.113.1\n'
        sysif.files['/tmp/igc2_prefixv6'] = '2001:db8:1200::/56\n'
        known.gw = gateways(gateway('WAN_GW', upstream=True, if_has_ipv4=False),
                            leftover=[{'name': 'WAN_PPPOE', 'refs': ['dns']}])
        rows = facts.preflight(known, sysif, '1.0.0')
        self.assertEqual(ids(rows), [
            'tayga_missing', 'nat_mode', 'pref64_overlap', 'stale_gateway', 'wan_ipv4_ppp_native',
            'scrub_disabled', 'wan_mss', 'mtu_mismatch', 'uplink_mismatch', 'leftover_gateway', 'tayga_version',
        ])
        self.assertEqual([row['effect'] for row in rows], ['block'] * 4 + ['warn'] * 7)
        # without native IPv4 on the uplink the PPP setting blocks instead of warning
        del sysif.files['/tmp/igc2_router']
        self.assertEqual(ids(facts.preflight(known, sysif, '1.0.0'))[:2], ['tayga_missing', 'wan_ipv4_ppp'])
        self.assertNotIn('wan_ipv4_ppp_native', ids(facts.preflight(known, sysif, '1.0.0')))

    def test_rows_with_missing_facts_skipped(self):
        known, sysif = world(nat_mode='advanced', scrub=False)
        known.cfg['uplink'].update({'ipv4_ppp': True, 'mss': 1400, 'mtu': 1500, 'if': 'igc2'})
        full = ids(facts.preflight(known, sysif))
        self.assertEqual(full, ['wan_ipv4_ppp', 'nat_mode', 'scrub_disabled', 'wan_mss', 'mtu_mismatch',
                                'uplink_mismatch'])
        # no runtime uplink: nothing to compare the configured one with
        known.route6 = None
        self.assertEqual(ids(facts.preflight(known, sysif)), ['wan_ipv4_ppp', 'nat_mode', 'scrub_disabled', 'wan_mss'])
        # no configured uplink
        known.cfg['uplink'] = None
        self.assertEqual(ids(facts.preflight(known, sysif)), ['nat_mode', 'scrub_disabled'])
        # no config facts at all
        known.cfg = None
        self.assertEqual(facts.preflight(known, sysif), [])
        # gateway facts and version unknown: their rows are absent, known: present
        self.assertEqual(facts.preflight(known, sysif, None), [])
        known.gw = gateways(gateway('WAN_GW', upstream=True, if_has_ipv4=False),
                            leftover=[{'name': 'WAN_PPPOE', 'refs': ['dns']}])
        self.assertEqual(ids(facts.preflight(known, sysif, '1.0.0')),
                         ['stale_gateway', 'leftover_gateway', 'tayga_version'])


class FactsTest(unittest.TestCase):
    def test_initial(self):
        known = facts.Facts()
        self.assertEqual(known.settings, facts.DEFAULT_SETTINGS)
        self.assertIsNot(known.settings, facts.DEFAULT_SETTINGS)
        self.assertIsNone(known.cfg)
        self.assertIsNone(known.cfg_stat)
        self.assertIsNone(known.route6)
        self.assertEqual(known.ifaces, {})
        self.assertIsNone(known.ndp)
        self.assertIsNone(known.gw)
        self.assertIsNone(known.uplink_dev())
        self.assertIsNone(known.uplink_router())
        self.assertEqual(known.claims(), [])
        self.assertEqual(known.addresses6(), set())
        self.assertIsNone(known.mtu6())
        sysif = Stub()
        self.assertFalse(known.uplink_native(sysif))
        self.assertIsNone(known.delegated(sysif))
        self.assertEqual(known.local_networks(sysif), [])

    def test_load_settings(self):
        known = facts.Facts()
        sysif = Stub({facts.SETTINGS: '{"enabled": false, "ipv4_mtu": 1400}\n'})
        self.assertTrue(known.load_settings(sysif))
        self.assertEqual(known.settings, dict(facts.DEFAULT_SETTINGS, enabled=False, ipv4_mtu=1400))
        for text in ('{"enabled": ', None):
            sysif.files[facts.SETTINGS] = text
            self.assertFalse(known.load_settings(sysif))
            self.assertIs(known.settings['enabled'], False)
            self.assertEqual(known.settings['ipv4_mtu'], 1400)

    def test_refresh_config(self):
        known = facts.Facts()
        sysif = Stub(replies=[(CONFIG_CMD, (0, json.dumps({'config': CONFIG}) + '\n', ''))])
        # no config.xml and nothing forced: nothing has changed since the start
        self.assertFalse(known.refresh_config(sysif))
        self.assertEqual(sysif.commands, [])
        sysif.stats[facts.CONFIG_XML] = (1000, 4096, 7)
        self.assertTrue(known.refresh_config(sysif))
        self.assertEqual(known.cfg, CONFIG)
        self.assertEqual(known.cfg_stat, (1000, 4096, 7))
        self.assertEqual(sysif.commands, [CONFIG_CMD])
        self.assertEqual(sysif.timeouts, [facts.PHP_TIMEOUT])
        # unchanged file: the helper does not run
        self.assertFalse(known.refresh_config(sysif))
        self.assertEqual(sysif.commands, [CONFIG_CMD])
        self.assertTrue(known.refresh_config(sysif, force=True))
        self.assertEqual(sysif.commands, [CONFIG_CMD] * 2)
        sysif.stats[facts.CONFIG_XML] = (2000, 4100, 8)
        self.assertTrue(known.refresh_config(sysif))
        self.assertEqual(known.cfg_stat, (2000, 4100, 8))
        self.assertEqual(sysif.commands, [CONFIG_CMD] * 3)

    def test_refresh_config_failure_keeps_old_value(self):
        known = facts.Facts()
        known.cfg = {'old': True}
        known.cfg_stat = (0, 1, 1)
        for number, reply in enumerate(((1, '', 'PHP Fatal error'), (124, '', ''), (0, '', ''), (0, 'no json', ''),
                                        (0, '[]', ''), (0, '{"gateways": {}}', ''), (0, '{"config": null}', '')), 1):
            sysif = Stub(replies=[(CONFIG_CMD, reply)])
            sysif.stats[facts.CONFIG_XML] = (number, 1, 1)
            self.assertTrue(known.refresh_config(sysif), reply)
            self.assertEqual(known.cfg, {'old': True}, reply)
            # the old facts were not read from this file: the next call asks again
            self.assertEqual(known.cfg_stat, (0, 1, 1), reply)
            self.assertTrue(known.refresh_config(sysif), reply)
            self.assertEqual(sysif.commands, [CONFIG_CMD] * 2, reply)

    def test_refresh_config_retried_until_the_helper_answers(self):
        known = facts.Facts()
        sysif = Stub(replies=[(CONFIG_CMD, (124, '', ''))])
        sysif.stats[facts.CONFIG_XML] = (1000, 4096, 7)
        # the helper fails when the daemon starts: there are no config facts, and nothing passes for read
        self.assertTrue(known.refresh_config(sysif, force=True))
        self.assertIsNone(known.cfg)
        self.assertIsNone(known.cfg_stat)
        self.assertTrue(known.refresh_config(sysif))
        self.assertIsNone(known.cfg)
        sysif.replies[tuple(CONFIG_CMD)] = (0, json.dumps({'config': CONFIG}) + '\n', '')
        self.assertTrue(known.refresh_config(sysif))
        self.assertEqual(known.cfg, CONFIG)
        self.assertEqual(known.cfg_stat, (1000, 4096, 7))
        self.assertFalse(known.refresh_config(sysif))
        self.assertEqual(sysif.commands, [CONFIG_CMD] * 3)
        # a forced run that fails on the unchanged file: the facts still describe it, nothing to ask again
        sysif.replies[tuple(CONFIG_CMD)] = (1, '', 'PHP Fatal error')
        self.assertTrue(known.refresh_config(sysif, force=True))
        self.assertEqual(known.cfg, CONFIG)
        self.assertFalse(known.refresh_config(sysif))
        self.assertEqual(sysif.commands, [CONFIG_CMD] * 4)

    def test_refresh_link(self):
        known = facts.Facts()
        sysif = Stub(replies=[(ROUTE_CMD, (0, ROUTE_GET, '')), (IFCONFIG_CMD, (0, IFCONFIG, ''))])
        self.assertIsNone(known.refresh_link(sysif))
        self.assertEqual(sysif.commands, [ROUTE_CMD, IFCONFIG_CMD])
        self.assertEqual(known.route6, ('pppoe0', ROUTER))
        self.assertEqual(known.uplink_dev(), 'pppoe0')
        self.assertEqual(known.uplink_router(), ROUTER)
        self.assertEqual(known.ifaces, facts.parse_ifconfig(IFCONFIG))

    def test_refresh_link_no_default_route(self):
        known = facts.Facts()
        known.route6 = ('pppoe0', ROUTER)
        not_found = (1, '', 'route: route has not been found\n')
        sysif = Stub(replies=[(ROUTE_CMD, not_found), (IFCONFIG_CMD, (0, IFCONFIG, ''))])
        known.refresh_link(sysif)
        self.assertIsNone(known.route6)
        self.assertIsNone(known.uplink_dev())
        self.assertIsNone(known.uplink_router())
        self.assertEqual(list(known.ifaces), ['igc1', 'pppoe0', 'tun464'])

    def test_refresh_link_route_command_fails(self):
        # exit 1 is route's answer "no default route"; whatever it printed is ignored
        known = facts.Facts()
        known.route6 = ('pppoe0', ROUTER)
        known.refresh_link(Stub(replies=[(ROUTE_CMD, (1, ROUTE_GET, '')), (IFCONFIG_CMD, (0, IFCONFIG, ''))]))
        self.assertIsNone(known.route6)
        self.assertEqual(list(known.ifaces), ['igc1', 'pppoe0', 'tun464'])

    def test_refresh_link_route_command_did_not_run(self):
        # a time-out (124) or a command that could not be started (127) is no answer: the route is kept
        for code in (124, 127):
            known = facts.Facts()
            known.route6 = ('pppoe0', ROUTER)
            known.refresh_link(Stub(replies=[(ROUTE_CMD, (code, '', '')), (IFCONFIG_CMD, (0, IFCONFIG, ''))]))
            self.assertEqual(known.route6, ('pppoe0', ROUTER), code)
            self.assertEqual(list(known.ifaces), ['igc1', 'pppoe0', 'tun464'], code)

    def test_refresh_link_interface_route(self):
        known = facts.Facts()
        text = ROUTE_GET.replace('    gateway: fe80::2a0:a5ff:fe12:3456%pppoe0\n', '')
        known.refresh_link(Stub(replies=[(ROUTE_CMD, (0, text, '')), (IFCONFIG_CMD, (0, IFCONFIG, ''))]))
        self.assertEqual(known.route6, ('pppoe0', None))
        self.assertEqual(known.uplink_dev(), 'pppoe0')
        self.assertIsNone(known.uplink_router())

    def test_refresh_link_route_on_a_device_that_is_down(self):
        # what a PPP session that ended leaves on OPNsense: the route, and the device without UP and addresses
        down = (
            'pppoe0: flags=8890<POINTOPOINT,NOARP,SIMPLEX,MULTICAST> metric 0 mtu 1500\n'
            '\tdescription: WAN (wan)\n'
            '\tnd6 options=23<PERFORMNUD,ACCEPT_RTADV,AUTO_LINKLOCAL>\n'
        )
        known = facts.Facts()
        sysif = Stub(replies=[(ROUTE_CMD, (0, ROUTE_GET, '')), (IFCONFIG_CMD, (0, down, ''))])
        known.refresh_link(sysif)
        self.assertIsNone(known.route6)
        self.assertIsNone(known.uplink_dev())
        self.assertEqual(list(known.ifaces), ['pppoe0'])
        sysif.replies[tuple(IFCONFIG_CMD)] = (0, IFCONFIG, '')
        known.refresh_link(sysif)
        self.assertEqual(known.route6, ('pppoe0', ROUTER))

    def test_refresh_link_route_on_an_unknown_device(self):
        known = facts.Facts()
        known.refresh_link(Stub(replies=[(ROUTE_CMD, (0, ROUTE_GET, ''))]))
        self.assertIsNone(known.route6)
        self.assertEqual(known.ifaces, {})

    def test_refresh_link_ifconfig_failure_keeps_interfaces(self):
        known = facts.Facts()
        known.ifaces = facts.parse_ifconfig(IFCONFIG)
        known.refresh_link(Stub(replies=[(ROUTE_CMD, (0, ROUTE_GET, '')), (IFCONFIG_CMD, (124, '', ''))]))
        self.assertEqual(list(known.ifaces), ['igc1', 'pppoe0', 'tun464'])
        self.assertEqual(known.route6, ('pppoe0', ROUTER))

    def test_refresh_activation(self):
        known = facts.Facts()
        known.route6 = ('pppoe0', ROUTER)
        gw = gateways(CLAT_GW)
        sysif = Stub(replies=[(NDP_CMD, (0, NDP, '')), (GATEWAYS_CMD, (0, json.dumps({'gateways': gw}) + '\n', ''))])
        self.assertTrue(known.refresh_activation(sysif))
        self.assertEqual(sysif.commands, [NDP_CMD, GATEWAYS_CMD])
        self.assertEqual(sysif.timeouts[1], facts.PHP_TIMEOUT)
        self.assertEqual(known.ndp, (1480, 1492))
        self.assertEqual(known.gw, gw)
        known.drop_activation()
        self.assertIsNone(known.ndp)
        self.assertIsNone(known.gw)

    def test_refresh_activation_ndp_failure(self):
        known = facts.Facts()
        known.route6 = ('pppoe0', ROUTER)
        known.ndp = (1480, 1492)
        gw = gateways()
        sysif = Stub(replies=[(NDP_CMD, (1, '', 'ndp: failed')), (GATEWAYS_CMD, (0, json.dumps({'gateways': gw}), ''))])
        # the result depends on the helper only
        self.assertTrue(known.refresh_activation(sysif))
        self.assertIsNone(known.ndp)
        self.assertEqual(known.gw, gw)

    def test_refresh_activation_helper_failure(self):
        for reply in ((1, '', ''), (124, '', ''), (0, '', ''), (0, '{"gateways": []}', ''), (0, '{"config": {}}', '')):
            known = facts.Facts()
            known.route6 = ('pppoe0', ROUTER)
            known.gw = gateways(CLAT_GW)
            sysif = Stub(replies=[(NDP_CMD, (0, NDP, '')), (GATEWAYS_CMD, reply)])
            self.assertFalse(known.refresh_activation(sysif), reply)
            self.assertIsNone(known.gw, reply)
            self.assertEqual(known.ndp, (1480, 1492), reply)

    def test_refresh_activation_without_runtime_uplink(self):
        gw = gateways(CLAT_GW)
        for reply, expected in (((0, json.dumps({'gateways': gw}), ''), True), ((1, '', ''), False)):
            known = facts.Facts()
            known.ndp = (1480, 1492)
            sysif = Stub(replies=[(GATEWAYS_CMD, reply)])
            self.assertIs(known.refresh_activation(sysif), expected)
            self.assertEqual(sysif.commands, [GATEWAYS_CMD])
            self.assertIsNone(known.ndp)
            self.assertEqual(known.gw, gw if expected else None)

    def test_uplink_native_router_file(self):
        known, sysif = world()
        self.assertFalse(known.uplink_native(sysif))
        sysif.files['/tmp/pppoe0_router'] = '\n'
        self.assertFalse(known.uplink_native(sysif))
        sysif.files['/tmp/pppoe0_router'] = '203.0.113.1\n'
        self.assertTrue(known.uplink_native(sysif))
        # the router file of another device does not count
        del sysif.files['/tmp/pppoe0_router']
        sysif.files['/tmp/igc1_router'] = '192.168.1.254\n'
        sysif.files[facts.ROUTER_FILE] = '192.0.0.2\n'
        self.assertFalse(known.uplink_native(sysif))

    def test_uplink_native_address(self):
        known, sysif = world()
        known.ifaces['pppoe0']['inet'].append(('169.254.7.9', None, 16))
        self.assertFalse(known.uplink_native(sysif))
        known.ifaces['pppoe0']['inet'].append(('203.0.113.7', '203.0.113.1', 32))
        self.assertTrue(known.uplink_native(sysif))
        # only the addresses of the runtime uplink are looked at
        known.ifaces['pppoe0']['inet'] = []
        self.assertFalse(known.uplink_native(sysif))
        known.route6 = ('igc1', None)
        self.assertTrue(known.uplink_native(sysif))
        known.route6 = ('igc9', None)
        self.assertFalse(known.uplink_native(sysif))

    def test_uplink_native_falls_back_to_configured_uplink(self):
        known, sysif = world()
        known.route6 = None
        self.assertFalse(known.uplink_native(sysif))
        sysif.files['/tmp/pppoe0_router'] = '203.0.113.1\n'
        self.assertTrue(known.uplink_native(sysif))
        known.cfg['uplink'] = None
        self.assertFalse(known.uplink_native(sysif))
        known.cfg = None
        self.assertFalse(known.uplink_native(sysif))

    def test_delegated(self):
        known, sysif = world()
        self.assertEqual(known.delegated(sysif), IPv6Network('2001:db8:1200::/56'))
        sysif.files['/tmp/pppoe0_prefixv6'] = ''
        self.assertIsNone(known.delegated(sysif))
        del sysif.files['/tmp/pppoe0_prefixv6']
        self.assertIsNone(known.delegated(sysif))
        sysif.files['/tmp/igc1_prefixv6'] = '2001:db8:3400::/56\n'
        self.assertIsNone(known.delegated(sysif))
        known.route6 = ('igc1', None)
        self.assertEqual(known.delegated(sysif), IPv6Network('2001:db8:3400::/56'))

    def test_claims(self):
        known, _sysif = world()
        self.assertEqual(known.claims(), [0])
        known.cfg['interfaces']['pppoe0']['claims'] = [0, 1, 16]
        self.assertEqual(known.claims(), [0, 1, 16])
        known.route6 = ('igc1', None)
        self.assertEqual(known.claims(), [])
        known.route6 = ('igc9', None)
        self.assertEqual(known.claims(), [])
        known.route6 = None
        self.assertEqual(known.claims(), [])
        known.route6 = ('pppoe0', ROUTER)
        known.cfg['interfaces'] = {}
        self.assertEqual(known.claims(), [])
        known.cfg = None
        self.assertEqual(known.claims(), [])

    def test_local_networks(self):
        known, sysif = world()
        self.assertEqual(known.local_networks(sysif), [
            IPv6Network('2001:db8:1200::/56'), IPv6Network('2001:db8:ffff:1::/64'), IPv6Network('2001:db8:5::/64'),
        ])
        known.cfg['static_v6'] = ['2001:db8:5::1/64', '2001:db8:6::1/', 'fd00::1/48']
        del sysif.files['/tmp/pppoe0_prefixv6']
        self.assertEqual(known.local_networks(sysif), [
            IPv6Network('2001:db8:ffff:1::/64'), IPv6Network('2001:db8:5::/64'), IPv6Network('fd00::/48'),
        ])
        known.cfg = None
        self.assertEqual(known.local_networks(sysif), [IPv6Network('2001:db8:ffff:1::/64')])
        known.route6 = None
        self.assertEqual(known.local_networks(sysif), [])

    def test_addresses6(self):
        known, _sysif = world()
        self.assertEqual(known.addresses6(), {
            IPv6Address('fe80::2a0:a5ff:fe12:3457'), IPv6Address('2001:db8:1200::1'),
            IPv6Address('fe80::2a0:a5ff:fe12:3456'), IPv6Address('2001:db8:ffff:1:2a0:a5ff:fe12:3456'),
        })

    def test_mtu6(self):
        known, _sysif = world()
        self.assertEqual(known.mtu6(), 1492)
        known.ndp = (1480, 1492)
        self.assertEqual(known.mtu6(), 1480)
        known.ndp = (0, 1492)
        self.assertEqual(known.mtu6(), 1492)
        known.settings['ipv6_mtu'] = 1400
        self.assertEqual(known.mtu6(), 1400)
        # the override can only lower the value
        known.settings['ipv6_mtu'] = 9000
        self.assertEqual(known.mtu6(), 1492)
        known.ifaces['pppoe0']['mtu'] = None
        self.assertIsNone(known.mtu6())
        known.route6 = ('igc9', None)
        self.assertIsNone(known.mtu6())
        known.route6 = None
        self.assertIsNone(known.mtu6())

    def test_tun_ok(self):
        known, _sysif = world()
        plan = Plan(pref64=IPv6Network('64:ff9b::/96'), clat6=IPv6Address('2001:db8:1200:ff::10'),
                    tayga6=IPv6Address('2001:db8:1200:ff::11'), ipv4_clat='192.0.0.1', ipv4_tayga='192.0.0.2',
                    tun_mtu=1492, offlink_mtu=1492, udp_cksum='calc')
        self.assertTrue(known.tun_ok(plan, 4242))
        self.assertFalse(known.tun_ok(plan, 4243))
        self.assertFalse(known.tun_ok(plan, None))
        # the /32 is missing: pf would read "CLAT net" as "any"
        known.ifaces['tun464']['inet'] = [('192.0.0.1', '192.0.0.2', 0)]
        self.assertFalse(known.tun_ok(plan, 4242))
        known.ifaces['tun464']['inet'] = [('192.0.0.1', '192.0.0.3', 32)]
        self.assertFalse(known.tun_ok(plan, 4242))
        known.ifaces['tun464']['inet'] = []
        self.assertFalse(known.tun_ok(plan, 4242))
        del known.ifaces['tun464']
        self.assertFalse(known.tun_ok(plan, 4242))


if __name__ == '__main__':
    unittest.main()
