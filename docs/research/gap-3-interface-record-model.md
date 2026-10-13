# Gap 3 - Which interface-record model keeps the CLAT WAN intact across GUI edits (26.7.x and 27.1)

Research date: 2026-10-11. Research only, no design.

Confidence tags: **[V]** verified (primary source read), **[L]** likely (inferred from code that was read, not executed), **[U]** unverified.

Path shorthands:

- `CORE/` = `refs/opnsense-core/src/` (opnsense/core master, HEAD `5de9cc0`, 2026-10-10 18:34 +0200)
- `PLUGINS/` = `refs/opnsense-plugins/`
- `STABLE:` = `https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/` (fetched 2026-10-11; branch HEAD `ea4f01f`, Oct 9 2026). These files were read as targeted fetched excerpts, not line by line.

---

## 0. Answer in short

| Question | Answer |
|---|---|
| (a) Is the #10996 fix in a 26.7.x release? | **No (as of 2026-10-11).** Latest release is 26.7.6 (tag `a842fe4`, Oct 8). `stable/26.7` is 3 commits ahead (HEAD `ea4f01f`, Oct 9) and has none of `099b68a`, `180f245`, `0bcd1e0`. No 26.7.7 tag, no 26.7.7 changelog (HTTP 404). Hotfix 26.7.6_3 does not contain it. Maintainer workaround in the issue: `opnsense-patch 099b68a44`. **[V]** |
| (b) Can a user edit or delete an `internal_dynamic` record in the new Assignments page? | **Yes to both**, on 26.7.6 and on master. Nothing in the model or controller looks at `internal_dynamic`. An applied edit **deletes `internal_dynamic` and `type`** (and every other key the model does not know) from config.xml. A delete removes the record and strips the interface from all firewall/NAT rules. **[V]** |
| (b) Does the next `plugins_interfaces()` run restore things? | **Yes for config keys**: `internal_dynamic` always, plus every key the hook returns (`if`, `enable`, `descr`, `mss`, `type`, ...); a deleted record is re-created under the same key. **But the Assignments apply does not trigger that run**, runtime state is not re-applied by it, deleted rules are not restored, and garbage collection is lost while `internal_dynamic` is missing. **[V]** |
| (c) Legacy `interfaces.php` save | The form rewrites the whole record without `internal_dynamic`, but `write_config()` calls `plugins_interfaces()` **before** serialising, so `internal_dynamic` and all hook-returned keys are back **inside the same save**. Keys the hook does not return (lock, mtu, blockpriv, ...) keep the user's values. **[V]** |
| (d) Is the `_devices()` function the only re-sync point after `interface_reset()`? | It is the only core hook that runs **between** the reset and `system_routing_configure()` (and it runs before the address flush). It is not the only hook: `plugins_configure('updateip'|'ipsec'|'dhcp'|'dns')` run after routing in both apply paths, the trailing `filter reload` runs `_firewall()` hooks, and every `Config::save()` fires the `config` syshook. The device function itself does not run for a disabled or deleted record. **[V]** |
| Which model survives GUI edits? | Neither is edit-proof on 26.7.6. Only the `<plugin>_interfaces()` model has a core-provided restore path (in-request for the legacy page, deferred for the MVC page) and a stable record id. A plugin-created `optN` has no restore path and no precedent; core treats it as user-owned. See section 7. |

---

## 1. (a) Backport status of #10996

### 1.1 The issue

`https://github.com/opnsense/core/issues/10996` (opened and closed 2026-10-10, label `bug`, milestone **27.1**, assignee fichtner). Title: "26.7.6: saving a WireGuard interface via the new assignments MVC/API writes ipaddr=none and strips the tunnel address on apply". Reporter adds that creating a new WireGuard assignment in the grid gives the same result. fichtner: fixed by `099b68a44`, with the patch command `# opnsense-patch 099b68a44`. AdSchellevis: constraints added in `0bcd1e0`. The words `stable/26.7`, `cherry-pick`, `hotfix`, `26.7.7` do not appear in the thread. **[V]**

### 1.2 The three commits (all master, Oct 10 2026)

| Commit | Content | Source |
|---|---|---|
| `099b68a4498fe8583901ef40b73783cf03391426` "interfaces: do not render \"none\" to configuration #10996" | Only `NetworkInterface.xml`: removes `<Required>Y</Required>`, `<Default>none</Default>`, `<none>None</none>` from `type4` and `type6`, adds `<BlankDesc>None</BlankDesc>` | `https://github.com/opnsense/core/commit/099b68a44.diff` |
| `180f2451701bd111a622956a6cd41cb7b8f4618c` "interfaces: small follow-up regarding 'none' use #10996" | `NetworkInterface.php`: PPP validation compares with `''` instead of `'none'`; `isEqual('pppoev6')` | `https://github.com/opnsense/core/commit/180f2451701bd111a622956a6cd41cb7b8f4618c.diff` |
| `0bcd1e0ef0d92410bd64c97ff68e566533907003` "Interfaces: Assignments - add some missing constraints ..." | `DeviceField.php` (+`isConfigurable()`, `canSpoofmac()`), `NetworkInterface.php` (+2 validations), `NetworkInterface.xml` (+UniqueConstraint on `descr`), `list_assign_options.php` (+`configurable`, `spoofmac` for plugin devices) | `https://github.com/opnsense/core/commit/0bcd1e0ef0d92410bd64c97ff68e566533907003.diff` |

Follow-up `f681fc2` "interfaces: defaults for \"configurable\" and \"spoofmac\" are ensured in plugins_devices()" (Oct 10) is also master only (`https://github.com/opnsense/core/commits/master/src/opnsense/mvc/app/models/OPNsense/Interfaces`). **[V]**

### 1.3 Release and branch state

- Tags (`https://github.com/opnsense/core/tags`): newest is `26.7.6` = `a842fe4`, Oct 8 2026. No `26.7.7`. **[V]**
- `https://github.com/opnsense/core/compare/26.7.6...stable/26.7`: 3 commits - `8f05eca` (alias diagnostics), `5b0605a` "interafces: PPP type validation fixes for new assignments", `ea4f01f` (UidField revert). None of the three fix commits. **[V]**
- `https://github.com/opnsense/core/commits/stable/26.7/src/opnsense/mvc/app/models/OPNsense/Interfaces`: top entries `5b0605a` (Oct 9) and `786c2e0` (Oct 7, "Interfaces: Assignments - add interface configuration settings in new assignments page"). **[V]**
- `STABLE:opnsense/mvc/app/models/OPNsense/Interfaces/NetworkInterface.xml`: `type4` and `type6` still have `<Required>Y</Required>`, `<Default>none</Default>`, option `none`, no `BlankDesc`. **[V]**
- Changelog: `https://raw.githubusercontent.com/opnsense/changelog/master/community/26.7/26.7.6` is dated "@ October 08, 2026" and lists "interfaces: add interface configuration settings in new assignments page" and "interfaces: add a new 'updateip' hook". Its only hotfix section, "A hotfix release was issued as 26.7.6_3", lists "interfaces: PPP type validation fixes for new assignments" and two unrelated items. `.../community/26.7/26.7.7` returns HTTP 404. **[V]**

Conclusion: every installed 26.7.6 (including 26.7.6_3) has the bug. Whether 26.7.7 picks the fix is not stated anywhere. **[V]** for the present state, **[U]** for 26.7.7.

### 1.4 Why 26.7.6 writes `none`

`STABLE:.../FieldTypes/NetworkInterfaceField.php` `toLegacy()` (identical to master `CORE/opnsense/mvc/app/models/OPNsense/Interfaces/FieldTypes/NetworkInterfaceField.php:44-55, 93-99`):

```php
} else {
    $result['ipaddr'] = $this->type4->getValue();
}
...
if ($value === '' && !in_array($key, ['descr', 'spoofmac'])) {
    unset($result[$key]);
}
```

On 26.7.6 the "None" choice has the value `none`, so it is not empty and is written as `<ipaddr>none</ipaddr>` / `<ipaddrv6>none</ipaddrv6>`. The file contains no special handling of the string `none`. **[V]**

Core then flushes on every configure because the test is only "non-empty" (`CORE/etc/inc/interfaces.inc:2308-2314`, same on stable):

```php
if (!empty($wancfg['ipaddr'])) {
    interfaces_addresses_flush($device, 4, $ifconfig_details);
}
if (!empty($wancfg['ipaddrv6'])) {
    interfaces_addresses_flush($realifv6, 6, $ifconfig_details);
}
```

`interfaces_addresses_flush()` deletes every address of that family except link-local (`interfaces.inc:2215-2238`). For a CLAT tun this removes the IPv4 point-to-point pair and any global IPv6 address. **[V]**

Scope of the 26.7.6 hazard:

- Triggered by saving **that interface** in the Assignments dialog or creating one in the grid/API with defaults (issue text). **[V]**
- A record that is not opened is not rewritten when another interface is saved: `fromLegacy()` maps a missing `ipaddr` to `''` (`$data[$key] = !empty($data[$key]) ? $data[$key] : '';` then `$this->type4 = ... : $data['ipaddr'];`), and the change detection compares `''` with `''`. **[L]** (stable code read as fetched excerpts; same statements as master `NetworkInterfaceField.php:136-144`, `NetworkInterface.php:141-156`)
- 26.7.6 has **no** `configurable` check in the MVC model: `STABLE:.../NetworkInterface.php` `performValidation()` has 11 messages, none of them "Cannot assign an IP configuration type to a tunnel interface."; `STABLE:.../FieldTypes/DeviceField.php` defines only `actionPostLoadingEvent()` and `setValue()`; `STABLE:opnsense/scripts/interfaces/list_assign_options.php` emits only `value`, `optgroup`, `data`. So `_devices()` `configurable => false` protects only the legacy page on 26.7.6. **[V]**
- On 26.7.6 `type4`/`type6` are `Required`, so the API cannot store an empty type at all; an interface created through `add_item` always gets `none`. **[L]**

---

## 2. How the new Assignments code treats interface records (master and 26.7.6)

Everything in this section is the same on `stable/26.7` unless noted (checked: `iterate_assignments`, constructor, `serializeToConfig`, `reconfigureAction`, `delItemAction`, `cleanRules`).

### 2.1 Which records it sees

`CORE/opnsense/mvc/app/models/OPNsense/Interfaces/NetworkInterface.php:57-65`:

```php
foreach (Config::getInstance()->object()->interfaces->children() as $key => $intf) {
    if (!empty((string)$intf->virtual)) {
        continue;
    }
    yield $key => $intf;
}
```

The constructor loads every yielded record into the in-memory model (`:93-114`). `internal_dynamic` is not referenced in `NetworkInterface.php`, `NetworkInterface.xml`, `NetworkInterfaceField.php` or `Api/AssignmentController.php` (grep over `CORE/`: the string occurs only in `plugins.inc`, `filter.inc:576`, `filter.lib.inc:587`, `overview.volt:132`, `Base/FieldTypes/InterfaceField.php:122-124` and two test fixtures). A non-virtual plugin-registered interface is therefore an ordinary grid row. **[V]**

The model (`NetworkInterface.xml`) has no field named `internal_dynamic`, `virtual`, `type` or `networks`. **[V]**

### 2.2 Save (`set_item`)

`ApiMutableModelControllerBase::setBase()` validates the whole model but reports only messages of the edited node (`CORE/opnsense/mvc/app/controllers/OPNsense/Base/ApiMutableModelControllerBase.php:615`, `280-316`), then `save()` calls the model's `serializeToConfig()` and `Config::getInstance()->save()` (`:327-342`).

`NetworkInterface::serializeToConfig()` (`NetworkInterface.php:120-198`):

```php
/* proactively save the fields that have no direct influence on operation */
foreach (['descr', 'lock'] as $ignore) {
    $intf->$ignore = $interfaces[$key][$ignore];
}
...
if ($changed) {
    $this->store_if_todo($key, [
        'pending_action' => $intf->if != $interfaces[$key]['if'] ? 'relink' : 'update',
        'pending' => $this->interface->$key->toLegacy(),
    ]);
}
```

- `descr` and `lock` are written straight into config.xml for **every** non-virtual record on every save, also untouched ones (`:135-138`). `lock` is a BooleanField, so an unlocked record gets `<lock>0</lock>`. Legacy code that uses `isset()` reads that as locked (`CORE/www/interfaces.php:255`), code that uses `!empty()` does not (`AssignmentController.php:86-89`, `console.inc:62`). Same class of problem as `https://github.com/opnsense/core/issues/10881`. **[V]** for the code, **[L]** for the effect.
- Any other changed field only creates an entry in `/tmp/.interfaces.todo` and waits for Apply (`:158-164`). **[V]**
- A description-only or lock-only change needs no Apply and strips nothing. **[V]**

Validation relevant to a plugin device:

- `if` is a `DeviceField` whose option list is `configctl interface list assign-opts` (`FieldTypes/DeviceField.php:41-53`); a value outside the list fails (`Base/FieldTypes/BaseListField.php:189-209`). The list holds physical devices from `get_interface_list()` plus every name in a `_devices()` hook's `names` (`CORE/opnsense/scripts/interfaces/list_assign_options.php:44-76`). `get_interface_list()` skips device names whose non-numeric part is in `interfaces_virtual_patterns()`, which includes `tun`, `tap`, `wg`, `ipsec`, `gif`, `gre` (`CORE/etc/inc/interfaces.lib.inc:563-595, 636-640`). So a `tunN` device is selectable/valid only when a `_devices()` hook lists it; a device with another name (os-tayga's `nat64`) shows up as "Hardware". **[V]**
- Master only (`0bcd1e0`): `NetworkInterface.php:307-327`

```php
if (!$if->if->isConfigurable()) {
    if (!$if->type4->isEmpty()) {
        ... 'Cannot assign an IP configuration type to a tunnel interface.' ...
```

  `isConfigurable()` returns the `configurable` flag from assign-opts and `false` for an unknown device (`DeviceField.php:70-77`). **[V]**
- `if` has a UniqueConstraint (`NetworkInterface.xml:21-29`): a device already bound to the plugin's record cannot be assigned a second time. **[V]**

### 2.3 Apply (`reconfigure`)

`CORE/opnsense/mvc/app/controllers/OPNsense/Interfaces/Api/AssignmentController.php:149-189`:

```php
if (trim($backend->configdRun("interface apply")) == 'OK') {
    Config::getInstance()->lock();
    foreach ($this->getModel()->get_if_todo() as $key => $props) {
        ...
        if ($props['pending_action'] == 'delete') {
            $this->cleanRules($key); /* remove associated rules */
            unset(Config::getInstance()->object()->interfaces->$key);
        } else {
            $pending = $this->getModel()->interface->$key?->toLegacy() ?? null;
            if ($pending !== null) {
                $removals = [ 'adv_dhcp6_config_advanced', ... ];
                foreach (Config::getInstance()->object()->interfaces->$key->children() as $remove) {
                    if (!in_array($remove->getName(), array_keys($pending))) {
                        $removals[] = $remove->getName();
                    }
                }
                foreach ($removals as $remove) { ... unset(...->interfaces->$key->$remove); }
                foreach ($pending as $akey => $avalue) {
                    Config::getInstance()->object()->interfaces->$key->$akey = $avalue;
                }
    ...
    Config::getInstance()->save();
    $this->getModel()->flush_todo();
    $backend->configdRun('filter reload skip_alias', true);
```

Step 1, `interface apply` = `CORE/opnsense/scripts/interfaces/apply_pending_if_changes.php:43-84` (same text on stable):

```php
interface_reset($id, false, !empty($ifcfg['enable']) && !empty($todos[$id]['enable']));   // update
interface_reset($id);                                                                    // delete, relink
...
$config['interfaces'][$ifname] = $todos[$ifname]['pending'];       // in memory only
...
interface_configure(true, $ifname, true, false, true);             // reload = true, batch = true
...
system_routing_configure(true, $to_configure);
plugins_configure('ipsec', true, $to_configure);
plugins_configure('dhcp', true);
plugins_configure('dns', true);
plugins_configure('updateip', true, [$to_configure]);
```

Step 2 (controller) takes the config lock, which **re-reads config.xml from disk** (`CORE/opnsense/mvc/app/library/OPNsense/Core/Config.php:799-811`), deletes every child that `toLegacy()` did not return, writes the pending keys, saves, and reloads the filter. So nothing a plugin writes to config during step 1 can prevent the strip. **[V]**

`toLegacy()` (sanitised) for a tun record with no addressing returns only `if`, `descr`, `spoofmac` (kept even when empty), `enable`/`lock` when set, and whatever the user filled in (`NetworkInterfaceField.php:41-129`). Consequently **`internal_dynamic` and `type` are removed** on every applied edit. **[V]**

### 2.4 Delete (`del_item`)

`AssignmentController.php:61-98`: refuses when the interface is a member of an interface group or bridge or is the parent of a GRE/GIF tunnel, or when

```php
!empty(Config::getInstance()->object()->interfaces->$ifname) &&
!empty(Config::getInstance()->object()->interfaces->$ifname->lock)
```

("Interface locked, unset lock first before removal"). No other guard; `$internalModelUseSafeDelete` is not enabled for this controller (`ApiMutableModelControllerBase.php:192-197`). On Apply: `interface_reset($id)`, no configure; then `cleanRules($key)` removes the interface from `filter.rule`, `nat.rule`, `nat.outbound.rule` and the MVC `rules`, `snatrules`, `npt`, `onetoone` sections, deleting rules that reference only this interface (`:100-138`), then the record is unset (`:155-157`). Gateway items are not touched. **[V]**

---

## 3. (b) `internal_dynamic` record under the new Assignments page

### 3.1 What `plugins_interfaces()` restores

`CORE/etc/inc/plugins.inc:178-242` (identical on stable, fetched):

```php
// mark previous dynamic registrations stale
foreach (config_read_array('interfaces', false) as $intf_ref => $intf_data) {
    if (isset($intf_data[0]['internal_dynamic']) || isset($intf_data['internal_dynamic'])) {
        $stale_interfaces[$intf_ref] = 1;
    }
}
...
    $intf_config = &config_read_array('interfaces', $intf_ref);          // vivifies a missing record
if (!isset($intf_config['internal_dynamic'])) {
    $intf_config['internal_dynamic'] = true;
    $changed = true;
}
foreach ($intf_data as $prop_name => $prop_value) {
    if ((empty($intf_config[$prop_name]) && !empty($prop_value)) || ($intf_config[$prop_name] ?? '') != $prop_value) {
        ...
        $intf_config[$prop_name] = $prop_value;
        $changed = true;
    }
}
...
// cleanup registrations
foreach ($stale_interfaces as $intf_ref => $no_data) { ... unset($config['interfaces'][$intf_ref]); }
```

Walking the cases (code reading, not executed):

| State left by the Assignments page | Result of the next run | |
|---|---|---|
| `internal_dynamic` removed by an applied edit | re-added (`:213-216`) | **[V]** |
| `type` removed | re-added when the hook returns it (`empty(...) && !empty('none')`) | **[V]** |
| `enable` removed (user unticked Enabled; `toLegacy()` drops empty legacy booleans) | set to `true` again when the hook returns `enable => true` | **[V]** |
| `descr` changed | overwritten with the hook's value | **[V]** |
| `if` changed (relink) | overwritten with the hook's device | **[V]** |
| `mss` changed | overwritten when the hook returns `mss`; left alone when it does not | **[V]** |
| `lock`, `mtu`, `spoofmac`, `blockpriv`, `blockbogons`, `promisc`, `gateway_interface`, `ipaddr`, `ipaddrv6` set by the user | **left as the user set them** unless the hook returns that key | **[V]** |
| Whole record deleted | re-created under the same key with exactly the hook's keys plus `internal_dynamic` | **[V]** |

Two consequences of the comparison expression that have no precedent in any shipped hook **[L]**:

- A hook that returns `'ipaddr' => ''` and `'ipaddrv6' => ''` resets a user- or bug-written `none`/`dhcp` to empty (`'none' != ''` is true) and never creates the key when it is absent (`(null ?? '') != ''` is false).
- A hook that returns `'lock' => true` re-locks the record on every run; a hook value `false` clears a user-set boolean, and `Config::fromArray()` then drops the key (`Config.php:214-220`, "skip empty booleans").

Shipped hooks return only `enable`, `descr`, `if`, `type`, `virtual`, `networks`, and for `lo0` address keys (`CORE/etc/inc/plugins.inc.d/ipsec.inc:186-203`, `wireguard.inc:77-84`, `PLUGINS/net/tayga/src/etc/inc/plugins.inc.d/tayga.inc:66-80`). No hook in core or plugins returns `lock`. **[V]**

### 3.2 When that run happens

`plugins_interfaces()` has exactly two callers (grep over `CORE/`): `CORE/sbin/pluginctl:242-245` (`pluginctl -i`, which saves when something changed) and `CORE/etc/inc/config.inc:214-219` (inside every legacy `write_config()`). `pluginctl -i` is run at boot by `convert_config()` (`config.inc:175-176`, called at `CORE/etc/rc.bootup:63`, before the interface mismatch check at `:73` and `interfaces_configure(true)` at `:90`), and on demand through `configctl interface invoke registration` (`CORE/opnsense/service/conf/actions.d/actions_interface.conf:68-72`), which `ApiControllerBase::runInterfaceRegistration()` wraps (`.../Base/ApiControllerBase.php:411-417`) and which many core controllers call (VLAN, bridge, LAGG, GIF, GRE, loopback, VXLAN, wireless settings, firewall groups, WireGuard, OpenVPN, IPsec). **[V]**

`AssignmentController` never calls it, and MVC `Config::save()` does not either. After an Assignments apply the stripped record stays stripped until the next legacy `write_config()`, the next `pluginctl -i`, or a reboot. **[V]**

### 3.3 What is wrong during the window

With `internal_dynamic` absent the record is an ordinary assigned interface:

- `antispoof log for <dev>` is emitted (`CORE/etc/inc/filter.inc:576-577`) and the "force gateway" rule set applies (`CORE/etc/inc/filter.lib.inc:587`). The filter reload at the end of the same Apply already runs in that state. **[V]** (impact on CLAT traffic not assessed)
- The interface appears in every `InterfaceField` selector, including those without `AllowDynamic` (`InterfaceField.php:122-128`), and gets the Settings cog in Interfaces: Overview (`overview.volt:129-133`). **[V]**
- **Garbage collection is lost**: only records carrying `internal_dynamic` at the start of a run are candidates for removal (`plugins.inc:186-190, 233-239`). Sequence: user edits the record in Assignments and applies; the plugin is then disabled so that the hook stops returning the key; the registration run sees a record without the tag and leaves it in config.xml permanently. **[V]** for the code, **[L]** for the sequence.

Dynamic gateway and automatic outbound NAT do **not** depend on `internal_dynamic`: `Gateways::getGateways()` only requires a non-virtual enabled record and a router file (`CORE/opnsense/mvc/app/models/OPNsense/Routing/Gateways.php:261-275, 386-390, 435-441`). They depend on the router file surviving the Apply, see section 5. **[V]**

### 3.4 What the registration run does not repair

- Runtime: it only edits config.xml. No `interface_configure()`, no routing, no filter reload. After a user "disable" that the hook reverts, config says enabled while the router file is still gone. **[V]**
- Rules removed by `cleanRules()` on a delete. **[V]**
- On 26.7.6: the addresses flushed because of `ipaddr=none`. **[V]**

### 3.5 Version-specific behaviour of an Assignments edit

| | 26.7.6 / stable/26.7 | master (27.1 line) |
|---|---|---|
| Dialog save writes `ipaddr=none`, `ipaddrv6=none` | yes (section 1.4) | no (`<BlankDesc>None</BlankDesc>`, empty value dropped) |
| Address type can be set on a `configurable => false` device | yes (no MVC check) | no (`NetworkInterface.php:314-327`) |
| Strip of `internal_dynamic`/`type` on applied edit | yes (`STABLE:.../Api/AssignmentController.php`, same `$removals` loop) | yes |
| Delete of an unlocked record | yes | yes |
| Record with a device not in assign-opts | edit fails validation on `if` | same, and `isConfigurable()` is false |

**[V]**

### 3.6 Core's own precedent has the same exposure

IPsec VTI is the only shipped non-virtual registration (`ipsec.inc:194-202`: `enable`, `descr`, `if`, `type => 'none'`) and it is paired with a `_devices()` entry (`ipsec.inc:208-235`: `function => ipsec_configure_device`, `configurable => false`, `volatile => true`, `names`). An `ipsecN` row in Assignments goes through exactly the code above. No issue or PR about this was found (`https://github.com/opnsense/core/issues?q=internal_dynamic`: 10 old closed results, none about the new page). **[V]**

---

## 4. (c) Legacy `interfaces.php` save

The page is still present and linked on both lines: the Interfaces menu links every non-virtual record to `/interfaces.php?if=<key>` (`CORE/opnsense/mvc/app/models/OPNsense/Interfaces/Menu/Menu.php:63-67, 88-93`; same on stable). Only the Overview cog is hidden for `internal_dynamic` (`overview.volt:129-133`). The GET branch only requires that the record exists (`CORE/www/interfaces.php:150-157`). **[V]**

Save path (`CORE/www/interfaces.php`, same statements on stable):

```php
$a_interfaces = &config_read_array('interfaces');                 // :147, reference into $config
...
$new_config = [];                                                  // :621
$new_config['if'] = $old_config['if'];
$new_config['descr'] = preg_replace('/[^a-z_0-9]/i', '', $pconfig['descr']);
$new_config['enable'] = !empty($pconfig['enable']);
$new_config['lock'] = !empty($pconfig['lock']);
...
$a_interfaces[$if] = $new_config;                                  // :806, record replaced
if (write_config()) {                                              // :809
```

and `write_config()` (`CORE/etc/inc/config.inc:214-226`):

```php
/* XXX temporary workaround for legacy interface creation */
try {
    plugins_interfaces();
} catch (Throwable $e) {
    null;
}
$cnf = OPNsense\Core\Config::getInstance();
$cnf->fromArray($config);
...
    $cnf->save($revision_info, $backup);
```

Because `$a_interfaces` is a reference into the global `$config`, `plugins_interfaces()` sees the freshly replaced record, finds no `internal_dynamic`, re-adds it and re-applies every hook-returned key **before** the config is serialised. The saved config.xml never lacks the tag. **[V]** (code path; not executed)

Effects for the user:

- Changes to hook-owned keys (`descr`, `enable`, `if`, `type`, `mss` when returned) are silently discarded in the same request. That includes the "disable" branch (`interfaces.php:334-345`: `unset($a_interfaces[$if]['enable'])` then `write_config(...)`): the hook's `enable => true` puts it straight back. **[V]**
- Keys the form writes and the hook does not return persist: `lock`, `spoofmac`, `blockpriv`, `blockbogons`, `gateway_interface`, `promisc`, `mtu`, and `mss` when the hook omits it (`:625-638`). **[V]**
- Address types: refused when the device matches a `_devices()` pattern with `configurable => false` (`:374-383`, "Cannot assign an IP configuration type to a tunnel interface."). Without such a device entry the user can select DHCP/static etc. and core will flush the tun addresses. **[V]**

Apply after a legacy save wipes the router file and re-runs the device function:

- master: `configd_run('interface legacy apply')` (`interfaces.php:322-327`) -> `CORE/opnsense/scripts/interfaces/apply_legacy_if_changes.php:43-49`: `interface_reset($ifapply, $ifcfgo, isset($ifcfgo['enable']));` `interface_configure(true, $ifapply, true);` then `filter reload`, `webgui restart 3`.
- stable/26.7: inline in `interfaces.php`: `interface_reset($ifapply, $ifcfgo, isset($ifcfgo['enable']));` `interface_configure(false, $ifapply, true);` then `system_routing_configure(false, array_keys($toapplylist));` `configd_run('filter reload');` (`STABLE:www/interfaces.php`, list file `/tmp/.interfaces.apply`). **[V]**

The comment "XXX temporary workaround for legacy interface creation" marks the `write_config()` call as provisional. The stated direction of the Assignments work is to "eventually merge the configuration pages with interface assignments" (`https://github.com/opnsense/core/issues/10568`). No commit or statement about removing `interfaces.php` was found; it still received commits on Oct 6-7 2026 (`https://github.com/opnsense/core/commits/master/src/www/interfaces.php`). **[V]** for what exists, **[U]** for the timeline.

---

## 5. (d) Re-sync points after `interface_reset()`

### 5.1 What the reset does to a tun with empty `ipaddr`/`ipaddrv6`

`CORE/etc/inc/interfaces.inc:815-910`: address flushes are guarded by `!empty($ifcfg['ipaddrv6'])` (871) and `!empty($ifcfg['ipaddr'])` (891), so nothing is flushed. It always ends with

```php
mwexecf('/usr/local/sbin/ifctl -4c -i %s', $device);
mwexecf('/usr/local/sbin/ifctl -6c -i %s', $realifv6);
```

(908-909). `ifctl -c` removes `/tmp/<dev>_{nameserver,prefix,router,searchdomain}[v6]` plus the `:slaac` variants and runs `arp -d -i <dev> -a`; it does not delete the default route (`CORE/opnsense/scripts/interfaces/ifctl.sh:142-168`, `flush_routes` only handles `prefix`, `:37-55`). **[V]**

With the router file gone `Gateways::getGateways()` emits no dynamic IPv4 gateway for the interface (`Gateways.php:435-441`), `system_routing_configure()` skips the family (`CORE/etc/inc/system.inc:708-711`: `if (empty($gateway['gateway'])) { continue; }`), and the next filter reload produces no automatic outbound NAT for it (`filter.lib.inc:60-73, 176-195`, see `opnsense-plugin-framework.md` d.3). **[V]**

### 5.2 Who calls `interface_reset()`

| Caller | Then | Applies to a CLAT tun record? |
|---|---|---|
| `apply_pending_if_changes.php:49,56` (MVC Apply; only ids present in `/tmp/.interfaces.todo`) | `interface_configure(true, id, true, false, true)` for update/relink/new, nothing for delete | only when that record was edited or deleted |
| `apply_legacy_if_changes.php:44` / inline on stable (legacy Apply; only ids in the apply list) | `interface_configure(true|false, id, true)` | only when that record was saved in the legacy page |
| `interface_suspend()` (`interfaces.inc:912-922`) from `rc.linkup:64` and `rc.syshook.d/carp/20-ppp:64` | - | no: devd link events are raised for ethernet/802.11 only, the CARP hook handles PPP |
| `console.inc:403,432,445`, `opnsense/scripts/shell/setaddr.php:613-614` | console reassignment / "Set interface IP address" | only on explicit console action |

Applying a change to LAN or to the PPPoE WAN does not reset the CLAT record. **[V]**

### 5.3 Hooks core runs in the reset -> configure sequence

`interface_configure()` (`interfaces.inc:2265-2508`):

```php
if (!isset($wancfg['enable'])) {
    return $loaded;                                   // 2270-2272, before everything else
}
...
if ($reload) {                                        // 2287-2298
    foreach ($all_devices as $one_device) {
        if (empty($one_device['function']) || empty($one_device['names']) || !$one_device['reload']) {
            continue;
        }
        if (in_array($realhwif, array_keys($one_device['names']))) {
            log_msg("Device $realhwif requires reload for $interface, configuring now");
            call_user_func_array($one_device['function'], [$realhwif]);
        }
    }
}
...
if (!empty($wancfg['ipaddr'])) { interfaces_addresses_flush(...) }      // 2308-2314, AFTER the device function
...
mwexecf('/sbin/ifconfig %s inet6 -accept_rtadv description %s up', [$device, $ifdescr]);   // 2446
...
if ($reload && !$batch) {                             // 2492-2498
    system_routing_configure($verbose, $interface);
    plugins_configure('ipsec', $verbose, [$interface]);
    plugins_configure('dhcp', $verbose);
    plugins_configure('dns', $verbose);
    plugins_configure('updateip', $verbose, [[$interface]]);
}
```

| # | Re-sync point | Order relative to routing | Conditions | Evidence |
|---|---|---|---|---|
| 1 | `_devices()` `function` | before the address flush and before `system_routing_configure()` | interface has `enable`; device listed in `names`; `reload` not false (default true, `plugins.inc:97-103`) | `interfaces.inc:2287-2298`; boot: `interfaces.inc:694-701, 774-779` |
| 2 | `_configure()` hooks on `updateip` (new in 26.7.6), `ipsec`, `dhcp`, `dns` | after `system_routing_configure()`; after the flush | MVC Apply: fired for every updated/relinked/new id, also when the record is now disabled; not fired when only deletes are pending. Legacy Apply: fired from inside `interface_configure()`, so not for a disabled record | `apply_pending_if_changes.php:74-80`; `interfaces.inc:2492-2498`; consumer example `PLUGINS/dns/rfc2136/src/etc/inc/plugins.inc.d/rfc2136.inc:38` |
| 3 | `_firewall()` at the trailing `filter reload` | after routing, after the MVC controller saved config | always | `AssignmentController.php:188`; `apply_legacy_if_changes.php:48` |
| 4 | `config` syshook: `/usr/local/etc/rc.syshook.d/config/NN-*` run with the backup file as argument after every `Config::save()` that writes a backup | asynchronous, after the save | via syslog-ng -> `configctl -e -t 0.5 system event config_changed` -> `trigger_config_changed_events.py`; an invocation that finds another one running exits 99 | `Config.php:764-771`; `CORE/opnsense/service/templates/OPNsense/Syslog/syslog-ng-config-events.conf:1-13`; `CORE/opnsense/scripts/system/trigger_config_changed_events.py:38-61`; plugin precedent `PLUGINS/sysutils/git-backup/src/etc/rc.syshook.d/config/10-git-backup` |
| 5 | Explicit actions a plugin can invoke: `configctl interface reconfigure <id>` -> `rc.configure_interface` -> `interface_configure(true, id, true)` (no reset); `configctl interface invoke registration` | on demand | - | `actions_interface.conf:1-6, 68-72`; `CORE/etc/rc.configure_interface` |

So the `_devices()` function is **not the only** point, but it is the only one that restores the router file in time for the routing pass and the filter reload of the same Apply. **[V]**

Limits of point 1:

- It is skipped when the record is not enabled (early return at 2270-2272) and never runs for a delete. **[V]**
- It runs before the flush, so on 26.7.6 it cannot repair addresses removed because of `ipaddr=none`; point 2 (`updateip`) runs after the flush. **[V]**
- It runs in-process inside the `interface apply` script. The controller only continues when that script returns `OK` (`AssignmentController.php:149`); otherwise it returns `failed` and leaves the todo file. A fatal error in a plugin device function would therefore block the user's Apply. **[L]**
- Listing the device in `names` is also what makes the device selectable and the record editable in Assignments (section 2.2). **[V]**

Precedent for "device function restores addresses and router file": core GRE/GIF. `core_devices()` registers `'function' => 'interfaces_gre_configure'`, `'configurable' => false`, `'volatile' => true`, `names` (`CORE/etc/inc/plugins.inc.d/core.inc:172-198`), and `_interfaces_gre_configure()` ends with

```php
/* XXX: write XXX_router file */
mwexecf('/usr/local/sbin/ifctl -i %s -%s -rd -a %s', [ $gre['greif'], ..., $gre['tunnel-remote-addr'] ]);
```

(`interfaces.inc:404-464`). IPsec VTI's device function re-creates device and addresses (`ipsec.inc:1675-1678` -> `ipsec_configure_vti(false, $device)`) but writes no router file. **[V]**

---

## 6. Plugin-created `optN` (the alternative model)

- No plugin in `PLUGINS/` writes an `interfaces` record or allocates `optN` (grep for `interfaces->addChild`, `config_read_array('interfaces', 'opt`, `'opt' .` finds nothing relevant). Core allocates `optN` only in the console assigner, the setup wizard and `NetworkInterface::serializeToConfig()` (`NetworkInterface.php:169-196`: first free `opt<N>`, writes `if` and `descr`, parks the rest in the todo file). **[V]**
- Core has no notion of a plugin-owned `optN`. Any marker key a plugin puts inside the record is removed by an applied Assignments edit (section 2.3) and by a legacy save (the form builds `$new_config` from scratch, `interfaces.php:621-806`). The plugin would have to remember the id elsewhere or find the record by device name. **[V]**
- Nothing ever reverts a user edit. `enable` off, a changed `descr` (which renames the automatic gateway, `Gateways.php:393-403`), `gateway_interface`, `mtu` all stay. **[V]**
- Delete protection is the same single mechanism, `lock` (new MVC rows default to `lock = 1`, `NetworkInterface.xml:30-33`). After a delete the plugin has to create a new record; the first free number may differ, and `cleanRules()` has already removed the rule references. **[V]**
- It is an ordinary interface for the firewall: `antispoof` and force-gw rules are generated, it is listed in all interface selectors, Overview shows the Settings cog. **[V]**
- It survives plugin removal (nothing garbage-collects it). **[V]**
- 26.7.6: creating it through `POST /api/interfaces/assignment/add_item` stores `ipaddr=none` (section 1.4); writing config.xml directly avoids that until the user saves the dialog. **[L]**
- Reset/re-sync behaviour (section 5) is identical, because it depends on the `_devices()` entry, not on the record type. **[V]**

---

## 7. Side-by-side

| Property | `<plugin>_interfaces()` record (non-virtual, `internal_dynamic`) | Plugin-created `optN` |
|---|---|---|
| Precedent | core IPsec VTI only | none in plugins |
| Setup clicks | none; created by `pluginctl -i` (boot and on demand) | none if the plugin writes config; no core helper |
| Record id | plugin-chosen, stable across delete/re-create | first free `optN`, may change |
| Legacy save | hook-owned keys restored in the same `write_config()` | user edit persists |
| Assignments edit + Apply | `internal_dynamic`, `type` stripped; restored at next registration run, which the Apply does not trigger | user edit persists; plugin marker keys stripped |
| Assignments delete | possible unless `lock`; record re-created at next registration; rules already cleaned | possible unless `lock`; plugin must re-create; rules already cleaned |
| User can disable/rename it in Interfaces | reverted (hook-owned) | yes, permanently |
| 26.7.6 `ipaddr=none` on dialog save | yes; hook could reset it at next registration **[L]** | yes; nothing resets it |
| master: address type blocked for `configurable => false` | yes | yes |
| antispoof / force-gw rules | suppressed while tagged; generated during the stripped window | always generated |
| Interface selectors without `AllowDynamic` | hidden while tagged | listed |
| Removed when plugin is disabled/removed | yes if still tagged at that moment; orphaned if stripped | never |
| Router file after an Apply on the record | device function (needs `names`, `enable`) | same |

---

## 8. Design implications (facts a designer must respect)

1. Plan for unfixed 26.7.6 installations: any save of the CLAT record in the new Assignments dialog writes `ipaddr=none`/`ipaddrv6=none`, and core then flushes the tun addresses on every `interface_configure()`. `configurable => false` does not prevent this on 26.7.6.
2. On master the `_devices()` entry with `configurable => false` is what blocks address types in both pages. The same entry (with `names`, `function`, `reload` left true) is what gives the router-file re-sync, and it also makes the row editable in Assignments.
3. With the registration model, treat every key the hook returns as plugin-owned (user changes are reverted) and every key it omits as user-owned (persisting). `enable` must be returned (core skips records without it), so the interface cannot be disabled from the Interfaces pages.
4. Do not rely on `internal_dynamic` being present at any given moment: an applied Assignments edit removes it and nothing in that flow restores it. Anything that must hold in that window (gateway, NAT, router file) must not depend on the tag. Gateway and automatic NAT do not.
5. A registration run has to be triggered by the plugin if prompt re-tagging matters; core offers `configctl interface invoke registration` and the `config` syshook as carriers. The syshook is asynchronous and `pluginctl -i` writes the whole config from its own in-memory copy.
6. Garbage collection only works while the tag is present. A plugin that stops returning its key cannot assume the record disappears.
7. `lock` is the only delete guard in the Assignments API. Without it a delete also removes the user's rules on the CLAT interface, and a re-created record does not bring them back. A `lock` on any interface also disables the boot-time interface mismatch prompt (`console.inc:61-65`).
8. The device function must be idempotent, fast and unable to fatal: it runs inside the user's Apply and at boot. It runs before the address flush and not at all for a disabled or deleted record; a second repair point after the flush exists only as `updateip`/own reconcile.
9. A registration run changes config only. After it re-creates or re-enables a record the plugin has to re-apply runtime state itself.
10. A plugin-created `optN` cannot carry a durable ownership marker inside the record, and its id is not stable across delete/re-create.
11. Device naming matters: `tunN` is offered for assignment only through a `_devices()` hook; another name is listed as hardware. `^tun` is already a volatile pattern (`core.inc:291`), a custom name needs its own `volatile` pattern to stay out of the boot mismatch check.

---

## 9. Open questions

1. Will 26.7.7 contain `099b68a`/`180f245`/`0bcd1e0`? Nothing published says so (milestone is 27.1; only `opnsense-patch` is offered).
2. Will 27.1 still ship `interfaces.php`, and will `write_config()` keep calling `plugins_interfaces()` (comment: "temporary workaround")? If the legacy page goes, the in-request restore of section 4 goes with it.
3. Will core change the Assignments page for non-virtual `internal_dynamic` rows (hide them, lock them, or preserve unknown keys)? IPsec VTI has the same exposure today; no issue exists.
4. Not executed anywhere: the `plugins_interfaces()` behaviour for hook values `''`, `false` and `lock => true` (section 3.1), and the claim that an untouched record is not rewritten with `none` on 26.7.6 (section 1.4). Both are code readings.
5. Effect of the temporary `antispoof` and force-gw rules on CLAT traffic during the stripped window was not analysed.
6. Runtime timing and reliability of the `config` syshook after the stripping save (syslog-ng `program()` destination, 0.5 s event batching, exit 99 when busy) was not measured; concurrent `pluginctl -i` writes were not analysed.
7. Master as of 2026-10-10: `list_assign_options.php:44-54` gives physical devices no `configurable` key while `DeviceField::isConfigurable()` reads it without a default (`f681fc2`). Whether hardware interfaces currently fail the new validation was not tested; it shows this code is still moving.
8. An existing config that already contains `ipaddr=none` from 26.7.6: no migration was found in the fix commits; behaviour after upgrading was not checked.
