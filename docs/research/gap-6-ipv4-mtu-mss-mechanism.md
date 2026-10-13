# Gap 6: what presents the reduced IPv4 MTU and TCP MSS for a tayga CLAT tun on OPNsense, without plugin-owned pf rules

Research date: 2026-10-11. Research only, no design. Nothing below was executed on a live system; every
claim is from reading source. Confidence tags: **[V]** verified in the primary source, **[L]** likely
(inferred from verified code), **[U]** unverified.

Path abbreviations (all under `refs/`):

- `CORE` = `opnsense-core` (opnsense/core master, HEAD 5de9cc0d, 2026-10-10)
- `SRC` = `opnsense-src` (opnsense/src stable/26.7, HEAD 412e7621, sparse)
- `TAYGA` = `tayga` (apalrd/tayga master 8a028c7 = 0.9.6 + 15 commits); tag 0.9.6 cross-checked in fetched excerpts
- stable/26.7 files that are not in the clones were read through `raw.githubusercontent.com` (fetched
  excerpts; exact short lines are quoted, but local line numbers are not available for them).

---

## 0. Answer in one screen

| Sub-question | Answer | Confidence |
|---|---|---|
| (a) Does the interface `mss` key emit max-mss rules for a plugin-registered interface? | Yes on both branches. 26.7: `scrub on <if> inet all ... max-mss (mss-40)` + `scrub on <if> inet6 all ... max-mss (mss-60)`. master: `match on <if> inet all scrub ( max-mss (mss-40) )` + the inet6 twin. No filter on `virtual` / `internal_dynamic`; the only conditions are "interface enabled", "`mss` numeric" and the global scrub switch. | V |
| (a) Which value gives 1432 / 1424? | A CLAT flow crosses the tun twice (IPv4 before tayga, IPv6 after), creates one pf state per crossing, and each state carries its own max-mss. Effective clamp = min(mss-40, mss-60) = **mss-60**. `mss = 1492` -> 1432. `mss = 1484` -> 1424. (`mss = 1472` gives 1412, 20 bytes too low.) | V (code path), no runtime test |
| (b) Does `route change -inet default -mtu N` survive? | It survives only the "keeping" branch (route untouched). Any re-add is `route add -inet default <gw>` with no `-mtu`; the kernel deletes the route whenever tayga closes the tun (`if_purgeaddrs`). More important: on OPNsense 26.7 the route MTU is **not consulted for forwarded IPv4** at all (`ip_tryforward()` uses `nifp->if_mtu`, an OPNsense divergence from FreeBSD, which uses `nh->nh_mtu`). A route MTU would only affect firewall-originated traffic. | V |
| (c) Do tayga's ICMPv4 frag-needed errors reach LAN hosts through NAT44? | Yes by code: ICMP errors are matched to the state of the embedded packet before any rule is evaluated; the outer source (192.0.0.2) is never checked against rules or tables; pf rewrites the embedded source and the outer destination back to the LAN host; the LAN-side state passes it out. The one sanity check (outer dst == inner src) is satisfied by tayga. | V (code path), no runtime test |
| (d) 20 or 28? | With tayga the "IPv4 MTU" is not a settable quantity: tayga hard-codes 20 (`MTU_ADJ`) in the three places that generate or translate PMTU values, with no config knob in 0.9.6 or master; pf's own af-to code also uses 20. The kernel cannot present either 1472 or 1464 (one MTU per ifnet, route MTU ignored on forwarding). The only place where the plugin can choose is the TCP MSS value (`mss` key 1492 -> 1432 for "20", 1484 -> 1424 for "28"). The 28 rule exists for already-fragmented IPv4 packets, which a TCP MSS clamp does not affect. | V (facts), choice itself is a design decision |

So, with tun MTU = WAN IPv6 MTU (1492):

- **IPv4 MTU for DF=1 packets** is presented by **tayga itself** (ICMPv4 type 3 code 4, MTU = tun MTU - 20 = 1472),
  delivered to LAN hosts by pf state matching. For packets larger than the tun MTU, pf sends its own
  pre-NAT frag-needed with the tun `if_mtu` (1492) first; the host then needs a second round (1472 from tayga).
- **DF=0 packets** are fragmented by tayga on the IPv6 side at `min(offlink-mtu, tun MTU)`; `offlink-mtu`
  defaults to 1280 and must be raised to the WAN IPv6 MTU.
- **TCP MSS** is presented by **core-generated** rules from the interface `mss` key on the plugin-registered
  interface. These are not plugin-owned pf rules.
- **Nothing in the kernel** presents 1472 or 1464. The kernel believes the IPv4 MTU of the tun is 1492.

---

## 1. Premise check: tayga 0.9.6 MTU behaviour

All line numbers are `TAYGA/nat64.c` at master; the same statements were confirmed at tag 0.9.6 through
`https://raw.githubusercontent.com/apalrd/tayga/0.9.6/nat64.c` (only difference: `gcfg->` instead of `gcfg.`). **[V]**

- `TAYGA/tayga.h:184` `#define MTU_ADJ 20u`; `:187` `#define MTU_MIN 1280`.
- tun MTU is read once at start: `TAYGA/tun.c:546-553` (FreeBSD branch) `ioctl(fd, SIOCGIFMTU, &ifr)` ...
  `gcfg.mtu = ifr.ifr_mtu;`. No other assignment of `gcfg.mtu` in the FreeBSD build (grep). The MTU must be
  on the device before tayga starts; a later change needs a tayga restart.
- IPv4 -> IPv6 (`xlate_4to6_data`, 365-481):
  ```c
  frag_size = gcfg.ipv6_offlink_mtu;          /* 374 */
  if (frag_size > gcfg.mtu) frag_size = gcfg.mtu;
  frag_size -= sizeof(struct ip6);
  ...
  if ((off & (IP4_F_MASK | IP4_F_MF)) == 0) {           /* 411: not a fragment */
      if (off & IP4_F_DF) {
          if (gcfg.mtu - MTU_ADJ < p->header_len + p->data_len) {
              host_send_icmp4_error(3, 4, gcfg.mtu - MTU_ADJ, p);   /* 415 */
              return;
          }
          no_frag_hdr = 1;
      } else if (p->data_len <= frag_size) {
          no_frag_hdr = 1;                    /* no atomic fragment */
      }
  }
  ```
  Fragmenting path (441-479): `frag_size = (frag_size - sizeof(header.ip6_frag)) & ~7;` then a loop that
  emits one IPv6 fragment per `frag_size` bytes.
- IPv6 -> IPv4 (`xlate_6to4_data`, 983-986):
  `if (sizeof(struct ip6) + p->header_len + p->data_len > gcfg.mtu) { ... host_send_icmp6_error(2, 0, gcfg.mtu, p);`
- ICMP translation: frag-needed -> PTB `mtu += MTU_ADJ; if (mtu > gcfg.mtu) mtu = gcfg.mtu; if (mtu < MTU_MIN) mtu = MTU_MIN;`
  (645-652); PTB -> frag-needed `if (mtu > gcfg.mtu) mtu = gcfg.mtu; mtu -= MTU_ADJ;` (1179-1181).
- tayga never touches TCP options: `xlate_payload_4to6` for TCP only adjusts the checksum (349-361). The MSS
  option in a SYN leaves tayga unchanged.
- The author's own comment explains the 20-versus-28 issue (402-410): DF is not honoured for already
  fragmented IPv4 packets "because the IP6 fragmentation header takes an extra eight bytes ... the IP4 source
  thinks the MTU is only 20 bytes smaller than the actual MTU on the IP6 side".
- No directive changes `MTU_ADJ`. Directive table at master (`TAYGA/conffile.c:715-728` plus `offlink-mtu`,
  `config_offlink_mtu` at 632-662) has only `offlink-mtu` (>= 1280, default 1280, `conffile.c:946`).
- OPNsense ships exactly 0.9.6: `refs/opnsense-ports/net/tayga/Makefile` `DISTVERSION= 0.9.6`.

Numbers for tun MTU 1492 and `offlink-mtu 1492` **[V arithmetic]**:

| IPv4 packet entering tayga | Result |
|---|---|
| DF=1, total <= 1472 | 1 IPv6 packet <= 1492, no Fragment header |
| DF=1, total 1473..1492 | dropped, ICMPv4 3/4 with MTU 1472 from `ipv4-addr` to the packet's source |
| DF=0, not a fragment, total <= 1472 | 1 IPv6 packet, no Fragment header |
| DF=0, not a fragment, total > 1472 | IPv6 fragments, payload `(1492-40-8) & ~7 = 1440`, i.e. 1488-byte packets |
| IPv4 fragment with payload <= 1440 | 1 IPv6 fragment |
| IPv4 fragment with payload 1441..1472 (what the kernel produces when it fragments at `if_mtu` 1492) | 2 IPv6 fragments (1440 + rest) |

With the default `offlink-mtu 1280` the DF=0 rows change to "fragment everything above 1260 bytes into
1280-byte packets" (frag_size 1240, fragment payload 1232).

---

## 2. Where the kernel takes the IPv4 MTU from (why the tun MTU is the only kernel knob)

### 2.1 One MTU per ifnet; IPv6 can only be lower **[V]**

- `SRC/sys/net/if_tuntap.c:1466-1467` `case SIOCSIFMTU: ifp->if_mtu = ifr->ifr_mtu;`, default
  `ifp->if_mtu = TUNMTU;` at `:1058`, `TUNMTU 1500` (`SRC/sys/net/if_tun.h:23`).
- `SRC/sys/netinet6/nd6.h:103-107`:
  ```c
  #define IN6_LINKMTU(ifp) \
      ((ND_IFINFO(ifp)->linkmtu && ND_IFINFO(ifp)->linkmtu < (ifp)->if_mtu) \
          ? ND_IFINFO(ifp)->linkmtu \
          : ((ND_IFINFO(ifp)->maxmtu && ND_IFINFO(ifp)->maxmtu < (ifp)->if_mtu) \
              ? ND_IFINFO(ifp)->maxmtu : (ifp)->if_mtu))
  ```
  and `SRC/sys/netinet6/nd6.c:1679-1685` rejects `ND.linkmtu > IN6_LINKMTU(ifp)` with `EINVAL`.
  The only possible asymmetry is "IPv6 lower than IPv4". CLAT needs the opposite (IPv4 1472, IPv6 1492),
  so it cannot be expressed on one tun.
- Corollary: the effective WAN IPv6 MTU is `IN6_LINKMTU(pppoe)`, i.e. the smaller of the interface MTU and
  an RA-advertised link MTU. That, not the raw `if_mtu`, is the value the tun MTU has to follow. **[L]**

### 2.2 Every IPv4 forwarding MTU decision in OPNsense 26.7 uses the interface MTU, not the route MTU **[V]**

1. pf, before NAT, on the outbound hook of forwarded packets, `SRC/sys/netpfil/pf/pf.c:11083-11090`:
   ```c
   if (af == AF_INET && dir == PF_OUT && pflags & PFIL_FWD &&
       pd.df && (*m0)->m_pkthdr.len > ifp->if_mtu) {
       PF_RULES_RUNLOCK();
       icmp_error(*m0, ICMP_UNREACH, ICMP_UNREACH_NEEDFRAG, 0, ifp->if_mtu);
       *m0 = NULL;
       return (PF_DROP);
   }
   ```
   (the IPv6 twin at 11093-11104 carries the comment "Just send it here, before we do any NAT").
2. `ip_tryforward()` in OPNsense stable/26.7
   (`https://raw.githubusercontent.com/opnsense/src/stable/26.7/sys/netinet/ip_fastfwd.c`, approx. lines
   520-545 as counted on the GitHub blob view): three statements, in this order after the output pfil hook
   `pfil_mbuf_fwd(V_inet_pfil_head, &m, nifp, NULL)`:
   ```c
   if (ip_len <= nifp->if_mtu) {
   ...
           icmp_error(m, ICMP_UNREACH, ICMP_UNREACH_NEEDFRAG,
               0, nifp->if_mtu);
   ...
           if (ip_fragment(ip, &m, nifp->if_mtu,
   ```
   `nh_mtu` occurs zero times in that file (checked with two independent fetches plus the blob view).
   Upstream FreeBSD `stable/15` has `if (ip_len <= nh->nh_mtu) {`, `0, nh->nh_mtu);`,
   `ip_fragment(ip, &m, nh->nh_mtu,` and no `nifp`
   (`https://raw.githubusercontent.com/freebsd/freebsd-src/stable/15/sys/netinet/ip_fastfwd.c`).
   The difference comes with OPNsense's forward-tag code in the same function
   (`if (IP_HAS_NEXTHOP(m) && !ip_get_fwdtag(m, &ndst, &nifp)) {`).
   `ip_input()` calls `ip_tryforward()` before its own pfil input hook, so this is the normal path for
   forwarded packets (`.../stable/26.7/sys/netinet/ip_input.c`).
3. pf `route-to` with shared forwarding (OPNsense default: `CORE/src/etc/config.xml.sample:43`
   `<pf_share_forward>1</pf_share_forward>`, `CORE/src/etc/inc/system.inc:129`): `pf_route()` only tags the
   packet (`ip_set_fwdtag(m0, gw, ifp)`, `SRC/sys/netpfil/pf/pf.c:9280-9294`) and returns it to the stack,
   i.e. back to item 2. Without shared forwarding `pf_route()` itself checks `ip_len <= ifp->if_mtu` and
   sends `pf_send_icmp(..., ICMP_UNREACH_NEEDFRAG, ifp->if_mtu, ...)` (9398-9439).
4. Only the slow path `ip_forward()` -> `ip_output()` and locally originated packets use the route MTU:
   `ip_output()` has `mtu = nh->nh_mtu;` in both route branches, and `ip_forward()` starts its ICMP MTU from
   `ro.ro_nh->nh_mtu` (`.../stable/26.7/sys/netinet/ip_output.c`, `ip_input.c`). **[V, fetched excerpt]**

Consequences with tun `if_mtu` 1492:

- Forwarded IPv4 DF packet > 1492: pf answers the LAN host, pre-NAT, with frag-needed MTU **1492**.
- Forwarded IPv4 DF packet 1473..1492: passes pf and the stack, reaches tayga, tayga answers with MTU **1472**.
- Forwarded IPv4 DF=0 packet > 1492: `ip_fragment(..., nifp->if_mtu)` -> 1492-byte fragments -> tayga
  splits each one in two (section 1 table).
- A route MTU on the default route changes none of the above.

---

## 3. (a) The interface `mss` key

### 3.1 How a plugin-registered interface gets into the loop **[V]**

- `CORE/src/etc/inc/plugins.inc:178-242` `plugins_interfaces()` copies **every** property the plugin's
  `<name>_interfaces()` returns into `config.interfaces.<ref>`:
  ```php
  foreach ($intf_data as $prop_name => $prop_value) {
      if ((empty($intf_config[$prop_name]) && !empty($prop_value)) || ($intf_config[$prop_name] ?? '') != $prop_value) {
          ...
          $intf_config[$prop_name] = $prop_value;
          $changed = true;
  ```
  Properties the plugin stops returning are **not** removed (only whole stale interfaces are, 233-239). To
  drop a clamp the plugin has to return `'mss' => ''`, not omit the key.
- `CORE/src/etc/inc/filter.lib.inc:60` `$cnfint = legacy_config_get_interfaces(["enable" => true]);` then
  `$fw->setInterfaceMapping($cnfint)` (83). `legacy_config_get_interfaces()`
  (`CORE/src/etc/inc/config.inc:328-371`) returns the full config record of each interface; the only filter
  here is `enable`. `virtual` and `internal_dynamic` records are included.
- `CORE/src/etc/inc/filter.inc:188` `$cnfint = iterator_to_array($fw->getInterfaceMapping());`
  (`Plugin.php:186-194` only suppresses the synthetic `_stf` entries).
- `mss` has exactly one consumer in core: `filter.inc` (grep over `CORE/src` for `mss`). It is not used by
  `interfaces.inc`.
- The legacy GUI page cannot edit such an interface (`CORE/src/www/interfaces.php:144`
  `legacy_config_get_interfaces(['virtual' => false])`), so for a `virtual` plugin interface the value has to
  come from the plugin's hook. For a normally assigned interface the GUI field exists
  (`interfaces.php:1219-1225`, validation `>= 576` at 613; MVC `dialogAssignment.xml:103-106`).
- Help text confirms the semantics: "MSS clamping for TCP connections to the value entered above minus 40
  (IPv4) or 60 (IPv6)" (`interfaces.php:1223-1225`). Core's own comment: "The interface value is an MTU,
  while PF expects the TCP payload MSS." (`filter.inc:494`).

### 3.2 master (27.1 line): `match ... scrub` **[V]**

`CORE/src/etc/inc/filter.inc:479-506`:

```php
function filter_generate_scrub_rules(&$FilterIflist)
{
    $settings = config_read_array('OPNsense', 'Firewall', 'Filter', 'settings', 'filter', false);
    $enabled = !isset($settings['scrub_enabled']) || !empty($settings['scrub_enabled']);
    if (!$enabled) { return $scrubrules; }
    ...
    foreach ($FilterIflist as $scrubcfg) {
        if (is_numeric($scrubcfg['mss'] ?? '')) {
            $mssclampv4 = 'max-mss ' . (intval($scrubcfg['mss'] - 40));
            $mssclampv6 = 'max-mss ' . (intval($scrubcfg['mss'] - 60));
            $random_id = !empty($settings['scrub_random_id']) ? ' random-id' : '';
            $scrubrules .= "match on {$scrubcfg['if']} inet all scrub ( {$mssclampv4}{$random_id} )\n";
            $scrubrules .= "match on {$scrubcfg['if']} inet6 all scrub ( {$mssclampv6}{$random_id} )\n";
```

Placement: after the NAT section and before all filter rules (`filter.inc:386-387`, comment "Generated scrub
matches are filter rules and must follow translation rules."). Reassembly is global
(`set reassemble yes [no-df]`, 470-477).

### 3.3 stable/26.7: legacy `scrub on` **[V, fetched excerpt]**

`https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/etc/inc/filter.inc`:

- `function filter_generate_scrubbing(&$FilterIflist)`, called as `$rules .= filter_generate_scrubbing($cnfint);`
  before the NAT section, with `$cnfint = iterator_to_array($fw->getInterfaceMapping());`.
- User rules from `config_read_array('filter', 'scrub', 'rule', false)` come first ("custom rules must be first").
- Then, inside `if (empty($config['system']['scrub_interface_disable'])) {`:
  ```php
  foreach ($FilterIflist as $scrubcfg) {
      if (is_numeric($scrubcfg['mss'] ?? '')) {
          $mssclampv4 = 'max-mss ' . (intval($scrubcfg['mss'] - 40));
          $mssclampv6 = 'max-mss ' . (intval($scrubcfg['mss'] - 60));
          $scrubrules .= "scrub on {$scrubcfg['if']} inet all {$scrub_gen_opts} {$mssclampv4}\n";
          $scrubrules .= "scrub on {$scrubcfg['if']} inet6 all {$scrub_gen_opts} {$mssclampv6}\n";
  ...
  $scrubrules .= "scrub in all {$scrub_gen_opts}\n";
  ```
  with `$scrub_gen_opts` built from `system.scrubnodf` / `system.scrubrnid`.
- No condition on `virtual`, `internal_dynamic` or `lo0` in this block. Neither `match` nor `set reassemble`
  occurs in the 26.7 file.

### 3.4 Kernel: both syntaxes end in the same per-state action (stable/26.7 src) **[V]**

- Legacy scrub rules are first-match (`SRC/sys/netpfil/pf/pf_norm.c:1391-1438`, `pf_normalize_tcp`): the loop
  breaks at the first rule that matches interface, direction, af, proto, addresses and ports, then
  `pf_rule_to_actions(rm, &pd->act);` (1437). The per-interface rules precede `scrub in all`, so on the tun
  they win; a user-defined scrub rule that matches earlier would shadow them.
- `match` rules: `pf_rule_to_actions(r, &pd->act);` for each matching match rule
  (`SRC/sys/netpfil/pf/pf.c:5808-5839`), then for the final pass rule (6027).
- `pf_rule_to_actions()` (`pf.c:5011-5039`): `if (r->max_mss) a->max_mss = r->max_mss;`.
- State creation copies the accumulated actions: `memcpy(&s->act, &pd->act, sizeof(struct pf_rule_actions));`
  (`pf.c:6246`).
- Every later packet of the state, in both directions, gets the state's actions back and is clamped,
  `pf.c:11288-11304`:
  ```c
  if (s) { ... memcpy(&pd.act, &s->act, sizeof(struct pf_rule_actions)); ... }
  ...
  pf_scrub(&pd);
  if (pd.proto == IPPROTO_TCP && pd.act.max_mss)
      pf_normalize_mss(&pd);
  ```
- `pf_normalize_mss()` (`pf_norm.c:1969-2001`) rewrites the MSS option only downwards:
  `if (ntohs(mss) > pd->act.max_mss) { pf_patch_16(... htons(pd->act.max_mss) ...`.
- Caveat for master only: when the NAT rule has `pass` (`ctx.nr->natpass`, `pf.c:6008-6011`) the filter
  ruleset, including `match` rules, is skipped. OPNsense's outbound NAT rules were not seen to use it. **[L]**

### 3.5 The CLAT flow crosses the tun twice, so both rules apply **[V code path]**

LAN host opens a TCP connection (device names illustrative):

| Hop | pf hook | State created by the SYN | max-mss stored in the state |
|---|---|---|---|
| 1 | in on LAN, inet | A | LAN `mss`-40 if the LAN has one, else none |
| 2 | out on tun, inet (NAT44 to the tun address) | B | **mss-40** (inet rule on the tun) |
| - | tayga 4->6, MSS option unchanged (`nat64.c:349-361`) | | |
| 3 | in on tun, inet6 | C | **mss-60** (inet6 rule on the tun) |
| 4 | out on PPPoE, inet6 | D | WAN `mss`-60 if the WAN has one, else none |

The SYN is clamped at hops 2 and 3; the SYN-ACK comes back through D, C (out on tun, inet6), tayga, B (in on
tun, inet), A and is clamped by the same states. Effective value in both directions =
min(mss-40, mss-60) = **mss-60** (further limited by a WAN `mss` if present).

| `mss` on the CLAT interface | inet rule | inet6 rule | Effective TCP MSS | IPv4 segment | IPv6 packet on a 1492 link |
|---|---|---|---|---|---|
| 1472 | 1432 | 1412 | 1412 | 1452 | 1472 (20 bytes unused) |
| **1492** (= tun MTU = WAN IPv6 MTU) | 1452 | 1432 | **1432** | 1472 | 1492 (exact fit) |
| **1484** (= WAN IPv6 MTU - 8) | 1444 | 1424 | **1424** | 1464 | 1484 |
| 1464 | 1424 | 1404 | 1404 | 1444 | 1464 |

General rule: `mss` = WAN IPv6 MTU gives MSS = WAN IPv6 MTU - 60, the same value a native IPv6 TCP connection
over that link would use. `mss` = WAN IPv6 MTU - 8 gives the claton "minus 28" value.

Dependencies of this result:

- pf must filter IPv6 on the tun (no `set skip` on it) and a pass rule must create state C. If only the inet
  rule applied, `mss = 1492` would give 1452, which is 20 bytes too large.
- Global switch: 26.7 `system.scrub_interface_disable` empty; master `scrub_enabled` not `0`
  (migration `MFP1_0_9.php:43` maps one to the other). With scrubbing disabled there is no clamp at all.
- Firewall-originated IPv4 TCP is covered too: its SYN also creates states B and C, and the clamped
  SYN-ACK tells the local stack to send at most 1432.

Other things that do or do not clamp:

- A WAN `mss` of 1492 already yields `inet6 ... max-mss 1432` on the PPPoE device (state D), independent of
  the CLAT interface. **[V arithmetic]**
- mpd5 `tcpmssfix` (enabled by default by core, `CORE/src/etc/inc/interfaces.inc:1193-1196`) is IPv4 only:
  in mpd's `iface.c` the option is tested only in `IfaceNgIpInit` (hook `NG_PPP_HOOK_INET`);
  `IfaceNgIpv6Init` has no MSS block; the userland fallback `IfaceCorrectMSS` casts to `struct ip`
  (`https://sourceforge.net/p/mpd/svn/HEAD/tree/trunk/src/iface.c?format=raw`, first 100 kB read). On an
  IPv6CP-only session it does nothing for the translated traffic. **[L]** (trunk read, port is 5.9 + patches)

---

## 4. (b) A route MTU on the default route

### 4.1 Core's handling **[V]**

`CORE/src/etc/inc/system.inc:617-655`:

```php
foreach ($routes as $route) {
    if ($route['proto'] != ($family == 'inet6' ? 'ipv6' : 'ipv4')) { continue; }
    elseif ($route['destination'] != 'default') { continue; }
    elseif ($route['gateway'] != $gateway) { continue; }

    log_msg("ROUTING: keeping {$family} default route to {$gateway}");
    return;
}
log_msg("ROUTING: setting {$family} default route to {$gateway}");
mwexecfm('/sbin/route delete -%s default', [$family]);
mwexecf('/sbin/route add -%s default %s', [$family, $gateway]);
```

- "Keeping" compares only protocol, destination and gateway and does not touch the route, so a previously
  applied `route change -inet default -mtu N` stays in place across such runs.
- Any other outcome deletes and re-adds without `-mtu`. `-mtu` does not occur anywhere in `CORE/src`
  (grep); gateways and static routes have no MTU attribute (`system.inc:751-794` builds
  `route add -inet <net> <gw>` only).
- The only plugin event fired from inside `system_routing_configure()` is `monitor`
  (`system.inc:816`, and only when `$monitor === true`). There is no "route configured" hook.

### 4.2 Kernel side **[V]**

- An explicit MTU sets `RTF_FIXEDMTU` (`SRC/sys/net/route/nhop_ctl.c:950-960`, called for `RTV_MTU` at
  168-173). On an interface MTU change a fixed route MTU is kept unless it is larger than the new interface
  MTU (`nhop_ctl.c:1066-1071`: `if ((nh_priv->rt_flags & RTF_FIXEDMTU) == 0 || nh->nh_mtu > mtu) nh->nh_mtu = mtu;`).
- The route itself disappears whenever tayga closes the tun: `tunclose()` does `if_down(ifp)` and
  `if_purgeaddrs(ifp)` under the comment "Delete all addresses and routes which reference this interface."
  (`SRC/sys/net/if_tuntap.c:1276-1288`). Every tayga restart therefore removes the IPv4 default route and
  with it any route MTU. The tun `if_mtu` itself is not reset by close (only `tuncreate` sets it, `:1058`).
- Other re-add triggers: default gateway switching (`system.inc:690-722`), a changed gateway address, boot.

### 4.3 It would not help forwarded traffic anyway **[V]**

Section 2.2: `ip_tryforward()`, pf's pre-NAT check and `pf_route()` all use `if_mtu` on OPNsense 26.7. A
route MTU of 1472 or 1464 would be seen only by `ip_output()` (firewall-originated packets and the slow
forwarding path). The tayga documentation recipe `ip route add default dev clat mtu 1260`
(`TAYGA/docs/clat/clat-masq.sh:19`, `clat-proxynd.sh:24`, `clat-route.sh:17`) is a Linux recipe; it does not
carry over to OPNsense's forwarding path.

---

## 5. (c) tayga's ICMPv4 frag-needed through NAT44

### 5.1 What tayga emits **[V]**

`TAYGA/nat64.c:249-268` and `216-247`:

```c
orig_len = orig->header_len + orig->data_len;
if (orig_len > 576 - sizeof(struct ip4) - sizeof(struct icmp))
    orig_len = 576 - sizeof(struct ip4) - sizeof(struct icmp);
...
host_send_icmp4(0, &gcfg.local_addr4, &orig->ip4->src, &icmp, (uint8_t *)orig->ip4, orig_len);
```

Outer source = tayga's `ipv4-addr` (192.0.0.2 in the upstream CLAT examples, `TAYGA/docs/clat/*.conf:4`),
outer destination = source of the offending packet (after NAT44 that is the tun address, 192.0.0.1), payload
= the original IPv4 header plus up to 548 bytes, TTL 64, written to the tun. 192.0.0.0/24 is in OPNsense's
bogon list (`CORE/src/etc/bogons.sample:4`).

### 5.2 pf on the tun, inbound (stable/26.7 src) **[V]**

- Dispatch, `SRC/sys/netpfil/pf/pf.c:11243-11253`:
  ```c
  action = pf_test_state_icmp(&s, &pd, &reason);
  if (action == PF_PASS || action == PF_AFRT) { ... r = s->rule; a = s->anchor; }
  else if (s == NULL)
      action = pf_test_rule(&r, &s, &pd, &a, &ruleset, &reason, inp, &match_rules);
  ```
  Rules (bogon block, private-network block, antispoof, default deny) are evaluated only when no state
  matched. The bogon rule is an ordinary filter rule anyway (`CORE/src/etc/inc/filter.lib.inc:327-347`,
  `'from' => "<bogons>", 'direction' => 'in'`, enabled only with `blockbogons` on that interface).
- Error branch of `pf_test_state_icmp()` (`pf.c:8122-8426`): the embedded header is parsed, then the only
  check on the outer packet is
  ```c
  if (PF_ANEQ(pd->dst, pd2.src, pd->af)) { ... "pf: BAD ICMP %d:%d outer dst: " ... return (PF_DROP); }   /* 8207-8222 */
  ```
  tayga satisfies it (outer dst = embedded src). The outer **source** is not checked.
- State lookup uses the embedded addresses and ports with reversed direction
  (`pd2.sidx = (pd->dir == PF_IN) ? 1 : 0;` 8141-8142; key built at 8247-8254) and finds NAT state B through
  its wire key. `pf_find_state()` accepts floating states and states bound to the same interface
  (`pf.c:1940-1942`), so `state-policy if-bound` is not a problem.
- TCP: sequence window check against the state (8281-8303); tayga returns the real header, so it passes.
  UDP and ICMP echo have no such check (8429 ff.).
- Reverse translation (8317-8398): `pf_change_icmp(pd2.src, &th->th_sport, daddr, &nk->addr[pd2.sidx], nk->port[pd2.sidx], ...)`
  rewrites the embedded source and the **outer destination** to the LAN host and port; returns `PF_PASS`.

### 5.3 Forwarding and the LAN side **[V code path]**

The packet now has destination = LAN host, is forwarded, and on the LAN outbound hook
`pf_test_state_icmp()` matches the embedded packet to state A (created inbound on the LAN). No rule is
consulted. The LAN host receives ICMP 3/4 "MTU 1472" with source 192.0.0.2.

Limits:

- If state B has expired the error falls through to rule evaluation and is lost (normal pf behaviour).
- Whether a given LAN host OS accepts an ICMP error whose source is 192.0.0.2 was not tested. No generic
  reason for rejection was found; hosts validate the embedded packet. **[U]**
- For packets above the tun MTU the first error comes from pf itself (section 2.2 item 1), sourced by the
  firewall, with MTU 1492; the 1472 answer from tayga follows on the host's retry.
- ICMPv6 Packet Too Big arriving from the ISP side for the CLAT address takes the mirror path: state D on
  the WAN, state C on the tun, tayga converts it with `mtu -= MTU_ADJ` (`nat64.c:1171-1183`), then 5.2/5.3.
  **[L]**

---

## 6. (d) 20 or 28

Facts:

- draft-ietf-v6ops-claton-16 (5 March 2026), section 8 "MTU Considerations": "the CLAT instance SHOULD
  present IPv4-only applications with an IPv4 MTU which is 28 bytes smaller than the IPv6 MTU"; rationale is
  the 8-byte Fragment header that RFC 7915 section 4.1 requires for already fragmented IPv4 packets. The
  section and the whole draft do not mention TCP MSS, PMTUD, 1280 or 1260
  (`https://www.ietf.org/archive/id/draft-ietf-v6ops-claton-16.txt`). **[V]**
- tayga 0.9.6 and master: 20 is compiled in (`MTU_ADJ`), used for the frag-needed threshold and advertised
  MTU (`nat64.c:413-415`), frag-needed -> PTB (`:645`) and PTB -> frag-needed (`:1181`); no directive
  changes it (section 1). A tayga CLAT therefore always tells IPv4 hosts "tun MTU - 20". **[V]**
- FreeBSD pf's own address-family translation uses 20 as well: `mtu -= 20;` for PTB -> frag-needed
  (`SRC/sys/netpfil/pf/pf.c:3914-3917`) and `mtu += 20;` for the reverse (4023-4026). The firewall-native
  af-to path planned for 27.1 will therefore advertise the same number. **[V]**
- The kernel cannot present either value for forwarded traffic (section 2). The only quantity the plugin
  can actually choose is the TCP MSS, through the `mss` key: 1492 -> 1432 ("20"), 1484 -> 1424 ("28").
- A TCP segment with DF=1 and total length 1472 takes tayga's `no_frag_hdr = 1` path and becomes exactly
  1492 bytes of IPv6 (section 1). The Fragment header that motivates 28 appears only for IPv4 packets that
  are fragments or that tayga has to fragment (DF=0 above the limit). A TCP MSS clamp does not influence
  those cases. **[V]**
- What 28 would buy, a full-size IPv4 fragment that fits one IPv6 fragment, is not reachable here: the
  kernel fragments DF=0 IPv4 at the tun `if_mtu` (1492), which is 28 above the "ideal" 1464, and tayga then
  splits each full-size fragment in two. With pf reassembly enabled the IPv6 fragments are reassembled on
  the tun inbound hook and re-fragmented to the largest received fragment size on the way out
  (`SRC/sys/netpfil/pf/pf_norm.c:843-865`, `1036-1087`), so the wire result is again <= 1488-byte fragments.
  **[L]**
- Reference implementations: Android and NetworkManager subtract 28; clatd and tayga's examples use 20
  (already collected in `research/standards-requirements.md` section 3 and 5).

Reading of these facts: with tayga as datapath, "20" is what the code enforces for the advertised path MTU,
and `mss = WAN IPv6 MTU` (MSS 1432) is the value consistent with it. "28" can only be applied as a more
conservative TCP MSS (`mss = WAN IPv6 MTU - 8`), at a cost of 8 bytes per segment and without any effect on
the fragmented-packet case it was written for. Which one becomes the default is a design decision.

---

## 7. The three numbers and three places from the earlier reports, reconciled

| Earlier suggestion | Status after this trace |
|---|---|
| tun MTU as "the IPv4 MTU" (1472 / 1464) | Wrong role. The tun MTU is tayga's IPv6 limit and must equal the WAN IPv6 MTU (1492). With 1472 tayga advertises 1452 to IPv4 hosts (`gcfg.mtu - MTU_ADJ`), and inbound IPv6 packets above 1472 are refused with Packet Too Big, by the kernel's forwarding check (`SRC/sys/netinet6/ip6_forward.c:393-397`, `IN6_LINKMTU(ifp)`) or by tayga (`nat64.c:983-986`). With a tun MTU above the WAN MTU (for example the default 1500) tayga emits IPv6 packets the WAN cannot carry; pf or the stack then answers with PTB (`pf.c:11098-11104`), which tayga converts to frag-needed 1472: it works, with one more round trip and one more dependency on ICMP **[L]**. |
| Route MTU on the default route (1472 / 1464 / 1260) | Not available (core adds the route without `-mtu`), not durable (lost on every re-add, and the route is removed on every tayga restart), and not honoured for forwarded IPv4 on OPNsense 26.7 (`ip_tryforward` uses `if_mtu`). |
| Interface `mss` key | Works on 26.7 and master for a plugin-registered interface. The value is an MTU-like number; because both the inet and inet6 rule hit the flow, the correct value is the WAN IPv6 MTU (1492 -> 1432), not 1472. |
| 1260 | Only relevant when `offlink-mtu` is left at 1280 and for Linux route-MTU recipes. With `offlink-mtu` = WAN IPv6 MTU it has no role. |

---

## 8. Open questions

1. No runtime verification. A live 26.7 box should show: the two generated rules for the CLAT interface in
   `pfctl -sr` / `/tmp/rules.debug`; SYN and SYN-ACK MSS = 1432 on the PPPoE side with `mss = 1492`; a DF
   ping of 1473..1492 bytes from a LAN host answered by 192.0.0.2 with MTU 1472; a DF ping above 1492
   answered by the firewall with MTU 1492.
2. `ip_fastfwd.c` on the branch that 27.1 will ship (opnsense/src master or stable/27.1): still
   `nifp->if_mtu`, or back to `nh->nh_mtu`? Only stable/26.7 was read.
3. Whether common LAN host stacks act on a frag-needed error sourced from 192.0.0.2 (expected, not tested).
4. With scrubbing disabled globally there is no MSS clamp from the `mss` key; whether the plugin should
   detect and report that state is a design question.
5. mpd5 as packaged (5.9 + OPNsense patches): `tcpmssfix` IPv4-only was read on SourceForge trunk, not on
   the patched port.
6. Whether pf accepts a rule `on <tun>` while the device does not exist yet (expected: yes, pf keeps a
   placeholder kif) was not checked against the 26.7 pfctl.
7. Path MTU below 1492 beyond the BNG: relies on ICMPv6 PTB reaching the CLAT address and on tayga's
   translation (section 5.3 last bullet); not traced end to end.
8. How the firewall-native af-to path in 27.1 will present MSS (probably the WAN interface's own `mss`,
   since there is no tun) is outside this gap.
