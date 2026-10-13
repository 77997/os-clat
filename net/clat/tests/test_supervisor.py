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

import json
import os
import struct
import sys
import unittest
from ipaddress import IPv6Address, IPv6Network

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'src', 'opnsense', 'scripts', 'clat'))
sys.path.insert(0, HERE)

from fakes import FakeSystem  # noqa: E402
from lib import discovery  # noqa: E402
from lib import facts  # noqa: E402
from lib import supervisor  # noqa: E402
from lib.plan import tayga_argv, tayga_conf  # noqa: E402
from lib.supervisor import CONFIGCTL, IFCTL  # noqa: E402

PREFIX_FILE = '/tmp/pppoe0_prefixv6'
DELEGATED = '2001:db8:1200::/56\n'
WKP = IPv6Network('64:ff9b::/96')

ROUTE_GET = ['/sbin/route', '-6', '-n', 'get', 'default']
ROUTE_DELETE = ['/sbin/route', '-6', '-q', 'delete']
IFCONFIG_A = ['/sbin/ifconfig', '-a']
PFCTL_SN = ['/sbin/pfctl', '-sn']
HELPER_CONFIG = [facts.FACTS_PHP, 'config']
HELPER_GATEWAYS = [facts.FACTS_PHP, 'gateways']
REGISTRATION = [CONFIGCTL, 'interface', 'invoke', 'registration']

SECRET_WRITE = 'write ' + facts.SECRET
# trace entries that change nothing on the box: reads, DNS queries and the status file
READS = ('/sbin/route -6 -n get ', '/sbin/ifconfig -a', '/usr/sbin/ndp -i ', facts.FACTS_PHP + ' ',
         '/sbin/pfctl -sn', '/bin/ps ', 'write ' + facts.STATUS, 'dns')

ROUTE_GET_TEXT = """   route to: ::
destination: ::
       mask: ::
    gateway: fe80::1%%pppoe0
        fib: 0
  interface: pppoe0
      flags: <UP,GATEWAY,DONE,STATIC>
 recvpipe  sendpipe  ssthresh  rtt,msec    mtu        weight    expire
       0         0         0         0      %d         1         0
"""
NDP_TEXT = """linkmtu=0, maxmtu=%d, curhlim=64, basereachable=30s0ms, reachable=22s, retrans=1s0ms
Flags: nud accept_rtadv auto_linklocal
"""
PPPOE_TEXT = 'pppoe0: flags=88d1<UP,POINTOPOINT,RUNNING,NOARP,SIMPLEX,MULTICAST> metric 0 mtu %d'
NAT_RULE = 'nat on tun464 inet from (igc1:network) to any -> (tun464:0) port 1024:65535\n'


def gateway(name, dev, **changes):
    """ One entry of the gateway list of facts.php; the default is a DHCP gateway on another WAN. """
    item = {'name': name, 'interface': 'opt1', 'if': dev, 'gateway': '203.0.113.1', 'priority': 254,
            'upstream': False, 'disabled': False, 'defunct': False, 'dynamic': True, 'selected': False,
            'tunnel': False, 'if_has_ipv4': True}
    item.update(changes)
    return item


def router_advert(lifetime=1800, prefix='64:ff9b::', source='fe80::1', ifname='pppoe0', hoplimit=255):
    """ A router advertisement with one PREF64 option (/96), as System.ra_recv() returns it. """
    data = struct.pack('!BBHBBHII', 134, 0, 0, 64, 0, 1800, 0, 0)
    data += struct.pack('!BBH', 38, 2, lifetime) + IPv6Address(prefix).packed[:12]
    return discovery.RaPacket(ifname, hoplimit, discovery.ll_norm(source), data)


def activation(plan, create=False):
    """ What Activate does, in order (SPEC 7.4 steps 1 to 7; step 8 only reads). """
    steps = ['mkdir /usr/local/etc/clat', 'mkdir ' + facts.DATA_DIR, 'write ' + facts.TAYGA_CONF]
    if create:
        steps.append('/sbin/ifconfig tun464 create')
    return steps + [
        '/sbin/ifconfig tun464 mtu %d' % plan.tun_mtu,
        'child_stop',
        'spawn',
        '/sbin/ifconfig tun464 inet %s/32 %s up' % (plan.ipv4_clat, plan.ipv4_tayga),
        '/sbin/ifconfig tun464 inet6 -ifdisabled',
        '/sbin/route -6 -q delete %s/127' % plan.clat6,
        '/sbin/route -6 add %s/127 -interface tun464' % plan.clat6,
        'write ' + facts.MARKER,
        '%s -i tun464 -4rd -a %s' % (IFCTL, plan.ipv4_tayga),
        CONFIGCTL + ' filter reload skip_alias',
        CONFIGCTL + ' interface newip tun464 force',
    ]


def replaying(plan, address=False):
    """ What Replay does: Activate steps 4 (when the tun lost its addresses), 6 and 7. """
    steps = activation(plan)
    return (steps[6:8] if address else []) + steps[10:]


def deactivation(plan):
    """ What Deactivate does, in order. """
    return [
        'remove ' + facts.MARKER,
        IFCTL + ' -i tun464 -4rd',
        'child_stop',
        '/sbin/route -6 -q delete %s/127' % plan.clat6,
        '/sbin/pfctl -k %s' % plan.ipv4_clat,
        '/sbin/pfctl -k %s' % plan.clat6,
        CONFIGCTL + ' interface routes configure',
    ]


def renumbering(old):
    """ What Renumber does before it activates the new plan. """
    return [
        'child_stop',
        '/sbin/route -6 -q delete %s/127' % old.clat6,
        '/sbin/pfctl -k %s' % old.ipv4_clat,
        '/sbin/pfctl -k %s' % old.clat6,
    ]


class Box(FakeSystem):
    """ A FakeSystem that answers like a small OPNsense box with an IPv6-only PPPoE uplink: the read-only
        commands print what the box looks like, and the commands the supervisor changes it with have their
        effect on that. trace lists everything that was done, in order.
    """

    def __init__(self):
        super().__init__()
        self.trace = []
        self.wan = True             # pppoe0 exists and holds the IPv6 default route
        self.wan_link = True        # its PPP session is up; False: device and route stay, the device is down
        self.wan_mtu = 1492
        self.wan_inet = None        # IPv4 address on pppoe0
        self.tun = None             # {'mtu': n, 'inet': (local, peer) or None} once tun464 exists
        self.routes = set()         # IPv6 routes into the tun
        self.holder = None          # a process other than the child that has the tun open
        self.nat = True             # core makes the outbound NAT rule
        self.route_get = None       # (rc, out, err) of "route get" instead of what the box looks like
        self.helper_ok = True
        self.config_ok = True       # the helper answers when asked for the config facts
        self.gw_extra = []          # gateways besides the CLAT's own
        self.fallback = None
        self.registration_repairs = True
        self.child_says = None      # lines the child prints instead of reporting the tun
        self.child_dies = False     # the child exits at once
        self.cfg = {
            'uplink': {'key': 'wan', 'if': 'pppoe0', 'ppp': True, 'ipv4_ppp': False, 'mtu': 1492, 'mss': None},
            'mss': 1492,
            'nat_mode': 'automatic',
            'scrub': True,
            'record_ok': True,
            'interfaces': {'pppoe0': {'key': 'wan', 'claims': [0]}, 'igc1': {'key': 'lan', 'claims': []}},
            'static_v6': [],
        }
        self.ifindex['pppoe0'] = 7
        self.put(facts.SETTINGS, json.dumps(facts.DEFAULT_SETTINGS))
        self.put(facts.CONFIG_XML, '<opnsense/>')
        self.put(facts.TAYGA_BIN, '')
        self.put(facts.RESOLV_CONF, 'domain example.net\nnameserver 127.0.0.1\nnameserver 2001:db8::53\n')
        self.put(PREFIX_FILE, DELEGATED)

    def mark(self):
        """ Position in the trace, for changes(). """
        return len(self.trace)

    def changes(self, start=0):
        """ What was done since the trace position, without reads and without the status file. """
        return [entry for entry in self.trace[start:] if not entry.startswith(READS)]

    def wan_down(self):
        """ The PPP session ends: the device goes away and with it the IPv6 default route. """
        self.wan = False
        del self.ifindex['pppoe0']

    def wan_up(self, index):
        """ A new session: the device is back under another index. Core's prefix file is still the old one. """
        self.wan = True
        self.ifindex['pppoe0'] = index

    def ifconfig(self):
        lines = []
        if self.wan and not self.wan_link:
            lines.append('pppoe0: flags=8890<POINTOPOINT,NOARP,SIMPLEX,MULTICAST> metric 0 mtu 1500')
            lines.append('\tnd6 options=23<PERFORMNUD,ACCEPT_RTADV,AUTO_LINKLOCAL>')
        elif self.wan:
            lines.append(PPPOE_TEXT % self.wan_mtu)
            if self.wan_inet:
                lines.append('\tinet %s --> 203.0.113.1 netmask 0xffffffff' % self.wan_inet)
            lines.append('\tinet6 fe80::2a0:a5ff:fe00:2%pppoe0 prefixlen 64 scopeid 0x7')
            lines.append('\tnd6 options=23<PERFORMNUD,ACCEPT_RTADV,AUTO_LINKLOCAL>')
        lines.append('igc1: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500')
        lines.append('\tinet 192.168.1.1 netmask 0xffffff00 broadcast 192.168.1.255')
        lines.append('\tinet6 2001:db8:1200::1 prefixlen 64')
        if self.tun is not None:
            lines.append('tun464: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> metric 0 mtu %d' % self.tun['mtu'])
            if self.tun['inet']:
                lines.append('\tinet %s --> %s netmask 0xffffffff' % self.tun['inet'])
            holder = self.holder
            if holder is None and self.child_status is None:
                holder = self.child_pid
            if holder is not None:
                lines.append('\tOpened by PID %d' % holder)
        return '\n'.join(lines) + '\n'

    def helper(self, member):
        if not self.helper_ok or (member == 'config' and not self.config_ok):
            return (255, '', 'PHP Fatal error\n')
        if member == 'config':
            return (0, json.dumps({'config': self.cfg}) + '\n', '')
        items = list(self.gw_extra)
        if facts.ROUTER_FILE in self.files:
            items.append(gateway('CLAT_GW', 'tun464', interface='clat', gateway='192.0.0.2'))
        default = None
        if items:
            default = {key: items[0][key] for key in ('name', 'if', 'if_has_ipv4')}
        gateways = {'default': default, 'fallback': self.fallback, 'list': items, 'leftover': []}
        return (0, json.dumps({'gateways': gateways}) + '\n', '')

    def run(self, argv, timeout=10.0):
        if argv == ROUTE_GET and self.route_get is not None:
            self.reply(argv, *self.route_get)
        elif argv == ROUTE_GET and self.wan:
            self.reply(argv, out=ROUTE_GET_TEXT % self.wan_mtu)
        elif argv == ROUTE_GET:
            self.reply(argv, rc=1, err='route: route has not been found\n')
        elif argv == IFCONFIG_A:
            self.reply(argv, out=self.ifconfig())
        elif argv[:2] == ['/usr/sbin/ndp', '-i']:
            self.reply(argv, out=NDP_TEXT % self.wan_mtu)
        elif argv[:1] == [facts.FACTS_PHP]:
            self.reply(argv, *self.helper(argv[1]))
        elif argv == PFCTL_SN:
            self.reply(argv, out=NAT_RULE if self.nat and facts.ROUTER_FILE in self.files else '')
        elif argv[:4] == ROUTE_DELETE and argv[4] in self.routes:
            self.reply(argv)
        elif argv[:4] == ROUTE_DELETE:
            self.reply(argv, rc=1, err='route: route has not been found\n')
        result = super().run(argv, timeout)
        self.trace.append(' '.join(argv))
        if result[0] == 0:
            self.effect(argv)
        return result

    def effect(self, argv):
        if argv[:3] == [IFCTL, '-i', 'tun464']:
            if '-a' in argv:
                self.put(facts.ROUTER_FILE, argv[-1] + '\n')
            else:
                self.files.pop(facts.ROUTER_FILE, None)
        elif argv[:3] == ['/sbin/ifconfig', 'tun464', 'create']:
            self.ifindex['tun464'] = 9
            self.tun = {'mtu': 1500, 'inet': None}
        elif argv[:3] == ['/sbin/ifconfig', 'tun464', 'mtu']:
            self.tun['mtu'] = int(argv[3])
        elif argv[:3] == ['/sbin/ifconfig', 'tun464', 'inet'] and argv[-1] == 'up':
            self.tun['inet'] = (argv[3].split('/')[0], argv[4])
        elif argv[:3] == ['/sbin/ifconfig', 'tun464', 'inet'] and argv[-1] == '-alias':
            self.tun['inet'] = None
        elif argv[:3] == ['/sbin/route', '-6', 'add'] and argv[4:] == ['-interface', 'tun464']:
            self.routes.add(argv[3])
        elif argv[:4] == ROUTE_DELETE:
            self.routes.discard(argv[4])
        elif argv == REGISTRATION and self.registration_repairs:
            self.cfg['record_ok'] = True

    def closed(self):
        """ The kernel removes the addresses of a tun that nobody holds open. """
        if self.tun is not None:
            self.tun['inet'] = None

    def spawn(self, argv):
        self.trace.append('spawn')
        pid = super().spawn(argv)
        if pid is not None and self.child_says is not None:
            self.child_output = list(self.child_says)
        if pid is not None and self.child_dies:
            self.exit_child(1)
        return pid

    def child_stop(self, timeout=5.0):
        self.trace.append('child_stop')
        super().child_stop(timeout)
        self.closed()

    def exit_child(self, code):
        super().exit_child(code)
        self.closed()

    def write(self, path, text, mode=0o644):
        self.trace.append('write ' + path)
        return super().write(path, text, mode)

    def remove(self, path):
        self.trace.append('remove ' + path)
        return super().remove(path)

    def mkdir(self, path, mode=0o755):
        self.trace.append('mkdir ' + path)
        return super().mkdir(path, mode)

    def dns_aaaa(self, server, name, timeout):
        self.trace.append('dns')
        return super().dns_aaaa(server, name, timeout)


class Scenario(unittest.TestCase):
    """ A supervisor on a Box, and what drives it. """

    def setUp(self):
        self.box = Box()
        self.sup = supervisor.Supervisor(self.box)

    def settings(self, **changes):
        """ Render clatd.json with these values changed; a reload makes the supervisor read it. """
        self.box.put(facts.SETTINGS, json.dumps(dict(facts.DEFAULT_SETTINGS, **changes)))

    def where(self):
        return (self.sup.state, self.sup.reason)

    def status(self):
        return json.loads(self.box.files[facts.STATUS])

    def helper_runs(self):
        return self.box.commands.count(HELPER_GATEWAYS)

    def run_for(self, seconds):
        """ Let time pass as the main loop would without events: every timer that comes due is handled. """
        end = self.box.clock + seconds
        while self.sup.timers and min(self.sup.timers.values()) <= end:
            self.box.clock = max(self.box.clock, min(self.sup.timers.values()))
            self.sup.handle(set())
        self.box.clock = max(self.box.clock, end)

    def tick(self):
        """ One second later the periodic check runs. """
        self.box.advance(1)
        self.sup.timers['tick'] = self.box.clock
        self.sup.handle(set())

    def route_event(self):
        """ The routing socket reports a change; the reconcile follows after the debounce time. """
        self.box.route_flag = True
        self.sup.handle({'route'})
        self.run_for(supervisor.DEBOUNCE)

    def advert(self, **fields):
        self.box.ra_queue.append(router_advert(**fields))
        self.sup.handle({'ra'})

    def activate(self, **fields):
        """ Start with the uplink up, then the router announces the NAT64 prefix. Returns the plan. """
        self.sup.start()
        self.advert(**fields)
        self.assertEqual(self.where(), ('active', ''))
        return self.sup.running

    def lose_uplink(self):
        self.box.wan_down()
        self.route_event()

    def regain_uplink(self, rewritten=False):
        self.box.wan_up(12)
        if rewritten:
            self.box.put(PREFIX_FILE, DELEGATED)
        self.route_event()


class ActivationTest(Scenario):
    def test_uplink_up_at_start_and_pref64_in_the_ra(self):
        self.sup.start()
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
        self.assertEqual(self.box.rs_sent, ['pppoe0'])
        self.assertIn('rs', self.sup.timers)
        mark = self.box.mark()
        self.advert()
        plan = self.sup.running
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.box.changes(mark), [SECRET_WRITE] + activation(plan, create=True))
        self.assertEqual(self.box.commands[-1], PFCTL_SN)
        self.assertEqual(plan.pref64, WKP)
        self.assertIn(plan.clat6, IPv6Network('2001:db8:1200:ff::/64'))
        self.assertEqual(int(plan.clat6) % 2, 0)
        self.assertEqual(plan.tayga6, plan.clat6 + 1)
        self.assertEqual((plan.tun_mtu, plan.offlink_mtu, plan.ipv4_mtu), (1492, 1492, 1472))
        self.assertEqual(self.box.files[facts.TAYGA_CONF], tayga_conf(plan, facts.DATA_DIR))
        self.assertEqual(self.box.spawned, [tayga_argv(facts.TAYGA_CONF)])
        self.assertEqual(self.box.files[facts.MARKER], '192.0.0.2\n')
        self.assertEqual(self.box.files[facts.ROUTER_FILE], '192.0.0.2\n')
        self.assertEqual(self.box.modes[facts.SECRET], 0o600)
        self.assertRegex(self.box.files[facts.SECRET], '^[0-9a-f]{64}\n$')
        self.assertFalse(self.sup.withdrawn)
        self.assertIn((5, 'state listening -> active'), self.box.logs)
        self.assertIn((5, 'CLAT gateway: active'), self.box.logs)
        self.assertEqual([entry for entry in self.box.logs if entry[0] < 5], [])

    def test_status_file(self):
        plan = self.activate()
        now = round(self.box.time())
        self.assertEqual(self.status(), {
            'updated': now,
            'state': 'active',
            'reason': '',
            'since': now,
            'uplink': 'pppoe0',
            'pref64': {'prefix': '64:ff9b::/96', 'source': 'ra', 'expires': now + 1800},
            'plan': {
                'clat6': str(plan.clat6),
                'tayga6': str(plan.tayga6),
                'ipv4_clat': '192.0.0.1',
                'ipv4_tayga': '192.0.0.2',
                'tun_mtu': 1492,
                'offlink_mtu': 1492,
                'ipv4_mtu': 1472,
            },
            'withdrawn': False,
            'tayga': {'started': now, 'restarts': 0, 'output': ['Using tun device tun464 with MTU 1492']},
        })
        self.assertEqual(self.sup.status(), self.status())

    def test_status_file_is_written_only_when_it_changes(self):
        self.activate()
        mark = self.box.mark()
        self.tick()
        self.tick()
        self.assertEqual(self.box.trace[mark:], [])
        self.advert(lifetime=3600)              # the lifetime is refreshed: no pass, the file shows it at once
        self.assertEqual(self.box.trace[mark:], ['write ' + facts.STATUS])
        self.assertEqual(self.status()['pref64']['expires'], round(self.box.time()) + 3600)
        self.advert(prefix='2001:db8:64::')     # an advertisement that changes nothing
        self.advert(source='fe80::bad')         # and one that is not accepted
        self.tick()
        self.assertEqual(self.box.trace[mark:], ['write ' + facts.STATUS])

    def test_secret_is_kept(self):
        self.box.put(facts.SECRET, 'ab' * 32 + '\n')
        first = self.activate()
        self.assertNotIn(SECRET_WRITE, self.box.trace)
        self.assertEqual(self.box.files[facts.SECRET], 'ab' * 32 + '\n')
        self.setUp()                                # another installation
        self.box.put(facts.SECRET, 'cd' * 32 + '\n')
        self.assertNotEqual(self.activate().clat6, first.clat6)

    def test_rs_burst_stops_at_the_accepted_ra(self):
        self.sup.start()
        self.advert()
        self.assertNotIn('rs', self.sup.timers)
        self.run_for(30)
        self.assertEqual(self.box.rs_sent, ['pppoe0'])

    def test_rs_burst_without_an_answer(self):
        self.sup.start()
        self.assertEqual(self.sup.next_timeout(), supervisor.RS_INTERVAL)
        self.run_for(3.5)
        self.assertEqual(len(self.box.rs_sent), 1)
        self.run_for(0.5)
        self.assertEqual(len(self.box.rs_sent), 2)
        self.run_for(4)
        self.assertEqual(len(self.box.rs_sent), 3)
        self.run_for(600)
        self.assertEqual(self.box.rs_sent, ['pppoe0'] * supervisor.RS_MAX)

    def test_ra_that_is_not_from_the_default_router_of_the_uplink(self):
        self.sup.start()
        for fields in ({'ifname': 'igc1'}, {'hoplimit': 64}, {'source': 'fe80::bad'}, {'source': '2001:db8::1'}):
            self.advert(**fields)
            self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
            self.assertIn('rs', self.sup.timers)
        self.assertEqual(self.box.spawned, [])

    def test_static_prefix(self):
        self.settings(prefix='2001:db8:64::/96')
        self.sup.start()
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.running.pref64, IPv6Network('2001:db8:64::/96'))
        self.assertEqual(self.status()['pref64'], {'prefix': '2001:db8:64::/96', 'source': 'static', 'expires': None})
        self.assertEqual(self.box.dns_queries, [])

    def test_missing_nat_rule_and_another_default_gateway_are_reported(self):
        self.settings(keep_with_native=True)
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        self.box.nat = False
        self.activate()
        report = 'CLAT gateway: active, but not the IPv4 default: gateway WAN2_DHCP is preferred'
        self.assertIn((4, report), self.box.logs)
        self.assertIn((4, 'there is no outbound NAT rule on tun464'), self.box.logs)


class DormantTest(Scenario):
    def test_no_nat64_prefix(self):
        self.sup.start()
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
        status = self.status()
        self.assertEqual((status['state'], status['reason']), ('listening', 'no_nat64_prefix'))
        self.assertEqual((status['uplink'], status['pref64'], status['plan']), ('pppoe0', None, None))
        self.assertEqual(status['tayga'], {'started': None, 'restarts': 0, 'output': []})
        count = len(self.box.commands)
        self.tick()
        self.run_for(5 * supervisor.TICK)
        self.assertEqual(self.box.commands[count:], [])
        self.assertEqual(self.box.changes(), ['mkdir ' + facts.RUN_DIR, 'remove ' + facts.STATUS])
        self.assertEqual(self.box.logs, [(5, 'state listening -> listening (no_nat64_prefix)')])
        self.assertGreater(len(self.box.dns_queries), 1)

    def test_dns_discovery_switched_off(self):
        self.settings(discover_dns=False)
        self.sup.start()
        self.run_for(5 * supervisor.TICK)
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
        self.assertEqual(self.box.dns_queries, [])
        self.assertNotIn('dns', self.sup.timers)

    def test_no_uplink(self):
        self.box.wan_down()
        self.sup.start()
        self.assertEqual(self.where(), ('listening', 'no_uplink_ipv6'))
        self.assertEqual(self.box.rs_sent, [])
        self.assertEqual(self.box.dns_queries, [])
        self.assertIsNone(self.status()['uplink'])

    def test_behind_the_gate_with_a_native_gateway(self):
        self.settings(prefix='64:ff9b::/96')
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        self.sup.start()
        self.assertEqual(self.where(), ('native-ipv4', 'gateway'))
        self.assertEqual(self.helper_runs(), 1)
        count = len(self.box.commands)
        self.tick()
        self.tick()
        self.assertEqual(self.box.commands[count:], [])
        self.route_event()
        self.assertEqual(self.helper_runs(), 2)
        self.assertEqual(self.where(), ('native-ipv4', 'gateway'))
        self.box.gw_extra = []
        self.route_event()
        self.assertEqual(self.helper_runs(), 3)
        self.assertEqual(self.where(), ('native-ipv4', 'hold'))
        self.assertEqual(self.sup.timers['hold'], self.box.clock + supervisor.NATIVE_GONE_HOLD)
        count = len(self.box.commands)
        self.tick()
        self.assertEqual(self.box.commands[count:], [])
        self.assertEqual(self.where(), ('native-ipv4', 'hold'))
        self.assertEqual(self.box.spawned, [])

    def test_behind_the_gate_with_a_stale_gateway(self):
        self.settings(prefix='64:ff9b::/96')
        self.box.gw_extra = [gateway('OLD_GW', 'igc3', upstream=True, dynamic=False, if_has_ipv4=False)]
        self.sup.start()
        self.assertEqual(self.where(), ('blocked', 'stale_gateway'))
        self.assertEqual(self.helper_runs(), 1)
        count = len(self.box.commands)
        self.tick()
        self.tick()
        self.assertEqual(self.box.commands[count:], [])
        self.route_event()
        self.assertEqual(self.helper_runs(), 2)
        self.assertEqual(self.where(), ('blocked', 'stale_gateway'))
        self.box.gw_extra = []
        self.route_event()
        self.assertEqual(self.where(), ('active', ''))


class NativeIpv4Test(Scenario):
    def test_native_gateway_appears_and_goes(self):
        plan = self.activate()
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        mark = self.box.mark()
        self.route_event()
        self.assertEqual(self.box.changes(mark), deactivation(plan))
        self.assertEqual(self.where(), ('native-ipv4', 'gateway'))
        self.assertIsNone(self.sup.running)
        self.assertIsNone(self.sup.facts.gw)
        self.assertNotIn(facts.MARKER, self.box.files)
        self.assertNotIn(facts.ROUTER_FILE, self.box.files)
        self.box.gw_extra = []
        self.route_event()
        self.assertEqual(self.where(), ('native-ipv4', 'hold'))
        self.run_for(supervisor.NATIVE_GONE_HOLD - 1)
        self.assertEqual(self.where(), ('native-ipv4', 'hold'))
        self.assertEqual(len(self.box.spawned), 1)
        self.run_for(1)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(len(self.box.spawned), 2)

    def test_hold_counts_from_the_pass_that_finds_native_ipv4_gone(self):
        self.settings(prefix='64:ff9b::/96')
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        self.sup.start()
        self.route_event()                          # the last pass that sees the gateway
        seen = self.box.clock
        self.box.gw_extra = []
        self.run_for(59 - supervisor.DEBOUNCE)      # timers use the facts they have
        self.assertEqual(self.where(), ('native-ipv4', 'gateway'))
        self.route_event()                          # 59 s later a pass finds it gone
        self.assertEqual(self.box.clock, seen + 59)
        self.assertEqual(self.where(), ('native-ipv4', 'hold'))
        self.run_for(supervisor.NATIVE_GONE_HOLD - 1)
        self.assertEqual(self.where(), ('native-ipv4', 'hold'))
        self.assertEqual(self.box.spawned, [])
        self.run_for(1)
        self.assertEqual(self.where(), ('active', ''))

    def test_native_gateway_back_before_the_hold_ends(self):
        self.settings(prefix='64:ff9b::/96')
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        self.sup.start()
        self.box.gw_extra = []
        self.route_event()
        self.assertEqual(self.where(), ('native-ipv4', 'hold'))
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]      # no event tells: the facts held are stale
        self.run_for(supervisor.NATIVE_GONE_HOLD)
        self.assertEqual(self.where(), ('native-ipv4', 'gateway'))  # they are gathered afresh before activating
        self.assertEqual(self.box.spawned, [])

    def test_keep_with_native(self):
        self.settings(keep_with_native=True)
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        self.activate()

    def test_gateway_facts_are_not_kept_before_the_gate(self):
        self.settings(prefix='64:ff9b::/96')
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        self.sup.start()
        self.assertTrue(self.sup.gated)
        self.assertIsNotNone(self.sup.facts.gw)
        self.settings()
        self.sup.handle({'hup'})
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
        self.assertFalse(self.sup.gated)
        self.assertIsNone(self.sup.facts.gw)

    def test_native_gateway_while_suspended(self):
        plan = self.activate()
        self.lose_uplink()
        self.run_for(supervisor.UPLINK_LOSS_GRACE)
        self.assertEqual(self.where(), ('suspended', ''))
        self.assertFalse(self.sup.withdrawn)
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        mark = self.box.mark()
        self.route_event()
        self.assertEqual(self.box.changes(mark), deactivation(plan))
        self.assertEqual(self.where(), ('native-ipv4', 'gateway'))

    def test_no_dns_query_while_a_native_gateway_keeps_the_clat_down(self):
        self.box.dns_outcome = ('answer', ['64:ff9b::c000:aa', '64:ff9b::c000:ab'], 600)
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        self.sup.start()
        self.assertEqual(self.where(), ('native-ipv4', 'gateway'))
        self.assertEqual(self.box.dns_queries, [('127.0.0.1', 'ipv4only.arpa.')])
        self.run_for(7200)
        self.assertEqual(len(self.box.dns_queries), 1)
        self.assertNotIn('dns', self.sup.timers)
        self.box.gw_extra = []
        self.route_event()
        self.assertEqual(self.where(), ('native-ipv4', 'hold'))
        self.assertEqual(len(self.box.dns_queries), 1)
        self.run_for(supervisor.NATIVE_GONE_HOLD)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(len(self.box.dns_queries), 2)
        asked = len(self.box.trace) - 1 - self.box.trace[::-1].index('dns')
        self.assertLess(asked, self.box.trace.index('spawn'))
        self.assertEqual(self.status()['pref64'], {'prefix': '64:ff9b::/96', 'source': 'dns', 'expires': None})

    def test_router_file_on_the_uplink(self):
        self.box.put('/tmp/pppoe0_router', '203.0.113.1\n')
        self.sup.start()
        self.advert()
        self.assertEqual(self.where(), ('native-ipv4', 'uplink'))
        self.assertEqual(self.helper_runs(), 0)
        self.assertEqual(self.box.spawned, [])

    def test_ipv4_address_on_the_uplink_ends_the_clat(self):
        plan = self.activate()
        self.box.wan_inet = '203.0.113.5'
        mark = self.box.mark()
        self.route_event()
        self.assertEqual(self.box.changes(mark), deactivation(plan))
        self.assertEqual(self.where(), ('native-ipv4', 'uplink'))
        self.box.wan_inet = None
        self.route_event()
        self.assertEqual(self.where(), ('native-ipv4', 'hold'))


class PrefixTest(Scenario):
    def test_ra_lifetime_runs_out(self):
        plan = self.activate(lifetime=600)
        self.assertEqual(self.sup.timers['pref64'], self.box.clock + 600)
        mark = self.box.mark()
        self.run_for(599)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.box.changes(mark), [])
        self.run_for(1)
        self.assertEqual(self.box.changes(mark), deactivation(plan))
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
        self.assertEqual(self.box.trace[mark:].count('dns'), 1)

    def test_ra_lifetime_runs_out_and_dns_gives_the_same_prefix(self):
        plan = self.activate(lifetime=600)
        self.box.dns_outcome = ('answer', ['64:ff9b::c000:aa'], 300)
        mark = self.box.mark()
        self.run_for(601)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.box.changes(mark), [])
        self.assertEqual(len(self.box.spawned), 1)
        self.assertEqual(self.status()['pref64'], {'prefix': '64:ff9b::/96', 'source': 'dns', 'expires': None})

    def test_dns_prefix_is_forgotten_while_the_ra_has_one(self):
        self.box.dns_outcome = ('answer', ['64:ff9b::c000:aa'], 3600)
        self.sup.start()
        plan = self.sup.running
        self.assertEqual(self.where(), ('active', ''))
        self.advert(lifetime=600)                   # from now on the RA is the source
        self.assertEqual(self.status()['pref64']['source'], 'ra')
        self.assertEqual(self.sup.running, plan)
        self.box.dns_outcome = ('answer', [], 3600)
        mark = self.box.mark()
        self.run_for(600)                           # the RA entry expires: DNS is asked, not remembered
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
        self.assertEqual(self.box.changes(mark), deactivation(plan))

    def test_ra_withdraws_the_prefix(self):
        plan = self.activate()
        mark = self.box.mark()
        self.advert(lifetime=0)
        self.assertEqual(self.box.changes(mark), deactivation(plan))
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))

    def test_another_prefix_in_the_ra_is_ignored(self):
        plan = self.activate()
        mark = self.box.mark()
        self.advert(prefix='2001:db8:64::')
        self.assertEqual(self.box.trace[mark:], [])
        self.assertEqual(self.sup.running, plan)

    def test_dns_prefix(self):
        self.box.dns_outcome = ('answer', ['64:ff9b::c000:aa', '64:ff9b::c000:ab'], 30)
        self.sup.start()
        plan = self.sup.running
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.timers['dns'], self.box.clock + discovery.DNS_MIN_REFRESH)
        self.box.dns_outcome = ('fail', 'timeout', None)      # a time-out is not an answer
        mark = self.box.mark()
        self.run_for(600)
        self.assertEqual(self.where(), ('active', ''))
        self.assertGreater(self.box.trace[mark:].count('dns'), 1)
        self.assertEqual(self.box.changes(mark), [])
        self.box.dns_outcome = ('answer', [], 60)             # the name has no AAAA record any more
        self.run_for(discovery.DNS_NEGATIVE_MAX)
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
        self.assertEqual(self.box.changes(mark), deactivation(plan))


class UplinkLossTest(Scenario):
    def test_no_other_gateway(self):
        plan = self.activate()
        mark = self.box.mark()
        self.lose_uplink()
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.timers['grace'], self.box.clock + supervisor.UPLINK_LOSS_GRACE)
        count = len(self.box.commands)
        self.run_for(supervisor.UPLINK_LOSS_GRACE - 1)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.box.commands[count:], [])
        self.assertEqual(self.box.changes(mark), [])
        self.run_for(1)
        self.assertEqual(self.where(), ('suspended', ''))
        self.assertFalse(self.sup.withdrawn)
        self.assertIsNone(self.status()['uplink'])
        self.assertIn(facts.MARKER, self.box.files)
        self.assertEqual(self.box.changes(mark), [])
        count = len(self.box.commands)
        self.tick()
        self.assertEqual(self.box.commands[count:], [])
        self.regain_uplink(rewritten=True)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.box.changes(mark), [])
        self.assertEqual(len(self.box.spawned), 1)
        self.assertEqual(self.box.rs_sent, ['pppoe0', 'pppoe0'])

    def test_session_ends_and_the_device_and_the_route_stay(self):
        # what OPNsense 26.7 does when mpd5 loses the session and redials: pppoe0 keeps its index and the
        # IPv6 default route stays in the table; the device is down and has no address until the new session
        plan = self.activate()
        mark = self.box.mark()
        self.box.wan_link = False
        self.route_event()
        self.assertEqual(self.where(), ('active', ''))
        self.assertIsNone(self.sup.facts.route6)
        self.assertEqual(self.sup.timers['grace'], self.box.clock + supervisor.UPLINK_LOSS_GRACE)
        self.run_for(supervisor.UPLINK_LOSS_GRACE)
        self.assertEqual(self.where(), ('suspended', ''))
        self.assertFalse(self.sup.withdrawn)
        self.assertIsNone(self.status()['uplink'])
        self.assertEqual(self.box.changes(mark), [])
        self.box.wan_link = True
        self.route_event()
        self.assertEqual(self.where(), ('active', ''))
        self.assertTrue(self.sup.pd_trusted)        # the same device under the same index
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.box.changes(mark), [])
        self.assertEqual(len(self.box.spawned), 1)
        self.assertEqual(self.box.rs_sent, ['pppoe0', 'pppoe0'])

    def test_session_back_within_the_grace_period_and_the_device_stayed(self):
        plan = self.activate()
        mark = self.box.mark()
        self.box.wan_link = False
        self.route_event()
        # the loss was noticed although the route is still in the table: the grace period runs
        self.assertIsNone(self.sup.facts.route6)
        self.assertEqual(self.sup.timers['grace'], self.box.clock + supervisor.UPLINK_LOSS_GRACE)
        self.box.wan_link = True
        self.route_event()
        self.assertEqual(self.sup.facts.route6[0], 'pppoe0')
        self.assertNotIn('grace', self.sup.timers)
        self.run_for(supervisor.UPLINK_LOSS_GRACE)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.box.changes(mark), [])

    def test_uplink_device_gone_is_noticed_by_a_timer(self):
        self.activate()
        self.box.wan_down()
        mark = self.box.mark()
        self.tick()
        self.assertEqual(self.box.trace[mark:mark + 2], [' '.join(ROUTE_GET), ' '.join(IFCONFIG_A)])
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.timers['grace'], self.box.clock + supervisor.UPLINK_LOSS_GRACE)
        count = len(self.box.commands)
        self.tick()
        self.assertEqual(self.box.commands[count:], [])

    def test_uplink_back_within_the_grace_period(self):
        plan = self.activate()
        mark = self.box.mark()
        self.lose_uplink()
        self.regain_uplink(rewritten=True)
        self.assertEqual(self.where(), ('active', ''))
        self.assertNotIn('grace', self.sup.timers)
        self.run_for(supervisor.UPLINK_LOSS_GRACE)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.box.changes(mark), [])

    def test_another_gateway_takes_over(self):
        self.settings(keep_with_native=True)
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        self.box.fallback = 'WAN2_DHCP'
        plan = self.activate()
        mark = self.box.mark()
        self.lose_uplink()
        self.run_for(supervisor.UPLINK_LOSS_GRACE)
        self.assertEqual(self.where(), ('suspended', ''))
        self.assertTrue(self.sup.withdrawn)
        self.assertTrue(self.status()['withdrawn'])
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.box.changes(mark), [
            'remove ' + facts.MARKER,
            IFCTL + ' -i tun464 -4rd',
            '/sbin/ifconfig tun464 inet 192.0.0.1 -alias',
            '/sbin/pfctl -k 192.0.0.1',
            CONFIGCTL + ' interface routes configure',
        ])
        mark = self.box.mark()
        self.regain_uplink(rewritten=True)
        self.assertEqual(self.where(), ('active', ''))
        self.assertFalse(self.sup.withdrawn)
        self.assertEqual(self.box.changes(mark), replaying(plan, address=True))
        self.assertEqual([entry for entry in self.box.changes(mark) if entry.startswith('/sbin/route')], [])
        self.assertEqual(len(self.box.spawned), 1)
        self.assertEqual(self.box.tun['inet'], ('192.0.0.1', '192.0.0.2'))

    def test_resume_on_a_timer_after_a_withdraw(self):
        self.settings(keep_with_native=True)
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        self.box.fallback = 'WAN2_DHCP'
        plan = self.activate()
        del self.box.files[PREFIX_FILE]             # the delegation is lost, the default route stays
        self.tick()
        self.assertEqual(self.sup.timers['grace'], self.box.clock + supervisor.UPLINK_LOSS_GRACE)
        self.run_for(supervisor.UPLINK_LOSS_GRACE)
        self.assertEqual(self.where(), ('suspended', ''))
        self.assertTrue(self.sup.withdrawn)
        self.box.put(PREFIX_FILE, DELEGATED)
        mark = self.box.mark()
        self.tick()                                 # the interface facts held are older than the withdraw
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.box.changes(mark), replaying(plan, address=True))


class SessionTest(Scenario):
    def new_session(self):
        """ The uplink goes and comes back; core's prefix file is still the one of the old session. """
        self.lose_uplink()
        self.assertEqual(self.where(), ('listening', 'no_uplink_ipv6'))
        self.regain_uplink()
        self.assertFalse(self.sup.pd_trusted)
        self.advert()
        self.assertEqual(self.where(), ('waiting-for-prefix-delegation', ''))
        self.tick()
        self.assertEqual(self.where(), ('waiting-for-prefix-delegation', ''))
        self.assertEqual(self.box.spawned, [])

    def test_rewritten_prefix_file_confirms_the_session(self):
        self.sup.start()
        self.new_session()
        self.box.put(PREFIX_FILE, DELEGATED)
        self.tick()
        self.assertEqual(self.where(), ('active', ''))

    def test_usr2_confirms_the_session(self):
        self.sup.start()
        self.new_session()
        self.sup.handle({'usr1'})
        self.assertEqual(self.where(), ('waiting-for-prefix-delegation', ''))
        self.sup.handle({'usr2'})
        self.assertEqual(self.where(), ('active', ''))

    def test_usr2_of_a_trusted_session_is_used_up(self):
        self.sup.start()
        self.sup.handle({'usr2'})
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
        self.assertFalse(self.sup.event6)
        self.new_session()

    def test_usr2_without_an_uplink_is_used_up(self):
        self.sup.start()
        self.lose_uplink()
        self.sup.handle({'usr2'})
        self.assertFalse(self.sup.event6)
        self.regain_uplink()
        self.advert()
        self.assertEqual(self.where(), ('waiting-for-prefix-delegation', ''))

    def test_resume_waits_for_the_prefix_of_the_new_session(self):
        plan = self.activate()
        mark = self.box.mark()
        self.lose_uplink()
        self.regain_uplink()
        self.assertEqual(self.where(), ('active', ''))
        self.run_for(supervisor.UPLINK_LOSS_GRACE)
        self.assertEqual(self.where(), ('suspended', ''))
        self.box.put(PREFIX_FILE, DELEGATED)
        self.tick()
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.box.changes(mark), [])

    def test_missing_prefix_file(self):
        del self.box.files[PREFIX_FILE]
        self.sup.start()
        self.advert()
        self.assertEqual(self.where(), ('waiting-for-prefix-delegation', ''))
        self.assertEqual(self.helper_runs(), 0)
        self.box.put(PREFIX_FILE, '2001:db8:1200:aa00::/64\n')
        self.tick()
        self.assertEqual(self.where(), ('active', ''))
        self.assertIn(self.sup.running.clat6, IPv6Network('2001:db8:1200:aa00::/64'))

    def test_gap_in_the_default_route_is_the_same_session(self):
        self.sup.start()
        self.box.route_get = (1, '', 'route: route has not been found\n')
        self.route_event()                          # the route is gone, the device stays
        self.assertEqual(self.where(), ('listening', 'no_uplink_ipv6'))
        self.box.route_get = None
        self.route_event()                          # back on the same device under the same index
        self.assertTrue(self.sup.pd_trusted)
        self.advert()
        self.assertEqual(self.where(), ('active', ''))

    def test_failed_route_command_is_the_same_session(self):
        plan = self.activate()
        mark = self.box.mark()
        self.box.route_get = (124, '', '')          # the command gave no answer
        self.route_event()
        self.box.route_get = None
        self.route_event()
        self.assertTrue(self.sup.pd_trusted)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.box.changes(mark), [])


class RenumberTest(Scenario):
    def test_new_delegated_prefix(self):
        old = self.activate()
        self.run_for(supervisor.RESTART_MIN_INTERVAL + 1)
        self.box.put(PREFIX_FILE, '2001:db8:3400::/56\n')
        mark = self.box.mark()
        self.sup.handle({'usr2'})
        new = self.sup.running
        self.assertIn(new.clat6, IPv6Network('2001:db8:3400:ff::/64'))
        self.assertEqual(self.box.changes(mark), renumbering(old) + activation(new))
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.restarts, 0)

        self.box.advance(10)                        # a second change shortly after
        self.box.put(PREFIX_FILE, '2001:db8:5600::/56\n')
        mark = self.box.mark()
        self.sup.handle({'usr2'})
        self.assertEqual(self.sup.running, new)
        self.assertEqual(self.box.changes(mark), [])
        self.assertEqual(self.sup.timers['restart'], self.sup.tayga_started + supervisor.RESTART_MIN_INTERVAL)
        self.assertEqual(self.status()['plan']['clat6'], str(new.clat6))
        self.run_for(supervisor.RESTART_MIN_INTERVAL - 11)
        self.assertEqual(self.sup.running, new)
        self.run_for(1)
        self.assertIn(self.sup.running.clat6, IPv6Network('2001:db8:5600:ff::/64'))
        self.assertEqual(self.box.changes(mark), renumbering(new) + activation(self.sup.running))
        self.assertEqual(len(self.box.spawned), 3)
        self.assertNotIn('restart', self.sup.timers)

    def test_mtu_change_restarts_tayga(self):
        old = self.activate()
        self.run_for(supervisor.RESTART_MIN_INTERVAL + 1)
        self.box.wan_mtu = 1500
        mark = self.box.mark()
        self.route_event()
        new = self.sup.running
        self.assertEqual((new.tun_mtu, new.offlink_mtu, new.ipv4_mtu), (1500, 1500, 1480))
        self.assertEqual(new.clat6, old.clat6)
        self.assertEqual(self.box.changes(mark), renumbering(old) + activation(new))
        self.assertEqual(self.sup.output[-1], 'Using tun device tun464 with MTU 1500')


class TaygaExitTest(Scenario):
    def crash(self):
        self.box.child_output = ['poll returned error Bad file descriptor']
        self.box.exit_child(1)
        self.sup.handle({'chld'})

    def test_exit_and_retry(self):
        plan = self.activate()
        mark = self.box.mark()
        self.crash()
        self.assertEqual(self.where(), ('backoff', 'tayga_exit'))
        self.assertEqual(self.box.changes(mark), ['remove ' + facts.MARKER, IFCTL + ' -i tun464 -4rd', 'child_stop'])
        self.assertNotIn(facts.MARKER, self.box.files)
        self.assertNotIn(facts.ROUTER_FILE, self.box.files)
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.sup.restarts, 1)
        self.assertEqual(self.sup.timers['backoff'], self.box.clock + 5)
        self.assertIsNotNone(self.sup.facts.gw)
        status = self.status()
        self.assertEqual(status['tayga']['started'], None)
        self.assertEqual(status['tayga']['restarts'], 1)
        self.assertEqual(status['tayga']['output'][-1], 'poll returned error Bad file descriptor')
        self.assertIn((3, 'tayga exited with status 1'), self.box.logs)
        mark = self.box.mark()
        self.run_for(4)
        self.assertEqual(self.box.changes(mark), [])
        self.run_for(1)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.box.changes(mark), activation(plan))
        self.assertEqual(self.sup.restarts, 1)

    def test_delays_grow_and_start_over_after_a_quiet_time(self):
        self.activate()
        for delay in supervisor.BACKOFF_STEPS + (supervisor.BACKOFF_STEPS[-1],):
            self.crash()
            self.assertEqual(self.sup.timers['backoff'], self.box.clock + delay)
            self.run_for(delay)
            self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.restarts, 6)
        self.advert()                               # the prefix stays alive during the quiet time
        self.run_for(supervisor.BACKOFF_RESET + supervisor.TICK)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.failures, 0)
        self.crash()
        self.assertEqual(self.sup.timers['backoff'], self.box.clock + supervisor.BACKOFF_STEPS[0])

    def test_exit_noticed_by_a_timer(self):
        self.activate()
        self.box.exit_child(1)
        self.tick()
        self.assertEqual(self.where(), ('backoff', 'tayga_exit'))

    def test_disabled_during_the_backoff(self):
        plan = self.activate()
        self.crash()
        self.settings(enabled=False)
        mark = self.box.mark()
        self.sup.handle({'hup'})
        self.assertEqual(self.box.changes(mark), deactivation(plan))
        self.assertEqual(self.where(), ('disabled', ''))
        self.assertIsNone(self.sup.running)
        self.assertNotIn('backoff', self.sup.timers)

    def test_delegated_prefix_changes_during_the_backoff(self):
        old = self.activate()
        self.crash()
        self.box.put(PREFIX_FILE, '2001:db8:3400::/56\n')
        mark = self.box.mark()
        self.run_for(5)
        new = self.sup.running
        self.assertEqual(self.where(), ('active', ''))
        self.assertIn(new.clat6, IPv6Network('2001:db8:3400:ff::/64'))
        self.assertEqual(self.box.changes(mark), renumbering(old) + activation(new))

    def test_uplink_lost_during_the_backoff(self):
        plan = self.activate()
        self.crash()
        mark = self.box.mark()
        self.lose_uplink()
        self.assertEqual(self.where(), ('listening', 'no_uplink_ipv6'))
        self.assertEqual(self.sup.running, plan)        # still to be cleaned up or activated again
        self.assertEqual(self.box.changes(mark), [])
        self.assertNotIn('backoff', self.sup.timers)
        self.regain_uplink(rewritten=True)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.box.changes(mark), activation(plan))


class ActivationFailureTest(Scenario):
    def fail_at(self, step_done):
        """ Expected trace of an activation that fails right after the given entry. """
        self.sup.start()
        mark = self.box.mark()
        self.advert()
        plan = self.sup.wanted
        steps = activation(plan, create=True)
        cut = [index for index, entry in enumerate(steps) if entry.startswith(step_done)][-1] + 1
        self.assertEqual(self.box.changes(mark), [SECRET_WRITE] + steps[:cut] + deactivation(plan))
        self.assertIsNone(self.sup.running)
        self.assertEqual(self.sup.timers['backoff'], self.box.clock + 5)
        self.assertEqual(self.status()['plan']['clat6'], str(plan.clat6))
        return plan

    def test_route_add_fails(self):
        self.box.reply(['/sbin/route', '-6', 'add'], rc=1, err='route: writing to routing socket: Invalid argument\n')
        plan = self.fail_at('/sbin/route -6 add')
        self.assertEqual(self.where(), ('backoff', 'step_route'))
        self.assertIn((5, 'state listening -> backoff (step_route)'), self.box.logs)
        failed = '/sbin/route -6 add %s/127 -interface tun464' % plan.clat6
        warning = 'command failed (1): %s: route: writing to routing socket: Invalid argument' % failed
        self.assertIn((4, warning), self.box.logs)
        self.run_for(5)
        self.assertEqual(self.where(), ('backoff', 'step_route'))
        self.assertEqual(self.sup.timers['backoff'], self.box.clock + 10)
        self.box.reply(['/sbin/route', '-6', 'add'])
        self.run_for(10)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.sup.running, plan)

    def test_spawn_fails(self):
        self.box.spawn_fails = True
        self.fail_at('spawn')
        self.assertEqual(self.where(), ('backoff', 'tayga_start'))

    def test_tayga_exits_while_starting(self):
        self.box.child_says = ['Unable to open /dev/tun464, aborting: Device busy']
        self.box.child_dies = True
        self.fail_at('spawn')
        self.assertEqual(self.where(), ('backoff', 'tayga_start'))
        self.assertIn((3, 'tayga: Unable to open /dev/tun464, aborting: Device busy'), self.box.logs)
        self.assertEqual(self.status()['tayga']['output'], ['Unable to open /dev/tun464, aborting: Device busy'])

    def test_tayga_exits_after_reporting_the_tun(self):
        self.box.child_says = ['Using tun device tun464 with MTU 1492', 'Error: cannot set uid to 65534: denied']
        self.box.child_dies = True
        self.fail_at('spawn')                       # nothing is set up on a tun that nobody holds open
        self.assertEqual(self.where(), ('backoff', 'tayga_start'))
        self.assertIn((3, 'tayga did not start'), self.box.logs)

    def test_tayga_does_not_report_the_tun(self):
        self.box.tayga_fails = True
        self.sup.start()
        before = self.box.clock
        self.advert()
        self.assertEqual(self.where(), ('backoff', 'tayga_start'))
        self.assertAlmostEqual(self.box.clock - before, supervisor.TAYGA_START_TIMEOUT, delta=0.11)
        self.assertEqual(self.sup.timers['backoff'], self.box.clock + 5)
        self.assertIsNone(self.box.child_pid)

    def test_tayga_reports_another_mtu(self):
        self.box.child_says = ['Using tun device tun464 with MTU 1500']
        self.fail_at('spawn')
        self.assertEqual(self.where(), ('backoff', 'tayga_start'))

    def test_configctl_does_not_answer_ok(self):
        self.box.reply([CONFIGCTL, 'interface', 'newip'], out='Execute error\n')
        self.fail_at(CONFIGCTL + ' interface newip')
        self.assertEqual(self.where(), ('backoff', 'step_newip'))

    def test_filter_reload_before_the_default_route_fails(self):
        self.box.reply([CONFIGCTL, 'filter', 'reload'], out='Error (1)\n')
        self.fail_at(CONFIGCTL + ' filter reload')
        self.assertEqual(self.where(), ('backoff', 'step_newip'))


class HelperFailureTest(Scenario):
    DELAYS = supervisor.BACKOFF_STEPS[1:] + supervisor.BACKOFF_STEPS[-1:]     # after the first failure

    def next_attempt(self):
        """ Let the back-off end; the timers that come due before that are handled too. """
        self.run_for(self.sup.timers['backoff'] - self.box.clock)

    def test_helper_fails_before_the_activation(self):
        self.sup.start()
        self.box.helper_ok = False
        self.advert()
        self.assertEqual(self.where(), ('backoff', 'facts'))
        self.assertEqual(self.box.changes()[2:], [])
        self.box.helper_ok = True
        self.run_for(5)
        self.assertEqual(self.where(), ('active', ''))

    def test_helper_is_repeated_with_the_backoff(self):
        self.sup.start()
        self.box.helper_ok = False
        self.advert()
        self.assertEqual(self.where(), ('backoff', 'facts'))
        self.assertEqual((self.helper_runs(), self.sup.failures), (1, 1))
        due = self.sup.timers['backoff']
        count = len(self.box.commands)
        self.tick()
        self.assertEqual(self.box.commands[count:], [])       # a timer does not run it again
        self.route_event()
        self.assertEqual((self.helper_runs(), self.sup.failures), (1, 1))
        self.assertEqual(self.sup.timers['backoff'], due)
        for delay in self.DELAYS:
            self.next_attempt()
            self.assertEqual(self.sup.timers['backoff'], self.box.clock + delay)
        self.assertEqual(self.helper_runs(), 1 + len(self.DELAYS))
        self.assertEqual(self.box.spawned, [])

    def test_helper_fails_while_dormant_behind_the_gate(self):
        self.settings(prefix='64:ff9b::/96')
        self.box.gw_extra = [gateway('WAN2_DHCP', 'igc2')]
        self.sup.start()
        self.assertEqual(self.where(), ('native-ipv4', 'gateway'))
        self.box.helper_ok = False
        self.route_event()
        self.assertEqual(self.where(), ('backoff', 'facts'))
        count = len(self.box.commands)
        self.tick()
        self.tick()
        self.assertEqual(self.box.commands[count:], [])
        self.box.helper_ok = True
        self.next_attempt()
        self.assertEqual(self.where(), ('native-ipv4', 'gateway'))
        self.assertEqual(self.helper_runs(), 3)

    def test_helper_fails_while_active(self):
        self.settings(prefix='64:ff9b::/96')
        self.sup.start()
        self.assertEqual(self.where(), ('active', ''))
        self.run_for(supervisor.BACKOFF_RESET + supervisor.TICK)
        self.box.helper_ok = False
        mark = self.box.mark()
        self.route_event()
        self.assertEqual(self.where(), ('active', ''))      # nothing changes in that pass
        self.assertIsNone(self.sup.facts.gw)
        self.assertEqual(self.sup.timers['backoff'], self.box.clock + supervisor.BACKOFF_STEPS[0])
        count = len(self.box.commands)
        self.tick()
        self.assertEqual(self.box.commands[count:], [])       # a timer does not run it again
        for delay in self.DELAYS:                             # and the ticks do not start the delays over
            self.next_attempt()
            self.assertEqual(self.sup.timers['backoff'], self.box.clock + delay)
        self.assertEqual(self.where(), ('active', ''))
        self.box.helper_ok = True
        self.next_attempt()
        self.assertEqual(self.where(), ('active', ''))
        self.assertIsNotNone(self.sup.facts.gw)
        self.assertNotIn('backoff', self.sup.timers)
        self.assertEqual(self.box.changes(mark), [])

    def test_deactivation_ends_the_wait_for_the_helper(self):
        self.activate()
        self.box.helper_ok = False
        self.route_event()                          # the helper fails: its next run is 5 s away
        self.box.helper_ok = True
        self.advert(lifetime=0)                     # the router withdraws the prefix
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
        self.assertNotIn('backoff', self.sup.timers)
        self.advert()
        self.assertEqual(self.where(), ('active', ''))

    def test_config_facts_unreadable_at_start(self):
        self.box.cfg['nat_mode'] = 'advanced'
        self.box.config_ok = False
        self.sup.start()
        self.assertEqual(self.where(), ('backoff', 'facts'))
        self.advert()
        self.assertEqual(self.where(), ('backoff', 'facts'))    # nothing is activated without them
        self.assertIsNone(self.sup.facts.cfg)
        self.tick()
        self.assertEqual(self.box.commands.count(HELPER_CONFIG), 1)
        self.next_attempt()
        self.assertEqual(self.box.commands.count(HELPER_CONFIG), 2)
        self.assertEqual(self.sup.timers['backoff'], self.box.clock + supervisor.BACKOFF_STEPS[1])
        self.assertEqual((self.helper_runs(), self.box.spawned), (0, []))
        self.box.config_ok = True
        self.next_attempt()
        self.assertEqual(self.where(), ('blocked', 'nat_mode'))
        self.assertEqual(self.box.spawned, [])

    def test_config_facts_unreadable_while_active(self):
        plan = self.activate()
        self.box.cfg['nat_mode'] = 'disabled'
        self.box.put(facts.CONFIG_XML, '<opnsense><changed/></opnsense>')
        self.box.config_ok = False
        mark = self.box.mark()
        self.tick()
        self.assertEqual(self.where(), ('active', ''))      # nothing changes in that pass
        self.assertEqual(self.sup.timers['backoff'], self.box.clock + supervisor.BACKOFF_STEPS[0])
        count = len(self.box.commands)
        self.tick()
        self.assertEqual(self.box.commands[count:], [])       # the read is not repeated on every tick
        self.assertEqual(self.where(), ('active', ''))
        self.box.config_ok = True
        self.next_attempt()
        self.assertEqual(self.where(), ('blocked', 'nat_mode'))
        self.assertEqual(self.box.changes(mark), deactivation(plan))


class StartTest(Scenario):
    CLEANUP = ['remove ' + facts.MARKER, IFCTL + ' -i tun464 -4rd', 'child_stop',
               CONFIGCTL + ' interface routes configure']

    def test_nothing_left_behind(self):
        self.sup.start()
        self.assertEqual(self.box.changes(), ['mkdir ' + facts.RUN_DIR, 'remove ' + facts.STATUS])
        self.assertEqual(self.box.dirs[facts.RUN_DIR], 0o755)

    def test_marker_left_behind(self):
        self.box.put(facts.MARKER, '192.0.0.2\n')
        self.box.put(facts.STATUS, '{"state": "active"}\n')
        self.sup.start()
        self.assertEqual(self.box.changes(), ['mkdir ' + facts.RUN_DIR, 'remove ' + facts.STATUS] + self.CLEANUP)
        self.assertEqual(self.status()['state'], 'listening')

    def test_router_file_left_behind(self):
        self.box.put(facts.ROUTER_FILE, '192.0.0.2\n')
        self.sup.start()
        self.assertEqual(self.box.changes()[2:], self.CLEANUP)
        self.assertNotIn(facts.ROUTER_FILE, self.box.files)

    def leftover_tayga(self, comm):
        self.box.tun = {'mtu': 1492, 'inet': ('192.0.0.1', '192.0.0.2')}
        self.box.ifindex['tun464'] = 9
        self.box.holder = 777
        self.box.pids.add(777)
        self.box.reply(['/bin/ps', '-o', 'comm=', '-p', '777'], out=comm + '\n')

    def test_tayga_left_on_the_tun(self):
        self.leftover_tayga('tayga')
        before = self.box.clock
        self.sup.start()
        self.assertEqual(self.box.signals, [(777, self.box.SIGTERM), (777, self.box.SIGKILL)])
        self.assertAlmostEqual(self.box.clock - before, 5.0, places=6)

    def test_tayga_left_on_the_tun_stops_when_asked(self):
        def kill(pid, signo):
            self.box.signals.append((pid, signo))
            self.box.pids.discard(pid)
            return True

        self.leftover_tayga('tayga')
        self.box.kill = kill
        before = self.box.clock
        self.sup.start()
        self.assertEqual(self.box.signals, [(777, self.box.SIGTERM)])
        self.assertEqual(self.box.clock, before)

    def test_another_program_on_the_tun(self):
        self.leftover_tayga('openvpn')
        self.sup.start()
        self.assertEqual(self.box.signals, [])


class DriftTest(Scenario):
    def drift(self):
        """ Someone applied an edit of the CLAT record in Interfaces: Assignments. """
        self.box.cfg['record_ok'] = False
        self.box.put(facts.CONFIG_XML, '<opnsense><changed/></opnsense>')

    def test_registration_and_replay(self):
        plan = self.activate()
        self.drift()
        self.box.put(facts.TODO_FILE, 'a:0:{}')
        mark = self.box.mark()
        self.tick()
        self.assertEqual(self.box.changes(mark), [])          # an edit is waiting to be applied
        del self.box.files[facts.TODO_FILE]
        self.tick()
        self.assertEqual(self.box.changes(mark), [' '.join(REGISTRATION)] + replaying(plan))
        self.assertEqual(self.where(), ('active', ''))
        self.assertTrue(self.sup.facts.cfg['record_ok'])
        self.tick()
        self.assertEqual(self.box.commands.count(REGISTRATION), 1)

    def test_registration_is_rate_limited(self):
        self.box.registration_repairs = False
        self.sup.start()
        self.drift()
        mark = self.box.mark()
        self.tick()
        self.assertEqual(self.box.changes(mark), [' '.join(REGISTRATION)])     # no replay: nothing is active
        self.run_for(supervisor.DRIFT_REPAIR_MIN_INTERVAL - 1)
        self.assertEqual(self.box.commands.count(REGISTRATION), 1)
        self.run_for(1)
        self.assertEqual(self.box.commands.count(REGISTRATION), 2)
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))

    def test_router_file_removed(self):
        plan = self.activate()
        del self.box.files[facts.ROUTER_FILE]       # core does that whenever the record is applied
        mark = self.box.mark()
        self.tick()
        self.assertEqual(self.box.changes(mark), replaying(plan))
        self.assertEqual(self.where(), ('active', ''))

    def test_tun_addresses_removed(self):
        plan = self.activate()
        self.box.tun['inet'] = None
        mark = self.box.mark()
        self.tick()
        self.assertEqual(self.box.changes(mark), [])          # a timer does not look at the interfaces
        self.route_event()
        self.assertEqual(self.box.changes(mark), replaying(plan, address=True))
        self.assertEqual(self.where(), ('active', ''))

    def test_replay_fails(self):
        plan = self.activate()
        del self.box.files[facts.ROUTER_FILE]
        self.box.reply([IFCTL], rc=1, err='ifctl: failed\n')
        mark = self.box.mark()
        self.tick()
        self.assertEqual(self.box.changes(mark), replaying(plan)[:2] + deactivation(plan))
        self.assertEqual(self.where(), ('backoff', 'step_router'))


class BlockedTest(Scenario):
    def test_manual_outbound_nat(self):
        self.box.cfg['nat_mode'] = 'advanced'
        self.sup.start()
        self.advert()
        self.assertEqual(self.where(), ('blocked', 'nat_mode'))
        self.assertEqual(self.helper_runs(), 0)
        self.assertEqual(self.box.spawned, [])
        self.settings(manual_nat=True)
        self.sup.handle({'hup'})
        self.assertEqual(self.where(), ('active', ''))

    def test_tayga_not_installed(self):
        del self.box.files[facts.TAYGA_BIN]
        self.sup.start()
        self.advert()
        self.assertEqual(self.where(), ('blocked', 'tayga_missing'))
        self.assertEqual(self.helper_runs(), 0)

    def test_static_prefix_overlaps_the_delegated_prefix(self):
        self.settings(prefix='2001:db8:1200:64::/96')
        self.sup.start()
        self.assertEqual(self.where(), ('blocked', 'pref64_overlap'))

    def test_prefix_id_outside_the_delegated_prefix(self):
        self.settings(prefix_id='100')
        self.sup.start()
        self.advert()
        self.assertEqual(self.where(), ('blocked', 'prefix_id'))
        self.assertEqual(self.helper_runs(), 1)
        count = len(self.box.commands)
        self.tick()
        self.assertEqual(self.box.commands[count:], [])
        self.settings(prefix_id='a0')
        self.sup.handle({'hup'})
        self.assertEqual(self.where(), ('active', ''))
        self.assertIn(self.sup.running.clat6, IPv6Network('2001:db8:1200:a0::/64'))

    def test_blocked_while_active(self):
        plan = self.activate()
        self.box.cfg['nat_mode'] = 'disabled'
        self.box.put(facts.CONFIG_XML, '<opnsense><changed/></opnsense>')
        mark = self.box.mark()
        self.tick()
        self.assertEqual(self.box.changes(mark), deactivation(plan))
        self.assertEqual(self.where(), ('blocked', 'nat_mode'))


class ReloadTest(Scenario):
    def test_unchanged_settings(self):
        plan = self.activate()
        mark = self.box.mark()
        self.sup.handle({'hup'})
        self.assertEqual(self.box.changes(mark), [])
        self.assertIn(' '.join(HELPER_CONFIG), self.box.trace[mark:])
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.where(), ('active', ''))

    def test_changed_ipv4_mtu(self):
        old = self.activate()
        self.run_for(supervisor.RESTART_MIN_INTERVAL + 1)
        self.settings(ipv4_mtu=1400)
        mark = self.box.mark()
        self.sup.handle({'hup'})
        new = self.sup.running
        self.assertEqual((new.tun_mtu, new.offlink_mtu, new.ipv4_mtu), (1428, 1420, 1400))
        self.assertEqual(self.box.changes(mark), renumbering(old) + activation(new))
        self.assertEqual(self.where(), ('active', ''))

    def test_disabled(self):
        plan = self.activate()
        self.settings(enabled=False)
        mark = self.box.mark()
        self.sup.handle({'hup'})
        self.assertEqual(self.box.changes(mark), deactivation(plan))
        self.assertEqual(self.where(), ('disabled', ''))

    def test_state_changes_are_not_logged_when_switched_off(self):
        self.settings(log_state=False)
        self.activate()
        self.assertEqual([entry for entry in self.box.logs if entry[1].startswith('state ')], [])

    def test_unreadable_settings_keep_the_old_ones(self):
        plan = self.activate()
        self.box.put(facts.SETTINGS, '{"enabled": fal')
        mark = self.box.mark()
        self.sup.handle({'hup'})
        self.assertEqual(self.box.changes(mark), [])
        self.assertEqual(self.sup.running, plan)

    def test_reload_asks_dns_again_at_once(self):
        # dormant: the resolver of the box does no DNS64, and the next query is five minutes away
        self.box.dns_outcome = ('answer', [], 3600)
        self.sup.start()
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
        self.assertEqual(self.sup.timers['dns'], self.box.clock + discovery.DNS_NEGATIVE_MAX)
        self.box.dns_outcome = ('answer', ['64:ff9b::c000:aa'], 300)    # the customer has set up DNS64
        mark = self.box.mark()
        self.tick()
        self.assertEqual(self.box.trace[mark:], [])
        self.assertEqual(self.where(), ('listening', 'no_nat64_prefix'))
        self.sup.handle({'hup'})
        self.assertEqual(self.box.trace[mark:].count('dns'), 1)
        self.assertEqual(self.where(), ('active', ''))
        self.assertEqual(self.status()['pref64'], {'prefix': '64:ff9b::/96', 'source': 'dns', 'expires': None})

    def test_reload_with_a_dns_time_out_keeps_the_prefix(self):
        self.box.dns_outcome = ('answer', ['64:ff9b::c000:aa'], 3600)
        self.sup.start()
        plan = self.sup.running
        self.assertEqual(self.where(), ('active', ''))
        self.box.dns_outcome = ('fail', 'timeout', None)
        mark = self.box.mark()
        self.sup.handle({'hup'})
        self.assertEqual(self.box.trace[mark:].count('dns'), 1)
        self.assertEqual(self.box.changes(mark), [])
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.where(), ('active', ''))

    def test_reload_asks_no_dns_while_the_ra_has_the_prefix(self):
        self.activate()
        mark = self.box.mark()
        self.sup.handle({'hup'})
        self.assertNotIn('dns', self.box.trace[mark:])


class EchoTest(Scenario):
    def test_route_event_after_the_activation(self):
        plan = self.activate()
        mark = self.box.mark()
        self.route_event()
        self.assertEqual(self.box.changes(mark), [])
        self.assertEqual(self.box.trace[mark:mark + 2], [' '.join(ROUTE_GET), ' '.join(IFCONFIG_A)])
        self.assertEqual(self.sup.running, plan)
        self.assertEqual(self.where(), ('active', ''))

    def test_route_messages_are_debounced_once(self):
        self.activate()
        self.box.route_flag = True
        self.sup.handle({'route'})
        armed = self.sup.timers['debounce']
        self.box.advance(1)
        self.box.route_flag = True
        self.sup.handle({'route'})
        self.assertEqual(self.sup.timers['debounce'], armed)
        self.sup.handle({'route'})                  # nothing relevant was read
        self.run_for(1)
        self.assertNotIn('debounce', self.sup.timers)


class LoopTest(Scenario):
    def test_next_timeout(self):
        self.assertIsNone(self.sup.next_timeout())
        self.activate()
        self.assertEqual(self.sup.next_timeout(), supervisor.TICK)
        self.box.advance(supervisor.TICK + 5)
        self.assertEqual(self.sup.next_timeout(), 0.0)

    def test_one_reconcile_for_several_events(self):
        self.sup.start()
        self.settings(enabled=False)
        self.sup.handle({'hup', 'usr1', 'usr2', 'chld'})
        self.assertEqual(self.box.commands.count(HELPER_CONFIG), 2)
        self.assertEqual(self.box.commands.count(ROUTE_GET), 3)
        self.assertEqual(self.where(), ('disabled', ''))

    def test_own_commands_do_not_start_a_pass(self):
        self.activate()
        mark = self.box.mark()
        self.sup.handle({'chld'})                   # a command of the last pass has exited
        self.assertEqual(self.box.trace[mark:], [])

    def test_term_ends_the_loop(self):
        self.activate()
        events = [set(), {'ra'}, {'term', 'hup'}]
        waits = []

        def wait(timeout):
            waits.append(timeout)
            return events.pop(0)

        self.box.wait = wait
        mark = self.box.mark()
        self.sup.run()
        self.assertTrue(self.sup.stopping)
        self.assertEqual(waits, [supervisor.TICK] * 3)
        self.assertEqual(self.box.trace[mark:], [])

    def test_stop(self):
        plan = self.activate()
        mark = self.box.mark()
        self.sup.stop()
        self.assertEqual(self.box.changes(mark), deactivation(plan) + ['remove ' + facts.STATUS])
        self.assertNotIn(facts.STATUS, self.box.files)
        self.assertEqual(self.box.logs[-1], (5, 'stopped'))

    def test_stop_after_a_tayga_exit(self):
        plan = self.activate()
        self.box.exit_child(1)
        self.sup.handle({'chld'})
        mark = self.box.mark()
        self.sup.stop()
        self.assertEqual(self.box.changes(mark), deactivation(plan) + ['remove ' + facts.STATUS])

    def test_stop_while_dormant(self):
        self.sup.start()
        mark = self.box.mark()
        self.sup.stop()
        self.assertEqual(self.box.trace[mark:], ['remove ' + facts.STATUS])

    def test_tayga_output_is_relayed_and_kept(self):
        self.activate()
        self.box.advance(supervisor.RELAY_WINDOW)
        logged = len(self.box.logs)
        self.box.child_output = ['Error: one', 'Unable to two', 'three, aborting: four']
        self.box.child_output += ['line %d' % n for n in range(27)]
        self.sup.handle({'child'})
        relayed = self.box.logs[logged:]
        self.assertEqual(len(relayed), supervisor.RELAY_BURST)
        self.assertEqual(relayed[:4], [(3, 'tayga: Error: one'), (3, 'tayga: Unable to two'),
                                       (3, 'tayga: three, aborting: four'), (6, 'tayga: line 0')])
        self.assertEqual(self.sup.output, ['line %d' % n for n in range(17, 27)])
        self.box.advance(supervisor.RELAY_WINDOW)
        self.box.child_output = ['later']
        self.sup.handle({'child'})
        relayed = self.box.logs[logged + supervisor.RELAY_BURST:]
        self.assertEqual(relayed, [(4, 'tayga: 10 lines suppressed'), (6, 'tayga: later')])
        self.tick()
        self.assertEqual(self.status()['tayga']['output'][-1], 'later')
        self.assertEqual(len(self.status()['tayga']['output']), supervisor.OUTPUT_KEEP)


if __name__ == '__main__':
    unittest.main()
