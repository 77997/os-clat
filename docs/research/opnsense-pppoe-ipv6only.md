# OPNsense on a PPPoE WAN that negotiates IPv6CP only — behaviour and signals a plugin can use

Research date: 2026-10-10. Research only, no design.

**Path convention.** `refs/` below means the local clones (not in this repository).
`core` = `refs/opnsense-core` (opnsense/core **master**, i.e. 27.1 development). Where it matters, the
same file was re-read on GitHub branch `stable/26.7` and differences are called out.

**Confidence labels.** *verified* = primary source read (local clone, or upstream source/GitHub page fetched).
*likely* = inferred from that source but not runtime-tested. Nothing here was tested on a live box.

**Caveat on mpd5.** The ports tree only contains the port skeleton and patches
(`refs/opnsense-ports/net/mpd5`, `DISTVERSION= 5.9`, `PORTREVISION= 20`). mpd5 C source was read from the upstream
SourceForge SVN trunk as fetched excerpts (short verbatim quotes, not the full file).

---

## 0. Headline facts

1. IPCP is **not** always enabled. OPNsense writes `set bundle disable ipcp` when the interface's IPv4
   Configuration Type is "None", and `set bundle enable ipv6cp` when the IPv6 type is DHCPv6, SLAAC or PPPoEv6.
   This is in both master and stable/26.7 and dates from commit 805120e (Aug 2024, issue #7446, milestone 25.1).
2. IPv4 type does **not** have to be `pppoe` for the session to start. It must be "None" for an IPv6-only ISP to
   work properly: with IPv4 type `pppoe`, OPNsense starts rtsold/dhcp6c only from the **IPv4** link-up, so if IPCP
   never opens, DHCPv6-PD never starts.
3. Plugin event `newwanip` (family `inet6`) fires only when a script passes a non-empty reason to
   `rc.newwanipv6`. That happens on DHCPv6 SOLICIT/REQUEST replies and on a changed delegated prefix. It does
   **not** happen on PPP link loss, on an unchanged RENEW, or (by code reading) at all in pure SLAAC mode.
4. Nothing in OPNsense or the FreeBSD 15 base parses RA PREF64 (RFC 8781) on the receive side. The header
   constant exists; rtsold and the kernel ignore the option.
5. A PPPoE WAN without IPCP produces no IPv4 gateway object at all (or a `defunct`, skipped one if a gateway item
   was saved in config.xml), so it cannot block another IPv4 default gateway.

---

## 1. mpd5 configuration, IPCP/IPv6CP, IPv6-only recipe

### 1.1 What decides IPCP / IPv6CP

`core/src/etc/inc/interfaces.inc:1059-1084` (`interface_ppps_configure()`):

```php
$ipv4_mode = $ipv6_mode = 'disable';

switch ($ifcfg['ipaddr'] ?? 'none') {
    case 'ppp':
    case 'pppoe':
    case 'l2tp':
        $ipv4_mode = 'enable';
...
switch ($ifcfg['ipaddrv6'] ?? 'none') {
    case 'dhcp6':
    case 'pppoev6':
    case 'slaac':
        $ipv6_mode = 'enable';
...
if ($ipv4_mode != 'enable' && $ipv6_mode != 'enable') {
    log_msg("PPP {$ifcfg['if']} found no supported IP configuration mode.", LOG_ERR);
    return false;
}
```

Consequences:

- mpd5 is started when **either** family is enabled. The only other preconditions are that the assigned device
  appears in `<ppps>` (`interface_ppps_capable()`, `interfaces.inc:971-985`) and the interface is enabled
  (`interfaces.inc:1054-1057`).
- IPv6 types that enable IPv6CP are only `dhcp6`, `pppoev6`, `slaac`. Static IPv6, `linklocal`, `6rd`, `6to4`,
  `track6`, `idassoc6` do **not** enable IPv6CP.
- stable/26.7 has the same logic; its IPv4 switch additionally lists `pptp` (fetched
  `https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/etc/inc/interfaces.inc`).

### 1.2 The generated file

Header, `interfaces.inc:1162-1176`:

```
startup:
  # configure the console
  set console close
  # configure the web server
  set web close

default:
{$ppp['type']}client:
  create bundle static {$interface}
  set bundle {$ipv4_mode} ipcp
  set bundle {$ipv6_mode} ipv6cp
  set iface name {$ifcfg['if']}
```

Then (`interfaces.inc:1178-1200`): `set iface enable|disable on-demand`, `set iface idle N` (0 when no idle
timeout), `set iface addrs 10.10.1.1 10.10.1.2` (on-demand only), `set iface enable|disable tcpmssfix`, and

```
  set iface up-script /usr/local/opnsense/scripts/interfaces/ppp-linkup.sh
  set iface down-script /usr/local/opnsense/scripts/interfaces/ppp-linkdown.sh
```

The IPCP block is emitted **only** when IPv4 is enabled (`interfaces.inc:1202-1236`):
`set ipcp ranges {local}/{net} {remote}/{net}`, optional `set ipcp no vjcomp`, and — only when
`system.dnsallowoverride` is set — `set ipcp enable req-pri-dns` / `req-sec-dns`.

Per link (`interfaces.inc:1238-1349`): `create link static {$interface}_link{$pid} pppoe`,
`set link action bundle {$interface}`, `set link disable multilink` (single port), `set link keep-alive 10 60`,
`set link max-redial 0`, `set link disable chap pap`, `set link accept chap pap eap`,
`set link disable incoming`, MTU, `set auth authname "..."`, `set auth password ...`,
`set pppoe service "{hostuniq}{provider}"`, `set pppoe iface {$port}`, `open`.

MTU (`interfaces.inc:1271-1279`): `$mtus[$pid] = !empty($ifcfg['mtu']) ? intval($ifcfg['mtu']) - 8 : 1492;` then
`set pppoe max-payload N` if N > 1492, else `set link mtu N`. After start the device MTU is set with
`legacy_interface_mtu($ifcfg['if'], $mtus[0])` (`interfaces.inc:1390`).

Files and process (`interfaces.inc:1352-1378`): config `/var/etc/mpd_{$interface}.conf`, pid
`/var/run/{$ppp['type']}_{$interface}.pid` (e.g. `/var/run/pppoe_wan.pid`), started as

```php
'/usr/local/sbin/mpd5 -b -d /var/etc -f %s -p %s -s ppp %s'
```

During boot the start is deferred (`interfaces.inc:1156-1160` writes `/tmp/pppconfigure_<if>`), then replayed by
`core/src/etc/rc.syshook.d/start/10-newwanip:19-25` (`configctl -q interface ppp configure ${INTERFACE}`).

**Derived example for IPv4 = None, IPv6 = DHCPv6** (assembled from the code above, not captured from a live
system):

```
default:
pppoeclient:
  create bundle static wan
  set bundle disable ipcp
  set bundle enable ipv6cp
  set iface name pppoe0
  set iface disable on-demand
  set iface idle 0
  set iface enable tcpmssfix
  set iface up-script /usr/local/opnsense/scripts/interfaces/ppp-linkup.sh
  set iface down-script /usr/local/opnsense/scripts/interfaces/ppp-linkdown.sh
  create link static wan_link0 pppoe
  set link action bundle wan
  set link disable multilink
  set link keep-alive 10 60
  set link max-redial 0
  set link disable chap pap
  set link accept chap pap eap
  set link disable incoming
  set link mtu 1492
  set auth authname "<user>"
  set auth password <password>
  set pppoe service ""
  set pppoe iface <parent device>
  open
```

### 1.3 GUI: is IPv4 = None selectable on a PPPoE device?

Yes. `core/src/www/interfaces.php:849-876`:

```php
$types4 = $types6 = ['none' => gettext('None')];
...
if (!interface_ppps_capable($a_interfaces[$if], $a_ppps)) {
    $types4['staticv4'] = gettext('Static IPv4');
    $types4['dhcp'] = gettext('DHCP');
} else {
    switch ($a_ppps[$pppid]['type']) {
        ...
        case 'pppoe':
            $types4['pppoe'] = gettext('PPPoE');
            $types6['pppoev6'] = gettext('PPPoEv6');
```

The POST validation (`interfaces.php:392-494`) has no rule that forbids IPv4 `none` on a PPPoE device or that
requires IPv4 `pppoe` for IPv6 `dhcp6`/`slaac`/`pppoev6`. The only "needs IPv4" rules are for 6rd and 6to4
(`interfaces.php:455-457`, `480-482`). stable/26.7 is identical here apart from an extra `pptp` case (fetched
`https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/www/interfaces.php`).

History: issue opnsense/core#7446, "interfaces: restructure PPP to allow complex IPv6-only deployments and
remove 'Use IPv4 connectivity' by making it the default", milestone 25.1, closed 2025-01-08
(`https://github.com/opnsense/core/issues/7446`). Commit 805120e "interfaces: decouple starting PPP from
configured IP modes #7446" (2024-08-09) introduced the two-mode logic
(`https://github.com/opnsense/core/commit/805120e`). The 25.1 changelog only says: "interfaces: remove "Use IPv4
connectivity" setting as it will be set by default"
(`https://raw.githubusercontent.com/opnsense/changelog/master/community/25.1/25.1`).

**Recipe (derived, not found in official docs):** Interfaces > Devices > Point-to-Point: create the PPPoE
device; assign it; IPv4 Configuration Type = None; IPv6 Configuration Type = DHCPv6 (or SLAAC). No documentation
page or forum recipe stating this explicitly was found.

### 1.4 Why IPv4 must be "None" on an IPv6CP-only ISP

`interface_ppps_bound()` (`interfaces.inc:924-969`):

```php
if ($family == 4) {
    /* use this to steer configuration based on newwanip event */
    $bound = $ipv4_mode;
} elseif ($family == 6) {
    /* use this to steer configuration based on newwanipv6 event */
    $bound = !$ipv4_mode && $ipv6_mode;
} else {
    /* use this to prevent doing any early setup in general */
    $bound = $ipv4_mode || $ipv6_mode;
}
```

- `interface_configure()` does not start rtsold/dhcp6c on a PPP-bound interface
  (`interfaces.inc:2449-2458`: `if (!interface_ppps_bound($interface)) { interface_dhcpv6_prepare(); interface_dhcpv6_configure(); }`).
- The only other starter is `ppp-ipv6.php <dev> <4|6>`, which begins with
  `if (!interface_ppps_bound($interface, $family)) { exit(1); }`
  (`core/src/opnsense/scripts/interfaces/ppp-ipv6.php:48-50`).
- So with IPv4 = PPPoE **and** IPv6 = DHCPv6, family 6 is "not bound" and rtsold/dhcp6c are started only by
  `ppp-ipv6.php ${IF} 4`, i.e. from the **inet** link-up (`ppp-linkup.sh:29`). If IPCP never opens, that line
  never runs. The inet6 link-up then only records the peer link-local as router and fires
  `configctl -d interface newipv6 ${IF} force`.
- Maintainer confirmation in #10828: "Theoretically we're also waiting for PPPoE IPv4 to come up before
  triggering IPv6" (`refs/gh/opnsense_core_10828.md:86`).

Confidence: verified by code reading; the resulting "no PD on an IPv6CP-only ISP with IPv4 = PPPoE" is *likely*
(not runtime-tested).

### 1.5 What mpd5 does when IPCP is rejected but IPv6CP opens

mpd5 defaults (`https://mpd.sourceforge.net/doc5/mpd22.html`): `ipcp` "The default is enable.", `ipv6cp` "The
default is disable." OPNsense always sets both explicitly.

Source (`https://sourceforge.net/p/mpd/svn/HEAD/tree/trunk/src/`):

- `bund.c` `BundNcpsOpen()`: opens an NCP only `if (Enabled(&b->conf.options, BUND_CONF_IPCP))` (same for
  IPV6CP).
- `bund.c` `BundNcpsStart()`: `b->ncpstarted |= (u_int)((1<<proto)>>1);`
- `bund.c` `BundNcpsFinish()`: `b->ncpstarted &= (u_int)(~((1<<proto)>>1));` and only when no bit remains:
  `Log(LG_BUND, ("[%s] Bundle: No NCPs left. Closing links...", b->name));` then `BundCloseLinks(b);`
- `lcp.c` `LcpRecvProtoRej()`: for `PROTO_IPCP` `rej = l->bund ? &l->bund->ipcp.fsm : NULL;` then
  `FsmFailure(rej, FAIL_WAS_PROTREJ);`; returns `fatal` which stays FALSE (not fatal for LCP).
- `fsm.c` `FsmFailure()`: from ST_REQSENT/ACKSENT/ACKRCVD goes to ST_STOPPED and calls `LayerFinish`
  (unless passive). `FsmTimeout()` with exhausted Configure-Request retries calls
  `FsmFailure(fp, FAIL_NEGOT_FAILURE)` — same path when the peer silently ignores IPCP.
- `ipcp.c`: `IpcpLayerFinish` calls `BundNcpsFinish(b, NCP_IPCP)`; `IpcpFailure` only records the reason.
- `ipv6cp.c`: `Ipv6cpLayerUp` calls `BundNcpsJoin(b, NCP_IPV6CP)`, which brings the interface up
  (`IfaceIpv6IfaceUp`, `IfaceUp`).

So a rejected or ignored IPCP only clears the IPCP bit; with IPv6CP started the bundle, link and interface stay
up. Supporting runtime evidence: in the #10828 log the bundle closes only after **both** NCPs finished
(`refs/gh/opnsense_core_10828.md:183-187`: `IPCP: LayerFinish` ... `IPV6CP: LayerFinish`,
`Bundle: No NCPs left. Closing links...`).

Confidence: *likely* (source-level, trunk rather than the 5.9 tarball + port patches; none of the local port
patches touch this logic).

IPv6CP negotiates only the interface identifier — no DNS, no prefix (`ipv6cp.c`: only `INTIDENT`). The local
identifier is EUI-64 from the MAC when available, else random. The interface gets `fe80::<myintid>/64`
(`iface.c` `IfaceIpv6IfaceUp`).

---

## 2. Event chain

### 2.1 mpd5 script arguments

mpd5 manual, Interface layer (`https://mpd.sourceforge.net/doc5/mpd28.html`):
`script interface proto local-ip remote-ip authname [ dns1 server-ip ] [ dns2 server-ip ] peer-address`; if the
up-script exits non-zero mpd kills the protocol. `iface.c` format strings:

- inet: `"%s %s inet %s %s '%s' '%s' '%s' '%s' '%s'"` (self, peer, authname, `dns1 <ip>`, `dns2 <ip>`, peeraddr)
- inet6: `"%s %s inet6 %s%%%s %s%%%s '%s' '%s' '%s'"` (self`%`ifname, peer`%`ifname, authname, peeraddr) — **no
  DNS arguments for inet6**.

### 2.2 `ppp-linkup.sh`

`core/src/opnsense/scripts/interfaces/ppp-linkup.sh:18-38`:

```sh
ROUTER=
if [ -n "${4}" ]; then
	# XXX if this is link-local why bother stripping the required scope?
	ROUTER="-a $(echo ${4} | cut -d% -f1)"
fi
...
if [ "${AF}" = "inet" ]; then
	/usr/local/sbin/ifctl -i ${IF} -4nd ${DNS1} ${DNS2}
	/usr/local/sbin/ifctl -i ${IF} -4rd ${ROUTER}
	/usr/local/opnsense/scripts/interfaces/ppp-ipv6.php ${IF} 4
	/usr/local/sbin/configctl -d interface newip ${IF} force
elif [ "${AF}" = "inet6" ]; then
	/usr/local/sbin/ifctl -i ${IF} -6nd ${DNS1} ${DNS2}
	/usr/local/sbin/ifctl -i ${IF} -6rd ${ROUTER}
	if ! /usr/local/opnsense/scripts/interfaces/ppp-ipv6.php ${IF} 6; then
		# trigger event here since no higher layer IPv6 will trigger it
		/usr/local/sbin/configctl -d interface newipv6 ${IF} force
	fi
fi
```

stable/26.7 additionally runs `touch /tmp/${IF}_uptime` before `exit 0`; master has removed that line.

### 2.3 `ppp-ipv6.php`

`core/src/opnsense/scripts/interfaces/ppp-ipv6.php:54-69`:

```php
switch (is_ipv6_allowed() ? ($ifcfg['ipaddrv6'] ?? 'none') : 'none') {
    case 'dhcp6':
    case 'slaac':
        /* the code can race between here and interface_configure(), see #10828 */
        mwexecf('/sbin/ifconfig %s inet6 accept_rtadv -no_dad -ifdisabled up', $ifcfg['if']);

        interface_dhcpv6_prepare($interface, $ifcfg);
        interface_dhcpv6_configure($interface, $ifcfg);
        /* signal this succeeded to avoid triggering a newwanip event right away */
        exit(0);
    default:
        interface_static6_configure($interface, $ifcfg);
        system_routing_configure(false, $interface, true, 'inet6');
}
exit(1);
```

So "PPPoEv6" means: link-local from IPv6CP, default route to the PPP peer, no RA acceptance, no DHCPv6.

### 2.4 Sequence for IPv4 = None, IPv6 = DHCPv6 (assembled from the code)

1. mpd5 `IPV6CP: LayerUp` → up-script
   `ppp-linkup.sh pppoe0 inet6 fe80::<self>%pppoe0 fe80::<peer>%pppoe0 <authname> <peeraddr>`.
2. `ifctl -i pppoe0 -6nd` (clears `/tmp/pppoe0_nameserverv6`), `ifctl -i pppoe0 -6rd -a fe80::<peer>` (writes
   `/tmp/pppoe0_routerv6`).
3. `ppp-ipv6.php pppoe0 6`: sets `accept_rtadv`; `interface_dhcpv6_prepare()` writes
   `/var/etc/dhcp6c.pppoe0.conf` and the merged `/var/etc/dhcp6c.conf` (`interfaces.inc:2899-2918`);
   `interface_dhcpv6_configure()` (`interfaces.inc:2816-2838`) kills and restarts the single shared rtsold:

   ```php
   $rtsold_frmt = ['/usr/sbin/rtsold -%s -aiu -p %s -A %s -R %s'];
   // -d|-D, /var/run/rtsold.pid, rtsold_script.sh, rtsold_resolvconf.sh
   ```

   and, when `dhcp6_ratimeout` is non-empty (model default 10,
   `core/src/opnsense/mvc/app/models/OPNsense/Interfaces/Settings.xml:41-44`), backgrounds
   `rtsold_script.sh pppoe0` as a fail-safe that starts dhcp6c without an RA. Exits 0, so **no** forced
   `newipv6` here.
4. First RA with non-zero router lifetime → rtsold `-A` script, once per interface "lifetime"
   (`refs/opnsense-src/usr.sbin/rtsold/rtsol.c:335-340`) → `rtsold_script.sh pppoe0 <RA source>`
   (`core/src/opnsense/scripts/interfaces/rtsold_script.sh:57-84`): `ifctl -i pppoe0 -6rd -a <router>`, then
   starts `/usr/local/sbin/dhcp6c $(get_var EXTRAOPTS) -c /var/etc/dhcp6c.conf -p /var/run/dhcp6c.pid` or sends
   it HUP; touches `/tmp/rtsold.pppoe0.done`. The kernel itself handles SLAAC and the RA default router.
5. RA RDNSS/DNSSL → rtsold `-R` → `rtsold_resolvconf.sh -a "pppoe0:slaac:[fe80::router]"`
   (`rtsold_resolvconf.sh:80-87`): `ifctl -i pppoe0:slaac -6nu ...`, `-6su ...`, `-6ru -a <RA source>`; if
   anything changed, `configctl -d interface newipv6 pppoe0` **without** a reason.
6. dhcp6c reply → `dhcp6c_script.sh` (`core/src/opnsense/scripts/interfaces/dhcp6c_script.sh:33-83`), with
   `REASON`, `IFNAME`, `PDINFO`, `new_domain_name_servers`, `new_domain_name`:

   ```sh
   /usr/local/sbin/ifctl -i "${IFNAME}" -6nd ${ARGS}        # DNS servers
   /usr/local/sbin/ifctl -i "${IFNAME}" -6sd ${ARGS}        # search domains
   if [ ${REASON} = "REQUEST" -o ${REASON} = "SOLICIT" ]; then
       FORCE=${REASON}
       # can safely clear the prefix during connect
       /usr/local/sbin/ifctl -i "${IFNAME}" -6pd
   fi
   if [ ${REASON} != "INFOREQ" -a -n "${PDINFO}" ]; then
       ...
       if /usr/local/sbin/ifctl -i "${IFNAME}" -6pu ${ARGS}; then   # true only if the prefix changed
           if [ -z "${FORCE}" ]; then FORCE=${REASON}; fi
       fi
   fi
   /usr/local/sbin/configctl -d interface newipv6 "${IFNAME}" ${FORCE}
   ```

7. `rc.newwanipv6 pppoe0 <reason>` (`core/src/etc/rc.newwanipv6`):
   - `:44-47` deferred during boot (writes `/tmp/newwanipv6_<arg>`; replayed with `force` by
     `rc.syshook.d/start/10-newwanip:11-17`).
   - `:62-70` per-device lock; `:73` `waitfordad(2)`; `:76` `system_resolver_configure()`.
   - `:78-81`:
     ```php
     if (empty($reason)) {
         /* we used to log here but many have complained about spurious log lines caused by RAs */
         return;
     }
     ```
   - `:92` logs `IP renewal starting (reason: ..., address: ..., interface: ..., device: ...)`.
   - `:117-125`:
     ```php
     $interfaces = array_keys(link_interface_to_track6($interface, true));
     array_unshift($interfaces, $interface);
     system_routing_configure(false, $interfaces, true, $family);
     filter_configure_sync();
     plugins_configure('vpn', false, [$interfaces, $family]);
     plugins_configure('newwanip', false, [$interfaces, $family]);
     ```
     `link_interface_to_track6($interface, true)` also reconfigures tracking LANs and calls
     `plugins_configure('dhcp', false, ['inet6'])` (`interfaces.inc:3610-3618`).
     `system_routing_configure()` ends with `plugins_configure('monitor', $verbose, [$gwnames])`
     (`core/src/etc/inc/system.inc:800-817`).

### 2.5 What a plugin hook receives

`plugins_configure($hook, $verbose, $args)` prepends `$verbose` and passes at most the number of arguments the
plugin asked for with the `:N` suffix (`core/src/etc/inc/plugins.inc:261-335`). Existing subscribers:
`'newwanip' => ['kea_newwanip:3']` (`core/src/etc/inc/plugins.inc.d/kea.inc:151`),
`'newwanip' => ['dhcrelay_configure_if:3']` (`dhcrelay.inc:35`), `'newwanip' => ['unbound_configure_do:2']`
(`unbound.inc:45`).

A `...:3` hook gets `($verbose = false, $interfaces = ['wan', <tracking LANs...>], $family = 'inet6')`.
Log format example: `plugins_configure newwanip (,[opt7],inet)` (`refs/gh/opnsense_core_10828.md:344`).

### 2.6 Which situations produce the plugin event

| Situation | Call | Reaches `plugins_configure('newwanip')`? |
|---|---|---|
| DHCPv6 reply with REASON = REQUEST or SOLICIT | `newipv6 <if> REQUEST` | yes |
| RENEW/REBIND, delegated prefix changed (`ifctl -6pu` returned 0) | `newipv6 <if> RENEW` | yes |
| RENEW/REBIND, nothing changed | `newipv6 <if>` | no (early return) |
| INFOREQ (SLAAC mode runs dhcp6c `information-only`, `interfaces.inc:2925-2932`) | `newipv6 <if>` | no |
| RA RDNSS/DNSSL/router changed | `newipv6 <if>` (`rtsold_resolvconf.sh:86`) | no |
| dhcp6c EXIT / RELEASE | `newipv6 <if>` (`dhcp6c_script.sh:84-91`) | no |
| IPv6CP up, IPv6 type `pppoev6`/static, or IPv4 type `pppoe` | `newipv6 <if> force` (`ppp-linkup.sh:36`) | yes |
| IPv6CP down | `newipv6 <if>` (`ppp-linkdown.sh:25`) | no |
| End of boot replay | `newipv6 <if> force` | yes |

Therefore, by code reading, a pure **SLAAC** WAN with IPv4 = None never produces a forced `newwanipv6` when the
SLAAC address appears (confidence: *likely*, needs a live check).

### 2.7 Link loss

`core/src/opnsense/scripts/interfaces/ppp-linkdown.sh:10-26`:

```sh
ngctl shutdown ${IF}:
...
elif [ "${AF}" = "inet6" ]; then
	# remove previous SLAAC addresses as the ISP may
	# not respond to these in the upcoming session
	/usr/local/sbin/ifctl -i ${IF} -f
	/usr/local/sbin/ifctl -i ${IF} -6nd
	/usr/local/sbin/ifctl -i ${IF} -6rd
	/usr/local/sbin/configctl -d interface newipv6 ${IF}
fi
```

- `-f` removes every address flagged `autoconf` or `deprecated` (`ifctl.sh:57-62`).
- `/tmp/<if>_nameserverv6` and `/tmp/<if>_routerv6` are removed. `/tmp/<if>_prefixv6` and the `:slaac` files are
  **not** touched here; the prefix file is only cleared by `ifctl -6pd` on the next REQUEST/SOLICIT or on dhcp6c
  EXIT/RELEASE, or by `ifctl -6c` in `interface_reset()` (`interfaces.inc:907-909`).
- `newipv6` is called without a reason, so no plugin event.
- devd link events exist only for Ethernet and 802.11 media (`core/src/etc/devd/ifnet.conf:6-32`), not for the
  netgraph PPP interface.

---

## 3. Where WAN IPv6 state lives at runtime

### 3.1 ifctl files

`core/src/opnsense/scripts/interfaces/ifctl.sh:30` `FILES="nameserver prefix router searchdomain"`; file name is
`/tmp/${IF}_${MD}${EX}` with `EX=v6` for `-6` (`ifctl.sh:83-90`, `:234`). A second namespace `${IF}:slaac` is the
fallback written from RAs.

| File | Writer | Content |
|---|---|---|
| `/tmp/pppoe0_routerv6` | `ppp-linkup.sh` (PPP peer link-local, scope stripped), then `rtsold_script.sh` (RA source) | one link-local address |
| `/tmp/pppoe0:slaac_routerv6` | `rtsold_resolvconf.sh` (`-6ru -a <RA source>`) | RA source address |
| `/tmp/pppoe0_nameserverv6` | `dhcp6c_script.sh` (`-6nd -a ...`) | DHCPv6 DNS servers, one per line |
| `/tmp/pppoe0:slaac_nameserverv6` | `rtsold_resolvconf.sh` (`-6nu`) | RA RDNSS servers |
| `/tmp/pppoe0_searchdomainv6`, `/tmp/pppoe0:slaac_searchdomainv6` | same scripts (`-6sd` / `-6su`) | search domains |
| `/tmp/pppoe0_prefixv6` | `dhcp6c_script.sh` (`-6pu -a <PDINFO entries>`) | delegated prefix(es) `addr/len` |
| `/tmp/pppoe0_router`, `/tmp/pppoe0_nameserver` | `ppp-linkup.sh` inet branch only | absent when IPCP never opens |

Commands (man page `core/src/man/man8/ifctl.8:34-120`; reading without `-a/-c/-d/-f/-u` prints the data and
falls back to the `:slaac` file, `ifctl.sh:298-306`):

- `ifctl -6p -i pppoe0` delegated prefix; `ifctl -6r -i pppoe0` router; `ifctl -6n -i pppoe0` DNS servers;
  `ifctl -6s -i pppoe0` search domains.
- `ifctl -i pppoe0 -O` dumps every file with content (`ifctl.sh:178-201`).
- `ifctl -6nl -i pppoe0` prints the file name in use; `ifctl -nl` lists all nameserver files.
- `-u` "Atomically update ... The script returns false in case the data did not need to be updated."

Side effect to know: for every stored prefix whose length is not 64, ifctl installs a null route
(`ifctl.sh:287-292`):

```sh
if [ ${MD} = "prefix" -a "${CONTENT##*/}" != "64" ]; then
	route add -${AF} -blackhole ${CONTENT} ::1
fi
```

and removes it when the file is replaced or cleared (`flush_routes`, `ifctl.sh:37-55`).

### 3.2 PHP API

`core/src/opnsense/mvc/app/library/OPNsense/Interface/Autoconf.php:36-80`:
`Autoconf::getRouter($if, 'inet6')`, `getPrefix()`, `getNameserver()`, `getSearchdomain()`, `all($if)`; each
reads `/tmp/{$if}{''|':slaac'}_{$type}{''|'v6'}` and returns the trimmed file content (newline-separated when
several entries).

`core/src/opnsense/mvc/app/library/OPNsense/Interface/Idassoc.php:125-182` (present on stable/26.7 since
2026-05-20, commit 5b7c8e6): `Idassoc::prefix($ifname = null)` returns, for interfaces of type `idassoc6` only,
`prefix_on_link`, `prefix_allocated`, `prefix_associated`, `prefix_valid`, `prefix_source`. When no prefix file
exists it returns a placeholder `dead:beef:N::/48` with `prefix_valid => false` (`Idassoc.php:94-103`).

### 3.3 Addresses

- `pluginctl -6 wan` / `configctl interface address wan` → JSON with `address`, `network`, `bits`, `device`
  from `interfaces_primary_address6()` (`core/src/sbin/pluginctl:182-212`,
  `core/src/opnsense/service/conf/actions.d/actions_interface.conf:20-24`).
- `pluginctl -D pppoe0` → full parsed ifconfig as JSON (`pluginctl:213-214`).
- `interfaces_addresses()` exposes per address: `autoconf`, `deprecated`, `detached`, `tentative`, `scope`
  (link-local), `bits`, `lifetime`, `alias`, `unique` (ULA) (`interfaces.inc:3958-3974`).
- `get_interface_ipv6($interface, null, 'primary'|'routed'|'scoped')` (`interfaces.inc:3762-3792`).

### 3.4 Other runtime artefacts

`/var/etc/mpd_<if>.conf`, `/var/run/pppoe_<if>.pid`, `/var/etc/dhcp6c.conf`, `/var/etc/dhcp6c.<dev>.conf`,
`/var/run/dhcp6c.pid`, `/var/run/rtsold.pid`, `/tmp/rtsold.<dev>.done`. With "Debug logging" on:
`/tmp/dhcp6c.<dev>.ifconfig` and `/tmp/dhcp6c.<dev>.env` (`dhcp6c_script.sh:37-45`). `kill -USR1` rtsold writes
`/var/run/rtsold.dump` with RDNSS/DNSSL only (`refs/opnsense-src/usr.sbin/rtsold/dump.c:110-125`).

dhcp6c hook environment (`https://raw.githubusercontent.com/opnsense/dhcp6c/master/dhcp6c_script.c`): `IFNAME`,
`REASON`, `NAINFO` (IA_NA as `addr/128`), `PDINFO` (`addr/plen` list), `new_domain_name_servers`,
`new_domain_name`, `new_ntp_servers`, `new_aftr_name`, `new_raw_option_<opnum>` (hex), plus SIP/NIS/BCMCS lists.
OPNsense's hook uses only `REASON`, `IFNAME`, `PDINFO`, `new_domain_name_servers`, `new_domain_name`.

---

## 4. Which device carries the GUA, and how the delegated prefix maps to LANs

### 4.1 Per OPNsense IPv6 mode on the PPPoE WAN

| WAN IPv6 type | What appears on `pppoeN` | Evidence |
|---|---|---|
| `slaac` | link-local; kernel SLAAC `/64` flagged `autoconf` (RA with A-flag prefix); dhcp6c runs `information-only` for DNS | `interfaces.inc:2449-2452`, `2925-2932` |
| `dhcp6` | link-local; IA_NA address (`send ia-na`, `/128`) if the server gives one; SLAAC `/64` too if the RA carries one, because `accept_rtadv` is on in this mode as well | `interfaces.inc:2980-2983`, `3015-3017` |
| `dhcp6` + "Request prefix only" (`dhcp6prefixonly`) | link-local only from DHCPv6; SLAAC `/64` still possible; "primary" address is the link-local, "routed" address comes from a tracking LAN | `interfaces.inc:4022-4041`, `4070-4077`, `4150-4160` |
| `dhcp6` + "Optional prefix ID" (`dhcp6-prefix-id`) | additionally one `/64` of the PD on the WAN device itself (`prefix-interface {$wanif} { sla-id ...; sla-len ...; }`) | `interfaces.inc:2937-2948` |
| `pppoev6` | link-local only | `ppp-ipv6.php:64-66` |

Maintainer wording (#10828, `refs/gh/opnsense_core_10828.md:1301-1303`): "SLAAC address is a /64 annotated
"autoconf" in ifconfig, and IA_NA is a /128 address. ... it's currently not possible to refuse the address
because it refuses the default route as well. The kernel handles SLAAC addressing on its own as soon as
"accept_rtadv" is enabled." Issue #7759 (closed, milestone 26.7): "I don't think there's a graceful way to
prevent SLAAC address from usurping traffic."

Which of these a given ISP uses is ISP-specific and was not established here.

### 4.2 Delegated prefix → LAN prefix IDs

Generated dhcp6c.conf (`DHCP6_Config_File_Basic`, `interfaces.inc:2950-3027`):

```php
foreach (link_interface_to_track6($interface) as $friendly => $lancfg) {
    if (is_numeric($lancfg['track6-prefix-id'])) {
        $trackifv6 = get_real_interface($friendly, 'inet6');
        $pd_conf  = "  prefix-interface {$trackifv6} {\n";
        $pd_conf .= "    sla-id {$lancfg['track6-prefix-id']};\n";
        $pd_conf .= "    sla-len {$wancfg['dhcp6-ia-pd-len']};\n";
        if (isset($lancfg['track6_ifid'])) { $pd_conf .= "    ifid {$lancfg['track6_ifid']};\n"; }
```

- LAN `/64` = delegated prefix with `sla-id` in the bits between the PD length and /64. dhcp6c itself puts the
  address on the LAN device.
- `dhcp6-ia-pd-len` is stored as `64 - prefix length` (GUI map `8 => '56'`, `4 => '60'`, `0 => 64`,
  `interfaces.php:1730-1746`; hint is `prefix ::/{64 - len} infinity;`, `interfaces.inc:3021-3024`). It is a
  user setting; the length actually delegated is whatever is in `/tmp/<wan>_prefixv6`.
- LAN config keys: `track6-interface`, `track6-prefix-id` (decimal in config, hex in GUI), `track6_ifid`,
  `track6_prefix_range` ("Reserved prefix range ... for downstream prefix delegation"), `track6_assoc_pd`
  (`interfaces.php:118-136`, `2104-2128`).
- LAN types `track6` ("Track Interface (legacy)") and `idassoc6` ("Identity association") both use these keys
  (`interfaces.inc:3605`, `interfaces.php:881-882`).
- A tracking parent must be `6rd`, `6to4` or `dhcp6` — **not** `slaac`
  (`find_track6_idassoc6()`, `interfaces.php:105-116`).
- Uniqueness of prefix IDs is checked only in the GUI, against other tracking interfaces, their ranges, and the
  WAN's own `dhcp6-prefix-id` (`interfaces.php:63-90`). There is no registry or reservation API for an ID used
  by something that is not an interface.
- The whole PD is null-routed by ifctl (3.1), so any part of it not on an interface is discarded unless a more
  specific route exists.

---

## 5. RA PREF64 (RFC 8781) on the WAN side

- **rtsold** (`refs/opnsense-src/usr.sbin/rtsold/rtsol.c:378-523`): the RA option loop has
  `case ND_OPT_RDNSS:`, `case ND_OPT_DNSSL:` and

  ```c
  default:
      /* nothing to do for other options */
      break;
  ```

  With `-D` it logs `ndo->nd_opt_type = %d` at LOG_DEBUG (`rtsol.c:364-367`) but exposes nothing. Scripts only
  receive interface and router address (`-A/-M/-O`, `rtsol.c:80-82`) or a resolv.conf on stdin (`-R`).
- **Kernel** (`refs/opnsense-src/sys/netinet6/nd6.c:484-524`): `nd6_options()` handles SOURCE/TARGET_LINKADDR,
  MTU, REDIRECTED_HEADER, NONCE, PREFIX_INFORMATION; RDNSS/DNSSL are "Silently ignore[d]"; everything else:
  "Unknown options must be silently ignored" with an `nd6log` debug line
  `nd6_options: unsupported option %d - option ignored`. A grep for `pref64` (case-insensitive) over
  `sys/netinet6`, `sys/net`, `sys/netpfil`, `usr.sbin/rtsold`, `sbin/rtsol` in the 26.7 src clone finds nothing.
- **Header only**: `sys/netinet/icmp6.h` on stable/26.7 defines `#define ND_OPT_PREF64 38 /* RFC 8781 */` and
  `struct nd_opt_pref64 { ... uint16_t nd_opt_pref64_sl_plc; char nd_opt_prefix[12]; }`
  (`https://raw.githubusercontent.com/opnsense/src/stable/26.7/sys/netinet/icmp6.h`). FreeBSD added it for the
  sending side (rtadvd, April 2024).
- **dhcp6c**: PREF64 is an RA option, not DHCPv6. dhcp6c exports `new_aftr_name` and `new_raw_option_<n>`, which
  OPNsense's hook ignores.
- **OPNsense core**: the only PREF64 code is the LAN/sending side: `nat64prefix` in radvd
  (`core/src/etc/inc/plugins.inc.d/radvd.inc:307-308`, `Radvd.xml:126-129`) and Unbound DNS64
  (`unbound.inc:211-219`). ifctl has no PREF64 file type (`FILES="nameserver prefix router searchdomain"`).

Conclusion: there is no API, file or log to read a WAN-side PREF64 on OPNsense 26.7 / FreeBSD 15 (verified for
the code listed above; other installed tools were not examined).

---

## 6. IPv4 side of a PPPoE WAN without IPCP

Dynamic gateways are synthesised in `Gateways::getGateways()`
(`core/src/opnsense/mvc/app/models/OPNsense/Routing/Gateways.php:386-482`), per enabled interface and per
family:

```php
} elseif (($router = Autoconf::getRouter($device, $ipproto)) != null) {
    $thisconf['gateway'] = $router;
    ...
    $this->cached_gateways[$gwkey] = $thisconf;
} elseif (!empty($ifcfg['gateway_interface']) || substr($device, 0, 5) == 'ovpnc') {
    ...
} elseif (
    $ipproto == 'inet6'
        && in_array($ifcfg['ipaddrv6'] ?? 'none', ['6rd', '6to4', 'dhcp6', 'slaac'])
) {
    // Dynamic IPv6 interface, but no router solicit response received using rtsold.
    ...
} elseif (empty($thisconf['virtual'])) {
    // skipped dynamic gateway from config, add to $dynamic_gw to handle defunct
    $dynamic_gw[$ifname][] = $thisconf;
}
```

- For `inet`, an entry exists only if `/tmp/<dev>_router` exists. That file is written only by the inet branch
  of `ppp-linkup.sh`, i.e. only after IPCP opened. No IPCP → no IPv4 gateway for the WAN, whether the IPv4 type
  is None or PPPoE.
- If config.xml contains a saved dynamic gateway item for that interface/family, it is appended with
  `$gw_arr['defunct'] = true` (`Gateways.php:472-481`). `getDefaultGW()` skips disabled, defunct, loopback and
  force_down entries (`Gateways.php:493-513`), and `getInterfaceGateway()` skips defunct ones (`:597`).
- `system_routing_configure()` takes `getDefaultGW($down_gateways, $ipproto)` and additionally refuses
  addressless devices: `ROUTING: refusing to set {$ipproto} gateway on addressless ...`
  (`core/src/etc/inc/system.inc:703-723`).
- `rc.newwanip` is never invoked with `force` for the WAN in this case; if invoked it returns at
  `Failed to detect IP for interface` (`core/src/etc/rc.newwanip:65-69`).
- Stale files: `ppp-linkdown.sh` inet removes `/tmp/<if>_router` and `_nameserver`; `interface_reset()` runs
  `ifctl -4c` (`interfaces.inc:907-909`).

Result: nothing on the PPPoE WAN's IPv4 side competes for the IPv4 default route (verified by code reading).

How another interface becomes an IPv4 gateway (fact, for reference): any assigned, enabled interface with a
`/tmp/<dev>_router` file gets a dynamic `inet` gateway named `strtoupper("{$descr}_{$ctype}")`, where `$ctype`
is the non-address `ipaddr` value or `GW` (`Gateways.php:392-410`, `283-306`); default priority 254, or 255 for
devices starting with `gre`, `gif`, `ovpn`, `wg`, `ipsec` (`:412-421`). OpenVPN uses exactly this:
`ifctl -4rd -i ${1} ${ROUTERV4}` then `configctl -d interface newip ${1} force`
(`core/src/etc/inc/plugins.inc.d/openvpn/ovpn-linkup:27-30`). Automatic outbound NAT is generated for firewall
interfaces with a non-empty `gateway`, except `ovpn*` (`core/src/etc/inc/filter.lib.inc:186-190`).

---

## 7. DNS

### 7.1 Storage

See 3.1. DHCPv6 servers: `/tmp/<dev>_nameserverv6`. RA RDNSS: `/tmp/<dev>:slaac_nameserverv6`; rtsold appends
`%ifname` to link-local RDNSS addresses (`rtsol.c:410-415`). IPv6CP provides no DNS. DHCPv6 DNS is requested
unless `dhcp6_norequest_dns` is set (`interfaces.inc:2996-2999`).

`get_nameservers($interface = null, $with_gateway = false)` (`core/src/etc/inc/system.inc:349-481`):

- with an interface: reads `ifctl -4nli <dev>` and `ifctl -6nli <dev>` regardless of `dnsallowoverride`;
- without: reads `ifctl -nl` only if `system.dnsallowoverride` is set; then adds static `system.dnsserver`
  entries.

### 7.2 What the system resolver uses

`system_resolvconf_generate()` (`system.inc:212-220`):

```php
if (!isset($syscfg['dnslocalhost']) && !empty(service_by_filter(['dns_ports' => '53']))) {
    $resolvconf .= "nameserver 127.0.0.1\n";
}
$routes = system_resolvconf_host_routes();
foreach (array_keys($routes) as $host) {
    $resolvconf .= "nameserver {$host}\n";
}
```

So with Unbound (or another local DNS on port 53) running, libc lookups go to 127.0.0.1 first. Unbound's own
DNS64, if enabled, synthesises with its configured `dns64-prefix` (`unbound.inc:211-219`), which is unrelated to
the ISP's NAT64 prefix.

### 7.3 Querying the ISP resolver directly

- Server list: `ifctl -6n -i pppoe0` (DHCPv6 file, else the `:slaac` file), or PHP `get_nameservers('wan')`.
- Query tool already used by core: `core/src/opnsense/scripts/system/query_dns.py:63-68`

  ```python
  cmd = ['/usr/bin/drill']
  cmd.append(inputargs.domain)
  if inputargs.server:
      cmd.append('@%s' % inputargs.server)
  cmd.append(qtype)
  ```

  exposed as `configctl dns query <server> <domain>` (`actions_dns.conf:8-12`, `parameters: --server %s %s`,
  default types `A,AAAA,MX,TXT`, JSON output). Direct form: `/usr/bin/drill ipv4only.arpa @<server> AAAA`.
  `/usr/bin/host` is used by the same script for reverse lookups.

Not established: whether `drill` accepts a scoped link-local server (`fe80::1%pppoe0`).

---

## 8. opnsense/core#10828 — what changed

Source: `refs/gh/opnsense_core_10828.md` (closed 2026-09-18, milestone 27.1, label cleanup).

- **Symptom** (26.7.3_8): after PPPoE (re)dial the SLAAC address on `pppoe0` appeared only after 10+ minutes, in
  SLAAC mode and in DHCPv6 prefix-only mode; a manual `rtsol pppoe0` fixed it at once.
- **Root cause** (reporter, lines 843-849): `ppp-ipv6.php` — run from mpd's up-script — started rtsold before
  `interface_configure()` had set `accept_rtadv` on the new device; rtsold logged
  `<interface_up> pppoe0 does not accept Router Advertisement.` and sent no RS. Order confirmed at line 1088:
  "interface re-creation, dialing, and `ppp-linkup.sh` occur first, followed by `ppp-ipv6.php` starting
  `rtsold`, and last is `newwanip`."
- **Fix**: commit f1924c8 "interfaces: ppp-ipv6.php may be executed before later stages of interface_configure()
  #10828" (2026-09-03) adds to `ppp-ipv6.php`:
  `mwexecf('/sbin/ifconfig %s inet6 accept_rtadv -ifdisabled up', $ifcfg['if']);`
  (`https://github.com/opnsense/core/commit/f1924c86c0ae97ef13aacc53a81d09d30d3784e4.patch`). An attempt to move
  the flag into `interface_dhcpv6_configure()` (8d93911) broke PD and SLAAC and was reverted by 9e18f5c; the
  flag is now set in both `interface_configure()` and `ppp-ipv6.php`, with comments referring to #10828
  (`interfaces.inc:2451-2452`, `ppp-ipv6.php:57-58`). On stable/26.7 the commit is 5988099 (2026-09-04).
  Maintainer: "the change for @laozhoubuluo shipped in 26.7.4" (line 1281).
- **Rejected**: one rtsold per interface (`rtsold -iu -p /var/run/rtsold.<if>.pid ... <if>`). Maintainer: "I'd
  prefer auto-probing as it simplifies the code and daemon functionality" and "Multi-dhcp6c is on hold. Some
  testers reported weird issues" (lines 734, 771). Master still runs one `rtsold -aiu` with
  `/var/run/rtsold.pid` (`interfaces.inc:2816-2829`).
- **Follow-up** 2db64b9 "interfaces: be more conservative with -no_dad #10951" (2026-10-01): `-no_dad` is no
  longer applied unconditionally; IPv6 type `none` is now an explicit no-op:
  `/* no extra changes: "no_dad" and "ifdisabled" is not touched esp. relevant for tunnels */`
  (`interfaces.inc:2474-2476`). The unconditional line is now
  `ifconfig %s inet6 -accept_rtadv description %s up` (`interfaces.inc:2446`).
- **Stated limits**: SLAAC cannot be refused without losing the RA default route (line 1303);
  `net.inet6.ip6.accept_rtadv=0` is the default and per-interface `accept_rtadv` is what matters (line 1193).

---

## 9. Design implications (facts a designer must respect)

1. Require WAN IPv4 Configuration Type = None on an IPv6CP-only ISP. With IPv4 = PPPoE the DHCPv6 client is
   started only from the IPv4 link-up.
2. Subscribe to `newwanip` with `:3` and filter `$family == 'inet6'` and the WAN in `$interfaces`, but treat it
   as a hint only. It does not fire on PPP loss, on unchanged renewals, on RA-only changes, or (likely) in pure
   SLAAC mode. It is deferred during boot and replayed at the end.
3. Read state through `ifctl` / `OPNsense\Interface\Autoconf` (and `Idassoc::prefix()` for idassoc6 LANs), not
   through dhcp6c or rtsold internals. `/tmp/<wan>_prefixv6` can be stale after a PPP drop.
4. The delegated prefix is null-routed as a whole by ifctl; any CLAT address or prefix carved out of it needs
   its own more specific route.
5. Prefix IDs are allocated per interface in config (`track6-prefix-id`, `dhcp6-prefix-id`) with GUI-only
   collision checks; there is no reservation mechanism for a non-interface consumer.
6. LAN tracking requires WAN IPv6 type `dhcp6`; a `slaac` WAN cannot be a tracking parent.
7. SLAAC addresses on the WAN are removed by `ifctl -f` at every IPv6CP down; the IA_NA is a /128; in
   prefix-only mode the WAN has no DHCPv6 address at all.
8. NAT64 prefix discovery has to be implemented by the plugin: no PREF64 parsing exists. For RFC 7050 the query
   must go to the ISP resolver from the ifctl nameserver files, not through 127.0.0.1.
9. An IPv4 gateway for a virtual interface comes from `/tmp/<dev>_router` (`ifctl -i <dev> -4rd -a <ip>`) plus
   `configctl interface newip <dev> force`; the device must be an assigned, enabled interface with an IPv4
   address, otherwise routing refuses it.
10. Do not depend on `/tmp/<if>_uptime` (present in stable/26.7 `ppp-linkup.sh`, removed in master), on the
    rtsold pid file name, or on a per-interface rtsold/dhcp6c layout.
11. `ppp-linkup.sh`, `ppp-linkdown.sh`, `dhcp6c_script.sh`, `rtsold_*.sh` are core files with no plugin
    extension point; the only supported hooks in this chain are the `plugins_configure` events.
12. WAN MTU is `mtu - 8` or 1492 by default and is applied to the `pppoeN` device.

## 10. Open questions

1. Live confirmation on 26.7.x that IPv4 = None + IPv6 = DHCPv6/SLAAC brings up an IPv6CP-only PPPoE session
   end to end (code says yes; not tested).
2. Live confirmation that a pure SLAAC WAN produces no forced `newwanipv6`/`newwanip` plugin event.
3. The ISP's actual IPv6 provisioning: SLAAC /64 on the PPP link, IA_NA, PD-only; PD length; whether its RAs
   carry PREF64; whether its resolvers do DNS64; whether the whole WAN /64 is routed to the PPP session.
4. Whether mpd5 5.9 as packaged (port patches applied) matches the SVN-trunk behaviour described in 1.5 when the
   peer sends LCP Protocol-Reject for IPCP — relevant only for the misconfigured IPv4 = PPPoE case.
5. Whether `drill` can query a scoped link-local RDNSS address.
6. Whether any tool shipped with OPNsense 26.7 can decode PREF64 from a received RA.
7. Whether the on-hold multi-dhcp6c / per-interface rtsold work lands in 27.1 and renames pid/config files.
8. How local Unbound answers `ipv4only.arpa` AAAA in its different modes (recursive, forwarding, DNS64 on).
9. Whether a persisted `<WAN>_PPPOE` IPv4 gateway item left in config.xml (shown as defunct) causes any GUI or
   validation friction when another IPv4 gateway is added.
