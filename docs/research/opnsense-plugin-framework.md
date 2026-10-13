# OPNsense plugin hook framework for a plugin-owned tunnel device that must act as a WAN interface

Research date: 2026-10-10. Scope: facts only, no design.

## 0. Sources and version basis

All `file:line` references are relative to
`refs/` (local clones, not in this repository).

| Short name | What it is |
|---|---|
| `opnsense-core/...` | opnsense/core **master** (shallow clone fetched on the research date; contains commits dated 2026-10-10, i.e. 27.1 development) |
| `opnsense-plugins/...` | opnsense/plugins master |
| `gh/...` | saved GitHub threads |
| URLs | fetched on the research date and read as excerpts (quotes are short and line numbers approximate; re-open the URL before quoting) |

Important: the local core clone is **master**, not `stable/26.7`. The following were cross-checked against
`https://raw.githubusercontent.com/opnsense/core/stable/26.7/...` and found equivalent unless noted:
`src/etc/inc/plugins.inc` (same 11 functions, same `plugins_devices()` defaults), `src/etc/rc.bootup` (identical call order),
`src/etc/inc/interfaces.inc::interface_configure()` (same flush conditions, same switch labels, same queue names),
`src/etc/inc/filter.lib.inc` (same `internal_dynamic` test), `Routing/Gateways.php::getGateways()` (same dynamic gateway block, one small difference, see d.4),
`Interfaces/Api/AssignmentController.php` (exists, same public actions), `Interfaces/NetworkInterface.xml` (**differs**, see 3.5).
`src/www/interfaces_assign.php` returns HTTP 404 on stable/26.7, i.e. the MVC Assignments page is already what 26.7 ships.

---

## (a) The plugin hook surface

### a.1 Discovery and naming

`opnsense-core/src/etc/inc/plugins.inc:33-67` `plugins_scan($glob = '*')` globs `/usr/local/etc/inc/plugins.inc.d/<name>.inc`.
The function prefix is the file basename. A plugin whose name collides with `/usr/local/etc/inc/<name>.inc` or `<name>.class` is silently skipped (lines 51-62, comment "you found the reason why your plugin doesn't work").

`plugins.inc` defines exactly these collectors (line numbers in master):

| Collector | Line | Plugin function looked up | Return contract |
|---|---|---|---|
| `plugins_services()` | 69 | `<name>_services()` | list of service arrays |
| `plugins_devices()` | 94 | `<name>_devices()` | list of device-type arrays (see b) |
| `plugins_cron()` | 127 | `<name>_cron()` | list of `['autocron' => [cmd, minute, hour, mday, month, wday]]` |
| `plugins_syslog()` | 152 | `<name>_syslog()` | `[logname => ['facility' => [program, ...]]]` |
| `plugins_interfaces()` | 178 | `<name>_interfaces()` | `[interface_id => [prop => value]]` (see d) |
| `plugins_firewall($fw)` | 244 | `<name>_firewall($fw)` | none; mutates `OPNsense\Firewall\Plugin` |
| `plugins_configure($hook, $verbose, $args)` | 261 | `<name>_configure()` | `[event => ['func' or 'func:N', ...]]` |
| `plugins_run($hook, $args)` | 337 | `<name>_run()` | `[hook => callable]`; result collected per plugin |
| `plugins_xmlrpc_sync()` | 372 | `<name>_xmlrpc_sync()` | list of `['id','section','description','services','help']` |
| `plugins_argument_map(&$arg)` | 402 | helper for handlers | normalises `null` / comma string / array |

There is **no** `*_gateways` (or similar) hook. Gateways are derived only from `config.xml` + the `ifctl` router files (see d.4 and f).

### a.2 `plugins_configure()` argument conventions

`plugins.inc:261-335`:

* `$verbose` is unshifted as first argument (`array_unshift($args, $verbose)`, line 267).
* `$hook` may be `event:pluginname` to target a single plugin (`list($hook, $glob) = explode(':', $hook)`, lines 281-283).
* Each task is `'function'` or `'function:N'`; N = number of arguments passed **including** `$verbose`; default 1; capped to the number available (lines 304-315). `:0` passes nothing (e.g. `'openvpn_refresh_crls:0'`, `'filter_configure:0'`).
* Returns 1 when no handler ran, 0 otherwise (lines 265, 322). `\Error` is caught and logged (323-327).
* Every call logs `plugins_configure <hook> (<args>)` at LOG_INFO (line 279). Runtime example in `gh/opnsense_core_10828.md:344-358`: `plugins_configure newwanip (,[opt7],inet)` followed by `execute task : kea_newwanip(,[opt7],inet)`, `unbound_configure_do(,[opt7])`, `wireguard_sync()`.

CLI: `pluginctl [-q] <event> [args...]` (`opnsense-core/src/sbin/pluginctl:343-352`); `pluginctl` without arguments lists `event => plugins` (318-342). String arguments containing commas are turned into arrays by `plugins_argument_map()` (`plugins.inc:413-416`).

### a.3 Event names fired by core (who fires, with which arguments)

| Event | Fired from | Args after `$verbose` | Typical handler signature |
|---|---|---|---|
| `early` | `src/etc/rc.bootup:93` (after `interfaces_configure()` and a filter reload, before routing) | none | `openssh_configure_do`, `webgui_configure_do`, `unbound_cache_flush` |
| `dhcp` | `rc.bootup:96`; `interfaces.inc:854` (`['inet6', $track6]`), `:2495`, `:3616`; `system.inc:854`; `apply_pending_if_changes.php:78` | optional `$family`, `$ignorelist` | `radvd_configure_dhcp($verbose, $family, $ignorelist)` (`radvd.inc:99`) |
| `dns` | `rc.bootup:97`; `interfaces.inc:2496`; `apply_pending_if_changes.php:79`; configd `plugins configure dns` | none | `unbound_configure_do`, `dnsmasq_configure_do` |
| `monitor` | `rc.bootup:100`; `system.inc:816` (`[$gwnames]`); `rc.syshook.d/monitor/20-recover:73`; configd `interface monitor configure` | `$gwname_map` | `dpinger_configure_do($verbose, $gwname_map)` (`dpinger.inc:130`) |
| `vpn` | `rc.bootup:101`; `rc.newwanip:142`; `rc.newwanipv6:124`; `rc.reload_all:57`; `setports.php:47` | `$interfaces, $family` (only from rc.newwanip*) | `ipsec_configure_do:2`, `openvpn_configure_do:2`, `wireguard_configure_do` |
| `bootup` | `rc.bootup:102` (last call) | none | `ntpd_configure_do`, `unbound_configure_do`, `dhcrelay_configure_id`, `system_powerd_configure` |
| `newwanip` | `rc.newwanip:143`, `rc.newwanipv6:125` | `$interfaces` (array of interface ids), `$family` (`'inet'`/`'inet6'`) | `:1` none, `:2` `($verbose, $interface_map)`, `:3` `kea_newwanip($verbose, $interfaces, $family)` (`kea.inc:203`), `dhcrelay_configure_if` (`dhcrelay.inc:264`) |
| `local` | `rc.reload_all:56`; `setports.php:46` | none | service restart handlers |
| `updateip` | `interfaces.inc:2497` (`[[$interface]]`); `apply_pending_if_changes.php:80` | `$interface_map` | `rfc2136_configure_do:2` (plugins repo) |
| `ipsec` | `interfaces.inc:2494` (`[$interface]`); `apply_pending_if_changes.php:77`; `xmlrpc/legacy.inc:265` | `$interface_map` | `ipsec_configure_do:2` |
| `route_reload` | `ipsec.inc:1473` (list of VTI interface ids) | `$interface_map` | `system_routing_configure:2` (`core.inc:442`) |
| `dhcrelay` | `rc.syshook.d/carp/20-dhcrelay:39` | | |
| `webgui` | `setaddr.php:623` | | |

Private/named events invoked through `pluginctl -c <event>` by configd actions or other code (all registered in `core.inc:427-447` unless stated):
`crl`, `cache_flush`, `dns_reload`, `firmware_reload`, `networking_reload`, `syslog_reset`, `trust_reload`, `user_changed`,
`pfsync` (`pf.inc:53`), `loopback` (`loopback.inc:32`), `vxlan` (`vxlan.inc:33`), `openvpn`/`remote` (`openvpn.inc:38-39`), `radvd` (`radvd.inc:37`),
`kea_sync`/`kea_generate_dhcpv6` (`kea.inc:149-150`), `unbound_start`/`unbound_stop` (`unbound.inc:46-47`).
Plugins define their own the same way: `netbird_sync_config` (`opnsense-plugins/security/netbird/.../netbird.inc:71`), `caddy_sync`, `frr_sync`.
A plugin is therefore free to register a private event name and call it from its own configd action (`pluginctl -c myevent`), as `actions_interface.conf:203-205` does for vxlan.

Core tunnel plugins hooking WAN changes (precedent):
`wireguard_configure()` -> `'newwanip' => ['wireguard_sync'], 'vpn' => ['wireguard_configure_do']` (`wireguard.inc:145-151`);
`vxlan_configure()` -> `'newwanip' => ['vxlan_configure_do'], 'vxlan' => [...]` (`vxlan.inc:29-35`);
`ipsec_configure()` -> `'ipsec'`, `'vpn'` both `ipsec_configure_do:2` (`ipsec.inc:119-125`).

### a.4 `*_services()` keys

Consumed by `opnsense-core/src/etc/inc/util.inc:109-299`:
`name`, `description`, `id` (instance filter), `pidfile`, `nocheck` (always "running"), `noshow`, `locked`,
`configd => ['start'|'stop'|'restart' => ['<configd cmd>', ...]]`,
`php => ['start'|'restart'|'stop' => ['func', ...], 'args' => ['key', ...]]`,
`mwexec => [...]`. Start/restart precedence is configd > php > mwexec (`util.inc:215-235`, `276-296`); stop falls back to `killbypid(pidfile)` then `killbyname(name)` (`util.inc:259-264`).
Example of a tunnel plugin: `opnsense-plugins/net/tayga/src/etc/inc/plugins.inc.d/tayga.inc:36-54`.

### a.5 `*_run()` hooks known in core

`plugins_run()` (`plugins.inc:337-370`); CLI `pluginctl -r <hook> [args]` (`pluginctl:248-253`).

| Hook | Provider(s) | Consumer |
|---|---|---|
| `networks_source_nat` | `pf.inc:259`, `openvpn.inc:1332`, `ipsec.inc:1697` | `filter.lib.inc:184` (source networks of automatic outbound NAT) |
| `rules_source_nat`, `rules_destination_nat` | `pf.inc:260-261` | configd `actions_filter.conf:70,77` (`pluginctl -r ...`) |
| `host_routes` | `core.inc:452`, `dpinger.inc:305` | (no direct PHP caller found by grep in core) |
| `return_gateways_status`, `return_gateways_watcher` | `dpinger.inc:306-307` | `legacy_bindings.inc:185,191` |
| `static_mapping` | DHCP providers | `unbound.inc:657`, `dnsmasq.inc:239` |
| `dhcrelay_interfaces` | dhcrelay | `filter.lib.inc:206` |

### a.6 `*_firewall($fw)`

Called from `filter_configure_sync()` (`filter.inc:189`) with an `OPNsense\Firewall\Plugin` object. Public methods (`opnsense-core/src/opnsense/mvc/app/library/OPNsense/Firewall/Plugin.php`):
`registerAnchor` (223), `registerFilterRule` (260), `registerDestinationNatRule` (286), `registerForwardRule` (303), `registerStaticNatRule` (313), `registerDNatRule` (326), `registerSourceNatRule` (336), `registerSNatRule` (346), `registerNptRule` (356), `registerTable` (418).
Listed for completeness only; nothing in the WAN-ness logic below requires a plugin to use it.

### a.7 `*_syslog`, `*_cron`, `*_xmlrpc_sync`

* syslog: `plugins.inc:148-171`; e.g. `wireguard.inc:62-67` returns `['wireguard' => ['facility' => ['wireguard']]]`.
* cron: `system.inc:1108-1157`; e.g. `core.inc:300` `$jobs[]['autocron'] = ['/usr/local/sbin/configctl -d syslog archive', '1'];`
* xmlrpc: `plugins.inc:372-400`; e.g. `tayga.inc:56-64` (`'section' => 'OPNsense.tayga'`).

---

## (b) `*_devices()` contract in master

### b.1 Keys

Defaults (`plugins.inc:97-103`, identical on stable/26.7):

```php
'configurable' => true, /* allow to configure IP connectivity */
'pattern' => '^impossiblecontrolmatch$', /* never match by default */
'reload' => true, /* allow to reload on the fly */
'spoofmac' => true, /* allow to change the MAC address */
'volatile' => false, /* device known to persist */
```

All keys seen in use and their consumers:

| Key | Meaning / consumer |
|---|---|
| `pattern` | regex on device name. Used by `is_interface_mismatch()` (`console.inc:53-57`, only for `volatile` types), by the MAC-spoof guard in `interface_configure()` (`interfaces.inc:2324-2331`) and by legacy `interfaces.php:374-390` |
| `volatile` | device may be absent at boot; excluded from the boot-time "interface mismatch" check (`console.inc:66-68`) |
| `configurable` | if false, the GUI refuses an IPv4/IPv6 configuration type: legacy `interfaces.php:379-383`; MVC `NetworkInterface.php:314-327` via `DeviceField::isConfigurable()` (`DeviceField.php:70-77`) - message "Cannot assign an IP configuration type to a tunnel interface." |
| `spoofmac` | if false no MAC spoofing (`interfaces.inc:2326`, `NetworkInterface.php:307-312`) |
| `reload` | if true and the device is in `names`, `function` is called from `interface_configure(..., $reload = true)` (`interfaces.inc:2287-2298`); VLAN sets `false` (`core.inc:255`) |
| `function` | callable `function($device)`; creates/configures the device. Called by `interfaces_configure()` (boot / reload_all), `interface_configure()` on reload, and `pluginctl -d <device>` (`pluginctl:226-235`) |
| `names` | `[device => ['descr' => ..., 'ifdescr' => ..., 'name' => ..., 'exclude' => [...], 'ipaddr' => ...]]`; the enumerated instances. Drives the Assignments dropdown and the device/function map |
| `type` | short type id; `pluginctl -d` lists types, `pluginctl -d <type>` lists names (`pluginctl:215-225`) |
| `typedescr` | optgroup label in the Assignments dropdown (`list_assign_options.php:63`) |

Examples: `wireguard_devices()` (`wireguard.inc:101-122`): `function => 'wireguard_prepare'`, `configurable => false`, `type => 'wireguard'`, `volatile => true`, `pattern => '^wg'`, `names => $names`.
`ipsec_devices()` (`ipsec.inc:208-235`), `openvpn_devices()` (`openvpn.inc:116-153`), `loopback_devices()` (`loopback.inc:53-74`), `vxlan_devices()` (`vxlan.inc:37-57`), `core_devices()` (`core.inc:138-294`).
Minimal third-party form (pattern only, no names, no function): `tailscale_devices()` (`opnsense-plugins/security/tailscale/.../tailscale.inc:56-64`), `netbird_devices()` (`netbird.inc:37-45`), `zerotier_devices()`, `tinc_devices()`, `openconnect_devices()`.

Note: core already declares a catch-all volatile entry for tun/tap: `core.inc:291` `$devices[] = ['pattern' => '_stf|^tap|^tun|^ue', 'volatile' => true];`

### b.2 How a device appears in Interfaces > Assignments

`opnsense-core/src/opnsense/scripts/interfaces/list_assign_options.php:36-87` (configd `interface list assign-opts`, `cache_ttl:60`, `actions_interface.conf:81-86`):

1. "Hardware" group = `get_interface_list()` (`interfaces.lib.inc:607-665`), which drops any interface whose name, split on digits, contains one of `interfaces_virtual_patterns()` (`interfaces.lib.inc:563-595`: `_stf _vlan _wlan bridge carp enc gif gre ipfw ipsec l2tp lagg lo ng ovpnc ovpns pflog pfsync plip ppp pppoe qinq tap tun vlan vxlan wg`).
   Consequence: a device literally named `tunN` is **not** offered as hardware; a renamed tun (e.g. tayga's `nat64`, `tailscale0`, `wt0`, `ztXXXX`) **is** offered under "Hardware" as soon as it exists.
2. Then every `names` entry of every `*_devices()` result is added (overwriting a hardware entry of the same key) with `optgroup = typedescr ?? type`, plus `configurable` and `spoofmac` flags (`list_assign_options.php:57-77`).

The MVC model field `DeviceField` reads this list (`DeviceField.php:41-53`); `ApiControllerBase::runInterfaceRegistration()` invalidates the cache with `configdRun('!interface list assign-opts', false, 20)` (`ApiControllerBase.php:411-417`).

### b.3 Creation at boot and ordering

`rc.bootup:88-90`: `filter_configure_sync(true, false)`, `interfaces_hardware(true)`, `interfaces_configure(true)`.

`interfaces_dependencies()` (`interfaces.inc:676-754`) builds `$devices[name] = function` from every `*_devices()` entry that has both `function` and `names` (694-701), then sorts assigned, enabled, non-virtual interfaces into queues processed in this order (710-717):

```
hardware -> software -> track6 -> bridge -> dhcp6c -> unassigned
```

An interface goes to `software` when its `if` is one of the plugin device names (740-743); interfaces with `ipaddrv6 == dhcp6` go to `dhcp6c` (723-731); plugin device names not assigned to any interface end up in `unassigned` (748-751).

`interfaces_configure()` (`interfaces.inc:756-795`): for each queue item, first calls the device function for each required device (`log_msg("Device {$parent} required by ...")`, 774-780), then `interface_configure($verbose, $uuid, false, false, true, $plugins_devices)` (783).
So at boot the plugin's `function($device)` runs before core touches the assigned interface, and it also runs (last) when the device is not assigned at all.

Boot-blocking hazard: `rc.bootup:73-76` runs the console assignment prompt when `is_interface_mismatch()` is true. `console.inc:61-73`: an assigned non-virtual interface whose device does not exist is a mismatch **unless** the device matches a `volatile` pattern or **any** interface has `lock` set.

`interface_configure()` with `$reload = true` (GUI apply, `rc.configure_interface`, `rc.linkup`) calls the device function again when `reload` is true (`interfaces.inc:2287-2298`). devd only raises linkup events for `media-type "ethernet"` and `"802.11"` (`opnsense-core/src/etc/devd/ifnet.conf:6-31`), so a tun does not generate `rc.linkup` calls.

---

## (c) Assigned interface whose addressing is managed by a plugin

### c.1 Stored values

`interfaces.<id>.ipaddr` is either an IPv4 literal (static, with `subnet`), a type keyword (`dhcp`, `pppoe`, `ppp`, `l2tp`), or **absent/empty** for "None".
`ipaddrv6` is an IPv6 literal (with `subnetv6`), a keyword (`dhcp6`, `slaac`, `linklocal`, `6rd`, `6to4`, `idassoc6`, `track6`, `pppoev6`) or absent/empty.
Evidence: legacy page maps empty to type `none` (`src/www/interfaces.php:277-299`); MVC model in master uses a blank option (`NetworkInterface.xml:69-93`, `<BlankDesc>None</BlankDesc>`) and `toLegacy()` drops empty strings (`NetworkInterfaceField.php:93-99`); `legacy_config_get_interfaces()` normalises empty to `null` (`config.inc:358-359`).

### c.2 What `interface_configure()` does with ipaddr = ipaddrv6 = mtu = empty

`opnsense-core/src/etc/inc/interfaces.inc:2265-2508`:

| Step | Lines | Effect on a plugin-managed tun |
|---|---|---|
| return if not `enable` | 2270-2272 | nothing |
| reload: call device `function` | 2287-2298 | plugin hook runs (only when `$reload`) |
| `if (!empty($wancfg['ipaddr'])) interfaces_addresses_flush($device, 4, ...)` | 2308-2310 | **skipped** when ipaddr empty |
| `if (!empty($wancfg['ipaddrv6'])) interfaces_addresses_flush($realifv6, 6, ...)` | 2312-2314 | **skipped** when ipaddrv6 empty |
| MAC spoof, media, promisc | 2316-2413 | no-ops without config |
| `_interfaces_hardware($realhwif, ...)` | 2416 (body 569-661) | applies global offload settings via `ifconfig <dev> [-]txcsum ...`; same path wg/ovpn devices take |
| `if (!empty($wancfg['mtu'])) interface_configure_mtu(...)` | 2418-2420 | **skipped** without `mtu` |
| `switch ($wancfg['ipaddr'] ?? 'none')` default -> `interface_static_configure` | 2429-2436, 2197-2204 | returns early (not an IPv4) |
| `ifconfig %s inet6 -accept_rtadv description %s up` | 2446 | **always**: sets description `"<DESCR> (<id>)"`, disables accept_rtadv, brings device up |
| `switch ipaddrv6` case `none` | 2474-2476 | comment: "no extra changes: \"no_dad\" and \"ifdisabled\" is not touched esp. relevant for tunnels" |
| VIPs, neighbors, bridge | 2484-2488 | |
| if `$reload && !$batch`: `system_routing_configure($interface)`, events `ipsec`, `dhcp`, `dns`, `updateip` | 2492-2498 | **no** `newwanip` event here |

`interfaces_addresses_flush()` never removes link-local addresses (`interfaces.inc:2222-2224`).

### c.3 What `interface_reset()` does

`interfaces.inc:815-910`. Runs on GUI apply (`apply_pending_if_changes.php:48-57`, `apply_legacy_if_changes.php:44`) and `interface_suspend()`.
With empty ipaddr/ipaddrv6 no address is flushed (871-901 are guarded by `!empty(...)`), but it **always** ends with

```php
mwexecf('/usr/local/sbin/ifctl -4c -i %s', $device);
mwexecf('/usr/local/sbin/ifctl -6c -i %s', $realifv6);
```

(lines 908-909), which deletes `/tmp/<dev>_router`, `_nameserver`, `_prefix`, `_searchdomain` (v4 and v6) and runs `arp -d -i <dev> -a` (`ifctl.sh:142-168`). The following `interface_configure(true, $ifname, true, ...)` then calls the device function (reload).

### c.4 Flags

* `lock`: prevents removal in the Assignments API (`AssignmentController.php:86-94`, "Interface locked, unset lock first before removal"), is labelled "Prevent interface removal" (`interfaces.php:1081-1084`), and suppresses the boot-time mismatch prompt for the whole system when set on any interface (`console.inc:62-65`). New MVC assignments default to `lock = 1` (`NetworkInterface.xml:30-33`). It does not protect addresses.
* `virtual`: interface is skipped by `interfaces_configure()`/`interface` restart loops (`interfaces.inc:722, 3627`), hidden from the Interfaces menu (`Interfaces/Menu/Menu.php:65`), from Assignments (`NetworkInterface.php:59-62`), from gateway enumeration (`Gateways.php:266`) and from the Gateways interface selector (`Gateways.xml:27-30`, `<virtual>/^(?!1).*$/</virtual>`); no `<id>ip` address alias (`FilterBaseController.php:227-229`); no bogon/private rules (`filter.lib.inc:332-334`).
* `internal_dynamic`: set automatically for everything returned by `*_interfaces()` (`plugins.inc:213-216`) and used for garbage collection (`plugins.inc:186-190, 233-239`). Effects: excluded from `InterfaceField` selectors unless the field sets `AllowDynamic` (`Base/FieldTypes/InterfaceField.php:119-128`); no `antispoof` rule (`filter.inc:576`); no "let out anything from firewall host itself (force gw)" rule (`filter.lib.inc:587`); no Settings cog in Interfaces: Overview (`views/OPNsense/Interface/overview.volt:130-133`).
* `gateway_interface` ("Dynamic gateway policy": "This interface does not require an intermediate system to act as a gateway", `interfaces.php:1252-1260`): makes `Gateways::getGateways()` emit an address-less, interface-bound gateway (`Gateways.php:442-454`), rendered by pf as `route-to <if>` (`Firewall/Plugin.php:105-116`).

### c.5 26.7.6 hazard: the new Assignments page writes `ipaddr = none`

* `https://github.com/opnsense/core/issues/10996` (opened and closed 2026-10-10, label bug, milestone 27.1), title: "26.7.6: saving a WireGuard interface via the new assignments MVC/API writes ipaddr=none and strips the tunnel address on apply". Per the report, `toLegacy()` wrote the literal `none`, `interface_configure()` saw a non-empty `ipaddr` and flushed the addresses the tunnel daemon had added; 26.7.5 (legacy page) did not.
* Fix in master: `https://github.com/opnsense/core/commit/099b68a.diff` ("interfaces: do not render \"none\" to configuration #10996") replaces `<Required>Y</Required><Default>none</Default>` + `<none>None</none>` by `<BlankDesc>None</BlankDesc>` for `type4` and `type6`; follow-up `180f245`; `0bcd1e0` adds the `configurable`/`spoofmac`/unique-description validations.
* The local master clone contains these fixes (`NetworkInterface.xml:69-93`, `NetworkInterface.php:307-327`).
* stable/26.7 today still has the `none` option: `https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/opnsense/mvc/app/models/OPNsense/Interfaces/NetworkInterface.xml` (`<Default>none</Default>`, `<none>None</none>`), and the commit list `https://github.com/opnsense/core/commits/stable/26.7/src/opnsense/mvc/app/models/OPNsense/Interfaces` ends at `5b0605a` (Oct 9) / `786c2e0` (Oct 7, "add interface configuration settings in new assignments page") without `099b68a`.

This is direct confirmation of the mechanism in c.2: any non-empty `ipaddr`/`ipaddrv6` value, including the string `none`, makes core flush that family on every `interface_configure()`.

### c.6 Precedents of "plugin sets the addresses, core leaves them alone"

* WireGuard: `opnsense-core/src/opnsense/scripts/wireguard/wg-service-control.php:65-150` creates the device, adds addresses with `ifconfig <wg> inet|inet6 <addr> alias` (75-78), sets MTU (79-81), then `interfaces_restart_by_device(false, [device])` when (re)created (138-140) and finally `configd_run('filter reload')` after a restart (336-339).
  `interfaces_restart_by_device()` (`interfaces.inc:3623-3642`) runs `interface_configure()` for every enabled non-virtual interface using that device and then `system_routing_configure($verbose, <those interfaces>)`.
* IPsec VTI: `ipsec_configure_vti()` (`ipsec.inc:1559-1673`) creates `ipsecN` and sets point-to-point addresses itself, then `plugins_configure('route_reload', $verbose, [<vti ids>])` (`ipsec.inc:1473`).
* GRE/GIF (core): after configuring the tunnel core writes the remote end as router: `ifctl -i <gre> -4|-6 -rd -a <remote>` with the comment "XXX: write XXX_router file" (`interfaces.inc:459-464`, `556`).
* OpenVPN: `ovpn-linkup` (`plugins.inc.d/openvpn/ovpn-linkup:27-30`) writes `ifctl -4rd -i <dev> -a <gw>` / `-6rd` and then `configctl -d interface newip <dev> force`; `ovpn-linkdown:3-4` clears both.

---

## (d) `*_interfaces()` contract (automatic registration)

### d.1 Mechanism

`plugins_interfaces()` (`plugins.inc:178-242`): for every returned `id => props` it creates/updates `config.xml` `interfaces.<id>`, sets `internal_dynamic = true`, copies each property when different, and afterwards **deletes** every `internal_dynamic` interface that no plugin returned any more. Returns true when something changed; the caller must save.

When it runs:
* inside every legacy `write_config()` ("XXX temporary workaround for legacy interface creation", `config.inc:214-219`);
* `pluginctl -i` -> `if (plugins_interfaces()) write_config('Updated plugin interface configuration')` (`pluginctl:242-245`);
  called at boot from `convert_config()` (`config.inc:175-176`, invoked at `rc.bootup:63`) and via configd `interface invoke registration` (`actions_interface.conf:68-72`);
* from plugin service controllers: `ApiMutableServiceControllerBase::reconfigureAction()` calls `runInterfaceRegistration()` when the controller overrides `invokeInterfaceRegistration()` to return true (`ApiMutableServiceControllerBase.php:155-158, 201-203`); tayga does exactly that (`opnsense-plugins/net/tayga/.../Api/ServiceController.php:44-47`). The same base class offers `invokeFirewallReload()` -> `filter reload skip_alias` (163-166, 205-207).

### d.2 Properties seen

| Plugin | id | Properties |
|---|---|---|
| `loopback_interfaces()` (`loopback.inc:36-51`) | `lo0` | `descr, enable, if, ipaddr, ipaddrv6, subnet, subnetv6, type => 'none', virtual => true` |
| `wireguard_interfaces()` (`wireguard.inc:69-87`) | `wireguard` | `descr, if => 'wireguard', virtual, enable, type => 'group', networks => []` |
| `openvpn_interfaces()` (`openvpn.inc:100-114`) | `openvpn` | same shape (group) |
| `pf_interfaces()` (`pf.inc:90-106`) | each firewall group | group shape |
| `ipsec_interfaces()` (`ipsec.inc:168-206`) | `enc0` | `enable, if, descr, type => 'none', virtual => true` |
| `ipsec_interfaces()` | `ipsecN` (one per VTI) | `enable, descr, if => 'ipsecN', type => 'none'` - **not virtual** |
| `tayga_interfaces()` (`tayga.inc:66-80`) | `tayga` | `enable, if => 'tayga', descr => 'Tayga', type => 'group', virtual => true, networks => []` |
| `tinc_interfaces()`, `openconnect_interfaces()` | `tinc`, `ocvpn` | virtual, type none/group |

Any property is written verbatim (`plugins.inc:218-227`), so the set is open-ended; only the ones above have precedent.
The group form relies on a pf interface group of the same name: tayga's rc script does `ifconfig nat64 group tayga` (`opnsense-plugins/net/tayga/src/etc/rc.d/opnsense-tayga:29`), wireguard `ifconfig %s group wireguard` (`wireguard.inc:136`).

### d.3 Capabilities and limits of registered interfaces

| Question | Virtual (`virtual => true`) | Non-virtual `internal_dynamic` (IPsec VTI style) | Evidence |
|---|---|---|---|
| Firewall rules "tab" (MVC rules UI) | yes | yes | `Firewall/Api/FilterController.php:383-392` lists every `interfaces` child except `lo0` |
| Selectable in filter rules / source NAT / NPT / one-to-one / DNAT | yes | yes | `Firewall/Filter.xml:86-92` (rules), `510-516` (snatrules), `627-634` (npt), `694-701` (onetoone), `Firewall/DNat.xml:16-22`: `<AllowDynamic>Y</AllowDynamic>`, only `lo0` filtered |
| Can carry a gateway | **no** | **yes** | `Gateways.php:261-275` skips virtual; `Gateways.xml:23-31` `AllowDynamic Y`, `virtual != 1` |
| Automatic dynamic gateway from `/tmp/<dev>_router` | no | yes | `Gateways.php:386-441` iterates non-virtual enabled interfaces |
| Automatic outbound NAT | no (cannot have gateway) | yes when it has a gateway | `filter.lib.inc:186-190` iterates all enabled interfaces, no `internal_dynamic` test |
| `interface_configure()` at boot | no | yes | `interfaces.inc:722` filter `['enable' => true, 'virtual' => false]` |
| `rc.newwanip <dev>` accepted | n/a | yes | `rc.newwanip:53-60` only needs `convert_real_interface_to_friendly_interface_name()` (`interfaces.inc:3449-3471`, searches all interfaces) and `enable` |
| Interfaces menu entry / Assignments grid | no | yes | `Menu.php:63-67`, `NetworkInterface.php:57-65` (only `virtual` is skipped) |
| antispoof / force-gw rules | no | no | `filter.inc:576`, `filter.lib.inc:587` |
| Offered in ordinary `InterfaceField` selectors (DHCP, Unbound, ...) | no | no | `InterfaceField.php:122-123` (default `AllowDynamic` off) |
| Survives plugin disable | no, deleted on next registration run | same | `plugins.inc:233-239`; rules referencing it are not cleaned by this path |

"WAN" is not a stored attribute. Core derives it from "has a gateway for this family":
`filter_core_get_initialized_plugin_system()` sets `$value['gateway'] = $gateways->getInterfaceGateway($key, "inet", true)` for every enabled interface whose `ipaddr` is not a static IPv4 (`filter.lib.inc:60-73`);
`filter_auto_source_nat()` then NATs on every interface with `substr($ifcfg['if'], 0, 4) != 'ovpn' && !empty($ifcfg['gateway'])` (`filter.lib.inc:176-195`), generating "Automatic outbound rule" entries per source network (`filter.inc:208-226`);
`pf_get_default_nat_outbound_networks()` lists as source networks the interfaces with `!empty(ifconfig.ipv4) && empty(gateway)` (`pf.inc:285-300`).
Automatic rules exist only in outbound NAT modes `''`, `automatic`, `hybrid` (`filter.lib.inc:181`).

### d.4 How a gateway appears without anything in `config.xml`

`Gateways::getGateways()` (`opnsense-core/src/opnsense/mvc/app/models/OPNsense/Routing/Gateways.php:386-469`), for each enabled non-virtual interface and each family:

* default name `strtoupper("{$descr}_{$ctype}")`, `ctype` = interface type keyword or `GW` when none (`395-402`, `283-306`); `"dynamic" => true, "virtual" => true`, monitoring disabled by default (`404`);
* default priority 255 for devices starting with `gre`, `gif`, `ovpn`, `wg`, `ipsec`, otherwise 254 (`412-421`);
* `elseif (($router = Autoconf::getRouter($device, $ipproto)) != null) { $thisconf['gateway'] = $router; ...` (`435-441`) -> a gateway exists as soon as `/tmp/<device>_router` (v4) or `_routerv6` exists;
* else if `gateway_interface` is set on the interface (or device starts with `ovpnc`): address-less interface gateway (`442-454`). Master additionally sets `$thisconf['ipprotocol'] = ''` and `break`s (451-454); the fetched stable/26.7 excerpt does not show these two lines;
* a `gateway_item` configured in System > Gateways for the same interface/family with a non-IP gateway value overrides the defaults (`376-383`, `423-432`).

`getDefaultGW()` picks the first non-disabled, non-defunct, non-loopback gateway of the family in priority order (`493-513`).

`system_routing_configure()` (`system.inc:657-818`):
* refuses when the gateway device has no address of that family: `"ROUTING: refusing to set interface route on addressless ..."` (682-685) and `"ROUTING: refusing to set {$ipproto} gateway on addressless ..."` (714-717);
* `system_interface_route()` (`559-615`): for a dynamic IPv4 gateway that is outside the interface's primary network it logs `"ROUTING: treating '<gw>' as far gateway for '<net>'"` and runs `route add -inet <gw> -interface <dev>` (574-586, 611-614);
* `system_default_route()` (`617-655`): `route delete -inet default` / `route add -inet default <gw>`;
* finally `plugins_configure('monitor', $verbose, [$gwnames])` (800-817).
Runtime trace of exactly this path on a /32 PPPoE address: `gh/opnsense_core_10828.md:307-314`.

---

## (e) Creating / removing a real assigned interface (`optN`) programmatically

Precedent search:
* opnsense/plugins: `grep` for writes to `$config['interfaces'][...]`, `interfaces->addChild`, `'opt' .` in `*.php|*.inc|*.py|*.sh|*.conf` finds **only reads**. No plugin creates an `optN` entry. The only automatic mechanism plugins use is `*_interfaces()` (d).
* core:
  * console assignment: `console.inc:436-446` - `config_read_array('interfaces', 'opt' . ($i + 1)); $config['interfaces']['opt'.N]['if'] = ...; ['enable'] = true;` and for removal `interface_reset('optN'); unset($config['interfaces']['optN']);` followed by `write_config()`.
  * setup wizard: `Core/InitialSetup.php:289, 379` (`$target->interfaces->addChild('wan'|'lan')`).
  * MVC Assignments: `NetworkInterface::serializeToConfig()` (`NetworkInterface.php:169-196`) picks the first free `opt<N>`, `interfaces->addChild($newIdentifier)`, writes only `if` and `descr`, and parks everything else in `/tmp/.interfaces.todo` (`store_if_todo`, 46-52) with `pending_action => 'update'`. Same code on stable/26.7 (fetched).
  * Apply: `AssignmentController::reconfigureAction()` (`AssignmentController.php:140-193`): `configdRun("interface apply")` -> `apply_pending_if_changes.php` (reset, set `$config['interfaces'][$ifname] = pending`, `interface_configure(true, $ifname, true, false, true)`, `system_routing_configure`, events `ipsec/dhcp/dns/updateip`, lines 43-84), then under `Config::getInstance()->lock()` copies pending into config, `Config::getInstance()->save()`, `flush_todo()`, `configdRun('filter reload skip_alias', true)`.
  * Delete: `delItemAction()` refuses while the interface is member of a group/bridge/gre/gif or has `lock` (`61-98`); on apply `cleanRules($key)` strips the interface from `filter.rule`, `nat.rule`, `nat.outbound.rule` and the MVC `rules`, `snatrules`, `npt`, `onetoone` sections, deleting rules that reference only it (`100-138`), then `unset(...->interfaces->$key)` (155-157).

Available APIs for code that wants to do it:
* HTTP API: `POST /api/interfaces/assignment/add_item`, `set_item/<id>`, `del_item/<id>`, `reconfigure` (`AssignmentController.php:46-59, 61, 140`).
* MVC low level: `Config::getInstance()->lock(); ...object()->interfaces->addChild(...)...; Config::getInstance()->save();` (pattern at `AssignmentController.php:150-185`).
* Legacy: `config_read_array('interfaces', 'optN')` / `unset(...)` + `write_config($desc)` (`config.inc:199-237`), which also runs `plugins_interfaces()`.
* `pluginctl` has no switch for this (`pluginctl:160-181` help text; `-i` only runs registration).

---

## (f) `ifctl`

`/usr/local/sbin/ifctl` -> `opnsense/scripts/interfaces/ifctl.sh` (`opnsense-core/src/sbin/ifctl.link:1`), man page `opnsense-core/src/man/man8/ifctl.8` ("display or modify network device related data used by dynamic connections").

On-disk state (`ifctl.sh:30, 234`): `FILES="nameserver prefix router searchdomain"`, file name `/tmp/<device>_<kind>` for IPv4 and `/tmp/<device>_<kind>v6` for IPv6; optional fallback set `/tmp/<device>:slaac_<kind>v6` read only when the exact file is missing (`ifctl.sh:298-301`, man lines 53-61). One value per line. The key is the **device** name, not the interface id.

Flags (`ifctl.sh:81-136`, man 64-120): `-i device`; `-4` (default) / `-6`; mode `-n` nameserver (default), `-r` router, `-p` prefix, `-s` searchdomain;
`-a data` append (repeatable); `-d` delete-then-append (replace); `-u` atomic update, exit status 0 only if the content changed (`ifctl.sh:271-280`); `-c` clear all four kinds for the device and family and `arp -d -i <if> -a` (142-168); `-f` flush SLAAC addresses; `-l` list files; `-O` dump; `-V` debug. Prefix mode also installs/removes a blackhole route for non-/64 prefixes (`ifctl.sh:37-55, 287-292`).

Typical writer idiom: `ifctl -i <dev> -4rd -a <router>` (replace router), `ifctl -i <dev> -4rd` (remove), `ifctl -i <dev> -6nd -a <ns1> -a <ns2>`.

Writers in core: `dhclient-script:44,109,143,156,173,193`; `dhcp6c_script.sh:51,57,64,73,87-89`; `rtsold_script.sh:60`; `rtsold_resolvconf.sh:80-82`; `ppp-linkup.sh:27-28,32-33`; `ppp-linkdown.sh:13-14,20-23`; `ovpn-linkup:27-28`; `ovpn-linkdown:3-4`; GRE/GIF/6rd/6to4 in `interfaces.inc:460,556,2699,2785`; cleanup in `interface_reset()` (`interfaces.inc:908-909`).

Readers:
* `OPNsense\Interface\Autoconf` (`opnsense-core/src/opnsense/mvc/app/library/OPNsense/Interface/Autoconf.php:36-80`): `getRouter($if, $ipproto)`, `getNameserver`, `getPrefix`, `getSearchdomain`, `all($if)`; reads the first line set of `/tmp/{$if}{''|':slaac'}_{type}{''|'v6'}`.
* Gateways model (`Gateways.php:435`), `system_interface_route()` (`system.inc:574`), `rc.newwanip:71`.
* DNS: `get_nameservers()` (`system.inc:349-481`) uses `ifctl -nl` (only when `system.dnsallowoverride` is set), honours `dnsallowoverride_exclude`, and pairs each nameserver with `ifctl -<4|6> -ri <dev>` as host-route gateway; `get_searchdomains()` uses `ifctl -sl` (`system.inc:329`). `system_resolvconf_generate()` then writes `/etc/resolv.conf` and host routes (`system.inc:191-253`).
* GUI: Interfaces Overview shows them as "Dynamic router received" etc. (`Interfaces/Api/OverviewController.php:101-104, 159-161`).

---

## (g) configd actions, templates, rc.d + rc.conf.d, syshooks, packaging

* Actions: `/usr/local/opnsense/service/conf/actions.d/actions_<name>.conf`; section `[a.b]` is called as `configctl <name> a b [params]`. Fields: `command`, `parameters` (`%s` placeholders), `type` (`script` returns OK/Error, `script_output` returns stdout, `stream_output`, `inline`), `message`, optional `description` (exposes the action in the cron UI), `cache_ttl`, `allowed_groups`, `errors:no`. Examples: `opnsense-core/src/opnsense/service/conf/actions.d/actions_interface.conf` (e.g. 26-36 `newip`/`newipv6`, 68-72 `invoke.registration`), `actions_wireguard.conf:1-25`, tayga `opnsense-plugins/net/tayga/src/opnsense/service/conf/actions.d/actions_tayga.conf:1-26` (note `start` = `rc.d/opnsense-tayga start; /usr/local/etc/rc.routing_configure`).
  `configctl` flags: `-d` detach, `-q` quiet, `-e` event handler mode, `-t`, `-w` (`opnsense-core/src/man/man8/configctl.8:48-72`). PHP: `configd_run($cmd, $detach)` / `configdp_run($cmd, $params, $detach)` (`legacy_bindings.inc:38-56`); MVC: `(new Backend())->configdRun()` / `configdpRun()`.
* Templates: `/usr/local/opnsense/service/templates/<Vendor>/<Module>/+TARGETS` with `source:destination` lines; Jinja2 with the config tree and `helpers.exists()`, `helpers.toList()`, `helpers.getNodeByTag()`, `helpers.physical_interface(<interface id>)`. Rendered by `configctl template reload <Vendor>/<Module>` (`actions_template.conf:1-7`) and for all modules at boot by `rc.syshook.d/early/15-templates` (`template_ctl.py \*`). Examples: tayga `+TARGETS` (`tayga:/etc/rc.conf.d/opnsense-tayga`, `tayga.conf:/usr/local/etc/tayga.conf`); ndp-proxy-go `ndp_proxy_go:/etc/rc.conf.d/ndp_proxy_go` using `helpers.physical_interface(general.upstream)` (`.../NdpProxy/ndp_proxy_go:8`).
* rc.d + rc.conf.d: the plugin ships `/usr/local/etc/rc.d/<script>` and a template writing `/etc/rc.conf.d/<name>` with `<name>_enable="YES"`. `rc.freebsd` (`opnsense-core/src/etc/rc.freebsd:29-156`) sources `/etc/rc.conf.d/*`, orders scripts with `rcorder`, runs only those whose `rcvar` is YES, and honours `<name>_defer` and `<name>_skip`. It is invoked by `rc.syshook.d/start/20-freebsd:4` at boot (`rc.freebsd start`), by `rc.reload_all:60-61` (stop then start) and by `rc.syshook.d/stop/80-freebsd:3` (`rc.freebsd stop`).
  tayga has no `tayga_configure()` at all; it relies purely on this boot path (`tayga.inc` has only services/xmlrpc/interfaces; rc script `opnsense-tayga:22-34` starts the daemon, `sleep 1`, then `ifconfig nat64 inet ...`, `ifconfig nat64 group tayga`, `route add ...`).
* Syshooks: `/usr/local/etc/rc.syshook.d/<level>/NN-name`, run in sorted order by `rc.syshook <level> [args]` (`opnsense-core/src/etc/rc.syshook:44-77`; comment suggests `20-` for core and `50-` for plugins). Levels present in core: `early`, `import`, `start`, `stop`, `carp`, `monitor`, `update`, `upgrade`. `carp` receives `<subsystem> <MASTER|BACKUP|INIT>` (`actions_interface.conf:50-54`; e.g. `carp/20-wireguard` -> `configctl -dq wireguard configure $1`).
* Packaging (`opnsense-plugins/Mk/plugins.mk:178-217`, `Templates/*`): `src/` is installed under `/usr/local`; `+POST_INSTALL` is auto-generated to restart configd when `actions.d` exists, run model migrations, run `/usr/local/etc/rc.configure_plugins POST_INSTALL` (flushes caches, `opnsense-core/src/etc/rc.configure_plugins:41-49`), and `configctl template reload <dir>` per template directory. `.pre`/`.post` script fragments are supported (155-165). Dependencies via `PLUGIN_DEPENDS` (`opnsense-plugins/net/tayga/Makefile:4`).

---

## (h) Boot ordering and events for something that depends on WAN IPv6

### h.1 Boot sequence

`opnsense-core/src/etc/rc`: `touch /var/run/booting` (224-227) -> `rc.syshook early` (232; `10-configd` starts configd, `15-templates` renders all templates) -> `flock ... rc.bootup` (240) -> `rc.syshook start` (243).

`rc.bootup:63-102`: `convert_config()` (migrations + `pluginctl -i`), `system_devd_configure`, `system_login_configure`, mismatch check, loopback, kernel/sysctl/timezone/firmware/trust/hostname/resolver/syslog, then

```
filter_configure_sync(true, false); interfaces_hardware(true); interfaces_configure(true);
system_resolver_configure(true); filter_configure_sync(true);
plugins_configure('early', true);
system_routing_configure(true, null, 'ignore');
plugins_configure('dhcp', true); plugins_configure('dns', true);
filter_configure_sync(true);
plugins_configure('monitor', true); plugins_configure('vpn', true); plugins_configure('bootup', true);
```

`rc.syshook start`: `10-newwanip` replays deferred WAN events, `20-freebsd` starts rc.d services, then `25-syslog`, `90-carp`, `90-cron`, `90-openvpn`, `90-sysctl`, `95-beep`.

While booting (`product::booting()` = `/var/run/booting` is flock'ed, `config.inc:50-56`), `rc.newwanip`, `rc.newwanipv6`, `rc.linkup`, `rc.configure_interface`, `rc.routing_configure`, `rc.reload_all` exit immediately via `exit_on_bootup()` (`util.inc:316-325`). `rc.newwanip`/`rc.newwanipv6` first drop a marker `/tmp/newwanip_<dev>` / `/tmp/newwanipv6_<dev>` ("IP renewal deferred during boot", `rc.newwanipv6:44-47`), and `rc.syshook.d/start/10-newwanip:3-17` later runs `configctl -dq interface newip <dev> force` / `newipv6 <dev> force`.
So WAN address events that happen during boot reach plugin `newwanip` handlers only after `rc.bootup` finished, and before/around the rc.d service start of `20-freebsd`.

### h.2 `rc.newwanipv6` (WAN IPv6 event)

`opnsense-core/src/etc/rc.newwanipv6`: args `<device> [reason]` (39-40); requires the interface to be enabled (57-60); single-instance lock per device (62-70); `waitfordad(2)`; `system_resolver_configure()`; then

```php
if (empty($reason)) {
    /* we used to log here but many have complained about spurious log lines caused by RAs */
    return;
}
```

(78-81). Only with a reason does it continue: VIPs, linked GRE/GIF, `ifgroup_setup()`, `system_routing_configure(false, $interfaces, true, 'inet6')`, `filter_configure_sync()`, and finally

```php
plugins_configure('vpn', false, [$interfaces, $family]);
plugins_configure('newwanip', false, [$interfaces, $family]);
```

(117-125), where `$interfaces` = the WAN interface id followed by its tracking LAN ids and `$family = 'inet6'`.

Who calls `configctl interface newipv6` and with which reason:

| Caller | Reason passed | Evidence |
|---|---|---|
| `dhcp6c_script.sh` on `REQUEST`/`SOLICIT` | the reason name (forces) | `dhcp6c_script.sh:59-65, 82` |
| `dhcp6c_script.sh` on `RENEW`/`REBIND`/`INFOREQ` | forced only if the delegated prefix list changed (`ifctl -6pu` returned 0), else empty | `dhcp6c_script.sh:67-82` |
| `dhcp6c_script.sh` on `EXIT`/`RELEASE` | empty | `dhcp6c_script.sh:84-92` |
| `rtsold_resolvconf.sh` (RA with RDNSS/DNSSL or router change) | empty | `rtsold_resolvconf.sh:80-87` |
| `ppp-linkup.sh` for `inet6` when `ppp-ipv6.php` exits non-zero | `force` | `ppp-linkup.sh:31-37`; `ppp-ipv6.php:54-69` exits 0 for `dhcp6`/`slaac` (it starts the DHCPv6/rtsold machinery instead) and 1 for static/other |
| `ppp-linkdown.sh` for `inet6` | empty | `ppp-linkdown.sh:17-25` |
| boot replay | `force` | `rc.syshook.d/start/10-newwanip:11-17` |

Consequences that follow directly from the code: (1) the `newwanip` plugin event with family `inet6` fires on DHCPv6 (re)connect and on delegated-prefix change, and on the boot replay; (2) RA-only changes (pure SLAAC address/prefix change, router change), DHCPv6 RELEASE/EXIT and PPP IPv6 link-down call `rc.newwanipv6` **without** reason and therefore do **not** reach plugin handlers.

### h.3 `rc.newwanip` (IPv4 event, also usable for a plugin device)

`opnsense-core/src/etc/rc.newwanip`: args `<device> [force]`; resolves the interface by device (53); returns if the interface is missing/disabled (57-60) or has no IPv4 address ("Failed to detect IP", 65-69) or if the address equals `/tmp/<dev>_oldip` and not forced (79-82). Otherwise: `system_routing_configure(false, [$interface], true, 'inet')`, `filter_configure_sync()`, kills states of the old address / old gateway (127-138), then `plugins_configure('vpn', ...)` and `plugins_configure('newwanip', false, [$interfaces, 'inet'])` (142-143).
OpenVPN uses this for its own tun: `ovpn-linkup:30` `configctl -d interface newip ${1} force`.

### h.4 Other relevant entry points

* `configctl interface reconfigure <id>` -> `rc.configure_interface` -> `interface_configure(true, <id>, true)` (`actions_interface.conf:1-6`, `rc.configure_interface:39-41`).
* `configctl interface routes configure` -> `rc.routing_configure` -> `system_routing_configure(true, null, ...)` + `filter_configure_sync(true, false)` (`actions_interface.conf:166-170`, `rc.routing_configure:72-79`).
* `configctl filter reload [skip_alias]` -> `rc.filter_configure` (`actions_filter.conf:1-5`).
* `pluginctl -c route_reload <ids>` -> `system_routing_configure:2`.

---

## Summary table: what makes an interface behave as IPv4 WAN in core

| Requirement | Where enforced |
|---|---|
| Entry in `config.xml` `interfaces`, `enable` set, not `virtual` | `Gateways.php:261-275, 386-390`; `rc.newwanip:57` |
| Device has an IPv4 address | `system.inc:682-685, 714-717`; `rc.newwanip:65-69`; `dpinger.inc:186-196` |
| A gateway for the interface: `/tmp/<dev>_router`, or `gateway_interface`, or a configured gateway item | `Gateways.php:423-454` |
| Routing applied | `system_routing_configure()` via `rc.newwanip`, `interfaces_restart_by_device()`, `route_reload`, `rc.routing_configure` |
| Automatic outbound NAT | `filter.lib.inc:176-195`, `filter.inc:208-226` (modes automatic/hybrid only) |
| `ipaddr` must stay empty (or the plugin addresses are flushed) | `interfaces.inc:2308-2310`, `871-901`; issue #10996 |
