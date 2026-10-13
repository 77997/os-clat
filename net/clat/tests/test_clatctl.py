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

import contextlib
import io
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'opnsense', 'scripts', 'clat'))

import clatctl  # noqa: E402
import fakes  # noqa: E402
from lib import facts  # noqa: E402

PID = 4100
TARGET = '198.51.100.7'
TARGET6 = '64:ff9b::c633:6407'
CLAT6 = '2001:db8:0:ff:8c5a:1f3e:77a0:4c12'
TAYGA6 = '2001:db8:0:ff:8c5a:1f3e:77a0:4c13'

ROUTE_GET = (
    '   route to: ::\n'
    'destination: ::\n'
    '       mask: ::\n'
    '    gateway: fe80::2a0:a5ff:fe12:3456%pppoe0\n'
    '        fib: 0\n'
    '  interface: pppoe0\n'
    '      flags: <UP,GATEWAY,DONE,STATIC>\n'
)
IFCONFIG = (
    'pppoe0: flags=88d1<UP,POINTOPOINT,RUNNING,NOARP,SIMPLEX,MULTICAST> metric 0 mtu 1492\n'
    '\tinet6 fe80::1:2%pppoe0 prefixlen 64 scopeid 0x8\n'
    '\tnd6 options=23<PERFORMNUD,ACCEPT_RTADV,AUTO_LINKLOCAL>\n'
    'tun464: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> metric 0 mtu 1492\n'
    '\tinet 192.0.0.1 --> 192.0.0.2 netmask 0xffffffff\n'
    '\tOpened by PID 4343\n'
)
NDP = 'linkmtu=0, maxmtu=1492, curhlim=64, basereachable=30s0ms, reachable=22s, retrans=1s0ms\n'
NAT_RULES = (
    'no nat proto carp all\n'
    'nat on tun464 inet from (igc1:network) to any -> (tun464:0) port 1024:65535\n'
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
GATEWAYS = {
    'default': {'name': 'CLAT_GW', 'if': 'tun464', 'if_has_ipv4': True},
    'fallback': None,
    'list': [{
        'name': 'CLAT_GW', 'interface': 'clat', 'if': 'tun464', 'gateway': '192.0.0.2', 'priority': 254,
        'upstream': False, 'disabled': False, 'defunct': False, 'dynamic': True, 'selected': False,
        'tunnel': False, 'if_has_ipv4': True,
    }],
    'leftover': [],
}
PLAN = {
    'clat6': CLAT6, 'tayga6': TAYGA6, 'ipv4_clat': '192.0.0.1', 'ipv4_tayga': '192.0.0.2',
    'tun_mtu': 1492, 'offlink_mtu': 1492, 'ipv4_mtu': 1472,
}
DORMANT = {'pref64': None, 'plan': None, 'tayga': {'started': None, 'restarts': 0, 'output': []}}

# the look at the command line of the process the pidfile names, and what it shows for the daemon
PS = ['/bin/ps', '-o', 'command=', '-p', str(PID)]
DAEMON = '/usr/local/bin/python3 /usr/local/opnsense/scripts/clat/clatd.py\n'
OTHER = '/usr/sbin/cron -s\n'

ECHO6 = ['/sbin/ping', '-6', '-n', '-c', '3', '-t', '5', TARGET6]
ECHO4 = ['/sbin/ping', '-4', '-n', '-c', '3', '-t', '5', '-S', '192.0.0.1', TARGET]


def ping_output(sent, received):
    return (
        'PING %s (%s): 56 data bytes\n'
        '\n'
        '--- %s ping statistics ---\n'
        '%d packets transmitted, %d packets received, %.1f%% packet loss\n'
    ) % (TARGET, TARGET, TARGET, sent, received, 100.0 * (sent - received) / sent)


def probe(size):
    """ The DF probe for an IPv4 packet of this size. """
    return ['/sbin/ping', '-4', '-n', '-D', '-c', '1', '-t', '2', '-S', '192.0.0.1', '-s', str(size - 28), TARGET]


# what FreeBSD's ping prints for a DF probe that tayga refuses, and for one above the MTU of the tun
FRAG_NEEDED = (
    '556 bytes from 192.0.0.2: frag needed and DF set (MTU 1472)\n'
    'Vr HL TOS  Len   ID Flg  off TTL Pro  cks       Src         Dst\n'
    ' 4  5  00 05c1 0000   2 0000  40  01 51e1 192.0.0.1 %s\n'
    '\n'
) % TARGET
TOO_LONG = 'ping: sendto: Message too long\n'


class ClatctlCase(unittest.TestCase):
    def setUp(self):
        self.sys = fakes.FakeSystem()
        self.now = int(self.sys.time())
        self.sys.put(facts.TAYGA_BIN, '')
        self.sys.reply(['/usr/local/sbin/pkg', 'query', '%v', 'tayga'], out='0.9.6\n')

    def settings(self, **changes):
        self.sys.put(facts.SETTINGS, json.dumps(dict(facts.DEFAULT_SETTINGS, **changes)))

    def box(self, config=None, gateways=None, nat_rules=NAT_RULES):
        """ A box with IPv6 on pppoe0 and the CLAT gateway as the IPv4 default. """
        self.sys.reply([facts.FACTS_PHP, 'config'], out=json.dumps({'config': config or CONFIG}) + '\n')
        self.sys.reply([facts.FACTS_PHP, 'gateways'], out=json.dumps({'gateways': gateways or GATEWAYS}) + '\n')
        self.sys.reply(['/sbin/route', '-6', '-n', 'get', 'default'], out=ROUTE_GET)
        self.sys.reply(['/sbin/ifconfig', '-a'], out=IFCONFIG)
        self.sys.reply(['/usr/sbin/ndp', '-i', 'pppoe0'], out=NDP)
        self.sys.reply(['/sbin/pfctl', '-sn'], out=nat_rules)

    def daemon(self, state=None, reason='', **changes):
        """ A running daemon; with a state also the status file it would have written. """
        self.sys.put(facts.PIDFILE, str(PID))
        self.sys.pids.add(PID)
        self.sys.reply(PS, out=DAEMON)
        if state is not None:
            status = {
                'updated': self.now, 'state': state, 'reason': reason, 'since': self.now - 1000,
                'uplink': 'pppoe0',
                'pref64': {'prefix': '64:ff9b::/96', 'source': 'ra', 'expires': self.now + 1630},
                'plan': dict(PLAN),
                'withdrawn': False,
                'tayga': {'started': self.now - 1000, 'restarts': 0, 'output': []},
            }
            status.update(changes)
            self.sys.put(facts.STATUS, json.dumps(status) + '\n')

    def commands(self):
        """ The commands that were run, without the look at the daemon's command line. """
        return [argv for argv in self.sys.commands if argv != PS]


class StatusTest(ClatctlCase):
    def test_stopped(self):
        # a status file and a pidfile left by an instance that is gone are ignored
        self.daemon('active')
        self.sys.pids.clear()
        result = clatctl.cmd_status(self.sys)
        self.assertFalse(result['running'])
        self.assertEqual((result['state'], result['reason']), ('stopped', ''))
        self.assertEqual(result['message'], 'The CLAT service is not running.')
        self.assertEqual(result['text']['state'], 'The CLAT service is not running.')
        self.assertIsNone(result['since'])
        self.assertIsNone(result['pref64'])
        self.assertIsNone(result['address'])
        self.assertEqual(result['tayga'], {'running': False, 'uptime': None, 'restarts': 0, 'output': []})

    def test_stopped_without_pidfile(self):
        result = clatctl.cmd_status(self.sys)
        self.assertFalse(result['running'])
        self.assertEqual(result['state'], 'stopped')

    def test_stopped_when_the_pid_belongs_to_another_process(self):
        # the daemon was killed and its pid was given to another process
        self.daemon('active')
        self.sys.reply(PS, out=OTHER)
        result = clatctl.cmd_status(self.sys)
        self.assertFalse(result['running'])
        self.assertEqual((result['state'], result['reason']), ('stopped', ''))
        self.assertIsNone(result['address'])
        self.assertIn(PS, self.sys.commands)

    def test_disabled(self):
        self.settings(enabled=False)
        result = clatctl.cmd_status(self.sys)
        self.assertFalse(result['running'])
        self.assertEqual(result['state'], 'disabled')
        self.assertEqual(result['message'], 'Disabled.')
        self.assertEqual(result['text']['state'], 'Disabled.')

    def test_starting(self):
        self.daemon()
        result = clatctl.cmd_status(self.sys)
        self.assertTrue(result['running'])
        self.assertEqual((result['state'], result['reason']), ('starting', ''))
        self.assertEqual(result['message'], 'The CLAT service is starting.')
        self.assertEqual(result['text']['state'], 'The CLAT service is starting.')

    def test_starting_with_unreadable_status_file(self):
        self.daemon()
        self.sys.put(facts.STATUS, '{"state": "act')
        self.assertEqual(clatctl.cmd_status(self.sys)['state'], 'starting')

    def test_state_messages(self):
        cases = (
            ('disabled', '', False, 'Disabled.'),
            ('listening', 'no_uplink_ipv6', False, 'Listening: the uplink is down or has no IPv6 default route.'),
            ('listening', 'no_nat64_prefix', False, 'Listening: no NAT64 prefix found.'),
            ('native-ipv4', 'uplink', False, 'Native IPv4 is present on the uplink.'),
            ('native-ipv4', 'gateway', False, 'A native IPv4 gateway is present.'),
            ('native-ipv4', 'hold', False, 'Native IPv4 disappeared; activation is held back for 60 seconds.'),
            ('waiting-for-prefix-delegation', '', False,
             'A NAT64 prefix is known; waiting for the delegated prefix of this session.'),
            ('active', '', False, 'Active.'),
            ('suspended', '', False, 'Suspended: the uplink lost IPv6.'),
            ('suspended', '', True,
             'Suspended: the uplink lost IPv6. The IPv4 default route was handed to another gateway.'),
            ('backoff', 'tayga_exit', False, 'Retrying after a failure (tayga_exit).'),
            ('backoff', 'step_route', False, 'Retrying after a failure (step_route).'),
        )
        for state, reason, withdrawn, message in cases:
            with self.subTest(state=state, reason=reason, withdrawn=withdrawn):
                self.daemon(state, reason, withdrawn=withdrawn)
                result = clatctl.cmd_status(self.sys)
                self.assertTrue(result['running'])
                self.assertEqual((result['state'], result['reason']), (state, reason))
                self.assertEqual(result['message'], message)
                self.assertEqual(result['text']['state'], message)
                self.assertEqual(result['since'], self.now - 1000)

    def test_blocked_message_is_the_preflight_row(self):
        self.box(config=dict(CONFIG, nat_mode='advanced'))
        self.daemon('blocked', 'nat_mode', **DORMANT)
        result = clatctl.cmd_status(self.sys)
        rows = {row['id']: row for row in result['preflight']}
        self.assertEqual(list(rows), ['nat_mode'])
        self.assertEqual(rows['nat_mode']['effect'], 'block')
        self.assertIn('Outbound NAT mode is advanced.', rows['nat_mode']['message'])
        self.assertEqual(result['message'], rows['nat_mode']['message'])
        self.assertEqual(result['text']['state'], rows['nat_mode']['message'])
        self.assertEqual(result['text']['preflight'], 'block: ' + rows['nat_mode']['message'])

    def test_blocked_by_a_plan_error(self):
        messages = {
            'uplink_mtu': 'The uplink IPv6 MTU is unknown or below 1280.',
            'prefix_id': 'Prefix ID 1ff does not fit in the delegated prefix.',
            'address': 'The CLAT IPv6 address cannot be used.',
        }
        self.settings(prefix_id='1ff')
        self.box(config=dict(CONFIG, scrub=False))
        for reason, message in messages.items():
            with self.subTest(reason=reason):
                self.daemon('blocked', reason, **DORMANT)
                result = clatctl.cmd_status(self.sys)
                # the row is added after the block rows of preflight() and before its warnings
                self.assertEqual([row['id'] for row in result['preflight']], [reason, 'scrub_disabled'])
                self.assertEqual(result['preflight'][0], {'id': reason, 'effect': 'block', 'message': message})
                self.assertEqual(result['message'], message)
                self.assertEqual(result['text']['preflight'].split('\n')[0], 'block: ' + message)

    def test_blocked_without_a_row(self):
        self.box()
        self.daemon('blocked', 'nat_mode', **DORMANT)
        result = clatctl.cmd_status(self.sys)
        self.assertEqual(result['preflight'], [])
        self.assertEqual(result['message'], 'Blocked (nat_mode).')

    def test_active(self):
        self.box()
        self.daemon('active')
        result = clatctl.cmd_status(self.sys)
        self.assertEqual(result, {
            'running': True, 'state': 'active', 'reason': '', 'message': 'Active.', 'since': self.now - 1000,
            'uplink': {'configured': 'wan', 'configured_device': 'pppoe0', 'runtime_device': 'pppoe0'},
            'pref64': {'prefix': '64:ff9b::/96', 'source': 'ra', 'lifetime': 1630},
            'address': {'clat6': CLAT6, 'tayga6': TAYGA6, 'ipv4_clat': '192.0.0.1', 'ipv4_tayga': '192.0.0.2'},
            'mtu': {'configured': 1492, 'effective': 1492, 'tun': 1492, 'offlink': 1492, 'ipv4': 1472, 'mss': 1432},
            'gateway': {'default': True, 'message': 'active'},
            'nat_rule': True,
            'tayga': {'running': True, 'uptime': 1000, 'restarts': 0, 'output': []},
            'preflight': [],
            'text': {
                'state': 'Active.',
                'uplink': 'pppoe0',
                'pref64': '64:ff9b::/96 (RA, 1630 s left)',
                'address': CLAT6 + ' (CLAT), 192.0.0.1',
                'mtu': 'configured 1492, effective 1492, IPv4 1472, TCP MSS 1432',
                'gateway': 'active',
                'tayga': 'running for 1000 s, 0 restarts',
                'preflight': 'No findings.',
            },
        })
        self.assertEqual(json.loads(json.dumps(result)), result)

    def test_facts_are_gathered_afresh(self):
        self.box()
        self.daemon('active')
        clatctl.cmd_status(self.sys)
        for command in (
            [facts.FACTS_PHP, 'config'],
            ['/sbin/route', '-6', '-n', 'get', 'default'],
            ['/sbin/ifconfig', '-a'],
            ['/usr/sbin/ndp', '-i', 'pppoe0'],
            [facts.FACTS_PHP, 'gateways'],
            ['/usr/local/sbin/pkg', 'query', '%v', 'tayga'],
            ['/sbin/pfctl', '-sn'],
        ):
            self.assertIn(command, self.sys.commands)

    def test_nothing_known(self):
        # no daemon, no helper output, no IPv6 default route
        self.sys.reply(['/sbin/route', '-6', '-n', 'get', 'default'], rc=1, err='route: route has not been found\n')
        result = clatctl.cmd_status(self.sys)
        self.assertEqual(result['uplink'], {'configured': None, 'configured_device': None, 'runtime_device': None})
        self.assertEqual(result['mtu'], {
            'configured': None, 'effective': None, 'tun': None, 'offlink': None, 'ipv4': None, 'mss': None,
        })
        self.assertIsNone(result['gateway'])
        self.assertIsNone(result['nat_rule'])
        self.assertEqual(result['preflight'], [])
        self.assertEqual(result['text'], {
            'state': 'The CLAT service is not running.',
            'uplink': '-',
            'pref64': '-',
            'address': '-',
            'mtu': 'configured -, effective -, IPv4 -, TCP MSS -',
            'gateway': '-',
            'tayga': 'not running, 0 restarts',
            'preflight': 'No findings.',
        })
        # the NAT rule is looked for in state active only
        self.assertNotIn(['/sbin/pfctl', '-sn'], self.sys.commands)

    def test_dormant_text(self):
        self.box()
        self.daemon('listening', 'no_nat64_prefix', **DORMANT)
        result = clatctl.cmd_status(self.sys)
        self.assertIsNone(result['gateway'])
        self.assertIsNone(result['nat_rule'])
        self.assertEqual(result['text'], {
            'state': 'Listening: no NAT64 prefix found.',
            'uplink': 'pppoe0',
            'pref64': '-',
            'address': '-',
            'mtu': 'configured 1492, effective 1492, IPv4 -, TCP MSS 1432',
            'gateway': '-',
            'tayga': 'not running, 0 restarts',
            'preflight': 'No findings.',
        })

    def test_prefix_sources(self):
        self.box()
        for source, text in (('static', '64:ff9b::/96 (static)'), ('dns', '64:ff9b::/96 (DNS)')):
            with self.subTest(source=source):
                self.daemon('active', pref64={'prefix': '64:ff9b::/96', 'source': source, 'expires': None})
                result = clatctl.cmd_status(self.sys)
                self.assertEqual(result['pref64'], {'prefix': '64:ff9b::/96', 'source': source, 'lifetime': None})
                self.assertEqual(result['text']['pref64'], text)

    def test_expired_lifetime_is_zero(self):
        self.box()
        self.daemon('active', pref64={'prefix': '64:ff9b::/96', 'source': 'ra', 'expires': self.now - 5})
        result = clatctl.cmd_status(self.sys)
        self.assertEqual(result['pref64']['lifetime'], 0)
        self.assertEqual(result['text']['pref64'], '64:ff9b::/96 (RA, 0 s left)')

    def test_nat_rule_missing(self):
        self.box(nat_rules='no nat proto carp all\nnat on igc0 inet from any to any -> (igc0:0)\n')
        self.daemon('active')
        result = clatctl.cmd_status(self.sys)
        self.assertIs(result['nat_rule'], False)
        self.assertEqual(result['gateway'], {'default': True, 'message': 'active'})
        self.assertEqual(result['text']['gateway'], 'active; NAT rule missing')

    def test_gateway_not_default(self):
        native = {'name': 'WAN2_DHCP', 'if': 'igc2', 'if_has_ipv4': True}
        self.box(gateways=dict(GATEWAYS, default=native))
        self.daemon('active')
        result = clatctl.cmd_status(self.sys)
        message = 'active, but not the IPv4 default: gateway WAN2_DHCP is preferred'
        self.assertEqual(result['gateway'], {'default': False, 'message': message})
        self.assertEqual(result['text']['gateway'], message)

    def test_gateway_unknown(self):
        # the gateway helper fails: no report, but the NAT rule is still looked at
        self.box()
        self.sys.reply([facts.FACTS_PHP, 'gateways'], rc=1)
        self.daemon('active')
        result = clatctl.cmd_status(self.sys)
        self.assertIsNone(result['gateway'])
        self.assertIs(result['nat_rule'], True)
        self.assertEqual(result['text']['gateway'], '-')

    def test_tayga_output(self):
        output = ['Unable to open /dev/tun464, aborting: Device busy']
        self.box()
        self.daemon('backoff', 'tayga_start', tayga={'started': None, 'restarts': 3, 'output': output})
        result = clatctl.cmd_status(self.sys)
        self.assertEqual(result['tayga'], {'running': False, 'uptime': None, 'restarts': 3, 'output': output})
        self.assertEqual(result['text']['tayga'], 'not running, 3 restarts\n' + output[0])
        # outside backoff the lines are in the data only
        output = ['Starting TAYGA 0.9.6', 'Using tun device tun464 with MTU 1492']
        self.daemon('active', tayga={'started': self.now - 60, 'restarts': 3, 'output': output})
        result = clatctl.cmd_status(self.sys)
        self.assertEqual(result['tayga'], {'running': True, 'uptime': 60, 'restarts': 3, 'output': output})
        self.assertEqual(result['text']['tayga'], 'running for 60 s, 3 restarts')

    def test_preflight_rows(self):
        config = dict(CONFIG, scrub=False, uplink=dict(CONFIG['uplink'], mss=1400))
        self.sys.reply(['/usr/local/sbin/pkg', 'query', '%v', 'tayga'], out='0.9.7_1\n')
        self.box(config=config)
        self.daemon('active')
        result = clatctl.cmd_status(self.sys)
        rows = result['preflight']
        self.assertEqual([row['id'] for row in rows], ['scrub_disabled', 'wan_mss', 'tayga_version'])
        self.assertEqual(result['text']['preflight'], '\n'.join('warn: ' + row['message'] for row in rows))
        # no clamp without normalisation
        self.assertIsNone(result['mtu']['mss'])
        self.assertEqual(result['text']['mtu'], 'configured 1492, effective 1492, IPv4 1472, TCP MSS -')

    def test_tayga_missing(self):
        self.sys.remove(facts.TAYGA_BIN)
        self.sys.reply(['/usr/local/sbin/pkg', 'query', '%v', 'tayga'], rc=1, err='pkg: no package matched\n')
        self.box()
        result = clatctl.cmd_status(self.sys)
        self.assertEqual([row['id'] for row in result['preflight']], ['tayga_missing'])

    def test_ipv6_mtu_override_lowers_the_configured_mtu(self):
        self.settings(ipv6_mtu=1400)
        self.box()
        self.daemon('active')
        result = clatctl.cmd_status(self.sys)
        self.assertEqual(result['mtu']['configured'], 1400)
        self.assertEqual(result['mtu']['effective'], 1400)
        self.assertEqual(result['preflight'], [])


class EventTest(ClatctlCase):
    def test_signals(self):
        self.daemon()
        cases = (
            ('inet6', '1', self.sys.SIGUSR2),
            ('inet6', '0', self.sys.SIGUSR1),
            ('inet', '1', self.sys.SIGUSR1),
            ('inet', '0', self.sys.SIGUSR1),
        )
        self.assertNotEqual(self.sys.SIGUSR1, self.sys.SIGUSR2)
        for family, uplink, signo in cases:
            with self.subTest(family=family, uplink=uplink):
                del self.sys.signals[:]
                self.assertIsNone(clatctl.cmd_event(self.sys, family, uplink))
                self.assertEqual(self.sys.signals, [(PID, signo)])

    def test_no_pidfile(self):
        clatctl.cmd_event(self.sys, 'inet6', '1')
        self.assertEqual(self.sys.signals, [])

    def test_stale_pidfile(self):
        # the daemon was killed: the pidfile is still there, the process is not
        self.daemon()
        self.sys.pids.clear()
        clatctl.cmd_event(self.sys, 'inet6', '1')
        self.assertEqual(self.sys.signals, [])
        self.assertEqual(self.sys.commands, [])

    def test_pid_of_another_process(self):
        # the default action of both signals would terminate whatever got the daemon's pid
        self.daemon()
        self.sys.reply(PS, out=OTHER)
        for family, uplink in (('inet6', '1'), ('inet', '0')):
            with self.subTest(family=family, uplink=uplink):
                clatctl.cmd_event(self.sys, family, uplink)
                self.assertEqual(self.sys.signals, [])
        self.assertEqual(self.sys.commands, [PS, PS])

    def test_unusable_pidfile(self):
        # Daemonize truncates the file before it writes the pid; a pid of 0 would be the process group
        for content in ('', '\n', 'pid', '0', '-1'):
            with self.subTest(content=content):
                self.sys.put(facts.PIDFILE, content)
                clatctl.cmd_event(self.sys, 'inet', '1')
                self.assertEqual(self.sys.signals, [])


class TestTest(ClatctlCase):
    def limit(self, size, refused=None, tun=1500):
        """ DF pings are answered up to this size and get no answer above it. With refused, the sizes
            from there on get "fragmentation needed" instead; above the MTU of the tun the kernel
            refuses to send.
        """
        for candidate in range(clatctl.PROBE_SMALL, 1501):
            if candidate <= size:
                self.sys.reply(probe(candidate), out=ping_output(1, 1))
            elif candidate > tun:
                self.sys.reply(probe(candidate), rc=2, out=ping_output(1, 0), err=TOO_LONG)
            elif refused is not None and candidate >= refused:
                self.sys.reply(probe(candidate), rc=2, out=FRAG_NEEDED + ping_output(1, 0))
            else:
                self.sys.reply(probe(candidate), rc=2, out=ping_output(1, 0))

    def probed(self):
        """ Sizes of the DF probes that were run, in order. """
        return [int(argv[argv.index('-s') + 1]) + 28 for argv in self.sys.commands if '-D' in argv]

    def active(self, ipv4_mtu=1472):
        """ An active CLAT that presents this IPv4 MTU; both echo tests are answered. """
        self.settings(test_target=TARGET)
        self.daemon('active', plan=dict(PLAN, ipv4_mtu=ipv4_mtu))
        self.sys.reply(ECHO6, out=ping_output(3, 3))
        self.sys.reply(ECHO4, out=ping_output(3, 3))

    def size_test(self):
        del self.sys.commands[:]
        return clatctl.cmd_test(self.sys)['tests'][2]

    def assert_error(self, result, error, target=TARGET):
        self.assertEqual(result, {'status': 'ok', 'error': error, 'target': target, 'tests': [], 'text': error})
        self.assertEqual(self.commands(), [])

    def test_daemon_not_running(self):
        self.settings(test_target=TARGET)
        self.assert_error(clatctl.cmd_test(self.sys), 'The CLAT is not active.')

    def test_daemon_starting(self):
        self.settings(test_target=TARGET)
        self.daemon()
        self.assert_error(clatctl.cmd_test(self.sys), 'The CLAT is not active.')

    def test_not_active(self):
        self.settings(test_target=TARGET)
        for state, reason in (('listening', 'no_nat64_prefix'), ('suspended', ''), ('backoff', 'tayga_exit')):
            with self.subTest(state=state):
                self.daemon(state, reason)
                self.assert_error(clatctl.cmd_test(self.sys), 'The CLAT is not active.')

    def test_stale_status_file(self):
        # state active in the file, but the daemon is gone
        self.settings(test_target=TARGET)
        self.daemon('active')
        self.sys.pids.clear()
        self.assert_error(clatctl.cmd_test(self.sys), 'The CLAT is not active.')

    def test_stale_status_file_and_a_reused_pid(self):
        self.settings(test_target=TARGET)
        self.daemon('active')
        self.sys.reply(PS, out=OTHER)
        self.assert_error(clatctl.cmd_test(self.sys), 'The CLAT is not active.')

    def test_no_target(self):
        self.daemon('active')
        self.assert_error(clatctl.cmd_test(self.sys), 'No test target is set.', target='')

    def test_not_active_is_reported_before_the_missing_target(self):
        self.daemon('listening', 'no_nat64_prefix')
        self.assert_error(clatctl.cmd_test(self.sys), 'The CLAT is not active.', target='')

    def test_all_pass(self):
        self.active()
        self.limit(1500)
        result = clatctl.cmd_test(self.sys)
        self.assertEqual(result, {
            'status': 'ok', 'error': '', 'target': TARGET,
            'tests': [
                {'id': 'plat', 'ok': True, 'detail': TARGET6 + ': 3 of 3 replies'},
                {'id': 'path', 'ok': True, 'detail': TARGET + ' from 192.0.0.1: 3 of 3 replies'},
                {'id': 'mtu', 'ok': True, 'size': 1472, 'detail': 'largest IPv4 packet that passes: 1472 bytes'},
            ],
            'text': '\n'.join((
                'NAT64 gateway over IPv6: ok (' + TARGET6 + ': 3 of 3 replies)',
                'IPv4 through the CLAT: ok (' + TARGET + ' from 192.0.0.1: 3 of 3 replies)',
                'IPv4 packet size: ok (largest IPv4 packet that passes: 1472 bytes)',
            )),
        })
        self.assertEqual(self.commands(), [ECHO6, ECHO4, probe(1472)])
        self.assertEqual(json.loads(json.dumps(result)), result)

    def test_reply_counting(self):
        self.active()
        self.limit(1500)
        self.sys.reply(ECHO6, rc=0, out=ping_output(3, 2))
        self.sys.reply(ECHO4, rc=2, out=ping_output(3, 0))
        result = clatctl.cmd_test(self.sys)
        self.assertEqual(result['tests'][0], {'id': 'plat', 'ok': True, 'detail': TARGET6 + ': 2 of 3 replies'})
        self.assertEqual(result['tests'][1], {
            'id': 'path', 'ok': False, 'detail': TARGET + ' from 192.0.0.1: 0 of 3 replies',
        })
        self.assertEqual(result['text'].split('\n')[:2], [
            'NAT64 gateway over IPv6: ok (' + TARGET6 + ': 2 of 3 replies)',
            'IPv4 through the CLAT: failed (' + TARGET + ' from 192.0.0.1: 0 of 3 replies)',
        ])
        self.assertEqual((result['status'], result['error']), ('ok', ''))

    def test_ping_without_summary(self):
        self.active()
        self.limit(1500)
        self.sys.reply(ECHO6, rc=68, err='ping: cannot resolve: nothing\nping: UDP connect: No route to host\n')
        self.sys.reply(ECHO4, rc=124)
        result = clatctl.cmd_test(self.sys)
        self.assertEqual(result['tests'][0], {
            'id': 'plat', 'ok': False, 'detail': TARGET6 + ': ping: UDP connect: No route to host',
        })
        self.assertEqual(result['tests'][1], {
            'id': 'path', 'ok': False, 'detail': TARGET + ' from 192.0.0.1: no reply',
        })

    def test_probe_answered_at_the_ipv4_mtu(self):
        # the IPv4 MTU presented is answered: nothing else is asked
        for mtu in (1472, 1480, 1500, 1260):
            with self.subTest(mtu=mtu):
                self.active(ipv4_mtu=mtu)
                self.limit(mtu, refused=mtu + 1)
                self.assertEqual(self.size_test(), {
                    'id': 'mtu', 'ok': True, 'size': mtu, 'detail': 'largest IPv4 packet that passes: %d bytes' % mtu,
                })
                self.assertEqual(self.probed(), [mtu])

    def test_probe_limit_marked_by_a_refusal(self):
        # a path that carries less than the uplink and says so: "fragmentation needed" above the limit
        for size in (1280, 1281, 1390, 1471):
            with self.subTest(size=size):
                self.active()
                self.limit(size, refused=size + 1)
                self.assertEqual(self.size_test(), {
                    'id': 'mtu', 'ok': True, 'size': size,
                    'detail': 'largest IPv4 packet that passes: %d bytes' % size,
                })
                probed = self.probed()
                self.assertEqual(probed[:2], [1472, 1280])
                # a bisection of the 192 sizes in between
                self.assertLessEqual(len(probed), 2 + 8)
                self.assertEqual(len(set(probed)), len(probed))
                self.assertTrue(all(1280 <= item <= 1472 for item in probed))

    def test_probe_refused_by_the_tun(self):
        # what the kernel says for a packet above the MTU of the tun is a refusal as well
        self.active(ipv4_mtu=1480)
        self.limit(1472, tun=1472)
        test = self.size_test()
        self.assertEqual((test['ok'], test['size']), (True, 1472))

    def test_probe_limit_marked_by_silence(self):
        # answered up to a size, and above it neither a reply nor a refusal. A NAT64 that returns large
        # echo replies as fragments looks like this (1260), and so does a path that loses large packets:
        # at no size is this "ok"
        for size in (84, 85, 1000, 1260, 1279, 1280, 1281, 1390, 1471):
            with self.subTest(size=size):
                self.active()
                self.limit(size)
                test = self.size_test()
                self.assertEqual((test['ok'], test['size']), (None, size))
                self.assertTrue(test['detail'].startswith('largest ping answered: %d bytes; ' % size))
                probed = self.probed()
                self.assertEqual(probed[:2], [1472, 1280])
                # at most: the IPv4 MTU, 1280, 84 and a bisection of the 1195 sizes below 1280
                self.assertLessEqual(len(probed), 3 + 11)
                self.assertEqual(len(set(probed)), len(probed))

    def test_probe_silence_below_a_refusal(self):
        # the sizes just above the limit are lost and only larger ones are refused: the limit is not marked
        self.active(ipv4_mtu=1480)
        self.limit(1400, refused=1473)
        test = self.size_test()
        self.assertEqual((test['ok'], test['size']), (None, 1400))
        self.assertEqual(self.probed()[:2], [1480, 1280])

    def test_probe_inconclusive_text(self):
        self.active()
        self.limit(1260)
        result = clatctl.cmd_test(self.sys)
        detail = ('largest ping answered: 1260 bytes; the next larger ping got no reply and no "fragmentation needed" '
                  'error; this happens when the NAT64 returns large ping replies as fragments, which the translator '
                  'does not pass for ping, and also when packets of that size are lost on the path; '
                  'check with a TCP download')
        self.assertEqual(result['tests'][2], {'id': 'mtu', 'ok': None, 'size': 1260, 'detail': detail})
        self.assertEqual(result['text'].split('\n')[2], 'IPv4 packet size: inconclusive (%s)' % detail)
        self.assertEqual((result['status'], result['error']), ('ok', ''))
        probed = self.probed()
        self.assertEqual(probed[:3], [1472, 1280, 84])
        self.assertTrue(all(84 < item < 1280 for item in probed[3:]))
        self.assertEqual(json.loads(json.dumps(result)), result)

    def test_probe_refused_at_the_floor(self):
        self.active()
        self.limit(1260, refused=1261)
        result = clatctl.cmd_test(self.sys)
        detail = 'an IPv4 packet of 1280 bytes is refused ("fragmentation needed")'
        self.assertEqual(result['tests'][2], {'id': 'mtu', 'ok': False, 'size': None, 'detail': detail})
        self.assertEqual(self.probed(), [1472, 1280])
        self.assertEqual(result['text'].split('\n')[2], 'IPv4 packet size: failed (%s)' % detail)

    def test_probe_refused_below_the_floor(self):
        # 1280 bytes get no answer, and the search below meets a refusal
        self.active()
        self.limit(1000, refused=1001)
        for candidate in range(1271, 1501):
            self.sys.reply(probe(candidate), rc=2, out=ping_output(1, 0))
        self.assertEqual(self.size_test(), {
            'id': 'mtu', 'ok': False, 'size': 1000,
            'detail': 'an IPv4 packet of 1001 bytes is refused ("fragmentation needed")',
        })
        self.assertEqual(self.probed()[:3], [1472, 1280, 84])

    def test_probe_without_any_answer(self):
        self.active()
        self.limit(0)
        result = clatctl.cmd_test(self.sys)
        self.assertEqual(result['tests'][2], {'id': 'mtu', 'ok': False, 'size': None, 'detail': 'no ping was answered'})
        self.assertEqual(self.probed(), [1472, 1280, 84])
        self.assertEqual(result['text'].split('\n')[2], 'IPv4 packet size: failed (no ping was answered)')

    def test_probe_at_the_lowest_ipv4_mtu(self):
        # an uplink with IPv6 MTU 1280 presents 1260 bytes: 1280 is not asked for
        self.active(ipv4_mtu=1260)
        self.limit(1000)
        test = self.size_test()
        self.assertEqual((test['ok'], test['size']), (None, 1000))
        self.assertEqual(self.probed()[:2], [1260, 84])
        self.limit(0)
        test = self.size_test()
        self.assertEqual((test['ok'], test['size']), (False, None))
        self.assertEqual(self.probed(), [1260, 84])
        self.limit(1259, refused=1260)
        self.assertEqual(self.size_test(), {
            'id': 'mtu', 'ok': False, 'size': None,
            'detail': 'an IPv4 packet of 1260 bytes is refused ("fragmentation needed")',
        })
        self.assertEqual(self.probed(), [1260])

    def test_addresses_come_from_the_status_file(self):
        prefix = {'prefix': '2001:db8:122::/48', 'source': 'static', 'expires': None}
        self.settings(test_target=TARGET)
        self.daemon('active', pref64=prefix, plan=dict(PLAN, ipv4_clat='192.0.0.5'))
        clatctl.cmd_test(self.sys)
        echo = ['-n', '-c', '3', '-t', '5']
        commands = self.commands()
        self.assertEqual(commands[0], ['/sbin/ping', '-6'] + echo + ['2001:db8:122:c633:64:700::'])
        self.assertEqual(commands[1], ['/sbin/ping', '-4'] + echo + ['-S', '192.0.0.5', TARGET])
        self.assertEqual(commands[2][8:10], ['-S', '192.0.0.5'])


class MainTest(ClatctlCase):
    def setUp(self):
        super().setUp()
        self.logged = []
        self.sys.log = lambda priority, message: self.logged.append((priority, message))

    def run_main(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            clatctl.main(self.sys, list(argv))
        return out.getvalue()

    def test_status_is_one_json_line(self):
        self.box()
        self.daemon('active')
        out = self.run_main('status')
        self.assertEqual(out.count('\n'), 1)
        self.assertEqual(json.loads(out)['state'], 'active')

    def test_test_is_one_json_line(self):
        out = self.run_main('test')
        self.assertEqual(out.count('\n'), 1)
        self.assertEqual(json.loads(out)['error'], 'The CLAT is not active.')

    def test_event(self):
        self.daemon()
        self.assertEqual(self.run_main('event', 'inet6', '1'), '')
        self.assertEqual(self.run_main('event', 'inet', '1'), '')
        # configd passes '' for a word that is missing
        self.assertEqual(self.run_main('event', '', ''), '')
        self.assertEqual([signo for _pid, signo in self.sys.signals],
                         [self.sys.SIGUSR2, self.sys.SIGUSR1, self.sys.SIGUSR1])
        self.assertEqual(self.logged, [])

    def test_unknown_command(self):
        self.assertEqual(self.run_main(), '')
        self.assertEqual(self.run_main('reload'), '')
        self.assertEqual(self.sys.commands, [])
        self.assertEqual(self.logged, [])

    def test_failure_is_logged_not_raised(self):
        self.sys.put(facts.SETTINGS, json.dumps(dict(facts.DEFAULT_SETTINGS, test_target='not an address')))
        self.daemon('active')
        self.assertEqual(self.run_main('test'), '')
        self.assertEqual([priority for priority, _message in self.logged], [3])
        self.assertIn('clatctl test: Traceback', self.logged[0][1])


if __name__ == '__main__':
    unittest.main()
