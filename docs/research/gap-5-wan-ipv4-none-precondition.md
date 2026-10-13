# Gap 5 - Is "WAN IPv4 = None" a hard precondition, what is left behind after the switch, and can lifecycle rely on events?

Research date: 2026-10-11. Research only, no design.

**Path convention.** `core/` = `refs/opnsense-core` (opnsense/core **master**, local clone). `src/` = `refs/opnsense-src`
(stable/26.7). `gh/` = `refs/gh`. `refs/` = local clones (not in this repository).
Where a statement is about 26.7, the same file was re-read on GitHub branch `stable/26.7` through
`https://raw.githubusercontent.com/opnsense/core/stable/26.7/...` (no line numbers available there).

**Confidence labels.** *verified* = the primary source was read (local clone, raw GitHub file, GitHub issue / API).
*likely* = inferred from verified sources, not runtime-tested. *unverified* = could not establish.
Nothing here was tested on a live box.

**Quoting.** Issue and forum comments are paraphrased; code identifiers and log lines are given as facts.

---

## 0. Answers in short

| Question | Answer | Confidence |
|---|---|---|
| (a) With WAN IPv4 = PPPoE and an ISP that never opens IPCP, does IPv6 (rtsold / dhcp6c) stay down? | Yes. The only starter of rtsold/dhcp6c on such a WAN is `ppp-ipv6.php <dev> 4`, called from the **inet** link-up only. | code path *verified* on master and stable/26.7; runtime *verified* on 25.1.x-25.7.x by two GitHub issues; no 26.7.x-specific runtime log found (*likely* unchanged, code is identical) |
| (a) Is a core fix planned? | No. The maintainer's position (core#9153) is that IPv4 = PPPoE is the wrong setting for such an ISP and IPv4 must be None. That issue was closed "not planned". core#7713 shows the same symptom, is still open (milestone 27.1), and nobody in it has connected it to the IPv4 type. | *verified* |
| (b) Saved `WAN_PPPOE` gateway item after the switch | Becomes `defunct`, is skipped for default route and NAT. Does **not** block the CLAT gateway. It has side effects (monitor-IP uniqueness, DNS servers bound to it are dropped, policy rules lose their route-to). | *verified* (code) |
| (b) Static IPv4 gateway marked "upstream" | Blocks. It sorts first; if it sits on an address-less interface the route is refused and there is **no fallback** to the next gateway. If it sits on an interface with IPv4 it simply is the default route. | *verified* (code) |
| (b) Outbound NAT in manual mode | No automatic rule for the CLAT interface in `advanced` (manual) or `disabled` mode. `hybrid` still generates it. | *verified* (code) |
| (c) Pure SLAAC WAN raises no `newwanip` (inet6) plugin event | Confirmed by code for a PPPoE WAN with IPv4 = None: not at link-up, not when the address appears, not at link-down, not at boot. | *verified* by code reading on master and stable/26.7; not runtime-tested |

---

## 1. (a) IPv4 = PPPoE on an IPv6CP-only ISP

### 1.1 The gate in code

`core/src/etc/inc/interfaces.inc:924-969`, `interface_ppps_bound($interface, $family = null)`:

```php
if ($family == 4) {
    $bound = $ipv4_mode;                    // ipaddr in ppp|pppoe|l2tp
} elseif ($family == 6) {
    $bound = !$ipv4_mode && $ipv6_mode;     // ipaddrv6 in dhcp6|pppoev6|slaac
} else {
    $bound = $ipv4_mode || $ipv6_mode;
}
```

Three call sites decide who starts rtsold/dhcp6c:

1. `interface_configure()` never does it on a PPP WAN - `interfaces.inc:2454-2457`:
   `if (!interface_ppps_bound($interface)) { interface_dhcpv6_prepare(...); interface_dhcpv6_configure(...); }`
2. `core/src/opnsense/scripts/interfaces/ppp-ipv6.php:48-50`: `if (!interface_ppps_bound($interface, $family)) { exit(1); }`
   placed **before** the block that sets `accept_rtadv` and starts DHCPv6 (`:54-63`).
3. `core/src/opnsense/scripts/interfaces/ppp-linkup.sh:26-38`:
   - inet: `ppp-ipv6.php ${IF} 4` then `configctl -d interface newip ${IF} force`
   - inet6: `if ! ppp-ipv6.php ${IF} 6; then configctl -d interface newipv6 ${IF} force; fi`

Truth table for a PPPoE WAN with IPv6 type DHCPv6 or SLAAC:

| IPv4 type | `bound(4)` | `bound(6)` | rtsold/dhcp6c started by | Forced `newipv6` at IPv6CP up |
|---|---|---|---|---|
| PPPoE | true | **false** | inet link-up only (IPCP must open) | yes (`ppp-ipv6.php 6` exits 1) |
| None | false | true | inet6 link-up | no (`ppp-ipv6.php 6` exits 0) |

stable/26.7: `ppp-linkup.sh`, `ppp-ipv6.php` (from the first `if` to the end) and `interface_ppps_bound()` were fetched
and are identical in logic. Differences: 26.7 lists `pptp` as an extra IPv4 mode, uses `global $config` instead of
`config_read_array()`, has `touch /tmp/${IF}_uptime` in `ppp-linkup.sh`, and calls `interface_ppps_configure()` in
`interface_configure()` without the early `return` that master has at `interfaces.inc:2423-2426`.
Last logic change in `ppp-linkup.sh`: 2024-08 (commits 58bfdec, 805120e, 9fb4149; history at
`https://github.com/opnsense/core/commits/master/src/opnsense/scripts/interfaces/ppp-linkup.sh`). **[verified]**

### 1.2 What the box looks like in the broken state

mpd5 is configured with `set bundle enable ipcp` and `set bundle enable ipv6cp` (`interfaces.inc:1172-1173`).
IPCP is rejected or ignored, IPv6CP opens. Then:

- mpd5 calls the up-script once, for `inet6`. It does not call it for `inet`: with dial-on-demand off (OPNsense
  default, `set iface disable on-demand`) the IPv4 interface-up path is `IpcpLayerUp` -> `BundNcpsJoin(b, NCP_IPCP)`
  -> `IfaceIpIfaceUp` (source `https://sourceforge.net/p/mpd/svn/HEAD/tree/trunk/src/bund.c?format=raw`; the
  on-demand variant was not examined). The core#7713 log in 1.3 shows exactly one link-up line, for inet6.
- `ppp-linkup.sh` writes `/tmp/<dev>_routerv6` (peer link-local), `ppp-ipv6.php <dev> 6` exits 1, so
  `newipv6 <dev> force` runs: IPv6 default route to the PPP peer link-local, filter reload, plugin event
  `newwanip` (inet6) with a WAN that has only a link-local address.
- Nobody runs `interface_dhcpv6_prepare()` / `interface_dhcpv6_configure()` for the WAN: no rtsold, no
  `/var/etc/dhcp6c.<dev>.conf`, no dhcp6c, no GUA, no delegated prefix.
- `accept_rtadv` on the PPP device:
  - boot path: `interface_ppps_configure()` returns false during boot ("PPP start deferred during boot",
    `interfaces.inc:1156-1160`), so `interface_configure()` returns early (master `:2423-2426`) or runs its
    `ifconfig` lines against a device that does not exist yet (26.7). The real dial happens later through
    `configctl -q interface ppp configure` (`core/src/etc/rc.syshook.d/start/10-newwanip:19-25`), which calls
    only `interface_ppps_configure()` (`core/src/opnsense/scripts/interfaces/reconfigure_ppp.php:38`). The only
    remaining place that sets `accept_rtadv` is `ppp-ipv6.php:58`, which is behind the gate. Result: the flag
    stays off, the kernel ignores RAs. **[verified code path; likely runtime]**
  - GUI apply / `configctl interface reconfigure wan`: `interfaces.inc:2452` sets `accept_rtadv` if the device
    exists by then, so the kernel may accept unsolicited RAs later; rtsold and dhcp6c are still not started.
- IPv4 side: no `/tmp/<dev>_router`, so no IPv4 gateway for the WAN (see 2.1). The IPv4 side would not hinder a
  CLAT gateway; what is missing is the global IPv6 address / prefix the CLAT needs.

### 1.3 Runtime evidence

**core#9153 "IPv6: PPPoE empty /var/etc/dhcp6c.conf"** (`https://github.com/opnsense/core/issues/9153`,
opened 2025-08-27 on OPNsense 25.7.2, closed 2026-02-23 by the bot as "not planned" after 180 days). **[verified]**

- Reporter: WAN with PPPoE for IPv4 and DHCPv6 for IPv6; PPPoE connects, interface has only a link-local address,
  `/var/etc/dhcp6c.conf` is empty; running dhcp6c by hand on the PPPoE device works. A second user reports the same.
- Reporter identifies the line `$bound = !$ipv4_mode && $ipv6_mode;` as the cause and proposes `$bound = $ipv6_mode`
  (comment 2025-08-27, `#issuecomment-3229719085`).
- Maintainer (fichtner), 2025-08-28 (`#issuecomment-3231957786`), paraphrased: the log shows the inet6 link-up line
  but no IPv4 counterpart, which suggests the provider offers no IPv4; in dual stack IPv6 is configured after IPv4
  (he links `ppp-linkup.sh` line 29); in that case "PPPoE" is the wrong IPv4 setting and "None" activates the other,
  working code path. He rejects the idea of a fundamental bug.
- Maintainer, 2025-09-02 (`#issuecomment-3245174316`): dhcp6c is steered from WAN, and for an IPv6-only ISP
  `an IPv4 configuration of "PPPoE" will not work` (fichtner).
- Maintainer, 2025-09-17 (`#issuecomment-3303880835`, `-3304336392`): mapping "IPv6 PPPoE = IPv4 mode None + IPv6 mode
  DHCPv6"; says IPv6-only PPPoE was worked on for 25.1.
- No commit or PR is linked to the issue.

**core#7713 "DS-Lite not coming up after a reboot"** (`https://github.com/opnsense/core/issues/7713`, open,
label cleanup, milestone 27.1; M-Net DS-Lite lines, PPPoE). **[verified]** The system log in the comment of
2025-04-16 (`#issuecomment-2809249435`, OPNsense 25.1.x) contains, for one dial:

```
[wan] IPCP: SendConfigReq #1
[wan_link0] LCP: protocol IPCP was rejected
[wan] IPCP: protocol was rejected by peer
[wan] IPCP: state change Req-Sent --> Stopped
[wan] IPCP: LayerFinish
[wan] IPV6CP: state change Ack-Sent --> Opened
[wan] IPV6CP: LayerUp
ppp-linkup: executing on pppoe0 for inet6
[wan] IFACE: Up event
rc.newwanipv6: IP renewal starting (address: misconfigured, interface: wan, device: pppoe0)
rc.newwanipv6: ROUTING: keeping inet6 default route to fe80:...%pppoe0
```

No `ppp-linkup ... for inet` line and no dhcp6c line follow. This is exactly the sequence of 1.2:
IPCP was attempted (so the IPv4 type was a PPP mode), the peer protocol-rejected it, the session stayed up on
IPv6CP, the forced `newipv6` ran with no usable address. The reporter states that after boot the WAN only ever has
a link-local address and that GUAs appear only after switching a LAN interface to DHCPv6 or re-saving a tracking
LAN. That workaround is explained by code: `interface_track6_configure()` with reload writes the WAN's dhcp6c
config and HUPs dhcp6c (`interfaces.inc:2532-2536`), and `interface_configure()` of a non-PPP interface in DHCPv6
mode starts the shared `rtsold -aiu` plus the dhcp6c fail-safe (`interfaces.inc:2816-2838`). **[likely]**
The same reporter says the behaviour is unchanged on 25.1.6_2, 25.1.7, 25.1.11, 25.7.4, 25.7.8, 25.7.11,
26.1.11_6, and that the 26.7.4 PPPoE/IPv6 race patch (598809955, core#10828) made no difference (2026-09-04,
`#issuecomment-5541015530`). The maintainer reads the log as PPPoE not really being up (2025-05-13,
`#issuecomment-2877430685`); the IPv4 type is not discussed anywhere in the thread, and "None" is never suggested.

**core#10828** (`gh/opnsense_core_10828.md`): a dual-stack session. It shows the ordering the gate relies on:
inet6 link-up first (`:286`), IPCP opens a moment later, inet link-up (`:306`), then the forced
`rc.newwanipv6 ... (reason: force ...)` (`:364`). The maintainer's remark at `:86` that IPv6 waits for PPPoE IPv4
matches the code. It does not contain an IPv6CP-only session. **[verified]**

**Other sources.** Search of github.com/opnsense/core issues for the PPP link-up log line plus dhcp6c returns
exactly these three issues. A pfSense forum thread (`https://forum.netgate.com/topic/197038`) shows the same mpd5
line `IPCP: protocol was rejected by peer` on an IPv6-only PPPoE session and mentions that OPNsense 25.1+ no longer
needs the old "Use IPv4 connectivity" switch. No OPNsense forum thread with a 26.7.x report of this scenario was
found.

### 1.4 mpd5 keeps the session up after an IPCP reject

- Source (trunk, `?format=raw` on SourceForge): `LcpRecvProtoRej()` maps `PROTO_IPCP` to the bundle's IPCP FSM,
  calls `FsmFailure(rej, FAIL_WAS_PROTREJ)` and returns non-fatal; `FsmFailure()` from Req-Sent goes to Stopped
  and calls layer-finish; `IpcpLayerFinish` -> `BundNcpsFinish(b, NCP_IPCP)`, which closes links only when no NCP
  bit remains ("No NCPs left. Closing links..."). A silently ignored IPCP ends the same way after
  `FSM_MAXCONFIG` = 10 Configure-Requests (`FsmTimeout` -> `FsmFailure(FAIL_NEGOT_FAILURE)`). **[verified, trunk]**
- The port (`refs/opnsense-ports/net/mpd5`, 5.9, PORTREVISION 20) has no patch touching this logic
  (`files/patch-noradius:436-485` only wraps `filter_id` arguments in `iface.c`). **[verified]**
- Runtime: the core#7713 log above is the packaged mpd5 doing exactly this. This closes open question 4 of
  `opnsense-pppoe-ipv6only.md`. **[verified for 25.1.x; likely for 26.7]**

### 1.5 Who ends up with IPv4 = PPPoE

- Factory default WAN: `<ipaddr>dhcp</ipaddr>`, `<ipaddrv6>dhcp6</ipaddrv6>` (`core/src/etc/config.xml.sample:55-56`).
- Setup wizard: IPv4 type options are only DHCP / Static / PPPoE
  (`core/src/opnsense/mvc/app/models/OPNsense/Core/InitialSetup.xml:47-55`); choosing PPPoE writes
  `interfaces.wan.ipaddr = pppoe` and leaves `ipaddrv6` untouched (`InitialSetup.php:341-343`; no `ipaddrv6`
  reference in the file). A wizard-built PPPoE WAN is therefore IPv4 = PPPoE + IPv6 = DHCPv6. **[verified, master]**
- Re-running the wizard on a PPPoE WAN preselects PPPoE whenever the WAN device name starts with `pppoe`
  (`InitialSetup.php:92-93`), writes `ipaddr = pppoe` again and deletes every `wan`/`inet` gateway item
  (`:299-304`). It silently undoes IPv4 = None. **[verified, master; presence in 26.7 not checked]**
- Official how-to `https://docs.opnsense.org/manual/how-tos/pppoe_isp_setup.html`: sets IPv4 Configuration Type
  PPPoE on the PPPoE interface; does not mention IPv6-only ISPs or IPv4 = None. **[verified]**
- Inference: on an ISP that is IPv6CP-only **today**, an OPNsense 25.1+ box whose WAN IPv6 (DHCPv6/SLAAC) already
  works must already have IPv4 = None (or IPv6 type PPPoEv6/static, or a manual workaround). The IPv4 = PPPoE
  population is: fresh installs via wizard/docs, and customers of an ISP that still answers IPCP. **[likely]**

### 1.6 What the switch to None is, mechanically

- Stored as the **absence** of `ipaddr` in `<interfaces><wan>`: `www/interfaces.php:621-806` rebuilds the record and
  only the `staticv4`/`dhcp`/PPP cases add `ipaddr`.
- GUI offers exactly None or PPPoE for IPv4 on a PPPoE device (`interfaces.php:849-876`); no validation ties IPv6
  DHCPv6/SLAAC to IPv4 PPPoE.
- Apply = `interface_reset()` + `interface_configure(true, $if, true)` + `filter reload`
  (`core/src/opnsense/scripts/interfaces/apply_legacy_if_changes.php:43-48`). mpd5 is killed and restarted with
  `set bundle disable ipcp` -> the PPPoE session is re-dialled (short outage, possibly a new prefix).
- `interface_reset()` clears the ifctl files (`ifctl -4c`, `-6c`; `interfaces.inc:907-909`).
- The interface page does not touch gateway items (`interfaces.php` only reads them at `:567-575`, `:1379`, `:1652`).
- Setting None while the BNG still offers IPCP is the same code path (mpd5 just does not open IPCP). What the BNG
  does with a rejected IPCP request was not examined. **[likely harmless, unverified]**

### 1.7 Predicates a preflight can evaluate (facts, all from code read above)

- Config: WAN device is listed in `<ppps>` and `interfaces.<wan>.ipaddr` is `ppp`/`pppoe`/`l2tp`
  (26.7 also `pptp`). `interface_ppps_bound($wan, 6)` returns true exactly when the WAN is in the
  "IPv6 drives the PPP session" mode (IPv4 off, IPv6 in dhcp6/pppoev6/slaac). It is a core-internal function with
  the same signature on master and 26.7, not a documented plugin API.
- Runtime signature of the broken state: no IPv4 address on the PPP device, no `/tmp/<dev>_router`,
  `/tmp/<dev>_routerv6` present, no global IPv6 address, no `/var/etc/dhcp6c.<dev>.conf`; PPP log has
  `IPCP: protocol was rejected by peer` and only `ppp-linkup: executing on <dev> for inet6`.
- Observation: `ppp-ipv6.php <dev> 4` checks only the configured IPv4 mode, not whether IPCP is up
  (`ppp-ipv6.php:48`, `interfaces.inc:957-959`). **[verified code; effect of calling it by hand not tested]**

---

## 2. (b) Leftovers after switching an existing config to IPv4 = None

### 2.1 Saved dynamic gateway item (`WAN_PPPOE`) -> defunct, harmless for routing and NAT

`core/src/opnsense/mvc/app/models/OPNsense/Routing/Gateways.php`:

- A config item whose `gateway` is not an IP is kept aside as settings for the dynamic gateway of that
  interface + family (`:370-383`).
- In the interface loop it replaces the virtual default (`:423-432`). With no `/tmp/<dev>_router`
  (`Autoconf::getRouter()` null), no `gateway_interface` flag and family inet, the only matching branch is
  `:464-467` (`elseif (empty($thisconf['virtual']))`), which puts it back; `:472-481` then appends it with
  `defunct = true` and `gateway` unset.
- `getDefaultGW()` skips `disabled`, `defunct`, `is_loopback`, `force_down` (`:493-513`);
  `getInterfaceGateway()` skips `disabled`/`defunct` and entries without address (`:597-600`).
- Its `defaultgw` ("upstream") flag and priority are irrelevant once defunct, because defunct entries are appended
  after the sort and skipped.
- GUI: listed with priority shown as "defunct" (`core/src/opnsense/mvc/app/views/OPNsense/Routing/configuration.volt:74-75`).
- stable/26.7 `getGateways()` dynamic part, `getDefaultGW()` and `newKey()` were fetched: same logic. **[verified]**

Without a saved item there is nothing at all: a virtual dynamic gateway only exists while the router file exists.

### 2.2 Side effects of the defunct item (not blockers for the default route)

| Leftover | Effect | Evidence |
|---|---|---|
| Monitor IP stored in the defunct item (e.g. 1.1.1.1) | Model validation collects monitors of **all** items; giving another gateway (e.g. the CLAT one) the same monitor IP fails with "This monitor IP address already exists." | `Gateways.php:52-59`, `:78-90` |
| Monitoring enabled on the defunct item | dpinger is not started ("Skipping gateway ... due to empty 'gateway' property", then "The required ... IPv4 interface address could not be found, skipping."); status is reported `down` because the default for a monitored gateway without a process is `down` | `core/src/etc/inc/plugins.inc.d/dpinger.inc:160-196`, `:316-338` |
| System DNS servers bound to gateway `WAN_PPPOE` (System > Settings > General) | Silently dropped from `get_nameservers()` (comment "do not present servers for defunct gateways") | `core/src/etc/inc/system.inc:443-451` |
| Firewall rules with policy gateway `WAN_PPPOE` | No route-to mapping exists for a gateway without address, so the rule degrades to a plain pass that follows the routing table; with "Skip rules when gateway is down" (`system.skip_rules_gw_down`) the rule is disabled instead | `core/src/opnsense/mvc/app/library/OPNsense/Firewall/Plugin.php:104-118`, `:58-60`; `FilterRule.php:209-216` |
| Gateway groups containing `WAN_PPPOE` | Member is passed with empty `gwip`; the group renders in interface mode (`route-to { pppoe0 }`) if that member is selected | `GatewayGroups.php:223-266`, `Plugin.php:141-155` **[likely, not traced to pf output]** |
| Empty `gateway` field in two items | Not a conflict: the unique constraint skips empty non-required values | `core/src/opnsense/mvc/app/models/OPNsense/Base/Constraints/UniqueConstraint.php:55-57`, `Gateways.xml:40-47` |

### 2.3 Static IPv4 gateway item (IP in `gateway`) - can block

Ordering (`Gateways.php:314-323`, `:471`): key = `sprintf("%01d%04d%010d", $is_default, 256 - $prio, $seq)`, `krsort`.
So: upstream flag first, then lower priority number, then **later registration wins a tie**. Config items are
registered before dynamic ones. Model defaults for a config item: priority 255, monitoring disabled
(`Gateways.xml:50-53`, `:62-68`). A dynamic gateway on a `tun*` or custom-named device has priority 254
(`Gateways.php:412-421`).

Consequences for a CLAT dynamic gateway (priority 254, not upstream):

| Other enabled IPv4 gateway | Who is returned by `getDefaultGW()` |
|---|---|
| static, default priority 255, not upstream | CLAT |
| static, priority 254, not upstream | CLAT (registered later) |
| static, priority < 254 | the static one |
| static or dynamic, **upstream** (`defaultgw=1`) | the upstream one |
| dynamic, priority 254, on an interface listed **after** the CLAT interface in `<interfaces>` | that one |

`system_routing_configure()` (`core/src/etc/inc/system.inc:703-723`) asks for exactly one candidate per family:

```php
$gateway = $gateways->getDefaultGW($down_gateways, $ipproto);
if (empty($gateway['gateway'])) { continue; }
if (isset($config['system']['gw_switch_default']) || empty($interface_map) || in_array($gateway['interface'], $interface_map)) {
    if (empty($ifdetails[$gateway['if']][$type][0])) {
        log_msg("ROUTING: refusing to set {$ipproto} gateway on addressless ...", LOG_ERR);
        continue;
    }
    ...
    system_default_route($gateway, $routes);
}
```

- Winner on an **address-less** interface (for example a static gateway item still attached to the PPPoE WAN):
  refused, `continue`, **no second candidate is tried** -> no IPv4 default route at all. If the call is scoped to
  another interface (e.g. the CLAT one) and gateway switching is off, the block is skipped silently (no log line).
- Winner on an interface that has IPv4 (second uplink, LTE router, etc.): it becomes the default route; the CLAT
  gateway stays unused. That is core doing what the config says.
- Escape through gateway switching only if the blocking gateway is **monitored**: `$down_gateways` is filled from
  statuses containing `down` (`system.inc:690-697`); a gateway with monitoring disabled reports `none`
  (`dpinger.inc:318`) and is never skipped. The wizard creates its static `WAN_GW` with `defaultgw=1` and
  `monitor_disable=1` (`InitialSetup.php:351-361`).
- How likely on a PPPoE customer: a static upstream gateway on the PPPoE WAN itself would already have broken
  IPv4 before the switch (it outranks `WAN_PPPOE`), so it is improbable in a config that worked; a static upstream
  gateway on another interface is a deliberate multi-WAN setup. **[likely]**

All of the above verified by code reading (master; `getDefaultGW`/`newKey`/dynamic part re-read on 26.7).

### 2.4 Outbound NAT mode

- Modes: `automatic`, `hybrid`, `advanced`, `disabled`
  (`core/src/opnsense/mvc/app/models/OPNsense/Firewall/FieldTypes/SNatModeField.php:37`).
- Automatic rules are generated only for mode `''`, `automatic`, `hybrid`
  (`core/src/etc/inc/filter.lib.inc:181`), for every enabled interface whose device does not start with `ovpn` and
  that has an IPv4 gateway (`:186-190`).
- Manual rules are loaded for `advanced` and `hybrid` (`core/src/etc/inc/filter.inc:194-206`) at priority 100
  (MVC rules 50), automatic rules at 200 (`:208-226`).
- So: `advanced` (GUI "manual") and `disabled` -> nothing for the CLAT interface; existing manual rules are bound to
  the old WAN interface and do not match traffic leaving another device. `hybrid` -> automatic CLAT rules exist,
  unless a manual rule on the CLAT interface matches first. After the switch the WAN itself no longer qualifies
  (no IPv4 gateway), so no stale automatic `nat on pppoe0 inet` rules remain. **[verified]**

### 2.5 The switch itself does not install the CLAT default route

`interface_configure($verbose, 'wan', true)` ends with `system_routing_configure($verbose, $interface)`
(`interfaces.inc:2492-2494`), i.e. scoped to `wan`. With gateway switching off, the inet block above only acts when
the best gateway's interface is in the map. A CLAT gateway on another interface is therefore not installed by the
WAN apply; it needs its own trigger (`configctl interface newip <clatdev> force`, `route_reload`, or an unscoped
call such as System > Gateways apply -> `rc.routing_configure:73`). **[verified]**

---

## 3. (c) Events on a pure SLAAC WAN

### 3.1 Every caller of `rc.newwanipv6`

`plugins_configure('newwanip', false, [$interfaces, 'inet6'])` is at `core/src/etc/rc.newwanipv6:125`, after the
guard at `:78-81` (`if (empty($reason)) { return; }`). stable/26.7 identical (fetched). Callers (grep over
`core/src` for `newipv6`):

| Caller | Reason argument | Reaches the plugin hook |
|---|---|---|
| `ppp-linkup.sh:36` | `force`, only when `ppp-ipv6.php <dev> 6` exits non-zero | yes |
| `dhcp6c_script.sh:82` | `${FORCE}` = REQUEST/SOLICIT, or the reason when the stored prefix changed and reason is not INFOREQ | only then |
| `dhcp6c_script.sh:91` (EXIT/RELEASE) | none | no |
| `rtsold_resolvconf.sh:86` (RDNSS/DNSSL/router changed) | none | no |
| `ppp-linkdown.sh:25` | none | no |
| `rc.syshook.d/start/10-newwanip:16` (boot replay) | `force`, for each `/tmp/newwanipv6_*` written while booting | yes |

A reason-less call only runs `waitfordad(2)` and `system_resolver_configure()`
(`rc.newwanipv6:73-76`; `system.inc:509-513`), which contains no plugin hook.

### 3.2 Trace for PPPoE WAN, IPv4 = None, IPv6 = SLAAC

1. IPv6CP up -> `ppp-linkup.sh` inet6 -> `ppp-ipv6.php <dev> 6`: bound, case `slaac` -> sets `accept_rtadv`,
   starts rtsold (+ fail-safe), `exit(0)` (`ppp-ipv6.php:55-63`). No `newipv6`.
2. First RA with non-zero router lifetime -> rtsold "always" script once per interface lifetime
   (`src/usr.sbin/rtsold/rtsol.c:330-340`) -> `rtsold_script.sh`: writes the router file, starts or HUPs dhcp6c.
   It contains no `configctl` call (`core/src/opnsense/scripts/interfaces/rtsold_script.sh:57-84`).
3. Kernel forms the SLAAC address. No userland notification exists for this.
4. RA with RDNSS/DNSSL -> `rtsold_resolvconf.sh` -> `newipv6 <dev>` without reason, and only if a file changed.
5. dhcp6c in SLAAC mode is configured `information-only` (`interfaces.inc:2925-2932`). A reply to an
   Information-request reaches the script with REASON `INFOREQ` (`client6_script(..., state, ...)` in
   `https://raw.githubusercontent.com/opnsense/dhcp6c/master/dhcp6c.c`; `dhcp6_event_statestr()` in `common.c`
   maps `DHCP6S_INFOREQ` to "INFOREQ"). In `dhcp6c_script.sh` FORCE is set only for REQUEST/SOLICIT (`:59-61`)
   and the prefix branch excludes INFOREQ (`:67`) -> `newipv6 <dev>` without reason.
6. Link loss: `ppp-linkdown.sh` inet6 removes autoconf addresses and the router/DNS files, then `newipv6 <dev>`
   without reason.

Result: zero `newwanip` (inet6) plugin events over the whole life of the session. If the ISP's RA has no RDNSS and
its DHCPv6 server does not answer Information-requests, `rc.newwanipv6` is not even invoked. **[verified by code]**

### 3.3 Boot

- `rc.newwanipv6` is deferred only while `/var/run/booting` is locked (`core/src/etc/inc/config.inc:50-56`,
  `core/src/etc/inc/util.inc:316-322`). The lock is held by `flock -n -o ${BOOTLOCK} /usr/local/etc/rc.bootup`
  only (`core/src/etc/rc:224-240`); `rc.syshook start` runs afterwards (`rc:243`).
- `10-newwanip` replays deferred IPv4 events, then deferred IPv6 events, **then** dials PPP (`:3-28`).
- So a PPPoE WAN has no deferred IPv6 event to replay (the device did not exist during boot), and everything after
  the dial follows 3.2. No forced event at boot either. **[verified code; likely runtime]**
- For comparison: an Ethernet SLAAC WAN can get one forced replay at the end of boot if any reason-less call was
  deferred during boot. "Never" is therefore exact for PPPoE, not for every SLAAC WAN.

### 3.4 Other IPv6 types, for completeness

- DHCPv6 mode, IPv4 = None: no event at IPv6CP up; first event when dhcp6c completes SOLICIT/REQUEST; later only on
  a changed delegated prefix. Nothing on link loss, unchanged renew, RA-only changes, or when the ISP's DHCPv6
  server never answers.
- `pppoev6` / static IPv6: forced event at every IPv6CP up (`ppp-ipv6.php:64-69` -> exit 1).
- IPv4 link-down: `ppp-linkdown.sh:16` calls `newip <dev>` without force; `rc.newwanip` returns at
  "Failed to detect IP" (`core/src/etc/rc.newwanip:65-69`). No plugin event.

### 3.5 Other hooks in the neighbourhood

- `rc.syshook monitor <gateways>` runs from `rc.routing_configure` on a gateway alarm
  (`core/src/etc/rc.routing_configure:73-77`; alarms come from `gateway_watcher.php:104-149`). It needs a
  monitored gateway and either gateway switching or a gateway group trigger. It is not an address event.
- No devd rule covers netgraph PPP interfaces (see `opnsense-pppoe-ipv6only.md` 2.7).

Conclusion: in SLAAC mode a plugin learns nothing from events; in DHCPv6 mode it learns "connected" and "prefix
changed" only. Periodic reconciliation is required in both. **[verified by code; no runtime confirmation found]**

---

## 4. Design implications

1. Treat "WAN IPv4 Configuration Type = None" as a hard precondition whenever the WAN is a PPP device and its IPv6
   type is DHCPv6 or SLAAC. Upstream will not change this: the maintainer calls PPPoE the wrong setting for an
   IPv6-only ISP, and the one-line patch proposed in core#9153 was not taken.
2. Do not expect a core fix in 27.1. core#7713 is open with that milestone but is not diagnosed as this problem.
3. Preflight must detect the misconfiguration explicitly, because the box looks half alive: PPPoE "up",
   link-local address, IPv6 default route, and even a `newwanip` (inet6) plugin event at link-up.
   Usable predicates are in 1.7.
4. Onboarding has one unavoidable core-side step for wizard/docs-built boxes: set IPv4 to None and apply. It
   re-dials the PPPoE session. Whether the plugin offers to do it or only instructs the user is a design choice;
   the fact is that the value lives in core's `<interfaces>` record (absence of `ipaddr`) and that the legacy
   interface page rewrites that record on every save.
5. Warn that re-running the setup wizard reverts the WAN to IPv4 = PPPoE and deletes WAN IPv4 gateway items.
   The preflight has to be re-evaluated continuously, not only at install time.
6. A leftover `WAN_PPPOE` gateway item does not need to be deleted for routing or NAT. Preflight should still
   surface: its monitor IP (collides with reuse), DNS servers bound to it, firewall rules and gateway groups that
   reference it, and "skip rules when gateway is down".
7. Compute the IPv4 default-gateway outcome instead of assuming it: ask `Gateways::getDefaultGW([], 'inet')` and
   compare with the CLAT gateway. Flag (a) any enabled IPv4 gateway that is upstream or has priority < 254,
   (b) specifically a winner whose interface has no IPv4 address, because core then installs no default route at
   all and tries nobody else.
8. Do not rely on gateway switching to get past a blocking gateway: it only skips monitored gateways that report
   down; wizard-made static gateways have monitoring disabled.
9. Check `nat.outbound.mode`. In `advanced` (manual) or `disabled` there is no automatic source NAT on the CLAT
   interface; in `hybrid` there is. This is a preflight message, not something to solve with generated rules.
10. The WAN apply does not install the CLAT default route (scoped routing call). The plugin's own bring-up has to
    trigger routing and filter for its interface.
11. Lifecycle cannot be event-driven. Keep the `newwanip` (inet6) subscription as an accelerator for DHCPv6 mode
    and for the misconfigured state, and add periodic reconciliation that reads actual state (addresses, ifctl
    files, PPP device presence). In SLAAC mode the poller is the only trigger.
12. If the WAN is SLAAC, there is also no delegated prefix and no tracking LAN (`opnsense-pppoe-ipv6only.md` 4.2);
    the poller is what notices the SLAAC address appearing, changing, or being flushed at link-down.

---

## 5. Open questions

1. No 26.7.x system log of an IPv6CP-only session with IPv4 = PPPoE was found. The code is identical and the
   25.1-26.1 reports are consistent, so the gap is small, but a 5-minute lab check would close it.
2. No user report was found that explicitly says "IPv4 = None + DHCPv6/SLAAC works on an IPv6CP-only PPPoE line on
   26.7". The maintainer says the mode was built and tested for 25.1.
3. Which IPv6 type the target ISP needs (SLAAC, DHCPv6 IA_NA, PD-only) decides which events exist at all.
4. Is the ISP already IPv6CP-only for all customers, or do some sessions still get IPCP? This decides how many
   existing boxes are currently on IPv4 = PPPoE (see 1.5, inference).
5. Behaviour of the ISP's BNG when the client does not open IPCP / rejects an IPCP request (IPv4 = None while the
   BNG still offers IPCP) was not examined.
6. Does the MVC setup wizard (`InitialSetup.php`) exist with the same logic on stable/26.7? Read on master only.
7. Exact pf output for a gateway group whose member is a defunct gateway (2.2) was not traced.
8. Whether `ppp-ipv6.php <dev> 4` run by hand brings IPv6 up cleanly on an IPv4 = PPPoE WAN without IPCP (it passes
   the gate by code) was not tested, and it would be an unsupported use of a core script.
9. How the new master-only interface assignment model (`opnsense-gateways-nat.md` appendix B) will store the IPv4
   type in 27.1 was not examined.
