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

import dataclasses
import hashlib
import os
import sys
import unittest
from ipaddress import IPv6Address, IPv6Network
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'opnsense', 'scripts', 'clat'))

from lib import plan  # noqa: E402
from lib.facts import DEFAULT_SETTINGS  # noqa: E402
from lib.plan import PlanError  # noqa: E402

WKP = IPv6Network('64:ff9b::/96')
DELEGATED = IPv6Network('2001:db8:1200::/56')
SUBNET = IPv6Network('2001:db8:1200:ff::/64')
SECRET = bytes(range(32))


def hashed_iid(subnet, secret, counter):
    """ The interface identifier of the given hash round, computed independently of plan.py. """
    digest = hashlib.sha256(secret + subnet.network_address.packed[:8] + bytes([counter])).digest()
    return int.from_bytes(digest[:8], 'big') & 0xFFFFFFFFFFFFFFFE


def clat_mss(uplink_mtu, ipv4_mtu=1500, offset=0, ipv6_mtu=0):
    """ Mirror of clat_mss() in clat.inc with the clamp on: the value handed to core as the interface MSS.
        It documents the rule only; the PHP cannot run here, so nothing in this file tests clat.inc.
    """
    mtu = min(uplink_mtu, ipv6_mtu) if ipv6_mtu > 0 else uplink_mtu
    return min(mtu, ipv4_mtu + 20) - offset


def make(mtu6=1492, pref64=WKP, delegated=DELEGATED, claims=(), in_use=(), **changes):
    settings = dict(DEFAULT_SETTINGS)
    settings.update(changes)
    return plan.make_plan(settings, pref64, delegated, claims, SECRET, in_use, mtu6)


class MtuTest(unittest.TestCase):
    def test_design_table(self):
        # DESIGN 8.1: uplink IPv6 MTU -> tun MTU, offlink-mtu, IPv4 MTU presented
        table = (
            (1492, (1492, 1492, 1472)),
            (1500, (1500, 1500, 1480)),
            (1520, (1520, 1520, 1500)),
            (1528, (1528, 1520, 1500)),
            (1536, (1528, 1520, 1500)),
            (9000, (1528, 1520, 1500)),
        )
        for mtu, expected in table:
            self.assertEqual(plan.clat_mtus(mtu), expected, mtu)

    def test_lowest_usable_uplink(self):
        self.assertEqual(plan.clat_mtus(1280), (1280, 1280, 1260))

    def test_other_ipv4_mtu(self):
        self.assertEqual(plan.clat_mtus(1500, 1400), (1428, 1420, 1400))
        self.assertEqual(plan.clat_mtus(1420, 1400), (1420, 1420, 1400))
        self.assertEqual(plan.clat_mtus(1300, 1400), (1300, 1300, 1280))
        self.assertEqual(plan.clat_mtus(9000, 1280), (1308, 1300, 1280))

    def test_mss_rule(self):
        # DESIGN 8.2 against the MSS column of 8.1: core clamps to the interface MSS minus 60. The rule is
        # documented with the mirror above and checked against clat_mtus(); clat.inc is not exercised
        for mtu, mss in ((1492, 1432), (1500, 1440), (1520, 1460), (1528, 1460), (9000, 1460)):
            self.assertEqual(clat_mss(mtu) - 60, mss, mtu)
            # the clamp never exceeds what fits in the IPv4 MTU presented
            self.assertEqual(clat_mss(mtu) - 60, plan.clat_mtus(mtu)[2] - 40, mtu)
        self.assertEqual(clat_mss(1492, offset=12) - 60, 1420)
        self.assertEqual(clat_mss(1500, ipv4_mtu=1400) - 60, 1360)
        # the IPv6 MTU override can only lower the value, as it does for the runtime MTU
        self.assertEqual(clat_mss(1500, ipv6_mtu=1492) - 60, 1432)
        self.assertEqual(clat_mss(1500, ipv6_mtu=1492) - 60, plan.clat_mtus(1492)[2] - 40)
        self.assertEqual(clat_mss(1500, ipv6_mtu=9000) - 60, 1440)
        self.assertEqual(clat_mss(9000, ipv6_mtu=1400, offset=12) - 60, 1328)

    def test_effective_mtu6(self):
        # RA MTU below, equal, above the device MTU, and none
        self.assertEqual(plan.effective_mtu6(1500, 1492, 1500), 1492)
        self.assertEqual(plan.effective_mtu6(1500, 1500, 1500), 1500)
        self.assertEqual(plan.effective_mtu6(1492, 1500, 1492), 1492)
        self.assertEqual(plan.effective_mtu6(1500, 0, 1500), 1500)
        self.assertEqual(plan.effective_mtu6(1500, 0, 0), 1500)
        # the kernel's copy of the device MTU counts when it is lower
        self.assertEqual(plan.effective_mtu6(1500, 0, 1480), 1480)
        self.assertEqual(plan.effective_mtu6(1500, 1280, 1480), 1280)


class PrefixFileTest(unittest.TestCase):
    def test_prefix(self):
        self.assertEqual(plan.parse_prefix_file('2001:db8:1200::/56\n'), DELEGATED)
        self.assertEqual(plan.parse_prefix_file('2001:db8:1200:ff::/64\n'), SUBNET)
        self.assertEqual(plan.parse_prefix_file('2001:db8:1200::/56'), DELEGATED)

    def test_host_bits_masked(self):
        self.assertEqual(plan.parse_prefix_file('2001:db8:1200:34::1/56\n'), DELEGATED)

    def test_missing_or_empty(self):
        self.assertIsNone(plan.parse_prefix_file(None))
        self.assertIsNone(plan.parse_prefix_file(''))
        self.assertIsNone(plan.parse_prefix_file('\n'))

    def test_garbage(self):
        self.assertIsNone(plan.parse_prefix_file('no prefix here\n'))
        self.assertIsNone(plan.parse_prefix_file('2001:db8:1200::\n'))
        self.assertIsNone(plan.parse_prefix_file('192.0.2.0/24\n'))
        self.assertIsNone(plan.parse_prefix_file('2001:db8:1200::/129\n'))

    def test_longer_than_64(self):
        self.assertIsNone(plan.parse_prefix_file('2001:db8:1200:ff::/65\n'))
        self.assertIsNone(plan.parse_prefix_file('2001:db8:1200:ff::1/128\n'))

    def test_two_lines(self):
        self.assertEqual(plan.parse_prefix_file('2001:db8:1200::/56\n2001:db8:3400::/56\n'), DELEGATED)
        self.assertEqual(plan.parse_prefix_file('\n2001:db8:1200::/56\n'), DELEGATED)


class ChooseSubnetTest(unittest.TestCase):
    def test_no_claims(self):
        self.assertEqual(plan.choose_subnet(DELEGATED, []), SUBNET)
        self.assertEqual(plan.choose_subnet(IPv6Network('2001:db8::/48'), []), IPv6Network('2001:db8:0:ffff::/64'))

    def test_claims_at_the_top(self):
        self.assertEqual(plan.choose_subnet(DELEGATED, [255]), IPv6Network('2001:db8:1200:fe::/64'))
        self.assertEqual(plan.choose_subnet(DELEGATED, [0, 253, 255, 254]), IPv6Network('2001:db8:1200:fc::/64'))
        self.assertEqual(plan.choose_subnet(DELEGATED, iter([0, 1, 2])), SUBNET)

    def test_claim_outside_the_delegation(self):
        self.assertEqual(plan.choose_subnet(DELEGATED, [256, 4096]), SUBNET)

    def test_single_64(self):
        self.assertEqual(plan.choose_subnet(SUBNET, []), SUBNET)
        self.assertEqual(plan.choose_subnet(SUBNET, [0]), SUBNET)

    def test_all_claimed(self):
        self.assertEqual(plan.choose_subnet(DELEGATED, range(256)), SUBNET)
        self.assertEqual(plan.choose_subnet(IPv6Network('2001:db8:1200:fc::/62'), [0, 1, 2, 3]), SUBNET)

    def test_prefix_id(self):
        self.assertEqual(plan.choose_subnet(DELEGATED, [], '0'), IPv6Network('2001:db8:1200::/64'))
        self.assertEqual(plan.choose_subnet(DELEGATED, [], 'a'), IPv6Network('2001:db8:1200:a::/64'))
        self.assertEqual(plan.choose_subnet(DELEGATED, [], 'FF'), SUBNET)
        # an explicit choice is not checked against the claims
        self.assertEqual(plan.choose_subnet(DELEGATED, [16], '10'), IPv6Network('2001:db8:1200:10::/64'))
        self.assertEqual(plan.choose_subnet(SUBNET, [], '0'), SUBNET)

    def test_prefix_id_out_of_range(self):
        for delegated, prefix_id in ((DELEGATED, '100'), (DELEGATED, 'ffff'), (SUBNET, '1'), (DELEGATED, 'xyz')):
            with self.assertRaises(PlanError) as caught:
                plan.choose_subnet(delegated, [], prefix_id)
            self.assertEqual(caught.exception.code, 'prefix_id')


class InterfaceIdTest(unittest.TestCase):
    def test_excluded(self):
        self.assertTrue(plan.iid_excluded(0))
        self.assertTrue(plan.iid_excluded(1))
        self.assertTrue(plan.iid_excluded(0xFFFF))
        self.assertFalse(plan.iid_excluded(0x10000))
        self.assertFalse(plan.iid_excluded(0xFDFFFFFFFFFFFF7F))
        self.assertTrue(plan.iid_excluded(0xFDFFFFFFFFFFFF80))
        self.assertTrue(plan.iid_excluded(0xFDFFFFFFFFFFFFFF))
        self.assertFalse(plan.iid_excluded(0xFE00000000000000))

    def test_hash(self):
        iid = plan.interface_id(SUBNET, SECRET)
        self.assertEqual(iid, hashed_iid(SUBNET, SECRET, 0))
        self.assertEqual(iid % 2, 0)
        self.assertTrue(0x10000 <= iid < 2 ** 64)

    def test_deterministic(self):
        self.assertEqual(plan.interface_id(SUBNET, SECRET), plan.interface_id(SUBNET, SECRET))
        self.assertEqual(plan.interface_id(SUBNET, SECRET, []), plan.interface_id(SUBNET, SECRET, iter(())))

    def test_differs_per_subnet_and_secret(self):
        iid = plan.interface_id(SUBNET, SECRET)
        self.assertNotEqual(iid, plan.interface_id(IPv6Network('2001:db8:1200:fe::/64'), SECRET))
        self.assertNotEqual(iid, plan.interface_id(SUBNET, bytes(32)))

    def test_rehash_when_in_use(self):
        first = plan.interface_id(SUBNET, SECRET)
        second = hashed_iid(SUBNET, SECRET, 1)
        self.assertNotEqual(first, second)
        even = SUBNET.network_address + first
        self.assertEqual(plan.interface_id(SUBNET, SECRET, [even]), second)
        self.assertEqual(plan.interface_id(SUBNET, SECRET, {even + 1}), second)
        self.assertEqual(plan.interface_id(SUBNET, SECRET, [even, SUBNET.network_address + second + 1]),
                         hashed_iid(SUBNET, SECRET, 2))
        # an address elsewhere on the box does not matter
        self.assertEqual(plan.interface_id(SUBNET, SECRET, [IPv6Address('2001:db8:1200:1::1')]), first)

    def test_rehash_when_excluded(self):
        first = hashed_iid(SUBNET, SECRET, 0)
        second = hashed_iid(SUBNET, SECRET, 1)
        with mock.patch.object(plan, 'iid_excluded', side_effect=lambda iid: iid == first):
            self.assertEqual(plan.interface_id(SUBNET, SECRET), second)
        with mock.patch.object(plan, 'iid_excluded', side_effect=lambda iid: iid == (first | 1)):
            self.assertEqual(plan.interface_id(SUBNET, SECRET), second)

    def test_nothing_usable(self):
        with mock.patch.object(plan, 'iid_excluded', return_value=True) as excluded:
            with self.assertRaises(PlanError) as caught:
                plan.interface_id(SUBNET, SECRET)
        self.assertEqual(caught.exception.code, 'address')
        self.assertEqual(excluded.call_count, 256)


class MakePlanTest(unittest.TestCase):
    def test_automatic_pair(self):
        result = make(claims=[0, 1])
        iid = hashed_iid(SUBNET, SECRET, 0)
        self.assertEqual(result.clat6, SUBNET.network_address + iid)
        self.assertEqual(result.tayga6, result.clat6 + 1)
        self.assertEqual(int(result.clat6) % 2, 0)
        self.assertIn(result.clat6, SUBNET)
        self.assertEqual(result.pref64, WKP)
        self.assertEqual((result.ipv4_clat, result.ipv4_tayga), ('192.0.0.1', '192.0.0.2'))
        self.assertEqual((result.tun_mtu, result.offlink_mtu, result.ipv4_mtu), (1492, 1492, 1472))
        self.assertEqual(result.udp_cksum, 'calc')
        self.assertEqual(result.pair, '%s/127' % result.clat6)

    def test_claimed_subnet_avoided(self):
        self.assertIn(make(claims=[255]).clat6, IPv6Network('2001:db8:1200:fe::/64'))

    def test_address_in_use_avoided(self):
        first = make()
        second = make(in_use={first.tayga6})
        self.assertNotEqual(second.clat6, first.clat6)
        self.assertEqual(second.clat6, SUBNET.network_address + hashed_iid(SUBNET, SECRET, 1))

    def test_prefix_id(self):
        self.assertIn(make(prefix_id='10').clat6, IPv6Network('2001:db8:1200:10::/64'))
        with self.assertRaises(PlanError) as caught:
            make(prefix_id='100')
        self.assertEqual(caught.exception.code, 'prefix_id')

    def test_manual_address(self):
        result = make(address='2001:db8:1200:5::10')
        self.assertEqual(result.clat6, IPv6Address('2001:db8:1200:5::10'))
        self.assertEqual(result.tayga6, IPv6Address('2001:db8:1200:5::11'))
        self.assertEqual(result.pair, '2001:db8:1200:5::10/127')

    def test_manual_address_odd_input_normalised(self):
        self.assertEqual(make(address='2001:db8:1200:5::11'), make(address='2001:db8:1200:5::10'))

    def test_manual_address_wins_over_prefix_id(self):
        self.assertEqual(make(address='2001:db8:99::10', prefix_id='100').clat6, IPv6Address('2001:db8:99::10'))

    def test_manual_address_unusable(self):
        with self.assertRaises(PlanError) as caught:
            make(address='not an address')
        self.assertEqual(caught.exception.code, 'address')

    def test_pair_inside_nat64_prefix(self):
        with self.assertRaises(PlanError) as caught:
            make(address='64:ff9b::10')
        self.assertEqual(caught.exception.code, 'address')
        with self.assertRaises(PlanError) as caught:
            make(pref64=IPv6Network('2001:db8:1200:ff::/64'))
        self.assertEqual(caught.exception.code, 'address')

    def test_uplink_mtu(self):
        for mtu6 in (None, 0, 1279):
            with self.assertRaises(PlanError) as caught:
                make(mtu6=mtu6)
            self.assertEqual(caught.exception.code, 'uplink_mtu')
        self.assertEqual(make(mtu6=1280).tun_mtu, 1280)

    def test_settings_used(self):
        result = make(mtu6=1500, ipv4_clat='192.0.0.4', ipv4_tayga='192.0.0.5', ipv4_mtu=1400, udp_cksum='drop')
        self.assertEqual((result.ipv4_clat, result.ipv4_tayga, result.udp_cksum), ('192.0.0.4', '192.0.0.5', 'drop'))
        self.assertEqual((result.tun_mtu, result.offlink_mtu, result.ipv4_mtu), (1428, 1420, 1400))

    def test_equality(self):
        self.assertEqual(make(), make())
        self.assertEqual(hash(make()), hash(make()))
        # the same tun MTU and offlink-mtu: no restart
        self.assertEqual(make(mtu6=1528), make(mtu6=9000))
        self.assertNotEqual(make(mtu6=1492), make(mtu6=1500))
        self.assertNotEqual(make(mtu6=1520), make(mtu6=1528))
        self.assertNotEqual(make(), make(pref64=IPv6Network('2001:db8:64::/96')))
        self.assertNotEqual(make(), make(delegated=IPv6Network('2001:db8:3400::/56')))
        self.assertNotEqual(make(), make(udp_cksum='forward'))
        self.assertNotEqual(make(), make(ipv4_tayga='192.0.0.3'))

    def test_frozen(self):
        with self.assertRaises(dataclasses.FrozenInstanceError):
            make().tun_mtu = 1500


class TaygaTest(unittest.TestCase):
    def test_conf(self):
        result = make(address='2001:db8:1200:ff::8c5a:4c12')
        self.assertEqual(plan.tayga_conf(result, '/var/run/clat/empty'), (
            'tun-device tun464\n'
            'ipv4-addr 192.0.0.2\n'
            'ipv6-addr 2001:db8:1200:ff::8c5a:4c13\n'
            'prefix 64:ff9b::/96\n'
            'map 192.0.0.1 2001:db8:1200:ff::8c5a:4c12\n'
            'udp-cksum-mode calc\n'
            'offlink-mtu 1492\n'
            'data-dir /var/run/clat/empty\n'
        ))

    def test_conf_other_values(self):
        result = make(mtu6=9000, pref64=IPv6Network('2001:db8:64::/48'), address='2001:db8:1200::2',
                      ipv4_clat='192.0.0.4', ipv4_tayga='192.0.0.5', udp_cksum='forward')
        lines = plan.tayga_conf(result, '/tmp/empty').splitlines()
        self.assertEqual(lines, [
            'tun-device tun464',
            'ipv4-addr 192.0.0.5',
            'ipv6-addr 2001:db8:1200::3',
            'prefix 2001:db8:64::/48',
            'map 192.0.0.4 2001:db8:1200::2',
            'udp-cksum-mode forward',
            'offlink-mtu 1520',
            'data-dir /tmp/empty',
        ])

    def test_argv(self):
        self.assertEqual(plan.tayga_argv('/usr/local/etc/clat/tayga.conf'), [
            '/usr/local/sbin/tayga', '-c', '/usr/local/etc/clat/tayga.conf', '--nodetach', '--stdout',
            '-u', 'nobody', '-g', 'nobody', '-r',
        ])


if __name__ == '__main__':
    unittest.main()
