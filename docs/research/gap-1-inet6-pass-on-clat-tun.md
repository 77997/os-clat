# Gap 1: passing the translated IPv6 that tayga re-injects `in on <tun> inet6`

Research date 2026-10-11. Facts only, no design. Nothing was executed on a firewall; every pf line below is
assembled from the generator code and is marked accordingly.

Path prefixes (all under `refs/`):

- `core/` = `opnsense-core` (opnsense/core **master**)
- `src/` = `opnsense-src` (opnsense/src **stable/26.7**)
- `plugins/` = `opnsense-plugins` (master), `tayga/` = `tayga`, `openwrt/` = `openwrt`, `gh/` = saved GitHub threads
- "26.7:" = cross-check through `https://raw.githubusercontent.com/opnsense/core/stable/26.7/<path>` (fetched excerpts; no line numbers)

Confidence: **[V]** read in the primary source; **[L]** inferred from verified code, not runtime-tested; **[U]** unverified.

Running example: device `tun464`, IPv4 `192.0.0.1 -> 192.0.0.2`, CLAT address `CLAT6`, PLAT prefix `PREF64::/96`,
WAN `pppoe0`, LAN `igb1`. `K` = the config key of the CLAT interface (`optN` if the user assigned it, or a
plugin-chosen key if the plugin registers it through `<plugin>_interfaces()` and it is therefore `internal_dynamic`).

---

## 0. Answers in brief

| # | Question | Answer | Conf. |
|---|----------|--------|-------|
| a | Core-native way to pass `in on <tun> inet6` with no plugin-emitted or user-created rule (stable/26.7 and master)? | **No.** No core rule passes it, `set skip` has three hard-coded sources and no hook, an out-of-band skip is wiped by every core reload, and skip would also bypass NAT44 on the tun. | V (code), L (runtime) |
| b | Supported carriers for the one rule | Two: (H) `<plugin>_firewall()` + `registerFilterRule()` and (M) an MVC rule under `//OPNsense/Firewall/Filter/rules`. H is the documented plugin hook with five in-tree emitters; no plugin in opnsense/plugins writes M. H vanishes with the plugin; M is config residue. Evidence favours H. **Needs a design decision** because H is, literally, a plugin-emitted pf rule. | V |
| c | Can the rule omit CLAT /128 and pref64? | **Yes.** `in on <tun>` can only be produced by the single process holding the tun open; what tayga can emit is bounded by its map table; IPv4 policy has already been applied on the IPv4 leg. Omitting the addresses makes the rule text constant, so the plugin never has to trigger a filter reload for it. The address-bearing form buys source hygiene only, and has an ordering problem at renumbering (core reloads the filter *before* the plugin's `newwanip` hook runs). | V (mechanisms), L (security equivalence) |
| d | Exact text / ordering / reply-to | Same rule text for both interface models: `pass in [log] quick on tun464 inet6 from {any} to {any} keep state label "<id>"`. H at prio 1 sits before every user rule; M sits at prio 400000 after floating and group rules and after quick bogon/private blocks. Neither gets `reply-to` (no IPv6 gateway on the tun). `internal_dynamic` only removes the tun's own `antispoof` line and the force-gw `route-to` rule; neither touches the inet6-in leg. | V (generator), L (final text) |

---

## 1. Why the packet is `in on <tun> inet6` and stateless

### 1.1 Kernel path (stable/26.7) **[V]**

```c
// src/sys/net/if_tuntap.c:2071 (tunwrite)
m->m_pkthdr.rcvif = ifp;
...
// :2079
return (tunwrite_l3(tp, m));

// src/sys/net/if_tuntap.c:1997-2011 (tunwrite_l3)
case AF_INET6:
        isr = NETISR_IPV6;
        break;
...
M_SETFIB(m, ifp->if_fib);
NET_EPOCH_ENTER(et);
netisr_dispatch(isr, m);
```

```c
// src/sys/netinet6/ip6_input.c:567-569
rcvif = m->m_pkthdr.rcvif;
if ((ND_IFINFO(rcvif)->flags & ND6_IFF_IFDISABLED))
        goto bad;
// src/sys/netinet6/ip6_input.c:769-775
if (!PFIL_HOOKED_IN(V_inet6_pfil_head))
        goto passin;
odst = ip6->ip6_dst;
if (pfil_mbuf_in(V_inet6_pfil_head, &m, m->m_pkthdr.rcvif,
    NULL) != PFIL_PASS)
        return;
```

```c
// src/sys/netpfil/pf/pf_ioctl.c:6866-6867 (pf_check6_in)
chk = pf_test(AF_INET6, PF_IN, flags, (*m)->m_flags & M_LOOP ? V_loif : ifp,
    m, inp, NULL);
```

So a packet written to the tun by its owner is `pf_test(AF_INET6, PF_IN, ifp = tun)`. There are exactly two
early exits before rule/state processing:

```c
// src/sys/netpfil/pf/pf.c:11027-11033
if (kif->pfik_flags & PFI_IFLAG_SKIP) {
        return (PF_PASS);
}
if ((*m0)->m_flags & M_SKIP_FIREWALL) {
        return (PF_PASS);
}
```

`M_SKIP_FIREWALL` is never set by `if_tuntap.c` (grep: no match in that file; setters are pf/ipfw/ip6_output
internals). No pf state can match either: the only state the flow has at that moment is the IPv4 NAT state
created `out on tun464`, a different address family. **[V]**

### 1.2 Who can inject `in on tun464` **[V]**

- One opener only: `src/sys/net/if_tuntap.c:1178-1183` `if ((tp->tun_flags & (TUN_OPEN | TUN_DYING)) != 0) { ... return (EBUSY); }`.
- Device node is `uucp:dialer 0600`: `if_tuntap.c:889-891` (`args.mda_uid = UID_UUCP; args.mda_gid = GID_DIALER; args.mda_mode = 0600;`).
- `tunwrite` is the only path that sets `rcvif = ifp` for this ifnet.

Therefore everything pf sees as `in on tun464` was written by the process that holds `/dev/tun464` open (tayga).

### 1.3 What tayga can write as IPv6 **[V]**

| Emission | Source address | Destination address | Code |
|---|---|---|---|
| Translated IPv4 packet | `map_ip4_to_ip6(ip4 src)` | `map_ip4_to_ip6(ip4 dst)` | `tayga/nat64.c:379-400` |
| ICMPv6 error (types 1, 2, 3, 4) | `gcfg.local_addr6` (tayga's `ipv6-addr`) | source of the offending IPv6 packet | `tayga/nat64.c:808-827`, call sites `:962, :974, :985, :1105, :1302, :1307` |
| ICMPv6 echo reply | the pinged address (tayga's own) | the pinger | `tayga/nat64.c:836-842` |

`map_ip4_to_ip6()` (`tayga/addrmap.c:485-544`) only yields: a static `map` target (`MAP_TYPE_STATIC`), an
RFC 6052 address inside `prefix` (`MAP_TYPE_RFC6052`, `append_to_prefix`), or a dynamic-pool host; otherwise
`ERROR_REJECT`/`ERROR_DROP` and nothing is written. With the WKP and `wkpf-strict` a private IPv4 address is
rejected (`addrmap.c:461-466`). Consequences:

- Destination of a translated packet is always inside `PREF64::/96` (or a configured static map). It cannot be
  one of the firewall's own IPv6 addresses unless the configuration maps one.
- Source is `CLAT6` when NAT44 to 192.0.0.1 was applied. An **un-NATed** LAN source is either rejected (WKP +
  strict) or mapped to `PREF64::<rfc1918>` (network-specific prefix or `wkpf-strict no`).

---

## 2. (a) Is there a core-native pass? No.

### 2.1 Every pass rule core generates (master) **[V]**

`core/src/etc/inc/filter.lib.inc:200-659` (`filter_core_rules_system`). Rules with no `direction` render as
`in`, because `FilterRule.php:44` is `'direction' => 'parseReplaceSimple,:in|any:'` (empty -> `in`, `any` -> nothing).

| Lines | Rule | Why it does not match TCP/UDP/echo from `CLAT6` in on the tun |
|---|---|---|
| 217-222 | `Default deny / state violation rule`, `'ipprotocol' => 'inet46'`, `'quick' => false`, block | this is what catches it |
| 226-232 | ICMPv6 types `1,2,3,4,135,136`, any source | passes tayga's ICMPv6 *errors* only |
| 234-265 | ICMPv6 `128,...` only `from (self)` out, or `from fe80::/10`, `ff02::/16`, `::` in | echo from a GUA not covered |
| 372-400 | DHCPv6 client, per interface with `ipaddrv6` in `dhcp6|slaac` | UDP 546/547, link-local |
| 403-459 | DHCPv4 client/server | IPv4 |
| 466-541 | 6rd / 6to4 proto 41, DHCPv6 server | protocol/port specific |
| 545-550 | `let out anything from firewall host itself`: `'direction' => 'out'`, `'quick' => false` | out only |
| 553-560 | `IPsec internal host to host` | out on enc0 |
| 563-580 | anti-lockout: `in` on the primary LAN, tcp to `(self)` | other interface |
| 585-620 | force gw: `'direction' => 'out'`, prio 10000 | out only |
| 623-658 | filter rules for DNAT entries, prio 500000 | user-driven |

Plus `pf_firewall()` (`core/src/etc/inc/plugins.inc.d/pf.inc:124-166`): `bypassstaticroutes` passes
`from (gw-if:network) to <static route net>` on the gateway interface only.

Other core `_firewall()` hooks (grep `function \w+_firewall\(` in `core/src/etc/inc/plugins.inc.d`): only
`pf`, `kea`, `dnsmasq`, `ipsec`, `captiveportal`. OpenVPN and WireGuard have none: their group tabs start empty
and the user writes the rules.

The factory rules are bound to `lan` (`core/src/etc/config.xml.sample:115-164`: `<interface>lan</interface>`,
`<source_net>lan</source_net>`).

26.7: the fetched enumeration of `filter_core_rules_system()` gives the same set plus two `allow PPTP client`
rules (tcp/gre) that master no longer has; conclusion there: "Every pass rule with an explicit direction 'in' is
also limited by protocol, port, or interface". **[V via fetch]**

### 2.2 `set skip` **[V]**

```php
// core/src/etc/inc/filter.inc:373-379   (identical three sources on stable/26.7)
$rules .= "set skip on lo0\n";
$rules .= "set skip on pfsync0\n";
foreach ((new \OPNsense\IPsec\Swanctl(true))->VTIs->VTI->iterateItems() as $vti) {
    if (!$vti->skip_fw->isEmpty()) {
        $rules .= sprintf("set skip on ipsec%s\n", $vti->reqid);
    }
}
```

- `OPNsense\Firewall\Plugin` has no skip API. Its public methods are the `register*Rule`, `registerAnchor`,
  `registerTable` family (`core/.../Firewall/Plugin.php:223-441`; same 24 methods on 26.7).
- Grep for `skip_fw|set skip` over `core/src`: only the lines above and the VTI model/form.
- An out-of-band skip does not survive: pfctl snapshots the kifs when loading a ruleset with options
  (`src/sbin/pfctl/pfctl.c:3606-3608` `pfctl_get_skip_ifaces()`), un-marks those the new file names again
  (`:434-456`), and then **clears the flag on every interface still marked** (`:485-490`
  `pfctl_set_interface_flags(pf, p->pfik_name, PFI_IFLAG_SKIP, 0)`; `how == 0` is `DIOCCLRIFFLAG`, `:2856-2858`),
  called at `:2342-2343`. Core loads `/tmp/rules.debug` with plain `pfctl -f` on every `filter_configure_sync()`
  (`filter.inc:401`).
- Semantics: `src/share/man/man5/pf.conf.5:665-668` "Packets passing in or out on such interfaces are passed as if
  pf was disabled, i.e. pf does not process them in any way." That includes the automatic
  `nat on tun464 ... -> (tun464:0)` rule, which is evaluated in the same `pf_test()` that returns early at
  `pf.c:11027`. The NAT44-to-192.0.0.1 model cannot work on a skipped tun. **[V mechanism, L outcome]**

### 2.3 Other knobs checked **[V]**

- `system.disablefilter` -> `pfctl -d` (`filter.inc:283-295`): disables NAT as well.
- Interface flags in `<interfaces>`: only `blockbogons` / `blockpriv` (block rules, `filter.lib.inc:327-369`).
  No per-interface "allow" flag exists.
- Interface groups: a plugin can register a group (os-tayga: `plugins/net/tayga/src/etc/inc/plugins.inc.d/tayga.inc:66-80`)
  but a group carries no rule by itself; the os-tayga how-to makes the user add one
  (https://docs.opnsense.org/manual/how-tos/tayga.html: "add a new rule, set the TCP/IP Version to IPv4+IPv6").

**Conclusion (a):** on both branches a pass rule has to come from somewhere outside core's own generator.

---

## 3. How one rule becomes pf text (needed for b and d)

### 3.1 Registration and ordering **[V]**

```php
// core/src/etc/inc/filter.inc:186-192
$fw = filter_core_get_initialized_plugin_system();
filter_core_bootstrap($fw);              // core rules, prio 1 / 5 / 10000 / 500000
$cnfint = iterator_to_array($fw->getInterfaceMapping());
plugins_firewall($fw);                   // every <plugin>_firewall($fw), alphabetical by file name; pf_firewall registers MVC rules
filter_core_rules_user($fw);             // legacy <filter><rule>
```

```php
// core/.../Firewall/Plugin.php:260-279
public function registerFilterRule($prio, $conf, $defaults = null)
{
    if (!empty($this->systemDefaults['filter'])) { $conf = array_merge($this->systemDefaults['filter'], $conf); }
    if ($defaults != null) { $conf = array_merge($defaults, $conf); }
    if (empty($conf['label'])) { $conf['label'] = Util::calcRuleHash($conf); }   // md5 of the conf minus descr
    $conf['#priority'] = $prio;
    $rule = new FilterRule($this->interfaceMapping, $this->gatewayMapping, $conf);
    $this->filterRules[$prio][] = $rule;
}
// Plugin.php:369-380  outputFilterRules(): ksort($this->filterRules); "# [prio: N]" header; rules in registration order
```

```php
// core/src/etc/inc/filter.inc:386-391
$rules .= filter_generate_scrub_rules($cnfint);   // master only: "match on <if> inet6 all scrub (...)"
$rules .= $fw->anchorToText('fw', 'head');
$rules .= filter_rules_legacy($cnfint);           // antispoof lines
$rules .= $fw->outputFilterRules();
$rules .= $fw->anchorToText('fw', 'tail');
```

Resulting filter section, top to bottom:

| Block | Content | quick? |
|---|---|---|
| antispoof | `antispoof log for <dev>` for every enabled interface that is not a bridge member, not `internal_dynamic`, not lo0 (`filter.inc:575-579`) | no (`parse.y:1585` `r.quick = $2.quick`) |
| prio 1, core | Block all IPv6 (only if IPv6 disabled), default deny (non-quick), ICMPv6, port 0, sshlockout, virusprot, DHCP, 6rd/6to4 | mostly quick |
| prio 1, plugins | kea, dnsmasq, frr, crowdsec, wazuh, captive portal ... in file-name order | per rule |
| prio 5 | bogon / private blocks per interface (quick, `in`), `let out anything` (non-quick), anti-lockout | |
| prio 10 / 10000 | bypassstaticroutes / force gw | non-quick |
| prio 200000 | floating: MVC first (registered inside `pf_firewall`), then legacy | per rule |
| prio 300000+seq | interface-group rules | |
| prio 400000 | single-interface rules, MVC in `sequence` order, then legacy | quick by default |
| prio 500000 | DNAT-associated rules, legacy IPsec auto rules | |
| prio 600000 | MVC rules whose interface is not in config ("Invalid rules (not applied by PF)", `FilterRuleField.php:160-163`) | |
| tail anchors | `anchor "acme-client/*"` etc. | |

Priorities: `filter.lib.inc:690-696` (legacy), `FilterRuleField.php:145-195` (MVC `getPriority()`), identical on 26.7.

pf semantics: "the last matching rule decides what action is taken" (`pf.conf.5:1597-1603`); with `quick`
"this rule is considered the last matching rule, and evaluation of subsequent rules is skipped" (`:1823-1828`).

### 3.2 Text generation **[V]**

`FilterRule.php:41-74` `$procorder` (same on 26.7 except the master-only `scrub` key): `disabled, type, direction,
log, quick, interface, gateway, reply, ipprotocol, protocol, from, from_port, os, to, to_port, [scrub,]
received-on, icmp-type, icmp6-type, flags, state, ..., allowopts, dn, divert-to, label, descr`.

- `from`/`to` are wrapped: `parsePlainCurly` (`Rule.php:226-234`) -> `from {any} to {any}`.
- `interface` must be a key of the interface mapping: `parseInterface` (`Rule.php:402-414`) prints
  `on <mapping[key]['if']>`, and the reader disables the rule otherwise:
  ```php
  // Rule.php:320-324
  if (empty($this->interfaceMapping[$interface]['if'])) {
      $this->log("Interface {$interface} not found");
      $rulecpy['disabled'] = true;
  }
  ```
  There is no way to name a raw device. The mapping is `legacy_config_get_interfaces(["enable" => true])`
  (`filter.lib.inc:60`, `config.inc:328-371`): every enabled `<interfaces>` child, including `internal_dynamic`
  and virtual group entries.
- Address literals: `<table>` and `(ifspec)` strings pass through unvalidated (`Rule.php:81-86`: "literal alias by
  automated rules", "literal interface by automated rules"); interface keys map to `(dev:network)`
  (`Rule.php:53-59`); IPs/subnets pass `Util::isIpAddress/isSubnet`.
- `quick` defaults to true for non-floating rules (`FilterRule.php:233-236`).

Runtime confirmation of the shape (maintainer's own output for an MVC interface rule, `gh/opnsense_core_10638.md:31,34`):

```
/tmp/rules.debug:  pass in quick on hn3 inet from {any} to {any} keep state label "5fa6810f-..." af-to ...
pfctl -s rules:    pass in quick on hn3 inet all flags S/SA keep state label "5fa6810f-..." af-to ...
```

### 3.3 reply-to **[V]**

```php
// FilterRule.php:169-193 (same on 26.7)
} elseif (empty($rule['disablereplyto']) && ($rule['direction'] ?? "") != 'any' && empty($rule['interfacenot'])) {
    $proto = $rule['ipprotocol'];
    if (!empty($rule['interface']) && !empty($this->interfaceMapping[$rule['interface']]['if']) && empty($rule['gateway'])) {
        switch ($proto) {
            case "inet6":   // needs interfaceMapping[if]['gatewayv6'] to be an IP
            default:        // needs interfaceMapping[if]['gateway'] to be an IP
                $rule['reply'] = "reply-to ( {$if} {$gw} ) ";
```

`gatewayv6` comes from `filter.lib.inc:69-73` = `getInterfaceGateway($key, "inet6", true)`, which returns only a
gateway that has an address (`Gateways.php:597-601`, `empty($gateway['gateway'])` -> skip). A tun with no
`/tmp/tun464_routerv6` and no configured IPv6 gateway has none. Hence:

- an **inet6** pass rule on the CLAT interface never gets `reply-to`, with either carrier, in either interface model;
- an **inet** (or `inet46`) pass rule on it does get `reply-to ( tun464 192.0.0.2 )` unless `disablereplyto` is set
  (per rule, or globally via `system.disablereplyto`, `Plugin.php:55-57`). This is what the os-tayga how-to rule
  ("IPv4+IPv6") would produce on a tun that has a dynamic IPv4 gateway.

---

## 4. (b) The carriers

### 4.1 Carrier H: `<plugin>_firewall($fw)` + `registerFilterRule()`

**Supported and documented [V].** `core/src/etc/inc/plugins.inc:244-259`; OPNsense docs "Using plugins > Firewall"
(https://docs.opnsense.org/development/backend/legacy.html): "To register firewall rules, create a function
called `<plugin>_firewall()`", with the example
`$fw->registerFilterRule(500000, array("direction" => "in", "protocol" => "udp", "to_port" => 9999));`.

**Precedents [V].**

| Emitter | Prio | quick | Interface-bound | User toggle | `#ref` | Evidence |
|---|---|---|---|---|---|---|
| core 6rd/6to4 (proto 41 for a transition mechanism) | 1 | **false** | yes | no | yes | `filter.lib.inc:467-498` |
| core Kea | 1 | default (true) | yes | `fwrulesEnabled()` | yes | `kea.inc:226-264` |
| core Dnsmasq | 1 | default | yes, by iterating `getInterfaceMapping()` | `dhcp.default_fw_rules` | yes | `dnsmasq.inc:99-164` |
| core IPsec (legacy tunnels) | 500000 | false | yes | `disablevpnrules` | yes | `ipsec.inc:237-332` |
| core Captive portal | 1 / 2 / 6 | default | yes | per-zone `disableRules` | yes | `captiveportal.inc:76-93,140-167,189-202` |
| plugin os-frr | 1 | true | no | `fwrules` | yes | `plugins/net/frr/.../frr.inc:59-83` |
| plugin os-crowdsec | 1 | true | no | `rules_enabled` | no | `plugins/security/crowdsec/.../crowdsec.inc:52-108` |
| plugin os-wazuh-agent | 1 | default | no | no | yes | `plugins/security/wazuh-agent/.../wazuhagent.inc:55-67` |

Pattern: every in-tree emitter of *pass* rules except the 6rd/6to4 block ships a setting that turns the automatic
rules off, and most set `#ref` to their own settings page.

**Properties [V].**

- Not persisted. The rule exists only while the hook returns it; disabling or removing the plugin removes it at
  the next reload. `<plugin>_interfaces()` registrations are removed the same way (`plugins.inc:233-239`).
- Visible in the GUI as an automatic rule: `core/src/opnsense/scripts/filter/list_non_mvc_rules.php:35-49,119-121`
  (`$rule['is_automatic'] = empty($rule['updated']); /* plugin generated rules have no timestamp */`) merged by
  `FilterController.php:187-191` ("automatic rules have their own category that is always visible"); a rule with
  `'interface' => K` is listed under that interface. Read-only for the user.
- The hook also runs from the listing script above and from `core/src/www/firewall_rule_lookup.php:34-35`, i.e.
  outside filter reloads. (os-crowdsec writes aliases to config.xml from inside its hook,
  `crowdsec.inc:10-25,46-47`; that is the only config write found in the hooks read: pf, kea, dnsmasq, ipsec,
  captiveportal, frr, crowdsec, wazuh-agent, acme-client, upnp, zabbix-agent, udpbroadcastrelay.)
- The plugin does not receive core's `$defaults['pass']`; emitters build their own conf. Core's internal defaults
  set `"disablereplyto" => 1` (`filter.lib.inc:34-43`); os-frr sets it explicitly, Kea/Dnsmasq do not.
- Needs the interface key. `internal_dynamic`: the plugin chose it. `optN`: found by matching `['if']` while
  iterating `$fw->getInterfaceMapping()` (Dnsmasq pattern). If the key is missing or disabled the rule is emitted
  commented out with `#debug:Interface <key> not found`.

### 4.2 Carrier M: an MVC rule in config.xml

**Model [V].** `core/.../models/OPNsense/Firewall/Filter.xml`: mount `//OPNsense/Firewall/Filter`, `rules/rule`,
`interface` is an `InterfaceField` with `<AllowDynamic>Y</AllowDynamic>` (`:86-92`), so a plugin-registered key is
accepted. Registered by `pf_firewall()`:

```php
// core/src/etc/inc/plugins.inc.d/pf.inc:170-174
foreach ($mdlFilter->rules->rule->sortedBy(['sequence']) as $key => $rule) {
    $content = $rule->serialize();
    $content['#ref'] = 'ui/firewall/filter#' . (string)$rule->getAttributes()['uuid'];
    $fw->registerFilterRule($rule->getPriority(), $content);
}
```

`serialize()` (`FilterRuleField.php:54-138`): `label` = uuid, `from`/`to` from `source_net`/`destination_net`,
`type` = action, `reply-to` = replyto, `disablereplyto` only when set. Documented API for creating such rules:
`firewall/filter/add_rule`, `set_rule`, `del_rule`, `toggle_rule`, and `filter_base/apply`
(https://docs.opnsense.org/development/api/core/firewall.html).

**Precedents [V].**

- The factory config: `core/src/etc/config.xml.sample:114-164` (two `lan` rules). Same on 26.7; the legacy
  `<filter>` section is empty on both.
- Core migrations (`Migrations/MFP1_0_8.php:97` `$model->rules->rule->Add()`).
- **No plugin.** Grep of `plugins/` for `OPNsense\Firewall\Filter`, `snatrules`, `['filter']['rule']`, `filter/rule`:
  no match. The nearest thing is os-crowdsec creating two *aliases* (`crowdsec.inc:10-25`).

**Properties [V].**

- User-owned from the moment it exists: listed, editable, disableable and deletable on Firewall > Rules > [K]
  (`Firewall/Menu/Menu.php:74-83` adds an entry per enabled interface, plugin-registered ones included); synced by
  HA under `filter,OPNsense.Firewall.Filter.rules` (`pf.inc:214-220`).
- Requires a config write by the plugin into a core model, plus bookkeeping (uuid) to stay idempotent and to
  notice a user deletion.
- The model is moving: stable/26.7 `Filter.xml` is version **1.0.6** with a `<general>` container and no
  `scrub_*` rule fields (fetched); master is **1.0.9** with `<settings>` and per-rule scrub fields
  (`Filter.xml:3,7-34,424-440`); PR #10638 adds `af-to-*` fields. The basic fields needed here exist in both.
- Lifecycle when the interface goes away:
  - `optN` deleted in Interfaces > Assignments: associated rules are deleted
    (`core/.../Interfaces/Api/AssignmentController.php:100-138` `cleanRules()`, called at `:155-157`
    `/* remove associated rules */`). The same controller is served from the stable/26.7 raw URL, while
    `src/www/interfaces_assign.php` is 404 there, so this applies to 26.7 too **[L]**.
  - `internal_dynamic` record removed by `plugins_interfaces()`: `cleanRules()` is **not** on that path. The rule
    stays in config.xml, `getPriority()` returns 600000 and the generator prints it disabled.
- Legacy `<filter><rule>` is not an alternative: the legacy rules pages only exist in the `os-firewall-legacy`
  plugin (`plugins/net/firewall-legacy/src/www/firewall_rules.php`; absent from `core/src/www` on master and 404 on
  26.7), and any legacy rule makes the "Migration assistant" menu appear (`Firewall/Menu/Menu.php:51-61`).

### 4.3 Other carriers that exist **[V]**

- **User-made rule, documented**: what os-tayga does (section 2.3).
- **Anchor**: `registerAnchor('<name>', 'fw')` in the hook plus `pfctl -a <name> -f <file>` at runtime
  (`plugins/security/acme-client/.../acmeclient.inc:43-45` and
  `.../LeValidation/TlsalpnAcme.php:132-140`; `plugins/net/upnp/.../miniupnpd.inc:48-52,108-109`). Tail anchors are
  evaluated after all user rules; contents can change without a core reload; contents are not shown in the rules
  UI. This is the plugin driving pfctl directly.

### 4.4 OpenWrt's own answer **[V]**

`openwrt/package/network/ipv6/464xlat/files/464xlat.sh:55-80`: the protocol handler attaches the rules to the
interface as netifd `data` (not to `/etc/config/firewall`), so they live exactly as long as the interface:

```sh
json_add_object ""
        json_add_string type rule
        json_add_string family inet6
        json_add_string proto all
        json_add_string direction in
        json_add_string dest "$zone"
        json_add_string src "$zone"
        json_add_string src_ip $ip6addr
        json_add_string target ACCEPT
json_close_object
```

That is the analogue of carrier H (handler-owned, non-persistent), and it does carry the CLAT /128 (`src_ip`),
regenerated on every protocol setup.

### 4.5 Side by side

| Aspect | H: `_firewall()` hook | M: seeded MVC rule |
|---|---|---|
| Documented for plugins | yes (docs + `plugins.inc:244`) | only as an external API; no plugin does it |
| In-tree precedent for a pass rule | Kea, Dnsmasq, IPsec, captive portal, 6rd/6to4, os-frr | factory config only |
| Lives in config.xml | no | yes |
| Disappears with the plugin | yes, automatically | no (orphan at prio 600000 for a plugin key; deleted with an `optN`) |
| User can edit / delete it | no (toggle in plugin settings is the convention) | yes, and can break the datapath by doing so |
| Position | chosen by the plugin (1, 500000, quick or not) | 400000, after floating/group rules and prio-5 quick blocks |
| Depends on the evolving rule model | no | yes (1.0.6 -> 1.0.9 -> af-to fields) |
| Is "a plugin-emitted pf rule" | **yes** | no (it is a user rule the plugin planted) |

---

## 5. (c) Can the rule omit the CLAT /128 and the pref64?

### 5.1 Facts supporting an address-less rule

1. `in on tun464` implies "written by tayga" (1.2). **[V]**
2. tayga's IPv6 output is limited to the three emission types in 1.3; destinations are `PREF64`-embedded or the
   sender of a packet tayga just received. **[V]**
3. The IPv4 packet was already filtered `in on igb1` (user LAN rules) and `out on tun464`. The out leg is passed by
   the non-quick `let out anything` rule (`filter.lib.inc:545-550`), which any later user rule can override. The
   IPv6 copy still crosses `out on pppoe0`. User policy on IPv4 destinations can only be expressed on the IPv4 leg
   anyway, because the IPv6 destination is an RFC 6052 encoding. **[V rules, L equivalence]**
4. ICMPv6 errors from tayga's own address are passed by core regardless (`filter.lib.inc:226-232`, types 1-4),
   unless `system.no_ipv6_rfc4890_req` is set.

What the address-bearing form adds: packets whose source is not `CLAT6` are dropped locally and logged by the
default deny instead of leaving on the WAN. The only way to get such a packet is an un-NATed LAN source combined
with a network-specific prefix or `wkpf-strict no` (1.3). That is hygiene and diagnostics, not protection of the
firewall. **[L]**

### 5.2 Reload behaviour **[V]**

- A rule without addresses renders to constant text; its label (`md5` of the conf, `Util.php:411-424`) is constant.
- Core reloads the filter on every WAN address event **before** it calls plugin hooks:
  ```php
  // core/src/etc/rc.newwanipv6:120-125   (rc.newwanip:123-125,142-143 is the same order)
  system_routing_configure(false, $interfaces, true, $family);
  filter_configure_sync();
  plugins_configure('vpn', false, [$interfaces, $family]);
  plugins_configure('newwanip', false, [$interfaces, $family]);
  ```
  A rule that embeds `CLAT6`/`PREF64` taken from plugin state is therefore rendered with the *old* values by that
  reload; the plugin must trigger a second reload after it has settled the new address. With H the values could
  instead be computed live inside the hook; with M they are in config.xml and need a config write per change.
- pf keeps existing states across a ruleset load, so reloads by themselves do not cut flows; flows die at
  renumbering because the PLAT state is keyed on the CLAT address. **[L]**

### 5.3 Forms between "any" and literals (mechanisms that exist) **[V]**

- Dynamic interface network: "When the interface name is surrounded by parentheses, the rule is automatically
  updated whenever the interface changes its address. The ruleset does not need to be reloaded."
  (`pf.conf.5:1920-1924`). `'from' => '(pppoe0:network)'` passes the generator untouched (`Rule.php:84-86`); core
  uses the same literal style at `filter.lib.inc:604` (`'from' => "({$ifcfg['if']})"`). Useful only if the CLAT
  /128 is carved from a prefix that is on-link on some interface. Behaviour of `:network` for an IPv6 /64 on a
  PPP interface was not checked. **[L]**
- Table: `$fw->registerTable($name, true)` (`Plugin.php:418-421`) + `'from' => '<name>'`, updated with
  `pfctl -t <name> -T replace`. No in-tree plugin calls `registerTable` (grep: definition only). os-nginx and
  os-q-feeds-connector do update pf tables with pfctl at runtime
  (`plugins/www/nginx/src/opnsense/scripts/nginx/ngx_autoblock.php:79`,
  `plugins/security/q-feeds-connector/src/opnsense/scripts/qfeeds/lib/__init__.py:166`); how those tables are
  declared was not checked.

---

## 6. (d) Exact text, ordering and reply-to per carrier and interface model

### 6.1 Rule text **[L: assembled from 3.2; shape confirmed by the PR output quoted there]**

Carrier H, conf `['type'=>'pass','direction'=>'in','interface'=>K,'ipprotocol'=>'inet6','statetype'=>'keep',
'quick'=>true,'disablereplyto'=>1,'log'=>!isset($config['syslog']['nologdefaultpass']),'descr'=>D,'#ref'=>R]`:

```
pass in log quick on tun464 inet6 from {any} to {any} keep state label "<32-hex md5>" # D
```

(`log` is present with the default config, as for Kea/Dnsmasq rules; `quick` disappears with `'quick' => false`.)

Carrier M, a rule like the factory LAN rule with `interface=K`, `ipprotocol=inet6`, `source_net=any`:

```
pass in quick on tun464 inet6 from {any} to {any} keep state label "<uuid>" # <description>
```

Address-bearing variants only change the braces: `from {CLAT6} to {PREF64::/96}`, `from {(pppoe0:network)}`,
`from {<table>}`. `pfctl -sr` normalises to `pass in quick on tun464 inet6 all flags S/SA keep state label "..."`.

The text is identical for `K = optN` and for a plugin key; only the label differs between carriers.

### 6.2 What the interface model changes **[V conditions, L rule text]**

| Item | `internal_dynamic` (plugin `_interfaces()`) | `optN` (user assignment) |
|---|---|---|
| `antispoof log for tun464` | not emitted (`filter.inc:576`) | emitted |
| force-gw `pass out ... route-to ( tun464 192.0.0.2 ) from {(tun464)} to {!(tun464:network)}` (prio 10000) | not emitted (`filter.lib.inc:587`) | emitted (IPv4 gateway only) |
| bogon / private rules on the CLAT interface | registered, commented out unless the flags are set (`filter.lib.inc:330-369`, only `virtual` is skipped) | same |
| Firewall > Rules entry for the interface | yes (`Firewall/Menu/Menu.php:43`) | yes |
| `<key>ip` alias | no (`Rule.php:56` only `wan|lan|opt[0-9]+`) | yes |
| MVC rule priority | 400000 (`type` is not `group`) | 400000 |
| MVC rule after the interface record disappears | orphan, 600000, disabled | deleted by `cleanRules()` |

Antispoof for the tun itself is irrelevant to the inet6-in leg: with only `192.0.0.1` on the device it expands to
`block drop in log on ! tun464 inet from 192.0.0.1/32 to any` and `block drop in log inet from 192.0.0.1 to any`
(`parse.y:1570-1655`; link-local IPv6 networks are skipped by `pfctl_parser.c:1714`
`if ((flags & PFI_AFLAG_NETWORK) && p->ifindex > 0) continue;`).

### 6.3 Ordering against antispoof, default deny, bogon/private and user blocks

| Earlier/later rule | H, prio 1, quick | H, prio 1, non-quick (6rd style) | H, prio 500000 (docs example / IPsec style) | M, prio 400000, quick |
|---|---|---|---|---|
| antispoof of *another* interface whose network contains `CLAT6` (`block drop in log on ! pppoe0 inet6 from <wan /64>`; non-quick, earlier) | pass wins | pass wins | pass wins | pass wins |
| `Default deny` (prio 1, non-quick, earlier) | pass wins | pass wins | pass wins | pass wins |
| `Block all IPv6` (prio 1, quick, earlier; only when IPv6 is disabled) | block wins | block wins | block wins | block wins |
| virusprot / port-0 quick blocks (prio 1 core, earlier) | block wins if matched | same | same | same |
| bogon / private quick blocks on the CLAT interface (prio 5; only if enabled there) | never reached | block wins if source matches (`<bogonsv6>`, `fd00::/8,fe80::/10`) | block wins | block wins |
| user floating rules (200000) | never reached | a matching user rule decides | a matching quick user rule decides | a matching quick floating block wins |
| user group rules (300000+) | never reached | decides | quick ones decide | quick ones win |
| user rules on the CLAT interface (400000) | never reached | decides | quick ones decide | order by `sequence` |

Notes:

- The antispoof case is real when the CLAT /128 is taken from the WAN /64 or a LAN /64 (OpenWrt model): the
  translated packet enters on a different interface than the one owning that prefix. Because antispoof is
  non-quick and comes first, any later matching pass overrides it, with every carrier. **[V rule order, L runtime]**
- With H at prio 1 quick the user keeps control through the other legs (LAN in, tun out, WAN out), not through
  rules on the tun's inet6-in.
- `pass ... keep state` implies `flags S/SA`: a translated mid-stream TCP segment without state falls to the
  default deny, as for any other interface. **[L]**

### 6.4 reply-to / route-to summary **[V]**

- The inet6 pass rule: no `reply-to` in any combination (3.3).
- H additionally can pin this with `'disablereplyto' => 1`; M has the `disablereplyto` field (default 0).
- If the rule were `inet46` (os-tayga how-to style): the inet half becomes
  `pass in quick on tun464 reply-to ( tun464 192.0.0.2 ) inet from {any} to {any} keep state ...` in both interface
  models, because the interface mapping's `gateway` is set whenever the dynamic IPv4 gateway exists.
- `route-to`: only the force-gw rule, only for `optN`, only `out`.

---

## 7. What has to go at the af-to hand-over (27.1)

With a firewall-native `af-to` rule on LAN there is no tun, so the `in on tun inet6` pass has no purpose. PR
#10638 renders af-to on ordinary MVC filter rules (`gh/opnsense_core_10638.md:31-32`).

| Carrier | Interface model | Residue after the plugin is disabled or removed |
|---|---|---|
| H | `internal_dynamic` | none: hook stops registering, `plugins_interfaces()` drops the record (`plugins.inc:233-239`) |
| H | `optN` | the user's `optN` assignment (and anything the user attached to it) |
| M | `internal_dynamic` | the MVC rule stays in config.xml as an invalid rule (prio 600000) until someone deletes it |
| M | `optN` | rule and assignment stay until the user deletes the assignment, which also deletes the rule (`cleanRules()`) |

---

## 8. Items for a design decision

1. **Constraint exception.** A tun-based CLAT cannot forward without one inet6 pass-in rule on the tun, and core
   has no native way to supply it on 26.7 or master (section 2). The design has to accept exactly one such rule.
2. **Carrier.** H (plugin hook, non-persistent, documented, five in-tree precedents, clean removal) or M (rule
   planted in the user's rule set, no plugin precedent, editable by the user, config residue). The evidence in
   4.5 and 7 favours H; it is nevertheless what the requirements ask to avoid, so the choice needs a decision.
3. **Scope of the rule.** Address-less (`from any to any` on the tun, constant text, no reload dependency) versus
   address-bearing (source hygiene, needs a reload or a dynamic/table form at renumbering) - section 5.
4. **Position.** Prio 1 quick (cannot be overridden by user rules), prio 1 non-quick, or late (500000) - section
   6.3. In-tree convention for automatic pass rules also includes a settings toggle to turn them off.

## 9. Not established

- No runtime test: the final `rules.debug` lines, the antispoof interaction for a CLAT /128 inside the WAN /64,
  and the absence of `reply-to` should be confirmed with `pfctl -sr` / `pfctl -vvsr` on a 26.7 box.
- Whether opnsense/plugins reviewers accept an address-less automatic pass rule on a plugin-registered interface
  (no existing emitter binds a rule to its own registered interface).
- Behaviour of `(pppoe0:network)` for IPv6 on a PPP interface, and whether the WAN has a GUA /64 at all when the
  ISP only does DHCPv6-PD.
- stable/26.7 line numbers (cross-checks were content-level, from fetched excerpts).

## 10. Sources

Local clones: files cited inline.

Web:
- https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/etc/inc/filter.inc
- https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/etc/inc/filter.lib.inc
- https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/opnsense/mvc/app/library/OPNsense/Firewall/FilterRule.php
- https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/opnsense/mvc/app/library/OPNsense/Firewall/Plugin.php
- https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/opnsense/mvc/app/models/OPNsense/Firewall/FieldTypes/FilterRuleField.php
- https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/opnsense/mvc/app/models/OPNsense/Firewall/Filter.xml
- https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/etc/config.xml.sample
- https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/AssignmentController.php (200)
- https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/www/interfaces_assign.php (404), .../src/www/firewall_rules.php (404)
- https://docs.opnsense.org/development/backend/legacy.html
- https://docs.opnsense.org/development/api/core/firewall.html
- https://docs.opnsense.org/manual/how-tos/tayga.html
