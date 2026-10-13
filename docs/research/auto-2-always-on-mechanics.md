# auto-2: OPNsense mechanics and side effects of an always-on, self-activating os-clat

Research date: 2026-10-11. Code reading only; nothing was run on a box.
DHCPv4 option 108 is out of scope and is not considered anywhere below.

Confidence tags: **[V]** verified (primary source read, quote given), **[L]** likely (inferred from code that was read, not executed), **[U]** unverified.

Path shorthands

- `CORE/` = `refs/opnsense-core/src/` (opnsense/core master)
- `PLUGINS/` = `refs/opnsense-plugins/` (opnsense/plugins master)
- `SRC/` = `refs/opnsense-src/` (opnsense/src stable/26.7, sparse)
- `STABLE:` = `https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/` (fetched 2026-10-11 as excerpts)

Cross-check of stable/26.7 against master done for: `sbin/pluginctl` (`-i`, `-g`, hook branch), `etc/rc.newwanip` (all early returns and calls), `opnsense/service/conf/actions.d/actions_interface.conf` (ten actions used below), `plugins/Mk/plugins.mk` (`scripts-auto` structure). All match. Everything else is master only unless a `STABLE:` reference is given; `plugins_interfaces()` on stable was already compared in `gap-3-interface-record-model.md`.

---

## 0. Answers in short

| # | Question | Answer |
|---|---|---|
| 1 | Interface record: permanent (A) or only while active (B)? | **A.** With A the whole activate/deactivate cycle is runtime state only (tun address + `/tmp/tun464_router`), exactly like core's OpenVPN up/down scripts, and causes **zero config.xml writes**. Every side effect of an address-less registered interface that was traced is cosmetic (extra rows in menus, overview, widget, traffic graph) or a no-op (no gateway object, no NAT source, rules load in pf). B costs an unlocked whole-file config rewrite, a backup/history entry and a config syshook run per transition, at least two per reboot, with no in-tree precedent for a daemon doing it. |
| 2 | Can install be the only step? | **Yes.** A versioned model with `<Default>1</Default>` + `<Required>Y</Required>` on `enabled` is persisted to config.xml by the auto-generated `+POST_INSTALL` (`run_migrations.php`). The auto script does **not** register the interface and does **not** start any service; the plugin needs a three-line `+POST_INSTALL.post`. Precedent for acting at install with default-on settings: os-crowdsec. No written convention against it was found. |
| 3 | Uplink without a setting | Uplink := device that carries the kernel's IPv6 default route (the result of core's own gateway choice), read in-process from the routing socket or `route -6 -n get default`. No configd action returns the Gateways model's interface/family, and none maps logical interface to device for an address-less interface, so richer facts (PD, resolvers, native-IPv4 gateway presence) are cheapest through `ifctl` and one plugin-owned PHP helper that uses core's `Gateways`/`Autoconf` classes. |
| 4 | Core triggers | Activation: `configctl interface newip tun464 force` (`force` is mandatory because the address is always 192.0.0.1). Deactivation: remove the router file, stop tayga, then `configctl interface routes configure`. `newip` is useless for deactivation: it returns at "Failed to detect IP" before routing and filter. |
| 5 | Idle budget | While no NAT64 is known: no `configctl`/`pluginctl`/PHP executions, no config writes, no filter reloads, no log lines except one per state change. RS only on uplink (re)attach (RFC 4861 6.3.7; RFC 7559 allows about one per hour only when no RA was ever received). RFC 7050 query only when the box has no native IPv4, on uplink attach, then not before the (negative) TTL expires. |

---

## 1. Interface record strategy

### 1.1 What `plugins_interfaces()` and `pluginctl -i` do

**F1.1 `plugins_interfaces()` never writes; it mutates the global `$config` and returns a flag. [V]**
`CORE/etc/inc/plugins.inc:178-242`: `$changed = false;` ... `$intf_config['internal_dynamic'] = true; $changed = true;` ... `return $changed;`.
Change test per hook key (`:219`): `if ((empty($intf_config[$prop_name]) && !empty($prop_value)) || ($intf_config[$prop_name] ?? '') != $prop_value)`.
Removal (`:233-239`): `unset($config['interfaces'][$intf_ref]); $changed = true;` for records that carried `internal_dynamic` and are no longer returned by any hook.

**F1.2 `pluginctl -i` writes config.xml only when something changed. [V]**
`CORE/sbin/pluginctl:242-245`: `if (plugins_interfaces()) { write_config('Updated plugin interface configuration'); }`. Same text on `STABLE:sbin/pluginctl`.
Consequence: a hook whose return value is a pure function of config.xml is idempotent; repeated runs write nothing.

**F1.3 Every legacy `write_config()` also runs the hooks and saves whatever they changed. [V]**
`CORE/etc/inc/config.inc:214-226`: `/* XXX temporary workaround for legacy interface creation */ try { plugins_interfaces(); } ...` followed by `$cnf->fromArray($config); ... $cnf->save($revision_info, $backup);`. The return value is ignored. A hook whose result depends on runtime state therefore changes config.xml as a side effect of any unrelated legacy save (legacy GUI pages, console, XMLRPC merge at `CORE/etc/inc/xmlrpc/legacy.inc:207`). MVC saves do not run it.

**F1.4 Callers of the registration. [V]**
Boot: `CORE/etc/inc/config.inc:175-176` (`/* register pluggable interfaces */ $function('/usr/local/sbin/pluginctl -i');`) from `convert_config()`, called at `CORE/etc/rc.bootup:63`, before the mismatch check (`:73`) and `interfaces_configure(true)` (`:90`).
On demand: `CORE/opnsense/service/conf/actions.d/actions_interface.conf:68-72`: `[invoke.registration] command:/usr/local/sbin/pluginctl -i ... type:script`.
Every in-tree caller of that action is an API controller reacting to a user's Apply (`ApiControllerBase::runInterfaceRegistration()`, `CORE/opnsense/mvc/app/controllers/OPNsense/Base/ApiControllerBase.php:411-417`; grep over both clones for `invoke registration|runInterfaceRegistration|invokeInterfaceRegistration` finds only controllers: VLAN, bridge, LAGG, GIF, GRE, loopback, VXLAN, wireless, firewall groups, WireGuard, OpenVPN, IPsec, and plugins os-tayga, os-openconnect). **No daemon, hook script or rc script in core or plugins invokes it.**

**F1.5 Nothing in core writes config.xml from a runtime network event. [V]**
grep `write_config\(` over `CORE/` outside `www/`: `sbin/pluginctl:120,244`, `etc/inc/xmlrpc/legacy.inc:207`, `etc/inc/plugins.inc.d/webgui.inc:208` (create TLS cert), `etc/rc.subr.d/livemode:102`, `etc/inc/console.inc:451`, `etc/inc/config.inc:167`, `opnsense/scripts/shell/setaddr.php:609`, `opnsense/scripts/shell/password.php:62,99,159`, `opnsense/scripts/interfaces/carp_set_status.php:49,54`. All are boot, console, user action or HA merge. `rc.newwanip`, `rc.newwanipv6`, `rc.linkup`, the PPP, DHCP and RA scripts keep their state in `/tmp` files (`ifctl`).

### 1.2 What one config save costs (relevant to B)

**F1.6 A save rewrites the whole file, creates a backup, an audit line and a config event. [V]**
`CORE/opnsense/mvc/app/library/OPNsense/Core/Config.php:749-782`:
`ftruncate($this->config_file_handle, 0); fwrite($this->config_file_handle, (string)$this);` ... `$backup_filename = $backup ? $this->backup($time) : null;` ... `$this->auditLogChange($backup_filename, $revision);` ... `$logger->info("config-event: new_config " . $backup_filename);` ... `$this->cleanupBackups();`.
`backup()` (`:568-595`) copies the full config.xml to `/conf/backup/config-<microtime>.xml`.

**F1.7 The history is finite: default 100 revisions. [V]**
`Config.php:691-701`: `return intval($this->simplexml->system->backupcount);` else `return 100;`; `cleanupBackups()` (`:730-741`) unlinks everything beyond that count. Each transition under B consumes one slot with the description "Updated plugin interface configuration" by user `(root)` (`config.inc:299-320`). Fifty up/down cycles evict a user's entire change history. [L]

**F1.8 The config syshook fires for every backup, asynchronously. [V]**
`CORE/opnsense/service/templates/OPNsense/Syslog/syslog-ng-config-events.conf:1-13`: `program("/usr/local/sbin/configctl -e -t 0.5 system event config_changed");` filtered on `message(".*config-event: new_config*")`.
`CORE/opnsense/scripts/system/trigger_config_changed_events.py:54-61`: for each backup newer than the last processed stamp `subprocess.run(["/usr/local/etc/rc.syshook", "config", filename])`; a second concurrent run exits 99 (`:38-44`).
Core ships no `config` hook (glob of `CORE/etc/rc.syshook.d/` shows only carp, early, import, monitor, start, stop, update, upgrade; `CORE/etc/rc.syshook:56-59` exits 0 when the directory is missing). A plugin that does: `PLUGINS/sysutils/git-backup/src/etc/rc.syshook.d/config/10-git-backup:70-75` (`git add config.xml` + `git commit` per config change).

**F1.9 HA XMLRPC sync is not triggered by a config save, and `interfaces` is not a sync section. [V]**
Only two invokers of `rc.filter_synchronize` exist: `CORE/opnsense/scripts/system/ha_xmlrpc_exec.php:56-58` (`case 'exec_sync': configd_run('filter sync');`, the HA status page button) and the cron-able action `CORE/opnsense/service/conf/actions.d/actions_system.conf:124-129` (`[ha_reconfigure_backup] ... rc.filter_synchronize pre_check_master restart_services`). grep for `filter sync|rc.filter_synchronize` over `*.php,*.inc,*.py,*.volt,*.xml,*.sh` finds nothing else.
Sync sections are declared per plugin (`CORE/etc/inc/plugins.inc.d/core.inc:354-416`, `pf.inc:204-254`): users, auth servers, certs, virtualip, staticroutes/gateways, syslog, cron, sysctl, ifgroups, filter rules, aliases, NAT, ... No entry has section `interfaces`. So neither A nor B causes HA traffic. On the receiving node each sync ends in `write_config()` (`legacy.inc:207`), which runs the local hooks (F1.3).

**F1.10 `pluginctl -i` is an unlocked read-modify-write of the whole file. [V for code, L for the race]**
`config.inc:406`: `$config = parse_config();` at include time (process start). `write_config()` then does `$cnf->fromArray($config)`, and `Config::fromArray()` (`Config.php:191-198`) starts with `$this->simplexml = simplexml_load_string('<' . $this->simplexml[0]->getName() . '/>');`, i.e. the in-memory snapshot replaces everything; `save()` takes `LOCK_EX` only around the write (`:757-773`) and does not re-read.
MVC controllers protect themselves with `Config::getInstance()->lock()` which re-reads under the lock (`Config.php:799-811`; used at `CORE/opnsense/mvc/app/controllers/OPNsense/Base/ApiMutableModelControllerBase.php:396,506,549,593,645,696`), but that does not stop a legacy writer that loaded earlier. A GUI/API save that lands between `pluginctl`'s start and its write is silently overwritten. The window is the runtime of `pluginctl -i` (PHP start, all plugin includes, all `_interfaces()` hooks). Core accepts this for user-initiated Applies; a daemon doing it at arbitrary moments has no precedent (F1.4).

### 1.3 Option A: every traced side effect of a permanent, enabled, non-virtual, address-less record

Assumed record (as in DESIGN.md 7.2): key `clat`, `if=tun464`, `enable`, `descr=CLAT`, `type=none`, empty `ipaddr`/`ipaddrv6`, `mss`; plus a `clat_devices()` entry with `names`, `function`, `volatile`, `configurable=false`.

| Area | Effect while the CLAT is inactive | Evidence | Conf. |
|---|---|---|---|
| Boot: mismatch check | None. `^tun` is already a volatile pattern, so a missing `tun464` cannot trigger the console assignment prompt. A custom device name would need its own volatile pattern or it would **block the boot** at the prompt, because the check runs before devices are created. | `CORE/etc/inc/plugins.inc.d/core.inc:291` `$devices[] = ['pattern' => '_stf|^tap|^tun|^ue', 'volatile' => true];`; `CORE/etc/inc/console.inc:66-72` `preg_match($regex, $ifcfg['if'])` ... `continue;` / `does_interface_exist(...) == false` ... `$mismatch = true;`; `CORE/etc/rc.bootup:73-76` | V |
| Boot: first filter load | The ruleset is loaded **before** `interfaces_configure()`, so rules naming `tun464` are loaded while the device does not exist yet. pfctl accepts that (next rows). | `rc.bootup:88` `filter_configure_sync(true, false); /* apply default policy before interface setup */`, `:90` `interfaces_configure(true);` | V |
| Boot: `interfaces_configure` | The record is queued as "software" because its device has a registered function; core logs "Device tun464 required by CLAT(clat), configuring now", calls the device function, then `interface_configure()` prints "Configuring CLAT interface..." and runs `ifconfig tun464 inet6 -accept_rtadv description 'CLAT (clat)' up`. No address flush (keys empty), no DHCP, no rtsold. The device function must create the tun unconditionally, otherwise that `ifconfig` fails on every boot and every Apply. | `CORE/etc/inc/interfaces.inc:694-701`, `:740-743`, `:774-779` (`log_msg("Device {$parent} required by ...`), `:2306` (`service_log(sprintf('Configuring %s interface...'`), `:2308-2314`, `:2446` | V (code) |
| Device admin state | Core sets IFF_UP at every `interface_configure()` (`:2446`). The kernel clears it and purges addresses whenever tayga closes the tun. So after boot the idle tun is "up"; after a deactivation it is "down" unless the supervisor sets it again. | `SRC/sys/net/if_tuntap.c:1276-1291`: `if (ifp->if_flags & IFF_UP) { ... if_down(ifp); }` / `/* Delete all addresses and routes which reference this interface. */ ... if_purgeaddrs(ifp);` / `if_link_state_change(ifp, LINK_STATE_DOWN);` | V |
| Gateway list | **No entry at all.** A dynamic gateway exists only while the router file exists; with `ipaddrv6` empty none of the fallback branches applies and a virtual default is never listed as defunct. A user-saved gateway item for `clat` would show as defunct while inactive (same under B). | `CORE/opnsense/mvc/app/models/OPNsense/Routing/Gateways.php:435-441` (`elseif (($router = Autoconf::getRouter($device, $ipproto)) != null)`), `:442`, `:455-458` (only `6rd, 6to4, dhcp6, slaac`), `:464-467` (`elseif (empty($thisconf['virtual']))`) | V |
| Default route, routing runs | Untouched. `system_routing_configure()` iterates gateways only; without a gateway the interface is invisible to it. | `CORE/etc/inc/system.inc:674-688`, `:708-711` `if (empty($gateway['gateway'])) { continue; }` | V |
| dpinger | No instance (instances come from the gateway list). | `CORE/etc/inc/plugins.inc.d/dpinger.inc:107-128` | V |
| Automatic outbound NAT | Not a NAT target (needs a gateway) and not a NAT source (needs an IPv4 address). | `CORE/etc/inc/filter.lib.inc:186-190` `if (substr($ifcfg['if'], 0, 4) != 'ovpn' && !empty($ifcfg['gateway']))`; `CORE/etc/inc/plugins.inc.d/pf.inc:291-295` `if (!empty($intfcf['ifconfig']['ipv4']) && empty($intfcf['gateway']))` | V |
| Core-generated rules for the interface | Four **disabled** bogon/private rules (comments in rules.debug); no antispoof and no force-gw rule because of `internal_dynamic`; no DHCP/DHCPv6/6rd rules (types empty). | `filter.lib.inc:330-369` (`'disabled' => empty($intfinfo['blockbogons'])`), `:587` `if (!isset($ifcfg['internal_dynamic']) && $ifcfg['if'] != 'lo0')`; `CORE/etc/inc/filter.inc:576-577` | V |
| Plugin pass rule and MSS rules on an address-less or missing device | **pfctl loads them.** An interface name in `on <if>` is not checked for existence; `(if)`, `(if:network)`, `(if:0)` are stored as dynamic references without lookup; `antispoof for <if>` on an address-less interface expands to nothing. Core renders interface addresses only in parenthesised form. | `SRC/sbin/pfctl/parse.y:3279-3300` (`if ((n = ifa_exists($1)) != NULL) $$->ifa_flags = n->ifa_flags;` - no error branch), `:3762-3813` (`$$->addr.type = PF_ADDR_DYNIFTL;`), `:1620-1629` (`h = ifa_lookup(...); ... if (h != NULL) expand_rule(`); `CORE/opnsense/mvc/app/library/OPNsense/Firewall/Rule.php:55` `sprintf("(%s:network)", $payload['if'])`, `SNatRule.php:78` `"({$interf_settings['if']}:0)"`; MSS: `filter.inc:500-501` `match on {$scrubcfg['if']} inet all scrub ( ... )` | V (code) |
| What would break a load | Only a **bare** interface name used as an address (`host : STRING` -> `yyerror("could not parse host specification")`, `parse.y:3640-3646`). Core guards against this itself (`filter.lib.inc:74-80`: "prevents \"could not parse host specification\" on load"). A failed load makes core fall back to the previous ruleset and log an error (`filter.inc:410-426`), so the plugin's own rule must never contain a bare `tun464` as source/destination/target. | as quoted | V |
| Log noise: "Failed to detect IP" | Only if something calls `rc.newwanip` for the device. Nothing in core does for a tun (no devd link events for tun, digest item "Link flap handling"); so it appears only if the supervisor calls `newip` while address-less. Note `log_msg()` raises INFO to NOTICE, so the line is visible in the default system log. | `CORE/etc/rc.newwanip:65-69`; `CORE/etc/inc/util.inc:884-889` (`case LOG_INFO: /* lowest handled value for the time being */ $prio = LOG_NOTICE;`) | V |
| Log noise: transitional | If the router file still exists while the address is gone (tayga died, file not yet removed) and any routing or monitor run happens: "ROUTING: refusing to set inet gateway on addressless clat(tun464)" (LOG_ERR) and, with monitoring enabled, "The required CLAT_GW IPv4 interface address could not be found, skipping." | `system.inc:714-716`, `:682-684`; `dpinger.inc:193-195` | V |
| Interfaces menu, Firewall rules tab | Permanent `[CLAT]` entry linking to `/interfaces.php?if=clat`, and a permanent CLAT tab under Firewall: Rules. | `CORE/opnsense/mvc/app/models/OPNsense/Interfaces/Menu/Menu.php:63-67,88-93`; `CORE/opnsense/mvc/app/models/OPNsense/Firewall/Menu/Menu.php:41-45` (`if (isset($node->enable) && $node->if != 'lo0')`) | V |
| Interfaces: Overview and dashboard Interfaces widget | A permanent row (the device exists). Status is `up` when the flag is set, else `down`; the widget colours the plug icon green only for `up`. No addresses, no gateway. | `CORE/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/OverviewController.php:141-150`, `:164-170` (`in_array('up', $details['flags'])) ? 'up' : 'down'`); `CORE/opnsense/www/js/widgets/Interfaces.js:59-71` (`text-${intf_data.status === 'up' ? 'success' : 'danger'}`) | V (code) |
| Traffic graph / statistics | CLAT is listed (enabled, non-virtual, device present) with zero counters. | `CORE/opnsense/scripts/interfaces/traffic_stats.php:57,94-98` | V |
| Interface selectors in services | Hidden wherever the field does not opt in to dynamic interfaces. | `CORE/opnsense/mvc/app/models/OPNsense/Base/FieldTypes/InterfaceField.php:122-124` | V |
| Assignments page | Permanent, editable and deletable row; exposes the record to the 26.7.6 `ipaddr=none` problem at all times, not only while active (details in `gap-3-interface-record-model.md`). Harmless while idle; the hook's empty `ipaddr`/`ipaddrv6` reset it at the next registration run. | gap-3 sections 2-3 | L |
| Anti-lockout interface | Unaffected: only `lan|opt[0-9]+|wan` qualify. | `CORE/etc/inc/util.inc:779-783` | V |
| Config writes | One at first registration, none afterwards as long as the hook returns config-derived values only (F1.2). | F1.1-F1.3 | V |

Not traced (open): what `_interfaces_hardware()` prints for a tun (`interfaces.inc:2416`), and whether `ifconfig` shows a `status:` line for a tun (if it did, the Overview would show that text instead of up/down, `OverviewController.php:165-169`).

### 1.4 Option B: cost and behaviour per activation/deactivation

1. **Two config revisions per up/down cycle** (register, deregister), each with F1.6-F1.8. [V]
2. **Two more per reboot.** `pluginctl -i` runs at `rc.bootup:63`; the supervisor starts much later (`CORE/etc/rc:240-243` -> `rc.syshook start` -> `CORE/etc/rc.syshook.d/start/20-freebsd`). A hook that keys on runtime state finds none at boot, so the record is removed during every boot and re-added at the first activation. [L]
3. **The hook becomes impure.** Because every legacy `write_config()` runs it (F1.3), unrelated saves add or remove the record depending on what the supervisor's state file says at that instant; MVC saves never do. [V]
4. **Lost-update race** with a user editing the configuration (F1.10). [L]
5. **Rules and objects bound to `clat` flap.** While the record is absent, every rule that names the interface, including the plugin's own pass rule and any user rule or manual outbound NAT rule, is rendered disabled: `CORE/opnsense/mvc/app/library/OPNsense/Firewall/Rule.php:320-324` `/* disable rule when device not found */ ... $this->log("Interface {$interface} not found"); $rulecpy['disabled'] = true;`. The Firewall tab disappears while the rules stay in config.xml; `plugins_interfaces()` removes only the record (`plugins.inc:233-239`), not the references. Users on manual outbound NAT lose the place to keep their rule. [V for code]
6. **`newip` cannot be used once the record is gone**: `rc.newwanip:57-60` `log_msg("Interface '{$interface}' ($device) is disabled or empty, nothing to do.", LOG_WARNING); return;`. [V]
7. **No precedent** (F1.4, F1.5). [V]
8. Benefit: nothing is visible on boxes where the CLAT never activates.

May the registration be invoked from a daemon at all? Technically yes: `configctl interface invoke registration` is a plain `type:script` action without a boot guard, executed by configd as root; nothing in `pluginctl` forbids it. The objections are the write semantics above, not access.

### 1.5 Recommendation

**Use A.** Reasons, in order of weight:

- It matches the mechanism core itself uses for a tunnel that comes and goes on a permanently assigned interface: `CORE/etc/inc/plugins.inc.d/openvpn/ovpn-linkup:27-30` (`ifctl -4rd -i ${1} ${ROUTERV4}` ... `configctl -d interface newip ${1} force`) and `ovpn-linkdown:3-4` (`ifctl -4rd -i ${1}`). The interface record is static; presence of the gateway, default route and NAT is derived from runtime files.
- Zero config writes, zero history churn, zero races at runtime.
- User-visible objects (rules tab, manual NAT rule, gateway item) keep a stable anchor.
- Every traced side effect of the idle record is cosmetic or nil, and pf loading is safe by code.

Costs to accept and state in the documentation: a dormant "CLAT" interface is visible on every box that has the plugin enabled; a boot console line; the Assignments exposure.

Design conditions that make A hold:

1. `clat_interfaces()` must return values derived **only from config.xml** (never the live WAN MTU, never the supervisor state), so that `plugins_interfaces()` is a no-op after the first run.
2. The device function must create `tun464` unconditionally (boot runs it before the supervisor exists).
3. The supervisor must never call `interface newip` while the tun has no IPv4 address, and must remove the router file before or together with the address.
4. Decide the idle admin state deliberately (up = green plug without address; down = red plug). Core re-asserts "up" at boot and on every Apply of the record; the kernel sets "down" when tayga exits.

Optional refinement if a dormant interface on never-NAT64 boxes is unacceptable ("latched A"): register the record the first time a NAT64 prefix is ever discovered and never remove it automatically. That is one locked config write per box lifetime, with the latch stored in the plugin's own model so the hook stays a pure function of config.xml. It keeps all properties of A afterwards. It is not needed for correctness and adds a second code path; it is listed as a design decision in section 7.

---

## 2. Default-on at install

### 2.1 What the generated `+POST_INSTALL` contains

`PLUGINS/Mk/plugins.mk:178-223` (`scripts-auto`), in this order, for a plugin that ships `actions.d`, a model and templates:

| Step | Generated line | Source | Effect |
|---|---|---|---|
| a | paths of `src/etc/rc.syshook.d/**/*.early` and `*.start` files | `plugins.mk:179-187` (`find -s . -type f -name "*.$${SYSHOOK}"`) | Runs only **legacy suffix-style** hook files. Directory-style hooks (`start/50-foo`) do not match the name pattern and are not run. Two plugins compensate by hand: `PLUGINS/sysutils/dec-hw/+POST_INSTALL:1` and `PLUGINS/misc/theme-flexcolor/+POST_INSTALL.post:1`. |
| b | `if [ -f /usr/local/etc/rc.d/configd ]; then /usr/local/etc/rc.d/configd restart; fi` | `plugins.mk:188-190`, `PLUGINS/Templates/actions.d:1` | New configd actions become available. |
| c | `.../mvc/script/run_migrations.php OPNsense/Clat` | `plugins.mk:197-203`, `PLUGINS/Templates/models:1` | Model migration, see F2.1. One config save. |
| d | `echo "Reloading plugin configuration"; /usr/local/etc/rc.configure_plugins POST_INSTALL` | `plugins.mk:204-208`, `PLUGINS/Templates/configure:1` | `CORE/etc/rc.configure_plugins:31-33` exits when `/conf/config.xml` is missing; `:44` `system_cache_flush(true);` (ACL, menu, model and volt caches, `system.inc:1180-1199`); `:47-49` `system_syslog_start(true);` (activates a `_syslog()` registration). |
| e | `configctl template reload OPNsense/Clat` | `plugins.mk:210-217`, `PLUGINS/Templates/templates:1` | Renders `+TARGETS`, e.g. `/etc/rc.conf.d/clat`. |
| f | content of the plugin's `+POST_INSTALL.post` | `plugins.mk:225-231` | Plugin's own steps. |

Not generated anywhere: interface registration (`pluginctl -i`), a filter reload, or a service start. [V] (the whole target was read; stable/26.7 structure confirmed through `https://raw.githubusercontent.com/opnsense/plugins/stable/26.7/Mk/plugins.mk`).

After `pkg install`, the GUI path also runs `register.php install <pkg>` (`CORE/opnsense/scripts/firmware/install.sh:46-48`), which adds the package to `system.firmware.plugins` and saves the config once more (`CORE/opnsense/scripts/firmware/register.php:139-145,201-203`). A GUI install therefore already produces two config revisions before the plugin does anything.

**F2.1 A default of 1 is persisted at install. [V]**
`CORE/opnsense/mvc/script/run_migrations.php:67-71`: `$mdl = $mdl_class_info->newInstance(true); ... $mig_performed = $mdl->runMigrations();` and `:95-97` `if ($executed_migration) { Config::getInstance()->save(); }`.
`CORE/opnsense/mvc/app/models/OPNsense/Base/BaseModel.php:501-503`: empty config node -> `$this->internal_current_model_version = "0.0.0";`; `:890` `version_compare(... ?? '0.0.0', $this->internal_model_version, '<')`; `:899` `$versions[$this->internal_model_version] = __DIR__ . "/BaseModelMigration.php";`; `:944-946` `$this->serializeToConfig();`.
`CORE/opnsense/mvc/app/models/OPNsense/Base/BaseModelMigration.php:45-46`: `elseif ($subnode->isRequired() && !$subnode->isSet()) { $subnode->applyDefault(); }`.
Conditions: the model XML needs a `<version>` (an unversioned model is "Left ... as unversioned", `run_migrations.php:83-85`); `enabled` needs `<Required>Y</Required>` and `<Default>1</Default>`; and **every** required field needs a default, because `serializeToConfig()` validates and a failure aborts the save (`BaseModel.php:950-953` `"Model ... can't be saved, skip"`).
After step c, config.xml contains `<OPNsense><clat><general><enabled>1</enabled>`, so step e's template can emit `clat_enable="YES"` (pattern: `PLUGINS/net/tayga/src/opnsense/service/templates/OPNsense/Tayga/tayga:1-3`).

### 2.2 What the plugin must add in `+POST_INSTALL.post`

Minimum for "works without a reboot" under option A:

```sh
#!/bin/sh
[ -f /conf/config.xml ] || exit 0          # same guard as rc.configure_plugins
/usr/local/sbin/pluginctl -i               # register the "clat" record (one config save, F1.2)
/usr/local/sbin/pluginctl -s clat restart  # start or restart the supervisor
```

- `pluginctl -i` is the same command core's action runs; calling the binary avoids depending on configd timing right after its restart (the generated script itself calls `configctl` immediately after the restart, so either form has precedent).
- `pluginctl -s <service> restart` is used the same way by `PLUGINS/security/q-feeds-connector/+POST_INSTALL.post:3` (`/usr/local/sbin/pluginctl -s cron restart`).
- No filter reload and no interface configure are needed at install: the record's rules matter only once the CLAT is active, and activation ends in `rc.newwanip`, which reloads the filter (`rc.newwanip:125`). The supervisor creates `tun464` itself at start if it is missing.
- `restart` rather than `start` covers the upgrade case (2.4).

At boot the service is started by `rc.freebsd` from `/etc/rc.conf.d/*` (`CORE/etc/rc.freebsd:38-40`, `:123-150`), run from `CORE/etc/rc.syshook.d/start/20-freebsd`, i.e. after `rc.bootup` has finished and after deferred `newip` events were replayed (`start/10-newwanip`).

### 2.3 Convention and precedents

- No statement against default-active plugins was found in `PLUGINS/README.md` or `PLUGINS/CONTRIBUTING.md` (grep for default/enable/start: only "Allow custom start, stop and early scripts", `README.md:17`). A web search for a maintainer statement found none. **[U]** that none exists.
- The common pattern is default off: e.g. `PLUGINS/net/tayga/src/opnsense/mvc/app/models/OPNsense/Tayga/General.xml:6-8` (`<enabled ...><Default>0</Default>`).
- Precedents for default on:
  - **os-crowdsec** (in opnsense/plugins): `PLUGINS/security/crowdsec/src/opnsense/mvc/app/models/OPNsense/CrowdSec/General.xml:6-17` (`agent_enabled`, `lapi_enabled`, `firewall_bouncer_enabled` all `<Default>1</Default>`), and `PLUGINS/security/crowdsec/+POST_INSTALL.post:3-6` (`configctl crowdsec reconfigure` + `service crowdsec reload`). Its reconfigure script reloads the firewall (`.../scripts/OPNsense/CrowdSec/reconfigure.sh:13` `/usr/local/sbin/configctl filter reload`) and its firewall hook even saves config (`.../plugins.inc.d/crowdsec.inc:23-24`) and registers block rules. Vendor documentation confirms the intent: the three components "are enabled by default" (`https://docs.crowdsec.net/docs/getting_started/install_crowdsec_opnsense`). **[V]**
  - `PLUGINS/dns/ddclient/.../DynDNS/DynDNS.xml:7-10` and `PLUGINS/security/wazuh-agent/.../WazuhAgent.xml:7-10`: `general.enabled` default 1 (both stay inert until the user adds an account or server). `PLUGINS/security/wazuh-agent/+POST_INSTALL.post:1-2` reloads the filter at install. **[V]**
- Standards side: RFC 8585 TRANS-2 requires a way to disable manually; claton section 4 requires enabling without user action when a prefix is found and no native IPv4 exists (`standards-requirements.md` items A1, A5, A6). Default-on with a visible off switch satisfies both.

### 2.4 Upgrade

- pkg runs the **old** package's pre-deinstall script and the new package's post-install script during an upgrade and marks both with `PKG_UPGRADE=true`. `https://raw.githubusercontent.com/freebsd/pkg/main/libpkg/pkg_add.c`: `ret = pkg_script_run(old, PKG_SCRIPT_PRE_DEINSTALL, (old != NULL), noexec);` (in `pkg_add_cleanup_old`) and `retcode = pkg_script_run(pkg, PKG_SCRIPT_POST_INSTALL, (local != NULL), noexec);`; `https://raw.githubusercontent.com/freebsd/pkg/main/libpkg/scripts.c`: `if (upgrade) { setenv("PKG_UPGRADE", "true", 1); }`. `PKG_SCRIPT_POST_DEINSTALL` does not occur in `pkg_add.c`. **[V]** for pkg `main`; **[U]** for the pkg version shipped with 26.7.
- A package-only firmware update does not reboot unless the user set `system.firmware.reboot`: `CORE/opnsense/scripts/firmware/update.sh:52-57` (`opnsense-update ... -pt`, then only `rc.restart_webgui`), `:78-82`. So a running supervisor keeps executing old code unless the plugin restarts it. **[V]**
- Therefore: `+PRE_DEINSTALL.pre` stops the service (clean teardown, section 4.3); `+POST_INSTALL.post` restarts it (2.2). The auto steps b-e run again on upgrade (migrations, cache flush, template reload). `pluginctl -i` on upgrade writes nothing if the hook output is unchanged (F1.2).
- Expect a short IPv4 interruption on every plugin upgrade.

### 2.5 Deinstall

- GUI path: `pkg remove -y`, `register.php remove`, `pkg autoremove -y` (`CORE/opnsense/scripts/firmware/remove.sh:34-36`); the last step removes `tayga` when nothing else needs it.
- Generated `+POST_DEINSTALL`: only `rc.configure_plugins POST_DEINSTALL` (cache flush; `plugins.mk:204-208`). Nothing is generated for `+PRE_DEINSTALL`.
- Plugin's `+PRE_DEINSTALL.pre`: stop the supervisor. Precedent: `PLUGINS/security/crowdsec/+PRE_DEINSTALL.pre:4`.
- Plugin's `+POST_DEINSTALL.post`, guarded by `[ "${PKG_UPGRADE}" = "true" ] && exit 0`: run `pluginctl -i` (now that `clat.inc` is gone the hook no longer returns the key, so the tagged record is removed, `plugins.inc:233-239`), `ifconfig tun464 destroy`, `configctl interface routes configure`. Precedent for doing config cleanup after the files are gone: `PLUGINS/security/crowdsec/+POST_DEINSTALL.post:21-50` (comment in `+PRE_DEINSTALL.pre:6-7`: "the rest of the cleanup is done in the post-deinstall script, otherwise the plugin recreates the objects during \"filter reload\"").
- Residue that stays by design: the `<OPNsense><clat>` settings node; any user rule on the CLAT tab (rendered disabled, `Rule.php:320-324`); and the record itself if a user edit stripped `internal_dynamic` (gap-3 section 3.3).

---

## 3. Uplink auto-selection and data sources for a Python daemon

### 3.1 configd actions and tools that exist (exact names and output)

| Command | Backend | Output | Useful for | Evidence |
|---|---|---|---|---|
| `configctl interface list ifconfig [<device>]` | `pluginctl -D` -> `legacy_interfaces_details()` | Pretty JSON object keyed by device: `flags[]` (lower case), `capabilities[]`, `options[]`, `macaddr`, `mtu`, `is_physical`, `device`, `ipv4[] {ipaddr, subnetbits, tunnel, endpoint}`, `ipv6[] {ipaddr, subnetbits, autoconf, deprecated, detached, tentative, link-local, pltime, vltime, tunnel}`, optional `status`, `groups[]`, `media` | device MTU, SLAAC address detection (`autoconf`), tun address check | `actions_interface.conf:130-134`; `pluginctl:213-214`; `CORE/etc/inc/interfaces.lib.inc:252-385` |
| `configctl interface address [<ifname>]` | `pluginctl -46` | `{"wan":[{"address","network","bits","device","interface","family":"inet"},{...,"family":"inet6"}]}`; all config interfaces when no argument. `device` is null when the interface has no address in that family. | logical name -> device **when addressed** | `actions_interface.conf:20-24`; `pluginctl:182-212`; `interfaces.inc:4043-4068` |
| `configctl interface routes list -n json` | `show_routes.py` (parses `netstat -rWn`) | JSON list of `{proto: "ipv4"|"ipv6", destination, gateway, flags, ..., netif, expire}` | default routes of both families and their device; core uses it itself (`system.inc:671`) | `actions_interface.conf:160-164`; `CORE/opnsense/scripts/routes/show_routes.py:42-67` |
| `configctl interface gateways status` | `gateway_status.php` | `{"WAN_GW":{"name","address","status","loss","delay","stddev","monitor","status_translated"}}` - **no interface, device or family field** | health only | `actions_interface.conf:193-196`; `CORE/opnsense/scripts/routes/gateway_status.php:38-46,79-82` |
| `configctl interface gateways list [-g|-l]` | `gateways.php` | `{"WAN_GW":"WAN_GW - <address or family>"}`, cached 20 s | names only | `actions_interface.conf:186-191`; `CORE/opnsense/scripts/routes/gateways.php:44-61` |
| `configctl system list nameservers [1]` | `nameservers.php` -> `get_nameservers(null, $with_gateway)` | JSON list; with the argument `{host, gateway, interface, source}`. Dynamic (WAN-learned) servers are included **only when `dnsallowoverride` is set**, and static servers are mixed in. | not suitable for RFC 7050 | `actions_system.conf:152-156`; `CORE/opnsense/scripts/system/nameservers.php:35`; `system.inc:370-376` |
| `/usr/local/sbin/ifctl -6p` | `ifctl.sh` | device names that have a prefix file, one per line | find the PD-carrying device(s) | `CORE/opnsense/scripts/interfaces/ifctl.sh:234-257` |
| `ifctl -i <dev> -6p` / `-6n` / `-6r` | `ifctl.sh` | file content, one item per line; falls back to the `<dev>:slaac_*` file | delegated prefix with real length; WAN-learned resolvers (may be scoped link-local); IPv6 router | `ifctl.sh:298-306`; `CORE/opnsense/mvc/app/library/OPNsense/Interface/Autoconf.php:36-48` |
| `ifctl -4r` | `ifctl.sh` | devices that have an IPv4 router file | native-IPv4 presence (exclude `tun464`) | `ifctl.sh:234-257` |
| `ifctl -i tun464 -4rd -a 192.0.0.2` / `ifctl -i tun464 -4rd` | `ifctl.sh` | writes / removes `/tmp/tun464_router` | gateway on / off | `ifctl.sh:259-285` |
| `pluginctl -g interfaces.wan.if` | `pluginctl` | raw config property, e.g. `pppoe0` (not a configd action) | logical name -> device from config | `pluginctl:240-241`, `:61-76` |
| `pluginctl -c route_reload <ifname>` | hook `'route_reload' => ['system_routing_configure:2']` | runs `system_routing_configure(true, [<ifname>])` | targeted routing run (not a configd action) | `CORE/etc/inc/plugins.inc.d/core.inc:442`; `pluginctl:343-347` |

Core has **no Python library for config.xml**. Python scripts either parse the file directly (`CORE/opnsense/scripts/captiveportal/lib/__init__.py:100` `xml.etree.ElementTree.parse('/conf/config.xml')`) or read files rendered by configd templates, where `helpers.physical_interface('wan')` gives the device (`CORE/opnsense/service/modules/addons/template_helpers.py:137-142` `return self.getNodeByTag('interfaces.'+name+'.if') or name`). Templates are rendered only on a reload (install, Apply, boot: `CORE/etc/rc.syshook.d/early/15-templates:4`), so they go stale if the user re-assigns WAN.

### 3.2 Three candidate definitions of "the IPv6 uplink"

| Definition | How | Multi-WAN behaviour | Assessment |
|---|---|---|---|
| Device of the kernel's IPv6 default route | routing socket `RTM_GET` in-process, or `route -6 -n get default` (`interface:` line), or the `ipv6`/`default` row of `interface routes list -n json` | Exactly one at any time; it is whatever core's `system_routing_configure()` installed (`system.inc:708-722`), and it changes on gateway switching | **Recommended.** It is also the path the translated packets will actually take, so the CLAT address, PD, resolvers and PREF64 must all come from this device anyway (otherwise the other ISP's ingress filtering drops them). |
| Default IPv6 gateway of the Gateways model | PHP only: `(new Gateways())->getDefaultGW([], 'inet6')` returns `interface`, `if`, `gateway` (`Gateways.php:493-513`) | Same choice as the kernel route when routing is in sync | Needs a PHP helper; no configd action exposes it (3.1). Good as a cross-check and to get the logical name. |
| Device whose ifctl prefix file holds a PD | `ifctl -6p` | Several devices possible; a stale file can survive a PPP drop (digest, opnsense-pppoe-ipv6only) | Use as a property of the chosen uplink, not as the selector. |

Multi-WAN ambiguity that remains: (a) with policy routing or gateway groups LAN traffic may use another WAN, but the CLAT's own IPv6 packets are routed by the FIB, so following the kernel default is the consistent choice; (b) on failover the uplink changes and the instance must be rebuilt from the new device's facts; (c) first version supports one instance. All three should be stated in the documentation.

"No native IPv4" test that is not fooled by the CLAT itself: there is no IPv4 default route whose device is not `tun464`, and no IPv4 router file other than `tun464`'s (`ifctl -4r`), and no enabled static IPv4 gateway item. The last needs the Gateways model.

### 3.3 Cleanest arrangement

- **Fast path in-process, no child processes:** a `PF_ROUTE` socket for route, address and interface messages; this answers "is there an IPv6 default route, on which device" and "did an IPv4 default route appear".
- **Facts on demand through `ifctl`** (small shell script, no PHP): `ifctl -i <dev> -6p`, `-6n`.
- **One plugin-owned PHP helper as a configd `script_output` action** (for example `clat uplink`), called only when the fast path reports a change, returning one JSON document built with core classes: default IPv6 and IPv4 gateways (`Gateways::getDefaultGW`), logical name and device, IPv6 type of the uplink, `Autoconf::getPrefix/getNameserver`, device MTU, outbound NAT mode. This keeps knowledge of core internals in PHP, where core's own scripts keep it (`gateways.php` is the model: `require_once("script/load_phalcon.php"); use OPNsense\Routing\Gateways;`).
- Do not parse `/conf/config.xml` in the daemon for anything the helper can answer; do not use `system list nameservers`.

---

## 4. Triggering core after activation and deactivation

### 4.1 What each trigger does

| Trigger | Script | What it does | Evidence |
|---|---|---|---|
| `configctl interface newip <dev> [force]` | `rc.newwanip` | During boot: defers (writes `/tmp/newwanip_<dev>`, replayed by `start/10-newwanip`). Returns early if the record is missing/disabled, if the device has **no IPv4 address** ("Failed to detect IP"), or if the address equals `/tmp/<dev>_oldip` and `force` is absent ("No IP change detected"). Otherwise: `system_resolver_configure()`, VIPs, GRE/GIF, `system_routing_configure(false, [if], true, 'inet')` (interface route, default route if that gateway is the chosen default, static routes on it, monitors on it), full `filter_configure_sync()`, state kill on address change, then `plugins_configure('vpn', ...)` and `plugins_configure('newwanip', false, [[if], 'inet'])`. | `CORE/etc/rc.newwanip:44-47`, `:57-60`, `:63`, `:65-69`, `:79-82`, `:123`, `:125`, `:127-131`, `:142-143`; `actions_interface.conf:26-30` |
| `configctl interface routes configure` | `rc.routing_configure` | No-op during boot (`exit_on_bootup()`), processes pending static-route deletions, `system_routing_configure(true, null, true)` for **all** interfaces (re-chooses the default gateway of each family, re-adds every static route, restarts all monitors), then `filter_configure_sync(true, false)` (filter reload without alias reload). Fires no `newwanip` hooks. | `CORE/etc/rc.routing_configure:38`, `:73`, `:79`; `actions_interface.conf:166-170`; `system.inc:800-817`; `dpinger.inc:130-145` |
| `configctl filter reload [skip_alias]` | `rc.filter_configure` | No-op during boot; `filter_configure_sync(true, $arg != 'skip_alias')`. Serialised by an exclusive lock on `/tmp/rules.debug`. | `CORE/etc/rc.filter_configure:36-40`; `filter.inc:171-172`; `actions_filter.conf:1-5` |
| `pluginctl -c route_reload <ifname>` | hook | `system_routing_configure(true, [ifname])` only: no filter reload, no hooks. Sets the default route only if the chosen default gateway belongs to that interface or gateway switching is on. With an empty gateway set for the interface it does **not** stop that interface's monitor (the monitor hook is skipped for an empty list). | `core.inc:442`; `system.inc:713`; `system.inc:802-816`; `plugins.inc:421-425` |

Facts that decide the choice:

- **`system_routing_configure()` never deletes a default route when no gateway is left**: `system.inc:708-711` `$gateway = $gateways->getDefaultGW(...); if (empty($gateway['gateway'])) { continue; }`. [V]
- **The kernel removes the CLAT default route itself when the tun address goes away.** Address deletion calls `in_ifadown(&ia->ia_ifa, 1)` with the comment "in_ifadown gets rid of all the rest of the routes" (`https://raw.githubusercontent.com/opnsense/src/stable/26.7/sys/netinet/in.c`, `in_difaddr_ioctl`), and with `del` set static routes are included: `if ((nhop_get_rtflags(nh) & RTF_STATIC) != 0 && ap->del == 0) return (0);` (`.../sys/netinet/in_rmx.c`, `in_ifadownkill`). tayga's close triggers the purge (`SRC/sys/net/if_tuntap.c:1282-1288`). [V] for the two functions; [L] for the full chain from `if_purgeaddrs()` (not read).
- **The automatic NAT rule disappears at the next filter reload after the gateway is gone**, because it keys on the gateway (`filter.lib.inc:186-190`). Until then the stale rule `nat on tun464 ...` is inert: nothing is routed to an address-less, down tun. [V]/[L]
- **Core's own teardown paths do less.** `ovpn-linkdown:3-4` only removes the router files. `CORE/opnsense/scripts/interfaces/ppp-linkdown.sh:13-16` removes them and calls `configctl -d interface newip ${IF}`, which ends at the "Failed to detect IP" return after `system_resolver_configure()`. Core therefore tolerates a stale NAT rule and does no routing run on IPv4 loss. [V]
- **`newip` fires `newwanip` hooks with side effects**: e.g. `CORE/etc/inc/plugins.inc.d/ntpd.inc:90` `'newwanip' => ['ntpd_configure_do']` and `:173-177` `killbyname('ntpd');` (unconditional restart); Unbound restarts when the interface matches (`unbound.inc:457-460`); WireGuard, OpenVPN, IPsec, webgui, openssh, Kea, dhcrelay handlers also run (grep `'newwanip'` in `plugins.inc.d`). This is the normal reaction to a WAN IPv4 change and is right at activation; it is the reason never to call `newip` periodically. [V]

### 4.2 Safe to call from a daemon?

Yes, with precedent for each:

- `configctl -d interface newip <dev> force` is called from daemon-spawned scripts in core: `ovpn-linkup:30` (OpenVPN up script), `CORE/opnsense/scripts/interfaces/ppp-linkup.sh:30` (mpd5), `CORE/opnsense/scripts/interfaces/dhclient-script:230,256` (dhclient). [V]
- `rc.routing_configure` is triggered through configd by a core daemon: `dpinger.inc:289-293` starts `gateway_watcher.php` with `'interface routes alarm'`, which is `flock -n ... rc.routing_configure alarm` (`actions_interface.conf:172-177`). The plain `routes configure` action has no lock of its own. [V]
- `configctl filter reload` is called from plugin scripts (`PLUGINS/security/crowdsec/.../reconfigure.sh:13`). [V]

Rules for the supervisor: issue triggers from one serialised state machine (never two at once); wait for the action to return (`configctl` without `-d`) with a timeout so its own next step sees the result; tolerate the boot guard (actions are no-ops or deferred while `/var/run/booting` is locked, `util.inc:316-325`), which cannot bite in practice because rc.d services start after `rc.bootup`; ignore its own echo (the `newwanip` hook for interface `clat`, family `inet`).

### 4.3 Recommended sequences

**Activation** (tayga running, tun has `192.0.0.1 --> 192.0.0.2`, IPv6 routes set):

1. `ifctl -i tun464 -4rd -a 192.0.0.2`
2. `configctl interface newip tun464 force`

`force` is required on every activation: the address never changes, so without it the second and later activations stop at `rc.newwanip:79-82`. This single action yields `CLAT_GW`, the default route (if it is the chosen default), the NAT rule and the pass/MSS rules in one filter reload, and tells VPN and other services that IPv4 connectivity appeared. Identical to core's `ovpn-linkup`.

**Deactivation** (prefix lost, native IPv4 appeared, user disabled, or tayga died):

1. `ifctl -i tun464 -4rd` (gateway object gone immediately, `Gateways.php:435`)
2. stop tayga; delete the IPv6 route(s) the supervisor added; `route -4 delete default 192.0.0.2` as a guarded belt-and-braces step (the kernel normally already removed it)
3. kill states of the CLAT address, the way core does for an old WAN address: `pfctl -k 0.0.0.0/0 -k 192.0.0.1` and `pfctl -k 192.0.0.1` (`rc.newwanip:129-130`)
4. `configctl interface routes configure`

Step 4 is the one core action that (a) re-chooses the IPv4 default gateway across all interfaces, which matters when native IPv4 has appeared: at equal priority the earlier `newip <wan>` may have left the default on the CLAT (`system.inc:713`), (b) restarts monitors so a user-enabled `CLAT_GW` dpinger stops, and (c) reloads the filter so the automatic NAT rule disappears. Its cost is a full routing pass (static routes are deleted and re-added, all dpinger instances restart).

Not correct for deactivation: `configctl interface newip tun464` (returns before routing and filter, and logs "Failed to detect IP for interface clat"); `pluginctl -c route_reload clat` alone (no filter reload, no default re-selection on other interfaces, no monitor stop).

Acceptable minimal variant when no other IPv4 gateway exists and monitoring is off: steps 1-3 plus `configctl filter reload skip_alias`; or, at the level of core's own OpenVPN teardown, steps 1-3 only.

---

## 5. Resource and noise budget of the idle listener

### 5.1 Must not do while no NAT64 prefix is known

| Do not | Why | Evidence |
|---|---|---|
| Write config.xml | history, backup, audit line, syshook per write | F1.6-F1.8 |
| Call `interface invoke registration` | same; and hook is idempotent anyway | F1.2 |
| Call `interface newip`, `routes configure`, `filter reload` | each is a PHP run plus ruleset load; `newip` restarts ntpd and fires every `newwanip` handler; `routes configure` re-adds static routes and restarts all monitors | 4.1 |
| Spawn `php`, `configctl`, `ifconfig`, `route`, `ifctl` on a timer | each configd action logs its `message:` line and forks; core treats periodic work as cron jobs, not as loops in daemons | `actions_interface.conf` (`message:` fields) |
| Run tayga | nothing to translate; an open tun also flips link state | DESIGN.md 8 |
| Log per probe or per timer tick | claton section 5: reasons for CLAT state changes should be logged, logging should be configurable and off by default | `standards-requirements.md` item A10 |
| Send RS or DNS queries on a short fixed interval | next subsection; OpenWrt's 3-second retry loop is its most reported 464xlat defect | digest, openwrt-464xlat |

The 60 s reconcile timer of DESIGN.md section 8 should, while idle, be limited to in-process checks (routing-socket state, timers). External commands belong to events: uplink attach, default-route change, `newwanip` kick, user action.

Raw socket hygiene: set `ICMP6_FILTER` to type 134 only, otherwise the process wakes for every ICMPv6 packet the box receives (default filter is pass-all; `gap-4-pref64-receive-path.md` section 1).

### 5.2 Router Solicitations

- RFC 4861 section 6.3.7 and constants: at most `MAX_RTR_SOLICITATIONS` (3) solicitations, `RTR_SOLICITATION_INTERVAL` (4 s) apart, after a random delay of up to `MAX_RTR_SOLICITATION_DELAY` (1 s), on an (re)initialisation event such as interface enable or link attach; once a valid RA with non-zero Router Lifetime arrived the host "MUST desist from sending additional solicitations on that interface" until the next such event (`https://www.rfc-editor.org/rfc/rfc4861.txt`; constants also in FreeBSD `nd6.h:179-181`, quoted in gap-4 section 2.1). Routers rate-limit multicast replies to one per `MIN_DELAY_BETWEEN_RAS`.
- RFC 7559 section 2 (`https://www.rfc-editor.org/rfc/rfc7559.txt`): when **no** RA is received, retransmit with exponential back-off, "IRT ... 4 seconds", "MRT ... 3600 seconds", no count or duration limit, i.e. "approximately 1 RS per hour"; stop when router discovery succeeds on multicast-capable links.
- RFC 8781 gives no RS rule; section 4.1 sets the router's default PREF64 lifetime to "the lesser of 3 x MaxRtrAdvInterval divided by 8, or 8191", and unsolicited RAs come every 200-600 s by default, up to 1800 s (RFC 4861 6.2.1). claton section 7.1 says a node "MAY send RS" when it suspects renumbering (`standards-requirements.md` line 171).

Budget that follows:

1. One RS burst (up to 3, 4 s apart, stop at the first RA) per uplink attach: service start with an IPv6 default route present, new IPv6 default route, PPP session up.
2. If an RA arrived but carried no PREF64: **no further RS**. Listen passively; unsolicited RAs cost nothing and will carry the option when the network starts offering it. (An operator who adds PREF64 later reaches idle boxes within one `MaxRtrAdvInterval`, or at their next reconnect.)
3. If no RA arrived at all: RFC 7559 back-off, capped at one RS per hour.
4. While active: at most one RS shortly before the PREF64 lifetime would expire without having been refreshed (already in DESIGN.md section 6); this is the only RS not tied to an attach event and goes slightly beyond the letter of 6.3.7, as gap-4 section 2.3 notes.

### 5.3 RFC 7050 queries

`https://www.rfc-editor.org/rfc/rfc7050.txt` section 3: "a node should perform Pref64::/n discovery only when needed (e.g., when local synthesis is required, when a new network interface is connected to a new network"; on a negative response "the node MUST obey the Time to Live (TTL) of the response before resending the AAAA resource record query"; on a timeout "the node SHOULD retransmit the DNS query like any other DNS query"; positive answers are cached and discovery "SHOULD" be repeated "ten seconds before the TTL ... expires". Section 6: a knob to disable discovery SHOULD exist. RFC 8880 (via `standards-requirements.md` item B10): query the uplink-learned resolvers only.

Budget that follows:

1. **No query at all while the box has a native IPv4 default route.** A CLAT cannot be activated then, so discovery is not "needed". On dual-stack boxes the supervisor's network activity is zero; it only watches the routing socket.
2. On an IPv6-only uplink: one AAAA query for `ipv4only.arpa` per uplink-learned resolver at uplink attach, and only if no PREF64 is known (RA has priority and only one source is used).
3. Negative answer: next query not before the negative TTL; apply a floor (suggest 15 min) and a ceiling (suggest 24 h) in case the resolver returns extreme values.
4. Timeout or unreachable resolver: normal resolver retransmission for that attempt, then exponential back-off between attempts (suggest 30 s doubling to 1 h). The 30 s to 5 min schedule in DESIGN.md section 6 is too aggressive for a permanently idle fleet box; keep it only for the first minutes after attach.
5. Positive answer: refresh 10 s before TTL expiry.

### 5.4 Footprint

One Python process blocked in `select()` on a routing socket, a filtered raw ICMPv6 socket and a control socket; no tayga, no child processes, no periodic commands. Memory and CPU figures were not measured. **[U]** A model without a daemon (cron job plus hooks) cannot receive unsolicited RAs and would have to solicit periodically, which is worse on both counts.

---

## 6. Design implications

1. Choose record model A: register `clat` whenever the plugin's `enabled` flag is set; express activation purely through tun address plus `/tmp/tun464_router`.
2. `clat_interfaces()` must be a pure function of config.xml. Do not return the live WAN MTU as `mss`; derive `mss` from a setting (or from the uplink's configured MTU in config.xml) so that `plugins_interfaces()` never reports a change at runtime.
3. Keep the device name `tun464` (or any `^tun` name). A name outside core's volatile patterns can stop the boot at the interface-assignment prompt.
4. The `_devices()` function must create the tun unconditionally and stay trivial: it runs inside `rc.bootup` and inside every Apply of the record.
5. Never emit a pf rule from the plugin that uses a bare device name as an address; `on tun464` and parenthesised forms are safe on a missing or address-less device.
6. Model: `<version>`, `enabled` with `Required=Y` and `Default=1`, and a default for every other required field, otherwise the install-time migration cannot persist the defaults.
7. `+POST_INSTALL.post`: `pluginctl -i`, then restart the service; guard on `/conf/config.xml`. `+PRE_DEINSTALL.pre`: stop the service. `+POST_DEINSTALL.post` (skipped when `PKG_UPGRADE=true`): `pluginctl -i`, destroy the tun, `configctl interface routes configure`.
8. The service controller must override `invokeInterfaceRegistration()` so that a user toggling `enabled` (a user-initiated Apply) adds or removes the record; the daemon itself never registers.
9. Activation trigger: `configctl interface newip tun464 force`, always with `force`. Deactivation trigger: router file removal first, then `configctl interface routes configure`. Never `newip` on an address-less tun.
10. Remove the router file in the same step that detects a dead tayga; a leftover file with a purged address produces LOG_ERR lines on every routing run.
11. Uplink := device of the kernel's IPv6 default route; take PD, resolvers and PREF64 from that device only; rebuild on change. Provide one PHP helper action for model-level facts; use `ifctl` for prefix and resolvers; do not use `system list nameservers`.
12. Idle discipline: event-driven only; no external commands on timers; no RS after an RA without PREF64; no RFC 7050 query while native IPv4 exists; DNS re-query bounded by TTL with floor and ceiling.
13. Decide and document the idle admin state of the tun (up or down), because the dashboard colours it; re-assert it from routing-socket events since core sets "up" on each configure.
14. Document for customers: a "CLAT" interface is always listed while the plugin is enabled; it shows no address and no gateway until a NAT64 prefix is found; turning the plugin off removes it.

---

## 7. Open questions

1. Design decision: is a permanently visible, dormant CLAT interface acceptable on boxes that never see a NAT64 prefix, or should the "latched A" variant (register at first discovery, one config write per box lifetime) be built?
2. Design decision: idle tun shown "up" (green, no address) or "down" (red) on the dashboard.
3. Would opnsense/plugins reviewers accept a plugin that is active by default? Only precedents were found, no rule either way.
4. Box test: boot and Apply with an address-less `tun464` record: console output, `_interfaces_hardware()` messages for a tun, whether `ifconfig` prints a `status:` line for a tun (changes the Overview text).
5. Box test: confirm that pfctl on 26.7.6 loads the generated ruleset with `tun464` missing and address-less (code says yes), and what the `mss` key renders to on stable/26.7 (only master's `match ... scrub` form was read here).
6. Box test: after tayga exits, is the IPv4 default route via 192.0.0.2 really gone, and what happens to the IPv6 `-interface` route(s)?
7. Which pkg version does 26.7 ship, does it set `PKG_UPGRADE`, and does it run the old package's `+POST_DEINSTALL` during an upgrade? Only pkg `main` was read.
8. Does `unbound_match_interface()` match the `clat` interface on a default Unbound setup, i.e. does every activation restart Unbound? Not traced.
9. Concurrency of `configctl interface routes configure` with a core-initiated `rc.newwanip` running at the same moment (PPPoE reconnect while the CLAT deactivates); the plain action has no lock.
10. Runtime cost of the idle supervisor and of one PHP helper call on low-end hardware; not measured.
11. ISP facts that set the idle timers: does the BNG include PREF64 in unsolicited RAs or only in solicited ones, its `MaxRtrAdvInterval`, RS rate limiting, and the negative TTL its resolvers return for `ipv4only.arpa` AAAA on a non-NAT64 access.
12. How to obtain a config-derived `mss` value when the PPPoE MTU is negotiated (RFC 4638) rather than configured.
13. stable/26.7 was cross-checked only for the files named in the header; `Config.php`, `filter.lib.inc`, `Gateways.php`, `interfaces.inc` and the firmware scripts were read on master.
