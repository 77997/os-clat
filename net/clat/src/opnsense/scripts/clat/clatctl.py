#!/usr/local/bin/python3

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
import sys
import traceback

from lib import discovery
from lib import facts

PKG = '/usr/local/sbin/pkg'
PFCTL = '/sbin/pfctl'
PING = '/sbin/ping'
PS = '/bin/ps'

STATE_MESSAGES = {
    'disabled': 'Disabled.',
    'stopped': 'The CLAT service is not running.',
    'starting': 'The CLAT service is starting.',
    'waiting-for-prefix-delegation': 'A NAT64 prefix is known; waiting for the delegated prefix of this session.',
    'active': 'Active.',
    'suspended': 'Suspended: the uplink lost IPv6.',
}
REASON_MESSAGES = {
    ('listening', 'no_uplink_ipv6'): 'Listening: the uplink is down or has no IPv6 default route.',
    ('listening', 'no_nat64_prefix'): 'Listening: no NAT64 prefix found.',
    ('native-ipv4', 'uplink'): 'Native IPv4 is present on the uplink.',
    ('native-ipv4', 'gateway'): 'A native IPv4 gateway is present.',
    ('native-ipv4', 'hold'): 'Native IPv4 disappeared; activation is held back for 60 seconds.',
}
WITHDRAWN_MESSAGE = ' The IPv4 default route was handed to another gateway.'

# reasons of the state "blocked" that are no preflight rows (lib.plan.PlanError codes)
PLAN_MESSAGES = {
    'uplink_mtu': 'The uplink IPv6 MTU is unknown or below 1280.',
    'prefix_id': 'Prefix ID %(prefix_id)s does not fit in the delegated prefix.',
    'address': 'The CLAT IPv6 address cannot be used.',
}

SOURCE_NAMES = {'ra': 'RA', 'dns': 'DNS', 'static': 'static'}

TEST_NAMES = {
    'plat': 'NAT64 gateway over IPv6',
    'path': 'IPv4 through the CLAT',
    'mtu': 'IPv4 packet size',
}
RESULT_NAMES = {True: 'ok', False: 'failed', None: 'inconclusive'}
PING_SUMMARY = re.compile(r'(\d+) packets transmitted, (\d+) packets received')
# what ping prints when a DF probe is refused: by a router on the path (tayga), or by the tun itself
PING_TOO_BIG = re.compile(r'frag needed and DF set|Message too long')
ECHO_WAIT = 5       # ping -t of the two echo tests
PROBE_WAIT = 2      # ping -t of one DF probe
PROBE_FLOOR = 1280  # an IPv4 packet of this size must not be refused
PROBE_SMALL = 84    # an ordinary ping (56 data bytes)


def daemon_pid(sysif) -> int | None:
    """ Pid of the running daemon; None when it does not run. The pidfile outlives a daemon that
        was killed, and its pid can then belong to another process: as rc.subr does, the command
        line of the process is looked at as well.
    """
    try:
        pid = int((sysif.read(facts.PIDFILE) or '').strip())
    except ValueError:
        return None
    if pid <= 0 or not sysif.pid_alive(pid):
        return None
    command = sysif.run([PS, '-o', 'command=', '-p', str(pid)])[1]
    return pid if 'clatd.py' in command else None


def daemon_status(sysif) -> tuple[bool, dict | None]:
    """ (the daemon runs, content of its status file). The file is None when the daemon does not
        run, and while it starts: it removes the file at start and writes it after the first pass.
    """
    if daemon_pid(sysif) is None:
        return False, None
    try:
        status = json.loads(sysif.read(facts.STATUS) or '')
    except ValueError:
        status = None
    return True, status if isinstance(status, dict) else None


def tayga_version(sysif) -> str | None:
    """ Version of the installed tayga package; None when it cannot be told. """
    code, out, _err = sysif.run([PKG, 'query', '%v', 'tayga'])
    return (out.strip() or None) if code == 0 else None


def nat_rule_present(sysif) -> bool:
    """ Core's automatic outbound NAT rule on the CLAT interface is loaded. """
    out = sysif.run([PFCTL, '-sn'])[1]
    return any(line.startswith('nat on %s ' % facts.TUN) for line in out.splitlines())


def state_message(state: str, reason: str, withdrawn: bool, rows: list) -> str:
    if state == 'blocked':
        for row in rows:
            if row['id'] == reason:
                return row['message']
        return 'Blocked (%s).' % reason
    if state == 'backoff':
        return 'Retrying after a failure (%s).' % reason
    if state == 'suspended' and withdrawn:
        return STATE_MESSAGES[state] + WITHDRAWN_MESSAGE
    return REASON_MESSAGES.get((state, reason)) or STATE_MESSAGES[state]


def show(value) -> str:
    return '-' if value is None else str(value)


def status_text(result: dict) -> dict:
    """ Plain text for the status panel: one string per row, lines separated by a newline. """
    pref64, address, gateway, tayga = (result[key] for key in ('pref64', 'address', 'gateway', 'tayga'))
    text = {'state': result['message'], 'uplink': show(result['uplink']['runtime_device'])}
    if pref64 is None:
        text['pref64'] = '-'
    else:
        source = SOURCE_NAMES.get(pref64['source'], pref64['source'])
        if pref64['lifetime'] is not None:
            source = '%s, %d s left' % (source, pref64['lifetime'])
        text['pref64'] = '%s (%s)' % (pref64['prefix'], source)
    text['address'] = '%s (CLAT), %s' % (address['clat6'], address['ipv4_clat']) if address else '-'
    text['mtu'] = 'configured %s, effective %s, IPv4 %s, TCP MSS %s' % tuple(
        show(result['mtu'][key]) for key in ('configured', 'effective', 'ipv4', 'mss'))
    text['gateway'] = gateway['message'] if gateway else '-'
    if result['nat_rule'] is False:
        text['gateway'] += '; NAT rule missing'
    if tayga['running']:
        lines = ['running for %d s, %d restarts' % (tayga['uptime'], tayga['restarts'])]
    else:
        lines = ['not running, %d restarts' % tayga['restarts']]
    if result['state'] == 'backoff':
        # what tayga printed last is its own explanation of the failure
        lines += tayga['output']
    text['tayga'] = '\n'.join(lines)
    rows = ['%s: %s' % (row['effect'], row['message']) for row in result['preflight']]
    text['preflight'] = '\n'.join(rows) or 'No findings.'
    return text


def cmd_status(sysif) -> dict:
    """ What the daemon last wrote to its status file, combined with freshly gathered facts. """
    now = int(sysif.time())
    known = facts.Facts()
    known.load_settings(sysif)
    known.refresh_config(sysif, force=True)
    known.refresh_link(sysif)
    known.refresh_activation(sysif)
    settings = known.settings
    cfg = known.cfg or {}
    configured = cfg.get('uplink') or {}

    running, status = daemon_status(sysif)
    if not running:
        state = 'stopped' if settings['enabled'] else 'disabled'
    elif status is None:
        state = 'starting'
    else:
        state = status.get('state', 'starting')
    status = status or {}
    reason = status.get('reason', '')
    plan = status.get('plan') or {}
    tayga = status.get('tayga') or {}

    rows = facts.preflight(known, sysif, tayga_version(sysif))
    if state == 'blocked' and reason in PLAN_MESSAGES:
        row = {'id': reason, 'effect': 'block', 'message': PLAN_MESSAGES[reason] % settings}
        warn = next((i for i, other in enumerate(rows) if other['effect'] != 'block'), len(rows))
        rows = rows[:warn] + [row] + rows[warn:]

    pref64 = status.get('pref64')
    if pref64:
        expires = pref64.get('expires')
        lifetime = None if expires is None else max(0, int(expires) - now)
        pref64 = {'prefix': pref64['prefix'], 'source': pref64['source'], 'lifetime': lifetime}

    mtu_configured = configured.get('mtu')
    if mtu_configured is not None and settings['ipv6_mtu']:
        mtu_configured = min(mtu_configured, settings['ipv6_mtu'])
    mss = cfg.get('mss')

    gateway = nat_rule = None
    if state == 'active':
        if known.gw is not None:
            code, message = facts.gateway_report(known.gw)
            gateway = {'default': code == 'default', 'message': message}
        nat_rule = nat_rule_present(sysif)

    started = tayga.get('started')
    result = {
        'running': running,
        'state': state,
        'reason': reason,
        'message': state_message(state, reason, bool(status.get('withdrawn')), rows),
        'since': status.get('since'),
        'uplink': {
            'configured': configured.get('key'),
            'configured_device': configured.get('if'),
            'runtime_device': known.uplink_dev(),
        },
        'pref64': pref64 or None,
        'address': {key: plan[key] for key in ('clat6', 'tayga6', 'ipv4_clat', 'ipv4_tayga')} if plan else None,
        'mtu': {
            'configured': mtu_configured,
            'effective': known.mtu6(),
            'tun': plan.get('tun_mtu'),
            'offlink': plan.get('offlink_mtu'),
            'ipv4': plan.get('ipv4_mtu'),
            'mss': mss - 60 if isinstance(mss, int) and cfg.get('scrub') else None,
        },
        'gateway': gateway,
        'nat_rule': nat_rule,
        'tayga': {
            'running': started is not None,
            'uptime': None if started is None else max(0, now - int(started)),
            'restarts': tayga.get('restarts', 0),
            'output': list(tayga.get('output') or []),
        },
        'preflight': rows,
    }
    result['text'] = status_text(result)
    return result


def cmd_event(sysif, family: str, uplink: str) -> None:
    """ Pass a newwanip event of core to the daemon. USR2: IPv6 on the configured uplink, which
        confirms the delegated prefix of a new session. USR1: anything else.
    """
    pid = daemon_pid(sysif)
    if pid is not None:
        confirmed = family == 'inet6' and uplink == '1'
        sysif.kill(pid, sysif.SIGUSR2 if confirmed else sysif.SIGUSR1)


def echo_test(sysif, test_id: str, argv: list, subject: str) -> dict:
    code, out, err = sysif.run(argv, timeout=ECHO_WAIT + 5.0)
    summary = PING_SUMMARY.search(out)
    if summary:
        detail = '%s of %s replies' % (summary.group(2), summary.group(1))
    else:
        detail = (err.strip().splitlines() or ['no reply'])[-1]
    return {'id': test_id, 'ok': code == 0, 'detail': '%s: %s' % (subject, detail)}


def probe_test(sysif, source: str, target: str, top: int) -> dict:
    """ Largest IPv4 packet for which a ping with DF set is answered, up to top, the IPv4 MTU presented.

        ok: top is answered, or the size above the largest one answered is refused with "fragmentation
        needed". A limit that is announced like this is one that path MTU discovery finds.
        inconclusive (ok is None): the size above the largest one answered gets neither a reply nor a
        refusal. The probe is a ping and needs its reply back, so it cannot tell a NAT64 that returns
        large echo replies as IPv6 fragments (tayga does not translate a fragmented ICMP message) from a
        path that silently loses packets of that size.
        failed: no ping is answered, or a size of PROBE_FLOOR or less is refused.
    """
    answers = {}

    def probe(size: int) -> str:
        """ 'reply', 'too big' (refused with "fragmentation needed") or 'lost' (no answer at all) """
        if size not in answers:
            argv = [PING, '-4', '-n', '-D', '-c', '1', '-t', str(PROBE_WAIT), '-S', source, '-s', str(size - 28)]
            code, out, err = sysif.run(argv + [target], timeout=PROBE_WAIT + 5.0)
            if code == 0:
                answers[size] = 'reply'
            else:
                answers[size] = 'too big' if PING_TOO_BIG.search(out + err) else 'lost'
        return answers[size]

    floor = min(PROBE_FLOOR, top)
    size, limit = None, floor   # the largest size answered, and the smallest one known not to be
    if probe(top) == 'reply':
        size = top
    elif probe(floor) != 'too big':
        if probe(floor) == 'reply':
            size, limit = floor, top
        elif probe(PROBE_SMALL) == 'reply':
            size = PROBE_SMALL
        # bisection between a size that is answered and one that is not
        while size is not None and limit - size > 1:
            middle = (size + limit) // 2
            if probe(middle) == 'reply':
                size = middle
            else:
                limit = middle

    refused = size != top and probe(limit) == 'too big'     # asked before: the answer is kept
    if size is None and not refused:
        ok, detail = False, 'no ping was answered'
    elif refused and (size is None or size < floor):
        ok, detail = False, 'an IPv4 packet of %d bytes is refused ("fragmentation needed")' % limit
    elif size == top or refused:
        ok, detail = True, 'largest IPv4 packet that passes: %d bytes' % size
    else:
        ok, detail = None, (
            'largest ping answered: %d bytes; the next larger ping got no reply and no "fragmentation needed" error; '
            'this happens when the NAT64 returns large ping replies as fragments, which the translator does '
            'not pass for ping, and also when packets of that size are lost on the path; '
            'check with a TCP download' % size)
    return {'id': 'mtu', 'ok': ok, 'size': size, 'detail': detail}


def test_result(target: str, tests: list, error: str = '') -> dict:
    lines = ['%s: %s (%s)' % (TEST_NAMES[test['id']], RESULT_NAMES[test['ok']], test['detail']) for test in tests]
    return {'status': 'ok', 'error': error, 'target': target, 'tests': tests, 'text': error or '\n'.join(lines)}


def cmd_test(sysif) -> dict:
    """ The three tests of the status page: the NAT64 gateway over plain IPv6, the whole path
        through the CLAT, and the largest IPv4 packet that a ping with DF set is answered for.
    """
    known = facts.Facts()
    known.load_settings(sysif)
    target = known.settings['test_target']
    status = daemon_status(sysif)[1] or {}
    plan, pref64 = status.get('plan'), status.get('pref64')
    if status.get('state') != 'active' or not plan or not pref64:
        return test_result(target, [], 'The CLAT is not active.')
    if not target:
        return test_result(target, [], 'No test target is set.')

    source = plan['ipv4_clat']
    target6 = str(discovery.embed(ipaddress.ip_network(pref64['prefix']), target))
    echo = ['-n', '-c', '3', '-t', str(ECHO_WAIT)]
    return test_result(target, [
        echo_test(sysif, 'plat', [PING, '-6'] + echo + [target6], target6),
        echo_test(sysif, 'path', [PING, '-4'] + echo + ['-S', source, target], '%s from %s' % (target, source)),
        probe_test(sysif, source, target, plan['ipv4_mtu']),
    ])


def main(sysif, argv: list) -> None:
    """ clatctl.py status | event <family> <uplink> | test """
    try:
        if argv[:1] == ['status']:
            print(json.dumps(cmd_status(sysif)))
        elif argv[:1] == ['event']:
            cmd_event(sysif, argv[1], argv[2])
        elif argv[:1] == ['test']:
            print(json.dumps(cmd_test(sysif)))
    except Exception:
        sysif.log(3, 'clatctl %s: %s' % (' '.join(argv), traceback.format_exc()))


if __name__ == '__main__':
    # only here: lib.sysif is the one module that needs FreeBSD
    from lib.sysif import System

    main(System(), sys.argv[1:])
    sys.exit(0)
