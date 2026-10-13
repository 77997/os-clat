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

import os
import struct
import sys
import unittest
from ipaddress import IPv6Address, IPv6Network

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'opnsense', 'scripts', 'clat'))

from lib import discovery  # noqa: E402
from lib.discovery import DnsPrefix, RaPacket, RaPrefix, ll_norm  # noqa: E402

# the first 96 bits of 2001:db8:1122:3344:5566:7788::
RAW = bytes.fromhex('20010db81122334455667788')
WKP = IPv6Network('64:ff9b::/96')
OTHER = IPv6Network('2001:db8:64::/96')
MTU_OPTION = struct.pack('!BBHI', 5, 1, 0, 1492)


def ra(*options, icmp_type=134, code=0):
    """ A router advertisement as read from the raw socket, with the options given. """
    return struct.pack('!BBHBBHII', icmp_type, code, 0, 64, 0, 1800, 0, 0) + b''.join(options)


def pref64(lifetime, plc, raw=RAW):
    """ Option 38 with length 2. """
    return struct.pack('!BBH', 38, 2, lifetime | plc) + raw


class LlNormTest(unittest.TestCase):
    def test_without_zone(self):
        self.assertEqual(ll_norm('fe80::1'), IPv6Address('fe80::1'))

    def test_with_zone(self):
        self.assertEqual(ll_norm('fe80::2a0:a5ff:fe12:3456%pppoe0'), IPv6Address('fe80::2a0:a5ff:fe12:3456'))

    def test_zoned_and_unzoned_compare_equal(self):
        self.assertEqual(ll_norm('fe80::1%pppoe0'), ll_norm('fe80::1'))
        self.assertIsInstance(ll_norm('fe80::1%pppoe0'), IPv6Address)

    def test_embedded_zone_cleared(self):
        self.assertEqual(ll_norm('fe80:9::1'), IPv6Address('fe80::1'))
        self.assertEqual(ll_norm('fe80:9::1%pppoe0'), IPv6Address('fe80::1'))
        self.assertEqual(ll_norm('febf:12::1'), IPv6Address('febf::1'))

    def test_outside_link_local_unchanged(self):
        self.assertEqual(ll_norm('2001:db8:9::1'), IPv6Address('2001:db8:9::1'))
        self.assertEqual(ll_norm('fec0:9::1'), IPv6Address('fec0:9::1'))

    def test_not_an_address(self):
        for text in ('link#9', '', '192.0.2.1', 'pppoe0'):
            with self.assertRaises(ValueError):
                ll_norm(text)


class ParseRaPref64Test(unittest.TestCase):
    def test_each_prefix_length_code(self):
        expected = (
            '2001:db8:1122:3344:5566:7788::/96',
            '2001:db8:1122:3344::/64',
            '2001:db8:1122:3300::/56',
            '2001:db8:1122::/48',
            '2001:db8:1100::/40',
            '2001:db8::/32',
        )
        for plc, text in enumerate(expected):
            self.assertEqual(discovery.parse_ra_pref64(ra(pref64(1800, plc))), [(IPv6Network(text), 1800)])

    def test_lifetime(self):
        self.assertEqual(discovery.parse_ra_pref64(ra(pref64(0xFFF8, 0)))[0][1], 65528)
        self.assertEqual(discovery.parse_ra_pref64(ra(pref64(8, 5)))[0][1], 8)
        # the three low bits are the prefix length code, never part of the lifetime
        self.assertEqual(discovery.parse_ra_pref64(ra(pref64(0x0708, 5))), [(IPv6Network('2001:db8::/32'), 1800)])

    def test_lifetime_zero(self):
        self.assertEqual(discovery.parse_ra_pref64(ra(pref64(0, 0, WKP.network_address.packed[:12]))), [(WKP, 0)])

    def test_no_option_38(self):
        self.assertEqual(discovery.parse_ra_pref64(ra()), [])
        self.assertEqual(discovery.parse_ra_pref64(ra(MTU_OPTION)), [])

    def test_other_option_38_forms_skipped(self):
        short = struct.pack('!BBH', 38, 1, 1800) + RAW[:4]
        long = pref64(1800, 0) + bytes(8)
        long = long[:1] + b'\x03' + long[2:]
        self.assertEqual(discovery.parse_ra_pref64(ra(short)), [])
        self.assertEqual(discovery.parse_ra_pref64(ra(long)), [])
        self.assertEqual(discovery.parse_ra_pref64(ra(pref64(1800, 6))), [])
        self.assertEqual(discovery.parse_ra_pref64(ra(pref64(1800, 7))), [])
        # a skipped option does not hide a valid one
        self.assertEqual(discovery.parse_ra_pref64(ra(short, pref64(600, 5))), [(IPv6Network('2001:db8::/32'), 600)])

    def test_two_options(self):
        data = ra(MTU_OPTION, pref64(1800, 0, WKP.network_address.packed[:12]), pref64(600, 1))
        self.assertEqual(discovery.parse_ra_pref64(data), [(WKP, 1800), (IPv6Network('2001:db8:1122:3344::/64'), 600)])

    def test_malformed(self):
        good = ra(pref64(1800, 0))
        self.assertIsNotNone(discovery.parse_ra_pref64(good))
        self.assertIsNone(discovery.parse_ra_pref64(ra(pref64(1800, 0), icmp_type=133)))
        self.assertIsNone(discovery.parse_ra_pref64(ra(pref64(1800, 0), code=1)))
        self.assertIsNone(discovery.parse_ra_pref64(ra()[:15]))
        self.assertIsNone(discovery.parse_ra_pref64(b''))
        # option length 0
        self.assertIsNone(discovery.parse_ra_pref64(ra(struct.pack('!BBHI', 5, 0, 0, 1492))))
        self.assertIsNone(discovery.parse_ra_pref64(ra(pref64(1800, 0), bytes(8))))
        # option running past the end
        self.assertIsNone(discovery.parse_ra_pref64(good[:-1]))
        self.assertIsNone(discovery.parse_ra_pref64(good[:-8]))
        self.assertIsNone(discovery.parse_ra_pref64(good + b'\x05'))


class AcceptRaTest(unittest.TestCase):
    def setUp(self):
        self.data = ra(pref64(1800, 0, WKP.network_address.packed[:12]))
        self.router = ll_norm('fe80::1%pppoe0')

    def packet(self, ifname='pppoe0', hoplimit=255, source='fe80::1', data=None):
        return RaPacket(ifname, hoplimit, ll_norm(source), self.data if data is None else data)

    def test_accepted(self):
        self.assertEqual(discovery.accept_ra(self.packet(), 'pppoe0', self.router), [(WKP, 1800)])

    def test_accepted_without_pref64(self):
        self.assertEqual(discovery.accept_ra(self.packet(data=ra(MTU_OPTION)), 'pppoe0', self.router), [])

    def test_wrong_interface(self):
        self.assertIsNone(discovery.accept_ra(self.packet(ifname='igc1'), 'pppoe0', self.router))
        self.assertIsNone(discovery.accept_ra(self.packet(ifname=''), 'pppoe0', self.router))

    def test_no_uplink(self):
        self.assertIsNone(discovery.accept_ra(self.packet(), None, self.router))
        self.assertIsNone(discovery.accept_ra(self.packet(ifname=''), '', self.router))

    def test_hop_limit(self):
        self.assertIsNone(discovery.accept_ra(self.packet(hoplimit=254), 'pppoe0', self.router))
        self.assertIsNone(discovery.accept_ra(self.packet(hoplimit=-1), 'pppoe0', self.router))

    def test_global_source(self):
        router = ll_norm('2001:db8::1')
        self.assertIsNone(discovery.accept_ra(self.packet(source='2001:db8::1'), 'pppoe0', router))

    def test_source_is_not_the_router(self):
        self.assertIsNone(discovery.accept_ra(self.packet(source='fe80::2'), 'pppoe0', self.router))

    def test_router_unknown(self):
        self.assertIsNone(discovery.accept_ra(self.packet(), 'pppoe0', None))

    def test_malformed_packet(self):
        self.assertIsNone(discovery.accept_ra(self.packet(data=self.data[:-1]), 'pppoe0', self.router))


class Pref64AnswerTest(unittest.TestCase):
    # sheet python-runtime 6.3: one address per RFC 6052 length, built from 192.0.0.170
    VECTORS = (
        ('64:ff9b::c000:aa', '64:ff9b::/96'),
        ('2001:db8:c000:aa::', '2001:db8::/32'),
        ('2001:db8:1c0:0:aa::', '2001:db8:100::/40'),
        ('2001:db8:122:c000:0:aa00::', '2001:db8:122::/48'),
        ('2001:db8:122:3c0:0:aa::', '2001:db8:122:300::/56'),
        ('2001:db8:122:344:c0:0:aa00:0', '2001:db8:122:344::/64'),
    )

    def test_vectors(self):
        for aaaa, prefix in self.VECTORS:
            self.assertEqual(discovery.pref64_candidates(aaaa), {IPv6Network(prefix)}, aaaa)
            self.assertEqual(discovery.pref64_from_answer([aaaa]), IPv6Network(prefix), aaaa)

    def test_negative(self):
        self.assertEqual(discovery.pref64_candidates('2001:db8::1'), set())
        self.assertIsNone(discovery.pref64_from_answer(['2001:db8::1']))
        self.assertIsNone(discovery.pref64_from_answer([]))

    def test_both_well_known_addresses(self):
        self.assertEqual(discovery.pref64_candidates('64:ff9b::c000:ab'), {WKP})
        self.assertEqual(discovery.pref64_from_answer(['64:ff9b::c000:aa', '64:ff9b::c000:ab']), WKP)
        self.assertEqual(discovery.pref64_candidates('64:ff9b::c000:ac'), set())

    def test_octet_8_must_be_zero_except_for_96(self):
        # 192.0.0.170 sits where a /32 would put it, but bits 64 to 71 are not zero
        self.assertEqual(discovery.pref64_candidates('2001:db8:c000:aa:100::'), set())
        sloppy = IPv6Network('2001:db8:0:0:100::/96')
        self.assertEqual(discovery.pref64_candidates('2001:db8:0:0:100::c000:aa'), {sloppy})
        # the same for /40, /48, /56 and /64, where those bits lie inside or just before the IPv4 address
        for aaaa in ('2001:db8:1c0:0:1aa::', '2001:db8:122:c000:100:aa00::', '2001:db8:122:3c0:100:aa::',
                     '2001:db8:122:344:1c0:0:aa00:0'):
            self.assertEqual(discovery.pref64_candidates(aaaa), set(), aaaa)

    def test_every_length_of_one_address(self):
        found = discovery.pref64_candidates('2001:db8:c000:aa:c0:0:aa00:0')
        self.assertEqual(found, {IPv6Network('2001:db8::/32'), IPv6Network('2001:db8:c000:aa::/64')})

    def test_lowest_of_several(self):
        self.assertEqual(discovery.pref64_from_answer(['2001:db8:64::c000:aa', '64:ff9b::c000:aa']), WKP)
        # same network address: the shorter prefix is the lower one
        answer = ['2001:db8:c0:0:aa::', '2001:db8:c000:aa::']
        self.assertEqual(discovery.pref64_from_answer(answer), IPv6Network('2001:db8::/32'))
        # the address decides before the length: the /96 at the lower address wins over the /32
        self.assertEqual(discovery.pref64_from_answer(['2001:db8:c000:aa::', '64:ff9b::c000:aa']), WKP)

    def test_current_kept(self):
        answer = ['2001:db8:64::c000:aa', '64:ff9b::c000:aa']
        self.assertEqual(discovery.pref64_from_answer(answer, current=OTHER), OTHER)
        self.assertEqual(discovery.pref64_from_answer(answer, current=IPv6Network('2001:db8:99::/96')), WKP)

    def test_reject(self):
        answer = ['2001:db8:64::c000:aa', '64:ff9b::c000:aa']
        self.assertEqual(discovery.pref64_from_answer(answer, reject=[IPv6Network('64:ff9b::/64')]), OTHER)
        self.assertEqual(discovery.pref64_from_answer(answer, OTHER, [IPv6Network('2001:db8::/32')]), WKP)
        self.assertIsNone(discovery.pref64_from_answer(answer, OTHER, iter([IPv6Network('::/0')])))


class EmbedTest(unittest.TestCase):
    # RFC 6052 section 2.4, 192.0.2.33
    EXAMPLES = (
        ('2001:db8::/32', '2001:db8:c000:221::'),
        ('2001:db8:100::/40', '2001:db8:1c0:2:21::'),
        ('2001:db8:122::/48', '2001:db8:122:c000:2:2100::'),
        ('2001:db8:122:300::/56', '2001:db8:122:3c0:0:221::'),
        ('2001:db8:122:344::/64', '2001:db8:122:344:c0:2:2100::'),
        ('2001:db8:122:344::/96', '2001:db8:122:344::c000:221'),
    )

    def test_rfc6052_examples(self):
        for prefix, address in self.EXAMPLES:
            self.assertEqual(discovery.embed(IPv6Network(prefix), '192.0.2.33'), IPv6Address(address), prefix)

    def test_discovery_finds_what_embed_builds(self):
        for prefix, _address in self.EXAMPLES:
            aaaa = str(discovery.embed(IPv6Network(prefix), '192.0.0.171'))
            self.assertIn(IPv6Network(prefix), discovery.pref64_candidates(aaaa))

    def test_other_length(self):
        with self.assertRaises(ValueError):
            discovery.embed(IPv6Network('2001:db8::/80'), '192.0.2.33')


class OverlapsTest(unittest.TestCase):
    def test_overlaps(self):
        nets = [IPv6Network('2001:db8:1200::/56'), IPv6Network('2001:db8:5::/64')]
        self.assertTrue(discovery.overlaps(IPv6Network('2001:db8:1200:ff::/96'), nets))
        self.assertTrue(discovery.overlaps(IPv6Network('2001:db8::/32'), nets))
        self.assertFalse(discovery.overlaps(WKP, nets))
        self.assertFalse(discovery.overlaps(WKP, []))


class RaPrefixTest(unittest.TestCase):
    def setUp(self):
        self.ra = RaPrefix()

    def test_starts_empty(self):
        self.assertIsNone(self.ra.current())
        self.assertFalse(self.ra.expire(1000.0))

    def test_first_prefix_selected(self):
        self.assertTrue(self.ra.update([(WKP, 1800)], 100.0))
        self.assertEqual(self.ra.current(), (WKP, 1900.0))

    def test_lowest_of_two_selected(self):
        self.assertTrue(self.ra.update([(OTHER, 1800), (WKP, 600)], 100.0))
        self.assertEqual(self.ra.current(), (WKP, 700.0))

    def test_lowest_is_by_address_then_length(self):
        self.assertTrue(self.ra.update([(IPv6Network('2001:db8::/32'), 600), (WKP, 600)], 100.0))
        self.assertEqual(self.ra.current(), (WKP, 700.0))

    def test_refresh(self):
        self.ra.update([(WKP, 1800)], 100.0)
        self.assertFalse(self.ra.update([(WKP, 600)], 400.0))
        self.assertEqual(self.ra.current(), (WKP, 1000.0))

    def test_different_prefix_ignored_while_current(self):
        self.ra.update([(OTHER, 1800)], 100.0)
        self.assertFalse(self.ra.update([(WKP, 1800)], 200.0))
        self.assertEqual(self.ra.current(), (OTHER, 1900.0))

    def test_lifetime_zero_withdraws(self):
        self.ra.update([(WKP, 1800)], 100.0)
        self.assertTrue(self.ra.update([(WKP, 0)], 200.0))
        self.assertIsNone(self.ra.current())

    def test_lifetime_zero_of_unknown_prefix(self):
        self.assertFalse(self.ra.update([(WKP, 0)], 100.0))
        self.assertIsNone(self.ra.current())
        self.ra.update([(OTHER, 1800)], 100.0)
        self.assertFalse(self.ra.update([(WKP, 0)], 200.0))
        self.assertEqual(self.ra.current(), (OTHER, 1900.0))

    def test_withdrawn_and_replaced_in_one_advertisement(self):
        self.ra.update([(WKP, 1800)], 100.0)
        self.assertTrue(self.ra.update([(WKP, 0), (OTHER, 600)], 200.0))
        self.assertEqual(self.ra.current(), (OTHER, 800.0))

    def test_expiry(self):
        self.ra.update([(WKP, 1800)], 100.0)
        self.assertFalse(self.ra.expire(1899.9))
        self.assertEqual(self.ra.current(), (WKP, 1900.0))
        self.assertTrue(self.ra.expire(1900.0))
        self.assertIsNone(self.ra.current())
        self.assertFalse(self.ra.expire(2000.0))
        # after the expiry any prefix can be selected again
        self.assertTrue(self.ra.update([(OTHER, 60)], 2000.0))
        self.assertEqual(self.ra.current(), (OTHER, 2060.0))

    def test_expired_entry_is_not_current(self):
        # an advertisement that is handled before expire() ran for the lifetime that is over
        self.ra.update([(WKP, 1800)], 100.0)
        self.assertFalse(self.ra.update([(OTHER, 1800)], 1899.9))
        self.assertEqual(self.ra.current(), (WKP, 1900.0))
        self.assertTrue(self.ra.update([(OTHER, 1800)], 1900.0))
        self.assertEqual(self.ra.current(), (OTHER, 3700.0))

    def test_expired_entry_announced_again(self):
        self.ra.update([(WKP, 1800)], 100.0)
        self.assertFalse(self.ra.update([(WKP, 600)], 2000.0))
        self.assertEqual(self.ra.current(), (WKP, 2600.0))
        # without a prefix in the advertisement the expired entry is gone
        self.assertTrue(self.ra.update([], 2600.0))
        self.assertIsNone(self.ra.current())

    def test_overlap_rejected(self):
        local = [IPv6Network('2001:db8::/32')]
        self.assertFalse(self.ra.update([(OTHER, 1800)], 100.0, local))
        self.assertIsNone(self.ra.current())
        self.assertTrue(self.ra.update([(OTHER, 1800), (WKP, 1800)], 100.0, iter(local)))
        self.assertEqual(self.ra.current(), (WKP, 1900.0))

    def test_empty_list_changes_nothing(self):
        self.assertFalse(self.ra.update([], 100.0))
        self.assertIsNone(self.ra.current())
        self.ra.update([(WKP, 1800)], 100.0)
        self.assertFalse(self.ra.update([], 500.0))
        self.assertEqual(self.ra.current(), (WKP, 1900.0))


class DnsPrefixTest(unittest.TestCase):
    ANSWER = ['64:ff9b::c000:aa', '64:ff9b::c000:ab']

    def setUp(self):
        self.dns = DnsPrefix()

    def test_initial_values(self):
        self.assertIsNone(self.dns.prefix)
        self.assertEqual(self.dns.next_query, 0.0)
        self.assertEqual(self.dns.failures, 0)
        self.assertTrue(self.dns.due(0.0))

    def test_answer_with_prefix(self):
        self.assertTrue(self.dns.result(('answer', self.ANSWER, 3600), 100.0))
        self.assertEqual(self.dns.prefix, WKP)
        self.assertEqual(self.dns.next_query, 3700.0)
        self.assertFalse(self.dns.due(3699.0))
        self.assertTrue(self.dns.due(3700.0))
        # the same answer again changes nothing
        self.assertFalse(self.dns.result(('answer', self.ANSWER, 3600), 3700.0))
        self.assertEqual(self.dns.next_query, 7300.0)

    def test_minimum_refresh(self):
        for ttl in (0, 5, None):
            self.dns.result(('answer', self.ANSWER, ttl), 100.0)
            self.assertEqual(self.dns.next_query, 100.0 + discovery.DNS_MIN_REFRESH, ttl)

    def test_answer_without_prefix_drops_it(self):
        self.dns.result(('answer', self.ANSWER, 3600), 100.0)
        self.assertTrue(self.dns.result(('answer', [], 3600), 200.0))
        self.assertIsNone(self.dns.prefix)
        self.assertEqual(self.dns.next_query, 200.0 + discovery.DNS_NEGATIVE_MAX)

    def test_negative_answer_interval(self):
        self.assertFalse(self.dns.result(('answer', [], 86400), 100.0))
        self.assertEqual(self.dns.next_query, 400.0)
        self.dns.result(('answer', ['2001:db8::1'], 120), 100.0)
        self.assertEqual(self.dns.next_query, 220.0)
        self.dns.result(('answer', [], None), 100.0)
        self.assertEqual(self.dns.next_query, 160.0)

    def test_failure_keeps_prefix_and_backs_off(self):
        self.dns.result(('answer', self.ANSWER, 3600), 100.0)
        now = 3700.0
        for count, step in enumerate((10.0, 30.0, 60.0, 300.0, 300.0, 300.0)):
            self.assertFalse(self.dns.result(('fail', 'timeout', None), now))
            self.assertEqual(self.dns.prefix, WKP)
            self.assertEqual(self.dns.next_query, now + step)
            self.assertEqual(self.dns.failures, count + 1)
            now += step
        # an answer ends the back-off
        self.dns.result(('answer', self.ANSWER, 3600), now)
        self.assertEqual(self.dns.failures, 0)
        self.dns.result(('fail', 'SERVFAIL', None), now)
        self.assertEqual(self.dns.next_query, now + 10.0)

    def test_failure_without_prefix(self):
        self.assertFalse(self.dns.result(('fail', 'no nameserver', None), 50.0))
        self.assertIsNone(self.dns.prefix)
        self.assertEqual(self.dns.next_query, 60.0)

    def test_current_prefix_kept(self):
        self.dns.result(('answer', ['2001:db8:64::c000:aa'], 3600), 100.0)
        self.assertEqual(self.dns.prefix, OTHER)
        self.assertFalse(self.dns.result(('answer', ['2001:db8:64::c000:aa', '64:ff9b::c000:aa'], 3600), 200.0))
        self.assertEqual(self.dns.prefix, OTHER)
        self.assertTrue(self.dns.result(('answer', ['64:ff9b::c000:aa'], 3600), 300.0))
        self.assertEqual(self.dns.prefix, WKP)

    def test_reject(self):
        self.assertFalse(self.dns.result(('answer', self.ANSWER, 3600), 100.0, [IPv6Network('64:ff9b::/64')]))
        self.assertIsNone(self.dns.prefix)
        self.assertEqual(self.dns.next_query, 400.0)

    def test_reset(self):
        self.dns.result(('answer', self.ANSWER, 3600), 100.0)
        self.dns.result(('fail', 'timeout', None), 200.0)
        self.dns.reset()
        self.assertIsNone(self.dns.prefix)
        self.assertEqual(self.dns.next_query, 0.0)
        self.assertEqual(self.dns.failures, 0)
        self.assertTrue(self.dns.due(0.0))


class ConstantsTest(unittest.TestCase):
    def test_values(self):
        self.assertEqual(discovery.PLC_TO_LEN, (96, 64, 56, 48, 40, 32))
        self.assertEqual(discovery.DNS_NAME, 'ipv4only.arpa.')
        self.assertEqual(discovery.DNS_TIMEOUT, 2.0)
        self.assertEqual(discovery.DNS_MIN_REFRESH, 60.0)
        self.assertEqual(discovery.DNS_NEGATIVE_MAX, 300.0)
        self.assertEqual(discovery.DNS_RETRY_STEPS, (10.0, 30.0, 60.0, 300.0))
        self.assertEqual(RaPacket._fields, ('ifname', 'hoplimit', 'source', 'data'))


if __name__ == '__main__':
    unittest.main()
