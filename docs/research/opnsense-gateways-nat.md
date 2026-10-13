# OPNsense: how core treats a plugin-created IPv4 point-to-point tun(4) (gateways, default route, monitoring, automatic firewall/NAT)

Research date 2026-10-10. Scope: facts only, no design.

Sources (all read directly unless marked otherwise):

- `core/` = `refs/opnsense-core` (opnsense/core **master**, HEAD `5de9cc0dcc` dated 2026-10-10)
- `src/` = `refs/opnsense-src` (opnsense/src **stable/26.7**)
- `plugins/` = `refs/opnsense-plugins` (master), `tayga/` = `refs/tayga` (apalrd/tayga master)
- stable/26.7 cross-checks were done through `https://raw.githubusercontent.com/opnsense/core/stable/26.7/...` (fetched, line-level excerpts; no line numbers available). Every code path below that matters was found **identical in stable/26.7** unless a difference is called out (the only difference found: scrub/MSS syntax, section 6).

Running example: device `tun0` (or any name), local `192.0.0.1`, peer `192.0.0.2`, assigned to an OPNsense interface with description `CLAT`. LAN is `igb1` / `192.168.1.0/24`. WAN is `pppoe0` with IPv6CP only.

Confidence legend: **[V]** verified by reading the primary source; **[L]** likely (inferred from verified code, not runtime-tested); **[U]** unverified.

---

## 0. One-paragraph answer

An enabled, non-`virtual` entry in `<interfaces>` whose device has an IPv4 address and a file `/tmp/<device>_router` containing the peer address is, for core, a full IPv4 "WAN": a dynamic gateway `<DESCR>_GW` appears without any gateway config, it becomes the IPv4 default route when it is the best `inet` candidate (it is the only one when PPPoE has no IPv4), and automatic/hybrid outbound NAT generates `nat on tun0 inet from (<lan>:network) to any -> (tun0:0)`. Nothing of that needs a plugin-generated pf rule or a user click, and the interface entry itself can be registered by the plugin through the `<plugin>_interfaces()` hook (IPsec VTI precedent). There is **no** gateway plugin hook; the `ifctl` router file is the runtime mechanism. The one thing core does **not** do automatically: pass the translated **IPv6** packets that a tun-based translator (tayga) re-injects **inbound on the tun**; without a pass rule they hit the default deny.

---

## 1. How a gateway comes to exist

File: `core/src/opnsense/mvc/app/models/OPNsense/Routing/Gateways.php`.

### 1.1 Inputs

`getGateways()` (329-484) builds the list from exactly three inputs **[V]**:

1. Built-in `Null4`/`Null6` loopback gateways (340-357, `is_loopback`).
2. Configured items: `gatewayIterator()` (192-255) reads MVC `//OPNsense/Gateways/gateway_item` (model `Gateways.xml:2,6`), falling back to legacy `<gateways><gateway_item>` only when no MVC item exists.
3. Dynamic gateways derived from **interfaces in config.xml** plus **ifctl files in /tmp**.

There is no other source. In particular there is no plugin hook (section 8).

### 1.2 Configured items: static vs. "configured dynamic"

```php
// Gateways.php:370-383
if (Util::isIpAddress($gw_arr['gateway'])) {
    if (empty($gw_arr['monitor_disable']) && empty($gw_arr['monitor'])) {
        $gw_arr['monitor'] = $gw_arr['gateway'];
    }
    $gwkey = $this->newKey($gw_arr['priority'], !empty($gw_arr['defaultgw']));
    $this->cached_gateways[$gwkey] = $gw_arr;
} else {
    // dynamic gateways might have settings, temporary store
    ...
    $gw_arr['dynamic'] = true;
    $dynamic_gw[$gw_arr['interface']][] = $gw_arr;
}
```

- `gateway` field holding an IP -> static gateway, always listed.
- `gateway` empty (or the string `dynamic`) -> the item only carries *settings* (name, priority, defaultgw, monitor ...) for the dynamic gateway of that interface + address family; it is matched by `interface` and `ipprotocol`, not by name (423-432).
- Model validation `validateDynamicMatch()` (142-161) only allows an empty `gateway` when the interface has no static address of that family: "Dynamic gateway values cannot be specified for interfaces with a static %s configuration."
- `createOrUpdateGateway($fields, $uuid = null)` (166-185) exists as a programmatic writer ("Backwards compatibility for wizard, setaddr"); it writes config.xml.

### 1.3 Dynamic gateways: exact conditions

Loop over `getDefinedInterfaces()` = every `<interfaces>` child whose `virtual` is not `1` (261-275), skipping interfaces without `enable` (387-390). For each of `inet`, `inet6`:

```php
// Gateways.php:393-410
$descr = !empty($ifcfg['descr']) ? $ifcfg['descr'] : $ifname;
$device = Util::getRealInterface($ifname, $ipproto);
$ctype = self::convertType($ipproto, $ifcfg);
$ctype = $ctype != null ? $ctype : "GW";
$thisconf = [
    "interface" => $ifname,
    "weight" => '1',
    "ipprotocol" => $ipproto,
    "name" => strtoupper("{$descr}_{$ctype}"),
    "descr" => "Interface " . strtoupper("{$descr}_{$ctype}") . " Gateway",
    "monitor_disable" => '1', // disable monitoring by default
    "monitor_noroute" => '0', // enabled host route by default
    "gateway_interface" => false, // Dynamic gateway policy
    "if" => $device,
    "dynamic" => true,
    "virtual" => true
];
```

Then, in this order (433-467) **[V]**:

| # | Condition | Result |
|---|-----------|--------|
| a | virtual entry whose name is already used by a configured gateway | nothing added |
| b | `($router = Autoconf::getRouter($device, $ipproto)) != null` | gateway with `gateway = $router`; monitor defaults to the gateway address if monitoring is enabled |
| c | `!empty($ifcfg['gateway_interface']) || substr($device, 0, 5) == 'ovpnc'` | address-less gateway, `gateway_interface = true`, **`ipprotocol = ''`** |
| d | `inet6` and `ipaddrv6` in `['6rd','6to4','dhcp6','slaac']` | address-less IPv6 gateway |
| e | a configured dynamic item exists but none of the above matched | item goes to the defunct list |

`Autoconf::getRouter()` (`core/src/opnsense/mvc/app/library/OPNsense/Interface/Autoconf.php:36-48,61-64`) is just a file read:

```php
$fsuffix = $ipproto == 'inet6' ? 'v6' : '';
foreach (['', ':slaac'] as $isuffix) {
    $file = "/tmp/{$if}{$isuffix}_{$type}{$fsuffix}";   // type = 'router'
    if (file_exists($file)) { return trim(@file_get_contents($file)); }
}
```

So the IPv4 rule is: **`/tmp/<device>_router` exists** (IPv6: `/tmp/<device>_routerv6`, fallback `/tmp/<device>:slaac_router[v6]`). There is no check of the interface's `ipaddr` type and no device-name restriction. **[V]**

The files are written by `ifctl` (`core/src/opnsense/scripts/interfaces/ifctl.sh`, man page `core/src/man/man8/ifctl.8`): `FILES="nameserver prefix router searchdomain"` (30), `FILE="/tmp/${IF:-*}_${MD}${EX}"` (234). Writers in core **[V]**:

- PPP: `ppp-linkup.sh:27-30` -> `ifctl -i ${IF} -4rd ${ROUTER}` then `configctl -d interface newip ${IF} force`; removed again in `ppp-linkdown.sh:13-16`.
- **GIF/GRE (closest precedent to a p2p tun)**: `core/src/etc/inc/interfaces.inc:459-464` and `555-560`:
  ```php
  /* XXX: write XXX_router file */
  mwexecf('/usr/local/sbin/ifctl -i %s -%s -rd -a %s', [$gif['gifif'], is_ipaddrv4(...) ? '4' : '6', $gif['tunnel-remote-addr']]);
  ```
  i.e. core itself configures `ifconfig gifX <local> <remote> netmask ...` and registers the **tunnel peer** as the dynamic router.
- 6rd/6to4 (`interfaces.inc:2699,2785`), rtsold (`rtsold_script.sh:60`).

### 1.4 Generated names

`convertType()` (283-306): device prefix `ovpnc` -> `VPNv4`/`VPNv6`; `gif`/`gre` -> `TUNNELv4`/`TUNNELv6`; otherwise the non-IP `ipaddr`/`ipaddrv6` config value (`dhcp`, `pppoe`, `dhcp6`, `slaac` ...); otherwise `GW`. Name = `strtoupper("{$descr}_{$ctype}")`.

- PPPoE WAN, IPv4 type PPPoE: `WAN_PPPOE`.
- A tun assigned as `CLAT` with IPv4 type "None": **`CLAT_GW`**, description "Interface CLAT_GW Gateway". **[V]**

### 1.5 Priority, `defaultgw`, ordering

```php
// Gateways.php:412-421
if (str_starts_with($device, 'gre') || str_starts_with($device, 'gif') ||
    str_starts_with($device, 'ovpn') || str_starts_with($device, 'wg') ||
    str_starts_with($device, 'ipsec')) {
    // consider tunnel type interfaces least attractive by default
    $thisconf['priority'] = 255;
} else {
    $thisconf['priority'] = 254;
}
```

```php
// Gateways.php:314-323
return sprintf("%01d%04d%010d", $is_default, 256 - $prio, $this->gatewaySeq++);
// Gateways.php:471
krsort($this->cached_gateways);
```

- A `tun*` (or custom-named) device is **not** in the tunnel list -> dynamic default priority **254**, the same as a dynamic `WAN_PPPOE`/`WAN_DHCP`. **[V]**
- Sort order: `defaultgw` ("Upstream Gateway", `dialogEditGateway.xml:53-56`) first, then lower priority number ("lower means more important", `dialogEditGateway.xml:42`), then **higher sequence number, i.e. the gateway registered later wins a tie** (static items are registered first in config order, dynamic ones afterwards in `<interfaces>` order). **[V by code reading; L for runtime]**
- A dynamic gateway's priority/defaultgw/monitor can only be changed through a configured `gateway_item` with empty `gateway` for the same interface + family. Without one it is hard-coded 254 / not upstream / monitoring disabled.

`getDefaultGW($skip, $ipproto)` (493-513) returns the **first** gateway of that family that is not in `$skip`, not `disabled`, not `defunct`, not `is_loopback`, not `force_down`.

### 1.6 Defunct handling

Configured dynamic items whose interface currently has no router (or is disabled) are appended with `defunct = true` and `gateway` unset (473-481). `getDefaultGW()` and `getInterfaceGateway()` skip them (500-505, 597-600). A purely virtual dynamic gateway simply disappears when the router file disappears.

### 1.7 Far gateway

- Config flag `fargw` (`Gateways.xml:49`, "allow the gateway to exist outside of the interface subnet").
- Automatic for dynamic gateways, `core/src/etc/inc/system.inc:572-615` (`system_interface_route()`): if the gateway equals the ifctl router and is outside the primary address' network it logs `ROUTING: treating '{$gateway}' as far gateway for '{$network}'`, then **keeps any existing host route on the device** (`gateway` starting with `link#`, flag `H`; 594-609) and only otherwise runs `route add -inet <gw> -interface <dev>`.
- For a p2p tun configured `192.0.0.1 --> 192.0.0.2 netmask 0xffffffff` the kernel already has the `UH` host route to the peer, so nothing is added **[L]**. `legacy_interfaces_details()` parses the p2p form correctly (`core/src/etc/inc/interfaces.lib.inc:326-336`: `'tunnel' => true, 'endpoint' => $line_parts[3]`). **[V]**

### 1.8 What the `gateway_interface` ("Dynamic gateway policy") flag does *not* give you

Case (c) above produces a gateway with `ipprotocol = ''` and no address. Consequences **[V]**:

- `getDefaultGW()` compares `$gateway['ipprotocol'] == $ipproto` -> never the default gateway.
- `getInterfaceGateway()` skips `empty($gateway['gateway'])` (599) -> the interface has no gateway for the firewall -> **no automatic outbound NAT, no reply-to, no force-gw rule**.
- It is only usable as a `route-to <if>` policy-routing target (`Plugin.php:105-116`).

---

## 2. IPv4 default route when PPPoE has no IPv4

`system_routing_configure($verbose, $interface_map, $monitor, $family)` - `core/src/etc/inc/system.inc:657-818`.

```php
// system.inc:703-723
$gateway = $gateways->getDefaultGW($down_gateways, $ipproto);
if (empty($gateway['gateway'])) { continue; }
if (isset($config['system']['gw_switch_default']) || empty($interface_map) || in_array($gateway['interface'], $interface_map)) {
    if (empty($ifdetails[$gateway['if']][$type][0])) {
        log_msg("ROUTING: refusing to set {$ipproto} gateway on addressless {$gateway['interface']}({$gateway['if']})", LOG_ERR);
        continue;
    }
    log_msg("ROUTING: configuring {$ipproto} default gateway on {$gateway['interface']}", LOG_INFO);
    system_default_route($gateway, $routes);
}
```

`system_default_route()` (617-655) does `route delete -inet default` + `route add -inet default <gw>` unless the route already matches.

### 2.1 PPPoE WAN without IPv4 has no IPv4 gateway at all **[V]**

- The WAN's IPv4 dynamic gateway exists only if `/tmp/pppoe0_router` exists, which is only written by `ppp-linkup.sh` when mpd calls it with `inet` (IPCP up).
- `interface_ppps_configure()` (`interfaces.inc:1059-1084,1172-1173`) emits `set bundle {$ipv4_mode} ipcp` / `set bundle {$ipv6_mode} ipv6cp`; IPv4 is only enabled for `ipaddr` in `ppp|pppoe|l2tp`. With IPv4 type "None" + IPv6 `pppoev6|dhcp6|slaac`, IPCP is disabled outright. `www/interfaces.php:857-876` offers exactly `None` or `PPPoE` for IPv4 on a PPPoE device.
- A user-edited `WAN_PPPOE` item (configured dynamic) becomes **defunct** and is skipped.

### 2.2 Result

With no WAN IPv4 gateway the CLAT gateway is the only non-loopback `inet` candidate, `getDefaultGW()` returns it and the default route `0.0.0.0/0 -> 192.0.0.2` is installed. **No gateway switching, no `defaultgw` flag, no priority tuning is needed.** **[V code path; L runtime]**

Preconditions hidden in the code:

1. The tun must have an IPv4 address at that moment, else "refusing to set inet gateway on addressless" and **no fallback to another gateway** (`continue`).
2. `system_routing_configure()` must actually run with either no interface map or a map containing the CLAT interface. Triggers:
   - boot: `core/src/etc/rc.bootup:94` `system_routing_configure(true, null, 'ignore')` (after `interfaces_configure()`, line 90);
   - `configctl interface newip <device> force` -> `core/src/etc/rc.newwanip:123-125`: `system_routing_configure(false, $interfaces, true, 'inet'); filter_configure_sync();` followed by `plugins_configure('vpn'...)` and `plugins_configure('newwanip', false, [$interfaces, $family])` (142-143). It returns early if the interface is not enabled (57-60) or has no IPv4 (65-69), and is deferred during boot (`exit_on_bootup`, 44-47; replayed by `rc.syshook.d/start/10-newwanip`);
   - `configctl interface routes configure` -> `rc.routing_configure:73-79` (routes for all + filter reload);
   - plugin hook `route_reload` => `system_routing_configure:2` (`core/src/etc/inc/plugins.inc.d/core.inc:442`; used by IPsec VTI at `ipsec.inc:1473`);
   - interface apply in the GUI (`interface_configure(..., $reload = true)` -> `interfaces.inc:2492-2494`).
3. Core never deletes a default route by itself when the gateway vanishes; it only replaces. (The kernel removes routes when the tun is closed, see 3.4.)

### 2.3 Role of "Gateway switching" (`system.gw_switch_default`)

GUI text (`www/system_general.php:548-554`): "Allow default gateway switching - If the link where the default gateway resides fails switch the default gateway to another available one." Not set in the default config. In code it does exactly two things **[V]**:

- `system.inc:690-697`: gateways whose monitor status contains `down` are put in `$down_gateways` and skipped by `getDefaultGW()`.
- `system.inc:713`: the default route is re-evaluated on *every* `system_routing_configure()` call, even one scoped to another interface.
- `gateway_watcher.php:104-109,147-149`: down/up transitions trigger `interface routes alarm` -> `rc.routing_configure alarm`.

It is irrelevant for the pure IPv6-only-PPPoE case. It matters only for failover between several IPv4 gateways, and it requires monitoring to be enabled on them (a gateway with `monitor_disable` reports status `none`, never `down`: `dpinger.inc:318`).

### 2.4 Traps

- **Dual-stack session (IPCP does come up):** `WAN_PPPOE` and `CLAT_GW` both exist with priority 254. Because of the tie-break (later registered wins) and `wan` being first in `<interfaces>`, **the CLAT gateway sorts first and takes the IPv4 default route** unless a `gateway_item` gives the CLAT gateway priority 255 (or WAN is marked upstream). **[V code reading; L runtime]**
- **Stale static IPv4 gateway on an address-less interface** (a `gateway_item` with an IP, especially with `defaultgw=1`): it is not defunct, `getDefaultGW()` returns it first, the route is refused as "addressless" and the loop `continue`s - **the CLAT gateway is never tried**, unless gateway switching is on *and* that gateway is monitored and down. **[V]**

---

## 3. Automatic outbound NAT (modes `automatic` and `hybrid`)

### 3.1 Which interfaces are "WAN"

`core/src/etc/inc/filter.lib.inc:54-88` computes one value per enabled config interface:

```php
// filter.lib.inc:60-68
$cnfint = legacy_config_get_interfaces(["enable" => true]);
foreach ($cnfint as $key => &$value) {
    if (!is_ipaddrv4($value['ipaddr']) || (!empty($value['gateway']) && $value['gateway'] != 'none')) {
        $value['gateway'] = $gateways->getInterfaceGateway($key, "inet", true);
    } else {
        $value['gateway'] = null;
    }
```

`getInterfaceGateway($interface, 'inet', $only_configured = true)` (`Gateways.php:594-620`) returns the gateway **address** of the first enabled, non-defunct `inet` gateway on that interface that has an address and satisfies

```php
if (!$only_configured || $intf_gateway == $gateway['name'] || !empty($gateway['dynamic'])) {
```

i.e. either a **dynamic** gateway (router file) or a configured gateway whose name is stored in the interface's own `<gateway>` setting.

`filter_auto_source_nat()` (`filter.lib.inc:176-195`):

```php
if (in_array($outbound['mode'] ?? '', ['', 'automatic', 'hybrid'])) {
    ...
    $networks = array_merge(...array_values(plugins_run('networks_source_nat', [$fw])));
    foreach ($fw->getInterfaceMapping() as $interface => $ifcfg) {
        /* XXX VPN is allowed but not OpenVPN dropping /tmp/ovpnxy_router(v6) file */
        if (substr($ifcfg['if'], 0, 4) != 'ovpn' && !empty($ifcfg['gateway'])) {
            $ret[$interface] = $networks;
        }
    }
}
```

So "WAN-ness" = *enabled interface, device name not starting with `ovpn`, has an IPv4 gateway by the rule above*. A tun with a router file qualifies; the interface's `ipaddr` being empty is fine (`!is_ipaddrv4(null)` is true). **[V]**

Corollary: a **static** `gateway_item` (IP in `gateway`) on an interface with IPv4 type "None" does **not** qualify unless the interface record carries `<gateway>NAME</gateway>`. `www/interfaces.php:650-657` writes that key only for type `staticv4`, and rewrites the whole interface record on save (`$a_interfaces[$if] = $new_config;`, 806), so a hand-injected `<gateway>` is lost on the next GUI save. The dynamic route has neither problem. **[V]**

### 3.2 Which source networks

`pf_get_default_nat_outbound_networks()` (`core/src/etc/inc/plugins.inc.d/pf.inc:285-300`):

```php
foreach ($fw->getInterfaceMapping() as $intf => $intfcf) {
    if (!empty($intfcf['ifconfig']['ipv4']) && empty($intfcf['gateway'])) {
        $result[$intf] = sprintf(gettext('%s networks'), $intfcf['descr']);
    }
}
$result[$loopback] = $loopback;   // '127.0.0.0/8'
```

= every enabled interface that currently has an IPv4 address and no IPv4 gateway (rendered as `(<dev>:network)`, `Rule.php:53-59`), plus `127.0.0.0/8`, plus whatever other plugins return from a `networks_source_nat` run-hook (OpenVPN `openvpn.inc:1332`, IPsec `ipsec.inc:1697`). Subnets routed behind a LAN router are not included (general OPNsense behaviour).

Side effect: while the tun has an address but **no** router file it is classified as a LAN-type source network for other WANs. Harmless.

### 3.3 Generated rules and translation address

`core/src/etc/inc/filter.inc:208-226`:

```php
foreach (filter_auto_source_nat($fw) as $interface => $networks) {
    foreach ([500, null] as $dstport) {
        $rule = [
            'descr' => 'Automatic outbound rule',
            'destination' => ['any' => true],
            'dstport' => $dstport,
            'interface' => $interface,
            'ipprotocol' => 'inet',
            'log' => !empty($config['syslog']['logoutboundnat']),
            'staticnatport' => !empty($dstport),
        ];
        foreach ($networks as $network => $unused) {
            $rule['source'] = ['network' => $network];
            $fw->registerSourceNatRule(200, $rule);
```

`SNatRule::parseNatRules()` (`core/src/opnsense/mvc/app/library/OPNsense/Firewall/SNatRule.php:73-85,134-138`): with no target, `$rule['target'] = "({$interf_settings['if']}:0)"`; `natport` is empty for static-port rules and `1024:65535` otherwise.

Expected output for the example **[L, assembled from the verified generators]**:

```
nat on tun0 inet from (igb1:network) to any port 500 -> (tun0:0) static-port # Automatic outbound rule
nat on tun0 inet from 127.0.0.0/8   to any port 500 -> (tun0:0) static-port # Automatic outbound rule
nat on tun0 inet from (igb1:network) to any -> (tun0:0) port 1024:65535 # Automatic outbound rule
nat on tun0 inet from 127.0.0.0/8   to any -> (tun0:0) port 1024:65535 # Automatic outbound rule
```

- IPv4 only (`'ipprotocol' => 'inet'`).
- Static-port only for destination port 500; everything else gets a rewritten source port.
- Priorities: MVC manual rules 50 (`pf.inc:176-183`), legacy manual 100, automatic 200 -> in `hybrid` manual rules win. In `advanced` (manual) or `disabled` mode nothing automatic is generated.

### 3.4 What `(tun0:0)` resolves to on a p2p tun

`src/sys/netpfil/pf/pf_if.c:733-782` (`pfi_instance_add`):

```c
/* XXX: For point-to-point interfaces, (ifname:0) and IPv4,
 *      jump over addresses without a proper route to work
 *      around a problem with ppp not fully removing the
 *      address used during IPCP. */
if ((ifp->if_flags & IFF_POINTOPOINT) && !(ia->ifa_flags & IFA_ROUTE) &&
    (flags & PFI_AFLAG_NOALIAS) && (af == AF_INET))
        continue;
...
else if (flags & PFI_AFLAG_PEER)  pfi_address_add(ia->ifa_dstaddr, af, net2);
else                               pfi_address_add(ia->ifa_addr, af, net2);
```

- `(tun0:0)` = the first **local** IPv4 address (`192.0.0.1`), never the peer (that would be `:peer`). **[V]**
- On a p2p interface the address is only used if it has `IFA_ROUTE` set. tun(4) is `IFF_POINTOPOINT` (`src/sys/net/if_tuntap.c:1033-1035`). A normally configured, UP local/peer pair has its route installed (this is the same mechanism `(pppoe0:0)` relies on) **[L - sys/netinet is not in the sparse clone]**.
- When the owning process closes the tun, the kernel downs it and purges all addresses: `if_tuntap.c:1276-1288` (`if_down(ifp)`; `/* Delete all addresses and routes which reference this interface. */ if_purgeaddrs(ifp)`). `(tun0:0)` is then empty and routes via the tun are gone, while `/tmp/tun0_router` stays unless somebody removes it. **[V]**
- `(tun0:network)` = local address with its own netmask (`pf_if.c:767-774,782`), e.g. `192.0.0.1/32`.

---

## 4. Automatic reply-to / route-to

### 4.1 reply-to

`FilterRule::convertReplyTo()` (`core/src/opnsense/mvc/app/library/OPNsense/Firewall/FilterRule.php:156-195`): for a **pass** rule bound to one interface, without an explicit gateway, with `disablereplyto` empty and direction not `any`:

```php
switch ($proto) {
    case "inet6":  // uses interfaceMapping[...]['gatewayv6']
    default:       // uses interfaceMapping[...]['gateway']
        $rule['reply'] = "reply-to ( {$if} {$gw} ) ";
```

- The CLAT interface has an IPv4 gateway only -> `reply-to ( tun0 192.0.0.2 )` is added to user **inet** pass rules on that interface; **inet6 rules on it get no reply-to** (no `gatewayv6`). **[V]**
- Not applied to: block/reject rules (227-232), LAN rules (LAN has no gateway), and core-internal rules, which default to `"disablereplyto" => 1` (`filter.lib.inc:34-43`).
- Off switches: global `system.disablereplyto` (`Plugin.php:55-57`), per-rule `disablereplyto`, or an explicit per-rule `reply-to` gateway (158-168).
- Effect on a p2p tun: replies to connections accepted inbound on the tun are forced back out the tun toward 192.0.0.2. On a p2p link the next hop is irrelevant, so this is harmless. **[L]**

### 4.2 route-to ("force gateway")

`filter.lib.inc:585-620`, active unless `system.pf_disable_force_gw`:

```php
if (!isset($ifcfg['internal_dynamic']) && $ifcfg['if'] != 'lo0') {
    ...
    $gwname = $fw->getGateways()->getInterfaceGateway($ifdescr, $inet, true, 'name');
    if (!empty($gwname)) {
        $fw->registerFilterRule(10000,
            ['from' => "({$ifcfg['if']})", 'direction' => 'out', 'gateway' => $gwname,
             'destination' => ['network' => $ifdescr, "not" => true],
             'statetype' => 'keep', 'allowopts' => true, 'quick' => false,
             'descr' => "let out anything from firewall host itself (force gw)"],
            $defaults['pass']);
```

-> roughly `pass out log route-to ( tun0 192.0.0.2 ) from (tun0) to ! (tun0:network) keep state allow-opts` (non-quick, no `on` clause). **[V generator; L exact text]**

- Because outbound NAT is applied before filtering, every NATed LAN packet leaving the tun has source `192.0.0.1` = `(tun0)` and matches this rule; as the later non-quick match it wins over the generic pass-out. The route-to target is the interface the packet is already leaving on, so nothing changes. **[L]**
- **Not generated for plugin-registered (`internal_dynamic`) interfaces.**
- No conflict was found between either mechanism and a p2p tun. **[L]**

### 4.3 State policy

pf default is floating (`src/share/man/man5/pf.conf.5:572-573`: "States can match packets on any interfaces (the default)"); OPNsense only emits `set state-policy if-bound` when `system.state-policy` is set (`filter.inc:329-331`). All CLAT flows are symmetric per interface, so either policy works. **[V/L]**

---

## 5. Default rules, private/bogon blocking, antispoof - and the one missing automatic pass

### 5.1 What core generates for every interface

From `filter_core_rules_system()` (`filter.lib.inc:200-659`) and `filter_rules_legacy()` (`filter.inc:563-582`) **[V]**:

- `Default deny / state violation rule` - block, non-quick, both families (217-222). A newly created/registered interface has **no pass-in rule**.
- `let out anything from firewall host itself` (545-550): `['direction' => 'out', 'statetype' => 'keep', 'allowopts' => true, 'quick' => false]` with no interface and no source -> effectively `pass out all keep state`, on every interface, for forwarded traffic as well.
- IPv6: only ICMPv6 housekeeping is passed globally (224-266): types `1,2,3,4,135,136` inbound from anywhere; echo request (128) only from `fe80::/10` or outbound from `(self)` to link-local/multicast.
- Per-interface opt-in blocks, rendered disabled unless the interface has the flag (328-369):
  - `blockbogons`: `block in quick on <if> inet from <bogons>` (and `<bogonsv6>`);
  - `blockpriv`: `'from' => '10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16'` (and `fd00::/8,fe80::/10`).
  Both default **off** for anything but the factory WAN (`config.xml.sample:57-58`).
- `antispoof log for <dev>` for every interface that is not a bridge member, not `internal_dynamic`, not `lo0` (`filter.inc:575-579`). It is emitted **before** all other filter rules (`filter.inc:389-390`) and is **non-quick**.
- Default config ships MVC rules "Default allow LAN to any rule" (inet) and "Default allow LAN IPv6 to any rule" (`config.xml.sample:114-164`), so LAN -> any IPv4 is passed inbound on LAN.
- `set skip on` exists only for `lo0`, `pfsync0` and IPsec VTIs with `skip_fw` (`filter.inc:373-379`); there is no plugin hook for it (and skipping the tun would also skip its NAT).

### 5.2 Bogons and 192.0.0.0/29

- `192.0.0.0/24` **is** in the bogon table: `core/src/etc/bogons.sample:4`. The live file is replaced by `fullbogons-ipv4.txt` from the OPNsense mirror (`core/src/opnsense/scripts/firmware/bogons.sh:30,67-73`). **[V sample; L live list]**
- The bogon rule is `direction => 'in'`, `from => <bogons>`, and only if `blockbogons` is set on that interface. Traffic sourced from `192.0.0.1` leaves the tun in the **out** direction and is never tested against it. Inbound IPv4 on the tun carries real Internet sources and matches existing NAT states (no rule evaluation).
- 192.0.0.0/29 is not in the `blockpriv` list.
- Only a translator-originated packet from a 192.0.0.x address that does **not** belong to a state could be dropped, and only if somebody enables `blockbogons` on the CLAT interface. tayga sources its own ICMP errors from its `ipv4-addr` (`tayga/nat64.c:249-268`), but pf matches ICMP errors to the state of the embedded packet. **[L]**

Conclusion: bogon/private blocking does not break traffic NATed to 192.0.0.1. **[L]**

### 5.3 Antispoof on a p2p tun

pfctl expands `antispoof for tun0` (`src/sbin/pfctl/parse.y:1570-1655`, `pfctl_parser.c:1685-1760`) to `block drop in on ! tun0 inet from 192.0.0.1/32 to any` and `block drop in inet from 192.0.0.1 to any`. Nothing in the CLAT flow arrives inbound with source 192.0.0.1. Antispoof for LAN/WAN prefixes is non-quick and first, so any later matching pass rule overrides it; it can only "win" where the default deny would have applied anyway. If the interface does not exist at load time `ifa_lookup()` returns NULL and no rule is produced. **[V/L]**

### 5.4 The gap: translated IPv6 re-entering on the tun

Packet walk for LAN host -> IPv4 Internet with a tun-based translator (tayga):

| Step | Packet | pf hook | Covered by |
|------|--------|---------|------------|
| 1 | IPv4 LAN -> Internet | in on igb1 | default LAN allow rule (state) |
| 2 | same, routed to default 192.0.0.2 | out on tun0 | automatic NAT -> 192.0.0.1, generic pass-out / force-gw rule (state) |
| 3 | **IPv6 CLAT-addr -> PLAT-prefix::dst, written to the tun by the translator** | **in on tun0** | **nothing automatic** |
| 4 | same, routed to WAN | out on pppoe0 | generic pass-out (state) |
| 5 | IPv6 reply | in on pppoe0, out on tun0 | states from 4 and 3 |
| 6 | IPv4 reply written to the tun | in on tun0, out on igb1 | states from 2 and 1 |

Step 3 is a new IPv6 flow arriving inbound on an interface that has no pass-in rule; the only global IPv6 passes are the ICMPv6 types listed in 5.1. It therefore ends at the default deny. **[V: no automatic rule exists in `filter_core_rules_system()`; L: runtime outcome]**

This also applies to dpinger probes to a remote IPv4 monitor (the translated ICMPv6 echo request, type 128 from a GUA, is not covered by the RFC 4890 rules).

Supporting evidence: the existing `os-tayga` plugin registers a firewall **group** `tayga` (`plugins/net/tayga/src/etc/inc/plugins.inc.d/tayga.inc:66-80`, `ifconfig nat64 group tayga` in `plugins/net/tayga/src/etc/rc.d/opnsense-tayga:29`) and its how-to requires the user to add an "IPv4+IPv6" pass rule on Firewall > Rules > Tayga and a manual outbound NAT rule (https://docs.opnsense.org/manual/how-tos/tayga.html).

Ways such a rule can come to exist (facts about the mechanisms, not a recommendation):

- a user-created rule on the CLAT interface (rule models allow plugin-registered interfaces: `Firewall/Filter.xml:88-91` `<AllowDynamic>Y</AllowDynamic>`);
- a config-owned MVC rule under `//OPNsense/Firewall/Filter/rules`;
- the supported plugin hook `<plugin>_firewall($fw)` -> `$fw->registerFilterRule($prio, $conf, $defaults)` (`core/src/etc/inc/plugins.inc:244-259`, `Plugin.php:260-279`), which is how core/plugins emit "automatically generated rules". This is a plugin-generated pf rule, but a plain filter pass, unrelated to af-to/NAT.

---

## 6. Per-interface MTU / MSS

### 6.1 MSS

Interface config key `mss` (GUI help, `www/interfaces.php:1223-1225`: "MSS clamping for TCP connections to the value entered above minus 40 (IPv4) or 60 (IPv6)"; validation >= 576, line 613).

master (`core/src/etc/inc/filter.inc:479-506`):

```php
foreach ($FilterIflist as $scrubcfg) {
    if (is_numeric($scrubcfg['mss'] ?? '')) {
        $mssclampv4 = 'max-mss ' . (intval($scrubcfg['mss'] - 40));
        $mssclampv6 = 'max-mss ' . (intval($scrubcfg['mss'] - 60));
        ...
        $scrubrules .= "match on {$scrubcfg['if']} inet all scrub ( {$mssclampv4}{$random_id} )\n";
        $scrubrules .= "match on {$scrubcfg['if']} inet6 all scrub ( {$mssclampv6}{$random_id} )\n";
```

stable/26.7 (fetched excerpt of `stable/26.7/src/etc/inc/filter.inc`): same loop and arithmetic, older syntax `scrub on {$scrubcfg['if']} inet all {$scrub_gen_opts} {$mssclampv4}` plus a generic `scrub in all`; master instead uses `set reassemble yes` (470-477) and has moved normalization into per-rule scrub options (`Firewall/Filter.xml:432` `scrub_max_mss`, migration `MFP1_0_8.php`). **This is the only master/26.7 difference found in the code paths studied.**

- `$FilterIflist` = `iterator_to_array($fw->getInterfaceMapping())` (`filter.inc:188,387`) = all enabled config interfaces with all their keys -> **applies to an assigned or plugin-registered tun** as soon as its record has a numeric `mss`. **[V]**
- No direction -> both directions. **Both** an `inet` and an `inet6` rule are emitted for the same device. On a CLAT tun both families cross the device (IPv4 pre-translation, IPv6 post-translation), so a single value `X` clamps IPv4 SYNs to `X-40` and the translated IPv6 SYNs to `X-60`. Arithmetic example with PPPoE IPv6 MTU 1492 (correct TCP MSS 1432): `mss=1492` -> v4 1452 / v6 1432 (the v6 rule yields the right value in both directions); `mss=1472` -> v4 1432 / v6 1412 (20 bytes lower than necessary). **[V arithmetic; L runtime]**

### 6.2 MTU

`interface_configure()` (`interfaces.inc:2418-2420`) -> `interface_configure_mtu()` (2240-2263) -> `legacy_interface_mtu()` = `/sbin/ifconfig <dev> mtu <n>` (`interfaces.lib.inc:150-158`).

- Applied to **any** device of an enabled config interface, including one core does not own, but only when `interface_configure()` runs for that interface (boot, GUI apply, `configctl interface reconfigure`) and only if the `mtu` key is non-empty. **[V]**
- If the daemon creates/recreates the device afterwards, the configured MTU is not re-applied until the next `interface_configure()`.

### 6.3 What else core does to a device it does not own **[V]**

- `interface_configure()` flushes IPv4/IPv6 addresses only `if (!empty($wancfg['ipaddr']))` / `ipaddrv6` (2308-2314); with IPv4/IPv6 type "None" the daemon's addresses are left alone. It always runs `ifconfig <dev> inet6 -accept_rtadv description '<descr> (<if>)' up` (2446).
- `interface_reset()` (GUI apply runs it first: `apply_legacy_if_changes.php:43-46`) **always clears the ifctl files**: `ifctl -4c -i <dev>` / `ifctl -6c -i <dev>` (`interfaces.inc:907-909`) - the dynamic gateway disappears until the router file is rewritten.
- `interface_configure(..., $reload = true)` calls the plugin's device function for registered device names before doing anything else (2287-2298), and at the end runs `system_routing_configure($verbose, $interface)` (2492-2494).
- `<plugin>_devices()` (`plugins.inc:94-125`; examples `wireguard.inc:101-122`, `ipsec.inc:208-235`, `core.inc:138-294`) keys: `function`, `names`, `pattern`, `type`, `typedescr`, `configurable` (default true), `reload` (true), `spoofmac` (true), `volatile` (false). `'configurable' => false` makes the GUI reject any IPv4/IPv6 type ("Cannot assign an IP configuration type to a tunnel interface.", `www/interfaces.php:374-383`). `names` makes a device selectable in Interfaces > Assignments even before it exists (`list_assign_options.php:57-77`).
- Core already registers `^tun` as a volatile pattern: `core.inc:290-291` `['pattern' => '_stf|^tap|^tun|^ue', 'volatile' => true]`.

---

## 7. dpinger monitoring

File: `core/src/etc/inc/plugins.inc.d/dpinger.inc`.

- A virtual dynamic gateway has `"monitor_disable" => '1'` (`Gateways.php:404`) -> no dpinger (`dpinger.inc:112-115`); status is reported as `none` (318) and the GUI shows it online ("This will consider this gateway as always being up", `dialogEditGateway.xml:76`). **[V]**
- With monitoring enabled and no monitor address, `monitor = gateway` (`Gateways.php:437-439`) = `192.0.0.2`.
- Source address (169-196): first interface address whose subnet contains the gateway, else the primary address with the log line "Chose to bind %s on %s since we could not find a proper match." -> `192.0.0.1` on a /32 p2p. Without any IPv4 on the device: "The required %s IPv4 interface address could not be found, skipping."
- Host route (229-236): `system_host_route($gateway['monitor'], $gateway['gateway'])` unless `monitor_noroute`; a no-op when monitor == gateway (`system.inc:545-547`), otherwise `route add -host -inet <monitor> 192.0.0.2`.
- Command (239-280): `dpinger -f -S -r 0 -i <name> -B <src> -p ... -u ... -s 1s -l 4s -t 60s -d 1 <monitor>` (defaults `GatewayField.php:37-49`: latency 200/500 ms, loss 10/20 %).

### 7.1 Peer answered by the local translator

tayga answers echo requests addressed to its own `ipv4-addr` itself:

```c
// tayga/nat64.c:755-758
/* Packet for ourselves*/
if (p->ip4->dest.s_addr == gcfg.local_addr4.s_addr) {
    if (p->data_proto == 1) host_handle_icmp4(p);
// tayga/nat64.c:276-282
case 8: p->icmp->type = 0; ... host_send_icmp4(p->ip4->tos, &p->ip4->dest, &p->ip4->src, ...)
```

- If the gateway/monitor address is the translator's own IPv4 address, the monitor is **always up with ~0 ms** as long as the daemon runs. It proves the process is alive, nothing about PPPoE/IPv6/PLAT. **[V tayga code; L end-to-end]**
- If the peer address is *not* the translator's own address, the probe is translated toward the PLAT (`PLAT-prefix::192.0.0.2`) and will normally never be answered -> gateway permanently down. **[L]**

### 7.2 Setting a meaningful monitor

- Only through a `gateway_item` for that interface + `inet` with empty `gateway`: `monitor_disable=0`, `monitor=<IPv4 target>`. Constraints: the monitor IP must be unique across gateways unless `monitor_noroute` is set (`Gateways.php:52-59,78-90`); `time_period >= 2*(interval+loss_interval)` (103-112).
- The GUI can do this by editing the virtual gateway (`SettingsController.php:158-177` turns it into an item with `gateway = null`).
- A remote monitor only works if step 3 of 5.4 is passed by the firewall and the PLAT handles ICMP echo.
- A gateway going `down` changes the default route only with gateway switching enabled (2.3) or via gateway groups.

---

## 8. Can a plugin register a gateway through a hook?

**No.** `core/src/etc/inc/plugins.inc` defines exactly: `plugins_scan`, `plugins_services`, `plugins_devices`, `plugins_cron`, `plugins_syslog`, `plugins_interfaces`, `plugins_firewall`, `plugins_configure`, `plugins_run`, `plugins_xmlrpc_sync`, `plugins_argument_map` (same list in stable/26.7). The only gateway-related run-hooks are consumers of status (`return_gateways_status`, `return_gateways_watcher`, `host_routes`: `dpinger.inc:302-309`, `legacy_bindings.inc:182-199`). `Gateways.php` reads config.xml and `/tmp/*_router*` only. **[V]**

What does exist:

| Mechanism | Where | Persisted in config.xml? |
|-----------|-------|--------------------------|
| ifctl router file -> dynamic gateway | `ifctl -i <dev> -4rd -a <peer>`; `Autoconf::getRouter()` | no (runtime, `/tmp`) |
| `<plugin>_interfaces()` -> interface record | `plugins.inc:178-242`; applied by `write_config()` (`config.inc:214-219`) or `pluginctl -i` = `configctl interface invoke registration` (`sbin/pluginctl:242-245`, `actions_interface.conf:68-72`, `ApiControllerBase.php:411-417`) | yes, marked `internal_dynamic` |
| `Gateways` model (`createOrUpdateGateway()`, API `routing/settings/*`) | `Gateways.php:166-185`, `SettingsController.php` | yes |
| `<plugin>_devices()` | device lifecycle callback, GUI constraints | no |
| `<plugin>_configure()` events `newwanip`, `vpn`, `bootup`, `early`, `monitor`, ... | `plugins.inc:261-335`; `rc.newwanip:142-143`, `rc.bootup:93-102` | no |
| `<plugin>_run()` `networks_source_nat` | extra source networks for automatic NAT (`filter.lib.inc:184`) | no |
| `<plugin>_firewall($fw)` | filter/NAT rules, anchors, tables (`Plugin.php`) | no |

Precedent for a plugin-registered **real** (non-group, non-virtual) interface: IPsec VTI, `core/src/etc/inc/plugins.inc.d/ipsec.inc:194-202` (identical in 26.7):

```php
foreach ($vtis as $intf => $details) {
    $interfaces[$intf] = [
        'enable' => true,
        'descr' => preg_replace('/[^a-z_0-9]/i', '', $details['descr']),
        'if' => $intf,
        'type' => 'none',
    ];
}
```

(key = device name, no `virtual`). Groups (`openvpn`, `wireguard`, `tayga`) and `enc0` use `'virtual' => true` and therefore never get gateways (`Gateways.php:266`).

Properties of an `internal_dynamic`, non-virtual interface **[V]**:

- considered for dynamic gateways, default route, automatic NAT, MSS rules, bogon/private options, `interface_configure()` at boot (`interfaces.inc:722`), `rc.newwanip` lookup (`interfaces.inc:3449-3471`);
- **no antispoof** (`filter.inc:576`) and **no force-gw route-to rule** (`filter.lib.inc:587`);
- shown in the Interfaces menu (`Interfaces/Menu/Menu.php:63-67`) and selectable in firewall rules and in the gateway model (`Gateways.xml:23-31` `<AllowDynamic>Y</AllowDynamic>`); hidden from MVC selectors without `AllowDynamic` (`InterfaceField.php:121-128`);
- `plugins_interfaces()` re-applies only the keys the hook returns (217-227) and removes the record when the hook stops returning it (233-239);
- saving the interface in the legacy GUI rewrites the whole record from the form (`www/interfaces.php:618-806`), dropping keys the form does not know (`internal_dynamic`, `type`, a hand-set `gateway` ...); the hook re-adds its own keys on the next registration run.

---

## 9. Minimum config.xml state, and who has to do what

### 9.1 Minimum for "dynamic gateway + default route + automatic NAT"

config.xml:

```xml
<interfaces>
  <KEY>                         <!-- optN (assigned by user) or plugin-chosen key -->
    <enable>1</enable>
    <if>tun0</if>               <!-- device name -->
    <descr>CLAT</descr>
    <!-- no ipaddr / ipaddrv6: core leaves the daemon's addresses alone -->
  </KEY>
</interfaces>
<nat><outbound><mode>automatic</mode></outbound></nat>   <!-- factory default; hybrid also works -->
```

Runtime (not config):

1. device exists, UP, IPv4 local + peer configured;
2. `/tmp/tun0_router` contains the peer (`ifctl -i tun0 -4rd -a 192.0.0.2`);
3. routing + filter are re-evaluated afterwards (`configctl interface newip tun0 force` does both, see 2.2).

**No gateway entry, no NAT rule and no `gw_switch_default` are required.** **[V per code path; L end-to-end]**

### 9.2 Optional config

```xml
<OPNsense><Gateways version="1.0.0">
  <gateway_item uuid="...">
    <disabled>0</disabled>
    <name>CLAT_GW</name>
    <interface>KEY</interface>
    <ipprotocol>inet</ipprotocol>
    <gateway/>                       <!-- empty = settings for the dynamic gateway -->
    <defaultgw>0</defaultgw>
    <priority>255</priority>         <!-- e.g. to rank below a native WAN_PPPOE (254) -->
    <monitor_disable>0</monitor_disable>
    <monitor>a.b.c.d</monitor>
    <weight>1</weight>
  </gateway_item>
</Gateways></OPNsense>
```

and `<mss>`/`<mtu>` on the interface record (section 6).

### 9.3 Clicks vs. plugin

| Item | Plugin can do it without the user | Otherwise the user must |
|------|-----------------------------------|-------------------------|
| Interface record | `<plugin>_interfaces()` + `pluginctl -i` (VTI precedent) | Interfaces > Assignments: add device, enable, save, apply |
| Dynamic gateway | write the ifctl router file at tunnel-up, remove at tunnel-down | - |
| Re-create router file after core cleared it (`interface_reset`) | `<plugin>_devices()` `function` callback / own events | - |
| Default route + filter refresh | `configctl interface newip <dev> force` or `route_reload` + `filter reload` | System > Gateways > Apply |
| Outbound NAT | nothing to do in `automatic`/`hybrid` | add a rule in `advanced` (manual) mode; nothing possible in `disabled` |
| LAN -> any IPv4 pass | factory default rule exists | add it if the default rule was removed |
| **IPv6 pass-in on the tun (5.4)** | only via `<plugin>_firewall()` or by writing a rule into config | add one rule on the CLAT interface |
| Monitor / priority / upstream | `Gateways` model write (config) | System > Gateways > Configuration, edit `CLAT_GW` |
| MSS / MTU | return `mss`/`mtu` from the interfaces hook, or set MTU on the device itself | Interfaces > [CLAT] |

---

## Appendix A. Things checked and found to be non-issues

- `Util::getRealInterface()` (`Firewall/Util.php:722-759`) returns the config `if` as-is; no device-type filtering.
- The "Misconfigured Gateway IP" GUI warning only applies to interfaces with a static address (`SettingsController.php:117-146`).
- pf loads rules referencing a not-yet-existing interface; interface/ifconfig details are only attached when the device exists (`filter.lib.inc:76-80`).
- Firewall-originated IPv4 (DNS, NTP, dpinger) leaves with source `192.0.0.1` and needs no NAT rule; the translator must map that address.

## Appendix B. master-only observations (not in the 26.7 code paths checked)

- A new MVC interface-assignment model/API exists in master (`core/src/opnsense/mvc/app/models/OPNsense/Interfaces/NetworkInterface.{php,xml}`, `controllers/OPNsense/Interfaces/Api/AssignmentController.php`): in-memory model, pending changes in `/tmp/.interfaces.todo`, new interfaces get `optN`, and on apply it **removes config keys that are not model fields** (`AssignmentController.php:169-178`). Whether this ships in 27.1 and how it treats `internal_dynamic` records was not established.
- core#10638 (af-to in filter rules, open): maintainers note it "will not work well with shared forwarding" and that "route-to and et al are not supported with af-to" (`refs/gh/opnsense_core_10638.md:40,52`).
