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

from .discovery import DNS_NAME, DNS_TIMEOUT, DnsPrefix, RaPrefix, accept_ra
from .facts import DATA_DIR, MARKER, RESOLV_CONF, ROUTER_FILE, RUN_DIR, SECRET, STATUS, TAYGA_CONF, TODO_FILE, TUN
from .facts import Facts, first_nameserver, gateway_report, native_gateways, preflight, stale_gateways
from .plan import Plan, PlanError, make_plan, tayga_argv, tayga_conf

# The CLAT state machine. Every event ends in one reconcile pass: gather the facts the event can have changed,
# decide what the state is to be, and run the sequence that leads there. All access to the system goes through
# the System object passed in; times are monotonic seconds except inside the status file.

DEBOUNCE = 2.0                      # routing-socket messages to reconcile; armed once, not pushed back
NATIVE_GONE_HOLD = 60.0             # native IPv4 must be absent this long before an activation
UPLINK_LOSS_GRACE = 15.0            # uplink without usable IPv6 before "suspended"
RESTART_MIN_INTERVAL = 60.0         # between a tayga start and a restart for a changed plan
BACKOFF_STEPS = (5.0, 10.0, 30.0, 60.0, 300.0)      # delay after the n-th consecutive failure
BACKOFF_RESET = 300.0               # "active" for this long resets the failure count
DRIFT_REPAIR_MIN_INTERVAL = 300.0   # between two registration runs
TICK = 60.0                         # periodic in-process check
RS_MAX = 3                          # Router Solicitations per uplink attach
RS_INTERVAL = 4.0
TAYGA_START_TIMEOUT = 5.0
TAYGA_STOP_TIMEOUT = 5.0
CONFIGCTL_TIMEOUT = 130.0           # above configctl's own 120 s
OUTPUT_KEEP = 10                    # tayga lines kept for the status file
RELAY_BURST = 20                    # tayga lines relayed to syslog per RELAY_WINDOW
RELAY_WINDOW = 10.0

EVENT_REASONS = ('start', 'route', 'event', 'reload')   # reconcile reasons that refresh the link facts
REASON_ORDER = ('reload', 'event', 'route', 'start')    # which reason wins when several arise at once
UP = ('active', 'suspended')
STATE_TIMERS = ('pref64', 'dns', 'grace', 'hold', 'backoff', 'restart')

CONF_DIR = '/usr/local/etc/clat'
IFCONFIG = '/sbin/ifconfig'
ROUTE = '/sbin/route'
PFCTL = '/sbin/pfctl'
PS = '/bin/ps'
IFCTL = '/usr/local/sbin/ifctl'
CONFIGCTL = '/usr/local/sbin/configctl'

TAYGA_READY = re.compile(r'Using tun device %s with MTU (\d+)' % TUN)
SECRET_FORMAT = re.compile('[0-9a-fA-F]{64}')


class Supervisor:
    """ Decides from the facts whether the CLAT is to be up and makes the box match: tayga on the tun, the
        tun's addresses, the route of the address pair and the router file.
    """

    def __init__(self, sysif) -> None:
        self.sys = sysif
        self.facts = Facts()
        self.ra = RaPrefix()
        self.dns = DnsPrefix()
        self.state = 'listening'
        self.reason = ''
        self.since = sysif.monotonic()      # time of the last state or reason change
        self.running = None                 # Plan whose runtime exists, also in part (failed step, tayga exit)
        self.wanted = None                  # Plan of the last decision, when that was 'up'
        self.withdrawn = False              # suspended, and the IPv4 default route was handed over
        self.gated = False                  # the last decision reached rule 7
        self.soft = False                   # the last decision came from rule 5 or 6
        self.pref64 = None                  # (prefix, source) of the last decision
        self.timers = {}                    # name -> deadline
        self.restarts = 0                   # tayga exits
        self.failures = 0                   # consecutive failures, for the back-off
        self.failure = ''                   # code of the step that failed last
        self.backoff_until = 0.0
        self.stopping = False
        self.event6 = False                 # a newwanip event for IPv6 on the uplink is waiting
        self.cfg_failed = False             # the last read of the config facts failed
        self.uplink_id = None               # (device, index) of the runtime uplink
        self.session_id = None              # the same of the last runtime uplink there was
        self.pd_trusted = True              # the prefix file belongs to the current session
        self.pd_stat = None                 # the prefix file as last seen in a trusted session
        self.native_present = False         # the last pass that tested for native IPv4 found it
        self.native_gone = None             # time of the pass that first found it gone
        self.lost_since = None              # time of the first soft result while active
        self.last_repair = None
        self.rs_count = 0
        self.tayga_pid = None
        self.tayga_started = None
        self.link_fresh = False             # this pass refreshed the link facts
        self.secret = None
        self.output = []                    # last lines tayga printed
        self.relay_start = None
        self.relay_count = 0
        self.relay_dropped = 0
        self.written = None                 # status file content as last written, without 'updated'

    # -- main loop --------------------------------------------------------------------------------------

    def start(self) -> None:
        """ Clean up what an instance that did not stop cleanly left behind, then reconcile. """
        self.sys.mkdir(RUN_DIR)
        self.sys.remove(STATUS)
        self.facts.load_settings(self.sys)
        self.refresh_link(self.sys.monotonic())
        pid = self.facts.ifaces.get(TUN, {}).get('opened_by')
        if pid and self.sys.run([PS, '-o', 'comm=', '-p', str(pid)])[1].strip() == 'tayga':
            self.sys.log(4, 'stopping a tayga left on %s (pid %d)' % (TUN, pid))
            self.sys.kill(pid, self.sys.SIGTERM)
            for _ in range(25):
                if not self.sys.pid_alive(pid):
                    break
                self.sys.sleep(0.2)
            else:
                self.sys.kill(pid, self.sys.SIGKILL)
        if self.sys.stat(MARKER) is not None or (self.sys.read(ROUTER_FILE) or '').strip():
            self.deactivate()
        self.reconcile('start')

    def run(self) -> None:
        """ The main loop. """
        while not self.stopping:
            self.handle(self.sys.wait(self.next_timeout()))

    def stop(self) -> None:
        """ Take the CLAT down and remove the status file. """
        if self.running is not None:
            self.deactivate()
        self.sys.remove(STATUS)
        self.sys.log(5, 'stopped')

    def next_timeout(self) -> float | None:
        """ Seconds until the earliest timer. """
        if not self.timers:
            return None
        return max(0.0, min(self.timers.values()) - self.sys.monotonic())

    def handle(self, events: set[str]) -> None:
        """ Dispatch what System.wait() returned and the timers that are due: at most one reconcile. """
        if 'term' in events:
            self.stopping = True
            return
        now = self.sys.monotonic()
        reasons = set()
        if 'hup' in events:
            reasons.add('reload')
        if 'usr2' in events:
            self.event6 = True
        if 'usr1' in events or 'usr2' in events:
            reasons.add('event')
        if 'child' in events or 'chld' in events:
            self.relay(self.sys.child_lines())
            if self.sys.child_exit() is not None:
                reasons.add('child')
        if 'ra' in events and self.router_adverts(now):
            reasons.add('ra')
        if 'route' in events and self.sys.route_changed():
            self.timers.setdefault('debounce', now + DEBOUNCE)
        for name in [name for name, deadline in self.timers.items() if deadline <= now]:
            del self.timers[name]
            if name == 'rs':
                self.solicit(now)
            elif name == 'debounce':
                reasons.add('route')
            elif name == 'tick':
                # a helper that failed while active arms the back-off too: count from its end
                if self.state == 'active' and now - max(self.since, self.backoff_until) >= BACKOFF_RESET:
                    self.failures = 0
                reasons.add('tick')
            else:
                reasons.add('timer')
        for reason in REASON_ORDER + tuple(sorted(reasons)):
            if reason in reasons:
                self.reconcile(reason)
                return
        self.arm_timers(now)
        if 'ra' in events:
            self.write_status()             # an advertisement that refreshed the prefix moved its expiry

    def router_adverts(self, now: float) -> bool:
        """ Take the router advertisements received. True when the prefix of the RA source changed. """
        changed = False
        for packet in self.sys.ra_recv():
            entries = accept_ra(packet, self.facts.uplink_dev(), self.facts.uplink_router())
            if entries is None:
                continue
            self.timers.pop('rs', None)     # the router answered: the burst ends
            if self.ra.update(entries, now, self.facts.local_networks(self.sys)):
                changed = True
        return changed

    def solicit(self, now: float) -> None:
        """ The next Router Solicitation of a burst. """
        dev = self.facts.uplink_dev()
        if dev is None:
            return
        self.sys.rs_send(dev)
        self.rs_count += 1
        if self.rs_count < RS_MAX:
            self.timers['rs'] = now + RS_INTERVAL

    def relay(self, lines: list[str]) -> None:
        """ tayga's output to syslog, at most RELAY_BURST lines per RELAY_WINDOW; the last lines are kept
            for the status file.
        """
        now = self.sys.monotonic()
        for line in lines:
            self.output = (self.output + [line])[-OUTPUT_KEEP:]
            if self.relay_start is None or now - self.relay_start >= RELAY_WINDOW:
                if self.relay_dropped:
                    self.sys.log(4, 'tayga: %d lines suppressed' % self.relay_dropped)
                self.relay_start, self.relay_count, self.relay_dropped = now, 0, 0
            if self.relay_count < RELAY_BURST:
                self.relay_count += 1
                failed = line.startswith(('Error', 'Unable')) or 'aborting' in line
                self.sys.log(3 if failed else 6, 'tayga: ' + line)
            else:
                self.relay_dropped += 1

    # -- reconcile --------------------------------------------------------------------------------------

    def reconcile(self, reason: str) -> None:
        """ One pass: refresh what the reason can have changed, decide, act, re-arm the timers. The gateway
            facts of the PHP helper are gathered only once every rule that needs no helper allows an
            activation, refreshed on events and configuration changes, and otherwise kept. A helper that
            failed is run again when the back-off ends, not before.
        """
        now = self.sys.monotonic()
        self.link_fresh = False
        if self.state in UP and self.sys.child_exit() is not None:
            self.tayga_exit(now)                    # from here on this pass is "not up"
        event = reason in EVENT_REASONS
        forced = reason in ('start', 'reload')
        if forced:
            self.facts.load_settings(self.sys)
            self.dns.next_query = 0.0               # a reload asks ipv4only.arpa again at once
        changed = self.refresh_config(now, forced)
        dev = self.facts.uplink_dev()
        linked = event or (dev is not None and self.sys.if_index(dev) is None)
        if linked:
            self.refresh_link(now)
        self.confirm_session()
        self.ra.expire(now)
        state, why = self.decide(now)
        refresh = self.gated and (event or changed)
        about_to_activate = state == 'up' and self.state not in UP and now >= self.backoff_until
        if self.cfg_failed and (changed or self.state not in UP):
            # the config facts are missing or old: nothing is activated on them
            state, why = self.helper_failed(now) if changed else (None, '')
        elif state == 'need_facts' and now < self.backoff_until:
            state = None                            # the helper failed: it runs again when the back-off ends
        elif state == 'need_facts' or refresh or about_to_activate:
            if not linked:
                self.refresh_link(now)
            if self.facts.refresh_activation(self.sys):
                state, why = self.decide(now)
            else:
                state, why = self.helper_failed(now)
        elif not self.gated:
            self.facts.drop_activation()            # stopped before the gate: nothing to keep
        self.repair_record(now)
        if state is not None:
            self.apply(state, why, now)
        self.arm_timers(now)
        self.write_status()

    def refresh_config(self, now: float, forced: bool) -> bool:
        """ The config facts afresh: when config.xml changed, on a start or reload, and again once the
            back-off has ended after a read that failed. True when the helper ran; cfg_failed says whether
            its last run failed.
        """
        if self.cfg_failed and not forced and now < self.backoff_until:
            return False
        known = self.facts.cfg
        ran = self.facts.refresh_config(self.sys, force=forced or self.cfg_failed)
        if ran:
            self.cfg_failed = self.facts.cfg is known       # a read that succeeds stores a new object
        return ran

    def helper_failed(self, now: float) -> tuple[str | None, str]:
        """ What a pass ends in when the PHP helper failed: while up nothing changes, otherwise the state
            becomes backoff / facts. In both cases the helper runs again when the back-off ends.
        """
        if self.state in UP:
            self.hold(now)
            return None, ''
        return 'failed', 'facts'

    def refresh_link(self, now: float) -> None:
        """ Runtime uplink and interfaces afresh (two commands), then follow the uplink. """
        self.facts.refresh_link(self.sys)
        self.link_fresh = True
        self.track_uplink(now)

    def track_uplink(self, now: float) -> None:
        """ Follow the runtime uplink. An uplink that appears is solicited for router advertisements. When
            it is another device or index than the last one there was, the session changed and the delegated
            prefix of the old one is no longer trusted. The same device under the same index keeps the trust,
            also after a gap in the IPv6 default route or a route command that failed. A device that mpd5
            redials keeps its index, is down in between, and has its prefix file rewritten by dhcp6c (a
            changed prefix is then a renumbering). A device that core sets up again is a new one; in the lab
            it came back under the old index, after core had removed the prefix file with the old device.
        """
        dev = self.facts.uplink_dev()
        current = None if dev is None else (dev, self.sys.if_index(dev))
        if current == self.uplink_id:
            return
        if current is not None:
            if self.session_id is not None and current != self.session_id:
                self.pd_trusted = False
            self.session_id = current
            self.sys.rs_send(dev)
            self.rs_count = 1
            self.timers['rs'] = now + RS_INTERVAL
        self.uplink_id = current

    def confirm_session(self) -> None:
        """ Trust the prefix file again once it was rewritten or core reported IPv6 on the uplink. An event
            is used up in the pass it arrives in, so it cannot confirm the stale file of a later session.
        """
        dev = self.facts.uplink_dev()
        if dev is None:
            self.event6 = False
            return
        stat = self.sys.stat('/tmp/%s_prefixv6' % dev)
        if not self.pd_trusted and (self.event6 or (stat is not None and stat != self.pd_stat)):
            self.pd_trusted = True
        self.event6 = False
        if self.pd_trusted:
            self.pd_stat = stat

    def repair_record(self, now: float) -> None:
        """ Run core's interface registration when the interface record was edited (rate-limited, and not
            while an edit in Interfaces: Assignments waits to be applied), then restore the runtime state.
        """
        cfg = self.facts.cfg
        if cfg is None or cfg.get('record_ok', True) or self.sys.stat(TODO_FILE) is not None:
            return
        if self.last_repair is not None and now < self.last_repair + DRIFT_REPAIR_MIN_INTERVAL:
            return
        self.last_repair = now
        self.sys.log(4, 'the CLAT interface record was changed; running the interface registration')
        self.command([CONFIGCTL, 'interface', 'invoke', 'registration'], CONFIGCTL_TIMEOUT)
        self.facts.refresh_config(self.sys, force=True)
        if self.state == 'active' and not self.replay():
            self.give_up()

    # -- decision ---------------------------------------------------------------------------------------

    def decide(self, now: float) -> tuple[str, str]:
        """ (state, reason) the facts ask for; the state may also be 'up' (self.wanted is then the plan) or
            'need_facts' (the gateway facts are missing). Sets self.gated, self.soft and self.pref64.
        """
        self.gated = False
        self.soft = False
        self.wanted = None
        self.pref64 = None
        settings = self.facts.settings
        up = self.state in UP
        if not settings['enabled']:                                             # rule 1
            return 'disabled', ''
        if self.facts.uplink_native(self.sys):                                  # rule 2
            self.native_present = True
            return 'native-ipv4', 'uplink'
        for row in preflight(self.facts, self.sys):                             # rule 3
            if row['effect'] == 'block' and row['id'] != 'stale_gateway':
                return 'blocked', row['id']
        self.pref64 = self.select_prefix(now)                                   # rule 4
        if self.pref64 is None:
            return 'listening', 'no_uplink_ipv6' if self.facts.route6 is None else 'no_nat64_prefix'
        soft = self.uplink_gap()                                                # rules 5 and 6
        if soft is not None and not up:
            self.soft = True
            return soft
        self.gated = True
        gateways = self.facts.gw
        if gateways is None:                                                    # rule 7
            return 'need_facts', ''
        if stale_gateways(gateways):                                            # rule 7a
            return 'blocked', 'stale_gateway'
        if not settings['keep_with_native'] and native_gateways(gateways):      # rule 8
            self.native_present = True
            return 'native-ipv4', 'gateway'
        if self.native_present:                                                 # rule 8a
            self.native_gone = now
            self.native_present = False
        if soft is not None:                                                    # rules 5 and 6 while up
            self.soft = True
            return soft
        try:                                                                    # rule 9
            wanted = make_plan(settings, self.pref64[0], self.facts.delegated(self.sys), self.facts.claims(),
                               self.load_secret(), self.facts.addresses6(), self.facts.mtu6())
        except PlanError as error:
            return 'blocked', error.code
        if not up and self.native_gone is not None and now < self.native_gone + NATIVE_GONE_HOLD:   # rule 10
            return 'native-ipv4', 'hold'
        self.wanted = wanted                                                    # rule 11
        return 'up', ''

    def uplink_gap(self) -> tuple[str, str] | None:
        """ Rules 5 and 6: what the uplink lacks for usable IPv6, None when nothing. """
        if self.facts.route6 is None:
            return 'listening', 'no_uplink_ipv6'
        if not self.pd_trusted or self.facts.delegated(self.sys) is None:
            return 'waiting-for-prefix-delegation', ''
        return None

    def select_prefix(self, now: float) -> tuple[ipaddress.IPv6Network, str] | None:
        """ (NAT64 prefix, source): the static one, else the one of the router advertisements, else the
            one ipv4only.arpa gives, which is asked for here when a query is due.
        """
        settings = self.facts.settings
        if settings['prefix']:
            try:
                return ipaddress.IPv6Network(settings['prefix'], strict=False), 'static'
            except ValueError:
                return None
        current = self.ra.current()
        if current is not None:
            self.dns.reset()
            return current[0], 'ra'
        if not settings['discover_dns']:
            self.dns.reset()
            return None
        if self.dns_wanted() and self.dns.due(now):
            server = first_nameserver(self.sys.read(RESOLV_CONF))
            outcome = ('fail', 'no nameserver', None)
            if server:
                outcome = self.sys.dns_aaaa(server, DNS_NAME, DNS_TIMEOUT)
            self.dns.result(outcome, now, self.facts.local_networks(self.sys))
        if self.dns.prefix is None:
            return None
        return self.dns.prefix, 'dns'

    def dns_wanted(self) -> bool:
        """ True while ipv4only.arpa is the source to ask: no static or RA prefix, a runtime uplink, and
            not a native gateway that keeps the CLAT down while a DNS prefix is held.
        """
        settings = self.facts.settings
        if settings['prefix'] or self.ra.current() is not None or not settings['discover_dns']:
            return False
        if self.facts.route6 is None:
            return False
        return not (self.state == 'native-ipv4' and self.reason == 'gateway' and self.dns.prefix is not None)

    def load_secret(self) -> bytes:
        """ The secret of the interface-identifier hash, created when missing. """
        if self.secret is None:
            text = (self.sys.read(SECRET) or '').strip()
            if not SECRET_FORMAT.fullmatch(text):
                text = self.sys.random(32).hex()
                self.sys.write(SECRET, text + '\n', 0o600)
            self.secret = bytes.fromhex(text)
        return self.secret

    # -- transitions ------------------------------------------------------------------------------------

    def apply(self, result: str, why: str, now: float) -> None:
        """ Go from the current state to what decide() returned. """
        up = self.state in UP
        if result == 'failed':
            self.fail(why, now)
            return
        if result != 'up' and not (up and self.soft):
            # a hard result, or any result while the CLAT is down
            if self.running is not None and not self.soft:
                self.deactivate()
            self.backoff_until = 0.0                # the failure count is kept
            self.lost_since = None
            self.set_state(result, why)
            return
        if result != 'up':
            # the uplink lost its IPv6 while the CLAT is up
            if self.state == 'suspended':
                return
            if self.lost_since is None:
                self.lost_since = now
            if now < self.lost_since + UPLINK_LOSS_GRACE:
                return                              # the 'grace' timer runs the next pass
            self.facts.refresh_activation(self.sys)
            if self.facts.gw and self.facts.gw.get('fallback'):
                self.withdraw()
            self.set_state('suspended', '')
            return
        if not up:
            if now < self.backoff_until:
                return
            if self.running is not None and self.running != self.wanted:
                done = self.renumber(self.wanted)   # left over from a tayga exit, and the plan changed
            else:
                done = self.activate(self.wanted)
        elif self.wanted != self.running:
            self.lost_since = None
            if now < self.tayga_started + RESTART_MIN_INTERVAL:
                return                              # the 'restart' timer runs the next pass
            done = self.renumber(self.wanted)
        elif self.state == 'suspended':
            done = not self.withdrawn or self.replay()
        else:
            done = self.intact() or self.replay()
        if done:
            self.lost_since = None
            self.set_state('active', '')
        else:
            self.give_up()

    def intact(self) -> bool:
        """ True when the runtime state is still what the activation left: the router file, and in a pass
            with fresh link facts also the tun's addresses and its owner.
        """
        if (self.sys.read(ROUTER_FILE) or '').strip() != self.running.ipv4_tayga:
            return False
        return not self.link_fresh or self.facts.tun_ok(self.running, self.tayga_pid)

    def give_up(self) -> None:
        """ After a failed step: take everything down, so that core's view is right, and retry later. """
        self.deactivate()
        self.fail(self.failure, self.sys.monotonic())

    def hold(self, now: float) -> None:
        """ Arm the back-off: what failed is not tried again before it ends. """
        self.backoff_until = now + BACKOFF_STEPS[min(self.failures, len(BACKOFF_STEPS) - 1)]
        self.failures += 1

    def fail(self, code: str, now: float) -> None:
        """ Arm the back-off; the state becomes backoff / code. """
        self.hold(now)
        self.set_state('backoff', code)

    def set_state(self, state: str, reason: str) -> None:
        """ A state or reason change, with its one log line. """
        if (state, reason) == (self.state, self.reason):
            return
        if self.facts.settings['log_state']:
            text = 'state %s -> %s' % (self.state, state)
            self.sys.log(5, '%s (%s)' % (text, reason) if reason else text)
        self.state = state
        self.reason = reason
        self.since = self.sys.monotonic()

    def arm_timers(self, now: float) -> None:
        """ Set the timers that follow from the state. A deadline that has passed is not armed: the pass
            that just ran was its turn, and the tick or the next event brings the following one.
        """
        deadlines = {}
        current = self.ra.current()
        if current is not None:
            deadlines['pref64'] = current[1]
        if self.dns_wanted():
            deadlines['dns'] = self.dns.next_query
        if self.state == 'active' and self.lost_since is not None:
            deadlines['grace'] = self.lost_since + UPLINK_LOSS_GRACE
        if self.state == 'native-ipv4' and self.reason == 'hold':
            deadlines['hold'] = self.native_gone + NATIVE_GONE_HOLD
        if self.state == 'backoff' or self.state in UP:     # while up: a helper that failed runs again
            deadlines['backoff'] = self.backoff_until
        if self.state in UP and self.wanted is not None and self.wanted != self.running:
            deadlines['restart'] = self.tayga_started + RESTART_MIN_INTERVAL
        for name in STATE_TIMERS:
            if deadlines.get(name, now) > now:
                self.timers[name] = deadlines[name]
            else:
                self.timers.pop(name, None)
        self.timers.setdefault('tick', now + TICK)

    # -- sequences --------------------------------------------------------------------------------------

    def command(self, argv: list[str], timeout: float = 10.0, quiet: bool = False) -> bool:
        """ Run a command. True when it succeeded, which for configctl includes the answer OK. A failure
            is logged unless quiet is set.
        """
        code, out, err = self.sys.run(argv, timeout)
        done = code == 0 and (argv[0] != CONFIGCTL or out.strip() == 'OK')
        if not done and not quiet:
            self.sys.log(4, 'command failed (%d): %s: %s' % (code, ' '.join(argv), (err or out).strip()))
        return done

    def activate(self, plan: Plan) -> bool:
        """ Bring the CLAT up with this plan. False when a step failed: self.failure has its code and
            self.running names what Deactivate has to remove.
        """
        self.running = plan
        return self.sequence((
            ('step_conf', self.step_conf),
            ('step_tun', self.step_tun),
            ('tayga_start', self.step_tayga),
            ('step_address', self.step_address),
            ('step_route', self.step_route),
            ('step_router', self.step_router),
            ('step_newip', self.step_newip),
        ))

    def replay(self) -> bool:
        """ Restore what an Apply on the interface record, a registration run or Withdraw removed: the
            tun's addresses when they are gone, the router file, core's view. The route of the pair stays
            in place on every path that leads here.
        """
        steps = [('step_router', self.step_router), ('step_newip', self.step_newip)]
        if self.withdrawn or not self.facts.tun_ok(self.running, self.tayga_pid):
            steps.insert(0, ('step_address', self.step_address))
        return self.sequence(steps)

    def sequence(self, steps: list | tuple) -> bool:
        """ Run the steps (failure code, method) with the running plan and stop at the first that fails;
            when all succeeded, report.
        """
        for code, step in steps:
            if not step(self.running):
                self.failure = code
                return False
        self.report()
        self.withdrawn = False
        return True

    def step_conf(self, plan: Plan) -> bool:
        """ tayga must never start from an older file, so every part must succeed. """
        made = self.sys.mkdir(CONF_DIR) and self.sys.mkdir(DATA_DIR)
        return made and self.sys.write(TAYGA_CONF, tayga_conf(plan, DATA_DIR))

    def step_tun(self, plan: Plan) -> bool:
        """ tayga reads the MTU of the tun once, when it starts. """
        if self.sys.if_index(TUN) is None and not self.command([IFCONFIG, TUN, 'create']):
            return False
        return self.command([IFCONFIG, TUN, 'mtu', str(plan.tun_mtu)])

    def step_tayga(self, plan: Plan) -> bool:
        """ Start tayga and wait until it has the tun open with the intended MTU. """
        self.sys.child_stop()
        pid = self.sys.spawn(tayga_argv(TAYGA_CONF))
        if pid is None:
            return False
        deadline = self.sys.monotonic() + TAYGA_START_TIMEOUT
        mtu = None
        while mtu is None:
            exited = self.sys.child_exit() is not None
            lines = self.sys.child_lines()
            self.relay(lines)
            for line in lines:
                ready = TAYGA_READY.search(line)
                if ready:
                    mtu = int(ready.group(1))
            if mtu is None:
                if exited or self.sys.monotonic() >= deadline:
                    self.sys.log(3, 'tayga did not start')
                    return False
                self.sys.sleep(0.1)
        if exited or self.sys.child_exit() is not None:
            self.sys.log(3, 'tayga did not start')      # it reported the tun and exited: nobody holds it
            return False
        if mtu != plan.tun_mtu:
            self.sys.log(3, 'tayga uses MTU %d on %s, not %d' % (mtu, TUN, plan.tun_mtu))
            return False
        self.tayga_pid = pid
        self.tayga_started = self.sys.monotonic()
        return True

    def step_address(self, plan: Plan) -> bool:
        """ The explicit /32 matters (without it "CLAT net" means "any" in pf), and a new tun has IPv6
            disabled: the kernel drops what tayga writes until the second command.
        """
        if not self.command([IFCONFIG, TUN, 'inet', plan.ipv4_clat + '/32', plan.ipv4_tayga, 'up']):
            return False
        return self.command([IFCONFIG, TUN, 'inet6', '-ifdisabled'])

    def step_route(self, plan: Plan) -> bool:
        """ The route survives a tayga exit, hence the delete; it fails when there is none. """
        self.command([ROUTE, '-6', '-q', 'delete', plan.pair], quiet=True)
        return self.command([ROUTE, '-6', 'add', plan.pair, '-interface', TUN])

    def step_router(self, plan: Plan) -> bool:
        """ The marker tells the device hook to write the router file again when core removes it. """
        if not self.sys.write(MARKER, plan.ipv4_tayga + '\n'):
            return False
        return self.command([IFCTL, '-i', TUN, '-4rd', '-a', plan.ipv4_tayga])

    def step_newip(self, plan: Plan) -> bool:
        """ Core lists the gateway, installs the default route and reloads the filter with the NAT rule, in
            that order. A packet forwarded into the tun in between would get a state without NAT that outlives
            the reload, so the filter is reloaded once before: the router file is enough for the NAT rule.
        """
        if not self.command([CONFIGCTL, 'filter', 'reload', 'skip_alias'], CONFIGCTL_TIMEOUT):
            return False
        return self.command([CONFIGCTL, 'interface', 'newip', TUN, 'force'], CONFIGCTL_TIMEOUT)

    def report(self) -> None:
        """ Last step of an activation: say who holds the IPv4 default route and whether core made the
            outbound NAT rule. Never fails.
        """
        self.refresh_link(self.sys.monotonic())
        self.facts.refresh_activation(self.sys)
        if self.facts.gw is not None:
            code, message = gateway_report(self.facts.gw)
            self.sys.log(5 if code == 'default' else 4, 'CLAT gateway: ' + message)
        out = self.sys.run([PFCTL, '-sn'])[1]
        if not any(line.startswith('nat on %s ' % TUN) for line in out.splitlines()):
            self.sys.log(4, 'there is no outbound NAT rule on %s' % TUN)

    def unpublish(self) -> None:
        """ Remove the marker and the router file: no routing run of core sees the CLAT gateway any more. """
        if not self.sys.remove(MARKER):
            self.sys.log(4, 'unable to remove ' + MARKER)
        self.command([IFCTL, '-i', TUN, '-4rd'])

    def deactivate(self) -> None:
        """ Take the CLAT down. Without a plan (leftovers found at start) the steps that need the address
            pair are left out. Failures are logged and otherwise ignored.
        """
        plan = self.running
        self.unpublish()
        self.sys.child_stop(TAYGA_STOP_TIMEOUT)     # the kernel removes the tun's addresses and routes
        if plan is not None:
            self.command([ROUTE, '-6', '-q', 'delete', plan.pair])
            self.command([PFCTL, '-k', plan.ipv4_clat])
            self.command([PFCTL, '-k', str(plan.clat6)])
        self.command([CONFIGCTL, 'interface', 'routes', 'configure'], CONFIGCTL_TIMEOUT)
        self.running = None
        self.withdrawn = False
        self.tayga_pid = None
        self.tayga_started = None
        self.facts.drop_activation()

    def tayga_exit(self, now: float) -> None:
        """ tayga is gone: remove the router file at once and retry with back-off. The plan, the route of
            the pair and the states stay, so that flows continue when the retry succeeds in time.
        """
        self.relay(self.sys.child_lines())
        self.sys.log(3, 'tayga exited with status %s' % self.sys.child_exit())
        self.unpublish()
        self.sys.child_stop(TAYGA_STOP_TIMEOUT)     # no process left: closes the pty
        self.tayga_pid = None
        self.tayga_started = None
        self.restarts += 1
        self.fail('tayga_exit', now)

    def withdraw(self) -> None:
        """ Suspend with fail-over: hand the IPv4 default route to another gateway. tayga, the tun and the
            route of the pair stay.
        """
        plan = self.running
        self.unpublish()
        self.command([IFCONFIG, TUN, 'inet', plan.ipv4_clat, '-alias'])
        self.command([PFCTL, '-k', plan.ipv4_clat])
        self.command([CONFIGCTL, 'interface', 'routes', 'configure'], CONFIGCTL_TIMEOUT)
        self.withdrawn = True

    def renumber(self, plan: Plan) -> bool:
        """ A changed plan: tayga cannot reload, so remove what belongs to the old pair and activate. """
        old = self.running
        self.sys.child_stop()
        self.command([ROUTE, '-6', '-q', 'delete', old.pair])
        self.command([PFCTL, '-k', old.ipv4_clat])
        self.command([PFCTL, '-k', str(old.clat6)])
        return self.activate(plan)

    # -- status -----------------------------------------------------------------------------------------

    def status(self) -> dict:
        """ Content of the status file. Times are converted to wall-clock seconds here. """
        wall = self.sys.time()
        offset = wall - self.sys.monotonic()

        def epoch(moment):
            return None if moment is None else round(offset + moment)

        pref64 = None
        if self.pref64 is not None:
            prefix, source = self.pref64
            current = self.ra.current()
            expires = epoch(current[1]) if source == 'ra' and current is not None else None
            pref64 = {'prefix': str(prefix), 'source': source, 'expires': expires}
        plan = self.running or self.wanted
        if plan is not None:
            plan = {
                'clat6': str(plan.clat6),
                'tayga6': str(plan.tayga6),
                'ipv4_clat': plan.ipv4_clat,
                'ipv4_tayga': plan.ipv4_tayga,
                'tun_mtu': plan.tun_mtu,
                'offlink_mtu': plan.offlink_mtu,
                'ipv4_mtu': plan.ipv4_mtu,
            }
        return {
            'updated': round(wall),
            'state': self.state,
            'reason': self.reason,
            'since': epoch(self.since),
            'uplink': self.facts.uplink_dev(),
            'pref64': pref64,
            'plan': plan,
            'withdrawn': self.withdrawn,
            'tayga': {'started': epoch(self.tayga_started), 'restarts': self.restarts, 'output': list(self.output)},
        }

    def write_status(self) -> None:
        """ Write the status file when its content, apart from the time of writing, has changed. """
        status = self.status()
        content = dict(status, updated=0)
        if content != self.written and self.sys.write(STATUS, json.dumps(status) + '\n'):
            self.written = content
