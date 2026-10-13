# pf `af-to` and the OPNsense firewall-native translation roadmap

Research date: 2026-10-10. Scope: facts only (no design). All local paths are relative to
`refs/` (local clones, not in this repository).

Clone heads used:

| clone | branch | head |
|---|---|---|
| `opnsense-src` | `stable/26.7` | `412e76211e74` (2026-10-09); `UPDATING:1` says "FreeBSD stable/15", `UPDATING:15-16` "15.1-RELEASE-p4" |
| `opnsense-core` | `master` | `5de9cc0dcc47` (2026-10-10) |
| `opnsense-plugins` | `master` | `1bc3c2f48f66` (2026-10-09) |

Confidence legend: **verified** = primary source read; **likely** = inferred from code/strong evidence, not tested; **unverified** = could not establish.

---

## 0. Executive summary

- opnsense/core#10638 is a **rule primitive only**: two static text fields on a firewall rule that render ` af-to <other-af> from <ip> [to <cidr>]`. No discovery, no address selection, no dynamic tracking, no interface, no route, no host-own IPv4. Not merged on master as of the research date.
- Maintainers push it to **27.1** (roadmap: "Add native NAT64 support", planned Jan 2027) because of **shared forwarding**, shaping and route-to interactions; they say the kernel side must be expanded.
- In the kernel OPNsense 26.7 ships (FreeBSD 15.1 base), `af-to` works by creating **one state with two keys of different address families** and transmitting the translated packet itself from `pf_route()`/`pf_route6()`, bypassing the normal forwarding path and the egress-interface pf pass.
- Code reading shows three concrete hazards for a CLAT (inet -> inet6) on OPNsense 26.7: (a) `pf_route6()` unconditionally defers to OPNsense's shared-forwarding tag when `net.pf.share_forward6=1` (the OPNsense default), handing an IPv6 packet back to the IPv4 input path; (b) the source port chosen by `pf_get_sport()` is **discarded** in FreeBSD's `pf_get_transaddr_af()` (OpenBSD assigns it), so many LAN clients share one IPv6 address **without port rewriting**; (c) the oversized-packet branch in `pf_route6()` emits an ICMPv6-typed error using the pre-translation address family.
- An inbound `af-to` rule can never see packets originated by the firewall itself. FreeBSD 15 does have (undocumented) outbound `af-to`, tested upstream for forwarded traffic only; the OPNsense PR forbids non-inbound rules.

---

## 1. What PR #10638 enables and what it does not

### 1.1 Status (verified)

- `gh/opnsense_core_10638.md:1-2`: `# opnsense/core#10638 [open] Firewall: Rules: Add af-to (address family translation) to filter rules`, `author: Monviech created: 2026-07-31 ... milestone:  labels: feature` (milestone empty).
- Live page https://github.com/opnsense/core/pull/10638 (fetched 2026-10-10): state Open, 1 commit (`b9f0e06`), milestone none, assignee fichtner (Monviech unassigned himself and assigned fichtner on 2026-08-06), review from AdSchellevis requested and still pending, **no comments after 2026-08-01**.
- Issue https://github.com/opnsense/core/issues/10570 (fetched 2026-10-10): Open, labels `feature` + `roadmap`, assignees AdSchellevis and Monviech, no milestone, no comments.
- Not merged: `opnsense-core/src/opnsense/mvc/app/library/OPNsense/Firewall/FilterRule.php:41-74` (`$procorder`) has no `af-to` key on master. The only `af-to` string in core master is the reserved-word list `opnsense-core/src/opnsense/mvc/app/models/OPNsense/Firewall/FieldTypes/AliasNameField.php:50`.

### 1.2 What the diff adds (verified, `gh/opnsense_core_10638.diff`)

1. Two model fields (diff lines 129-135, `Filter.xml`):
   ```xml
   <af-to-source type="NetworkField">
       <NetMaskAllowed>N</NetMaskAllowed>
   </af-to-source>
   <af-to-destination type="NetworkField">
       <NetMaskRequired>Y</NetMaskRequired>
       <Strict>Y</Strict>
   </af-to-destination>
   ```
   `NetworkField` only accepts literal IPs/CIDRs (plus the wildcard `any`): `opnsense-core/src/opnsense/mvc/app/models/OPNsense/Base/FieldTypes/NetworkField.php:142-198` ends in `filter_var($value, FILTER_VALIDATE_IP, $filterOpt)`. So the translation source is **one literal IP address, no alias, no `(interface)` dynamic address, no table**; the destination is a literal CIDR.
2. Two advanced dialog fields under a header "Address family translation" (diff lines 9-33). Help text: "Address family translation is only valid for inbound pass rules using an explicit IPv4 or IPv6 version."
3. Rendering (diff lines 45, 53-60, `FilterRule.php`):
   ```php
   'af-to' => 'parsePlain, af-to ',  // af-to always appears after the label in pfctl
   ...
   if (!empty($rule['af-to-source'])) {
       $address_family = $rule['ipprotocol'] === 'inet' ? 'inet6' : 'inet';
       $rule['af-to'] = sprintf('%s from %s', $address_family, $rule['af-to-source']);
       if (!empty($rule['af-to-destination'])) {
           $rule['af-to'] .= sprintf(' to %s', $rule['af-to-destination']);
       }
   }
   ```
4. Validation (diff lines 72-117, `Filter.php`): destination requires source; action must be `pass`; "Address family translation is only valid for inbound rules." (`direction != 'in'` rejected); ipprotocol must be `inet` or `inet6`; "Address family translation requires state tracking."; "cannot be combined with route-to."; "cannot be combined with reply-to."
5. Test evidence in the PR body is **rule loading only**, not traffic (`gh/opnsense_core_10638.md:30-36`):
   ```
   pass in quick on hn3 inet from {any} to {any} keep state label "5fa6810f-..." af-to inet6 from 2001:db8::1 to 2001:db8::/96 # translation
   pass in quick on hn3 inet6 from {any} to {64:ff9b::/96} keep state label "eb8ec833-..." af-to inet from 198.51.100.1 to 0.0.0.0/0 # translation
   ```

### 1.3 What it does not contain (verified by absence in the 138-line diff)

No NAT64 prefix discovery (RFC 7050 / PREF64 / DHCPv6), no CLAT address selection, no tracking of a changing WAN prefix/address, no virtual interface, no IPv4 route or gateway, no translation for firewall-originated traffic, no MTU/MSS handling, no interaction with outbound NAT, no kernel change, no shared-forwarding change. The issue text itself only says "Implement the `af-to` and test its usefulness" and lists tayga as the alternative (`gh/opnsense_core_10570.md:19-27`).

### 1.4 Related core pieces already merged (verified)

- radvd can **advertise** a static PREF64 on LAN: `opnsense-core/src/etc/inc/plugins.inc.d/radvd.inc:307-308` (`nat64prefix {...}`), model `Radvd.xml:126`, allowed lengths 32/40/48/56/64/96 in `Radvd.php:65-86`. This is server-side only; nothing in core *consumes* a PREF64 received on WAN.
- PR #10687 (open) only adds `AdvValidLifetime` to that block (`gh/opnsense_core_10687.diff`).

---

## 2. How a CLAT is expressed with pf `af-to`, and how it behaves

### 2.1 Syntax and the manual's own CLAT example (verified)

`opnsense-src/share/man/man5/pf.conf.5:1367-1376`:
> Translation between different address families (NAT64) is handled using af-to rules. Because address family translation overrides the routing table, it's only possible to use af-to on inbound rules, and a source address of the resulting translation must always be specified.

`pf.conf.5:1389-1390`: "For IPv4 to IPv6 translation the destination subnet defaults to the subnet of the new IPv6 source address with a prefix length of /96."

`pf.conf.5:3369-3374` (this is exactly a CLAT):
```
In the example below, a router handling both address families
translates an internal IPv4 subnet to IPv6 using the well-known
64:ff9b::/96 prefix:
pass in on $v4_if inet af-to inet6 from ($v6_if) to 64:ff9b::/96
```
Grammar, `pf.conf.5:3427-3428`: `"af-to" af "from" ( redirhost | "{" redirhost-list "}" ) [ "to" ( redirhost | "{" redirhost-list "}" ) ]`.

What OPNsense would emit after the PR for a CLAT (derived from 1.2):
```
pass in quick on <lan_if> inet from {<lan_net>} to {any} keep state label "<uuid>" af-to inet6 from <router-ipv6-literal> to <pref64>/96
```
Plain pf also accepts `from (pppoe0)` (dynamic interface address; pfctl turns it into a round-robin pool, see `sbin/pfctl/tests/files/pf1026.ok`: `af-to inet from (epair0a) round-robin`, and `parse.y:6139-6143`). The PR's `NetworkField` does **not** accept that form.

Dynamic-interface pools skip link-local addresses: `opnsense-src/sys/netpfil/pf/pf_lb.c:813-817` calls `pfr_pool_get(..., pf_islinklocal, true)`, and `pf_lb.c:528-534` defines `pf_islinklocal`. If the interface has no non-link-local IPv6 address the mapping fails (`PFRES_MAPFAILED`, `pf_lb.c:865-866`) and the packet is dropped (upstream test `no_v4` covers the analogous IPv4 case).

### 2.2 Restrictions enforced by pfctl/kernel in this tree (verified)

- Different AF required: `parse.y:5321-5323` "must indicate different address family with af-to"; kernel `pf_ioctl.c:2199-2225` (`pf_rule_checkaf`).
- Not on match rules: `parse.y:5390-5393` "af-to is not supported on match rules".
- Only `dup-to` is rejected with af-to; `route-to`/`reply-to` are accepted by FreeBSD pfctl: `parse.y:5371-5377`
  ```c
  if (r->rule_flag & PFRULE_AFTO && r->rt) {
      if (r->rt != PF_ROUTETO && r->rt != PF_REPLYTO) {
          yyerror("dup-to " "must not be used on af-to rules");
  ```
  (tests `sbin/pfctl/tests/files/pf1026.in`, `pf1027.in`). Monviech's statement "route-to and et al are not supported with af-to" (`gh/opnsense_core_10638.md:52`) is therefore an OPNsense-PR restriction, not a FreeBSD 15 one.
- **No direction check in FreeBSD pfctl or kernel.** Grep of `parse.y` for af-to diagnostics finds only the four messages above plus "cannot respecify af-to" / "af-to addresses must be in the target address family" (`parse.y:2973-3014`). The "inbound only" rule exists in the man page and in the OPNsense PR validation, not in code. See section 3.

### 2.3 Statefulness and return traffic (verified)

- af-to always creates a state. `pf.c:5640-5654` sets `ctx->nr = r; pd->naf = r->naf;` and calls `pf_get_transaddr_af()`; state creation is forced by `ctx.nr != NULL` at `pf.c:6090-6095`; translation of the first packet happens only inside that block (`pf.c:6111-6139`, `action = PF_AFRT`).
- The state has two keys in different address families: `pf.c:1759-1803` (`pf_state_key_setup`): `(*nk)->af = pd->naf;` and for `pd->dir == PF_IN` the translated key is stored **reversed** (`addr[pd->didx] = nsaddr`, `addr[pd->sidx] = ndaddr`), ICMP <-> ICMPv6 proto swapped.
- Return packets (IPv6 from the NAT64 prefix arriving inbound on WAN) are matched in the state lookup before any rule evaluation: `pf.c:1959-1983` "Look through the other list, in case of AF-TO", then `pf_test_state` sets `pd->naf = nk->af; action = PF_AFRT;` (`pf.c:7387-7392`), `pf_test` calls `pf_translate_af()` and `pf_route()` (`pf.c:11438-11458`). No WAN pass rule is needed for the return direction.
- Comment at `pf.c:10866-10875`: "The af-to in "in" direction covers both the inbound and the outbound side of state tracking, so pd->dir is always PF_IN."
- The state starts floating and is bound to the egress interface after the route lookup when `if-bound` is in use: `pf.c:447-463` (`BOUND_IFACE`: `pd->af != pd->naf && st->direction == PF_IN` -> `V_pfi_all`), `pf.c:9657-9664`.
- States cannot be recovered from mid-stream packets: `pf.conf.5:2108-2118` lists af-to among states that "will also not be recoverable from intermediate packets. Such connections will stall and time out." (relevant after a ruleset/state flush on PPPoE reconnect).

### 2.4 Egress path: own route lookup, egress pf pass skipped (verified)

- Without route-to, the translated packet is routed by a plain FIB lookup inside pf: `pf.c:9599-9613` (`fib6_lookup(M_GETFIB(m0), &ip6->ip6_dst, ...)`) and `pf.c:9249-9265` (`/* We're in the AFTO case. Do a route lookup. */ fib4_lookup(...)`).
- The outbound `pf_test()` on the egress interface is skipped for inbound af-to states: `pf.c:9666-9667` and `9319-9320`
  ```c
  if (r->rt == PF_DUPTO || (pd->af != pd->naf && s->direction == PF_IN))
      skip_test = true;
  ```
  Upstream commit 938ae26f "pf: Always skip outbound filtering for inbound af-to rules" (https://github.com/freebsd/freebsd-src/commit/938ae26f.patch): "The af-to rules on inbound direction create a single state spanning both the inbound and the outbound interface."
  Consequence (**likely**): WAN `out` rules, old-style outbound `nat`/`binat` (NPTv6) rules and WAN-out scrub/match rules never see af-to-translated packets.
- The packet is transmitted directly: `nd6_output_ifp(ifp, ifp, md, &dst, NULL)` (`pf.c:9755`) / `(*ifp->if_output)(...)` (`pf.c:9411`), i.e. it does not go through `ip6_output()`/`ip_output()` and their pfil output hooks. Consequence (**likely**): ipfw (OPNsense shaper/captive portal) does not see the translated packet on egress unless shared forwarding hands it back to the stack.

### 2.5 Shared forwarding (OPNsense-specific) - the blocker named by the maintainers

Verified facts:
- OPNsense default config enables it: `opnsense-core/src/etc/config.xml.sample:43` `<pf_share_forward>1</pf_share_forward>`; it drives both sysctls, `opnsense-core/src/etc/inc/system.inc:129-130` (`net.pf.share_forward`, `net.pf.share_forward6`). GUI text `opnsense-core/src/www/system_advanced_firewall.php:450-458`.
- Kernel knobs: `opnsense-src/sys/netpfil/pf/pf.c:551-563` ("If set pf(4) will defer IPv6 forwarding to the network stack.").
- `pf_route6()` (used for inet -> inet6, i.e. the **CLAT upstream direction**) defers unconditionally, `pf.c:9635-9647`:
  ```c
  if (V_pf_share_forward6) {
      if (!IP6_HAS_NEXTHOP(m0)) {
          if (ip6_set_fwdtag(m0, &dst, ifp)) { action = PF_DROP; goto bad; }
          if (pd->act.rt == PF_DUPTO) ip6_forward(m0, 1);
      }
      return (action);
  }
  ```
  and the caller then returns the (now IPv6) mbuf with PF_PASS to whoever called `pf_test()`: `pf.c:11438-11457` (`action = pf_route6(...); *m0 = pd.m; goto out;`). For a CLAT that caller is the **IPv4** input hook `pf_check_in()` (`pf_ioctl.c:6826-6836`, `pf_test(AF_INET, PF_IN, ...)`).
- The tag/flag are shared between families: `opnsense-src/sys/netinet6/in6.h:654-655` (`M_IP6_NEXTHOP` and `M_IP_NEXTHOP` are both `M_PROTO2`), `ip6_output.c:3376-3429` (tag type `PACKET_TAG_IPFORWARD`).
- `pf_route()` (inet6 -> inet, the CLAT return direction) only defers when `pd->act.rt_af == AF_INET`, which is only set by route-to; plain af-to falls through to the hard-coded send path: `pf.c:9280-9300` (`default: /* XXX support AF_INET6 */ break;`).

Inference (**likely**, not tested; `sys/netinet` is not in the sparse clone): with the OPNsense default `net.pf.share_forward6=1`, an IPv4 packet translated to IPv6 by an inbound af-to rule is tagged and handed back to the IPv4 input path as if it were still IPv4, so inet -> inet6 af-to does not work on a default install. This matches fichtner: "This will not work well with shared forwarding" and "the issue is that all the implementation is done in pf_route/pf_route6" (`gh/opnsense_core_10638.md:40,58`).

### 2.6 Does it port-overload many LAN clients onto one IPv6 address?

Verified code facts:
- The af-to source goes through the NAT source-port allocator: `pf_lb.c:1294-1301`
  ```c
  /* get source address and port */
  if (pf_get_sport(pd, r, &nsaddr, &nport, r->nat.proxy_port[0],
      r->nat.proxy_port[1], &r->nat, NULL, PF_SN_NAT)) {
  ```
  with the default range 50001-65535 applied by pfctl (`parse.y:6089-6093`, `pfctl_parser.h:60-61`).
- But in FreeBSD the result is never used: grep of `pf_lb.c` for `nsport =`/`nport` shows no `pd->nsport = nport;` in `pf_get_transaddr_af()` (`pf_lb.c:1270-1380`; only the ICMP `ntohs/htons` round trip at 1311/1316 touches `pd->nsport`). Same on upstream `main` and `releng/15.0` (https://raw.githubusercontent.com/freebsd/freebsd-src/main/sys/netpfil/pf/pf_lb.c, .../releng/15.0/...). OpenBSD has the assignment right after the call: `pd->nsport = nport;` (https://raw.githubusercontent.com/openbsd/src/master/sys/net/pf_lb.c).
- The translated state key is built from `pd->nsport` (`pf.c:6353`, `pf.c:1783-1791`).

Conclusion: many LAN clients **are** mapped to the one IPv6 source address, but (**likely**) the TCP/UDP source port and ICMP echo id are kept as sent by the client instead of being re-allocated. Two LAN clients using the same protocol, source port, destination and destination port at the same time would then produce the same IPv6-side state key; the second state insert fails (`pf.c:6362-6366`, `PFRES_STATEINS`). Not found in any upstream bug report; needs a lab test.

### 2.7 ICMP, TTL, fragments, MTU

- Echo and error type/code translation both ways: `pf.c:3872-4097` (`pf_translate_icmp_af`), including PTB/need-frag MTU adjustment (`mtu -= 20` at 3917, `mtu += 20` at 4026). ICMP errors that belong to an af-to state are rewritten, inner header included: `pf.c:8317-8378` (`pf_change_icmp_af`, `return (PF_AFRT)`).
- Only the IPv4 -> IPv6 direction preserves the real ICMP sender (`pf.c:8361-8369`: "IPv4 becomes IPv6 so we must copy IPv4 src addr to least 32bits in IPv6 address to keep traceroute/icmp working"). For ICMPv6 errors translated to IPv4 (what a CLAT's LAN clients receive from IPv6-only hops) the outer source comes from the state key (`pf.c:8353-8356`). **Likely**: traceroute from a LAN client shows the destination address for IPv6-only hops; no RFC 6791 handling.
- TTL: `pf.c:3664-3677` sends the ICMP error before translating when `pd->ttl == 1` (fix for FreeBSD Bug 291527, "NAT64 af-to generates garbage ICMP error packet when TTL exceeded", closed fixed per https://lists.freebsd.org/archives/freebsd-pf/2025-December/ and search summary of https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=291527).
- Fragments: translation needs reassembly. State (and thus translation) is skipped for `PF_VPROTO_FRAGMENT` (`pf.c:6090`). OPNsense emits `set reassemble yes` by default (`opnsense-core/src/etc/inc/filter.inc:470-477`), switchable off via the scrub setting. Reassembled packets are re-fragmented on the IPv6 side with an adjusted fragment tag (`pf.c:3747-3758`, `pf.c:9742-9748` -> `pf_refragment6`, `pf_norm.c:1034`). Upstream tests `fragmentation_in`/`fragmentation_out` cover inet6 -> inet only.
- MTU, inet -> inet6 (CLAT upstream, +20 bytes): if the translated packet exceeds the egress MTU and was not a reassembled packet, `pf.c:9759-9777` runs
  ```c
  pf_send_icmp(m0, ICMP6_PACKET_TOO_BIG, 0, ifp->if_mtu, pd->af, r, pd->act.rtableid);
  ```
  `pd->af` is still the pre-translation family (only set in `pf_setup_pdesc`, `pf.c:10500`), and `pf_send_icmp` picks `icmp_error()` vs `icmp6_error()` from that argument (`pf.c:4615-4626`, `2525-2550`). **Likely**: for IPv4 clients behind an af-to CLAT there is no correct ICMPv4 "fragmentation needed (MTU-20)" and no IPv6 fragmentation of DF=0 packets; IPv4 packets larger than WAN-IPv6-MTU minus 20 (1472 on a 1492 PPPoE link) are lost unless TCP MSS is clamped. Related open upstream report for the opposite direction: Bug 291617 "pf: NAT64 af-to doesn't generate ICMPv6 packet too big errors" (https://lists.freebsd.org/archives/freebsd-pf/2025-December/000902.html); kp's reply (.../000905.html): could not reproduce, "an overly large ping just succeeds" because pf_route() fragments IPv4, i.e. PMTUD ends at the translator. Final status unknown (Bugzilla blocks automated fetches).
- UDP zero checksum is fixed up for inet -> inet6 (`pf.c:9617-9625`).
- Prefix lengths: kernel `inet_nat64_inet6()` handles RFC 6052 lengths 32/40/48/56/64/96 (`inet_nat64.c:105-150`); the man page still says "The current implementation will only extract IPv4 addresses from the IPv6 addresses with a prefix length of /96 and greater" (`pf.conf.5:1417-1418`). Non-/96 for a CLAT is **likely** fine for inet -> inet6, untested.

### 2.8 Interaction with OPNsense's old-style NAT rules (verified code, likely effect)

OPNsense still renders NAT as old-style translation rules (`opnsense-core/.../Firewall/SNatRule.php:39,50`: `nat ... -> target`; `filter.inc:275-278,383-385`). `pf.c:5640-5643`:
```c
if (r->rule_flag & PFRULE_AFTO) {
    /* Don't translate if there was an old style NAT rule */
    if (ctx->nr != NULL)
        return (PFRES_TRANSLATE);
```
So a packet already matched by an `rdr`/`binat` rule on LAN (DNS redirect, port forward, reflection) that then hits an af-to pass rule is dropped with a translate error. An af-to rule must not be the matching rule for redirected traffic.

### 2.9 "Overrides the routing table"

Because translation happens at LAN ingress before the IPv4 FIB is consulted, **the rule's match criteria alone decide what is translated**. The man-page example (`inet` from anything to anything) would also translate IPv4 traffic addressed to the firewall's own LAN address or to other local IPv4 subnets. A tun/virtual-interface CLAT gets this selection for free from the IPv4 routing table.

### 2.10 Shaper (dummynet)

`pf_route()`/`pf_route6()` swap `dnpipe`/`dnrpipe` and call `pf_dummynet_route()` (`pf.c:9373-9392`, `9714-9734`); upstream has a `dummynet` nat64 test (inet6 -> inet, `dnpipe` on the af-to rule: https://raw.githubusercontent.com/freebsd/freebsd-src/stable/15/tests/sys/netpfil/pf/nat64.sh). fichtner still expects "general bugs in that area relating to shaping, route-to and related functionality" (`gh/opnsense_core_10638.md:48`).

---

## 3. Can pf af-to translate traffic originated by the firewall itself?

- **Inbound af-to: no (verified by mechanism).** Locally generated IPv4 packets only pass the *output* pfil hook (`pf_check_out`, `pf_ioctl.c:6838-6849`), never an input hook on LAN, and OPNsense sets `set skip on lo0` (`filter.inc:373`). The documented form ("only possible to use af-to on inbound rules", `pf.conf.5:1372-1376`, unchanged on FreeBSD main dated April 22, 2026) and the OPNsense PR validation ("only valid for inbound rules") therefore exclude host-originated traffic.
- **Outbound af-to exists in FreeBSD 15 but is undocumented.** Commit f6f116cd "pf: Make af-to work on outbound interface" (2025-02-23, https://github.com/freebsd/freebsd-src/commit/f6f116cd.patch): "Currently af-to works only on inbound interface by creating a reversed NAT state key ... Such limitation is not necessary. When an af-to state is created for an outbound rule do not reverse the NAT state key, making it work just like if it was created for a normal NAT rule." Present in this tree: `sys/net/pfvar.h:1016-1019` (`PF_REVERSED_KEY` requires `direction == PF_IN`), `pf.c:1785-1792`, `pf.c:10843-10847`. Upstream stable/15 test `nat64_setup_out` uses
  `pass out on ${epair_link}a from any to 64:ff9b::/96 af-to inet from (${epair_link}a)` after `route add -inet6 64:ff9b::/96 -iface ${epair_link}a` (translation happens after routing, so a route in the *original* family must already point at the interface carrying the rule).
- **Host-originated use of outbound af-to: unverified.** The upstream tests are forwarded traffic only. For local IPv4 traffic the kernel would still need an IPv4 source address and an IPv4 route to some interface before pf's output hook runs, i.e. a routable virtual interface is still required; the same `pf_route6()` shared-forwarding short-circuit applies; and the OPNsense rule model cannot express it.

---

## 4. Maintainers' stance and timeline (verified quotes)

From `gh/opnsense_core_10638.md` (identical on the live page):
- fichtner, 2026-07-31: "This will not work well with shared forwarding. I suggest this to be something for 27.1 otherwise it will rain bug reports."
- Monviech, 2026-07-31: "Could add a validation that when shared forwarding is enabled you cannot create af-to rules, and at some point remove that validation?"
- fichtner, 2026-07-31: "No we simply need to test this rigorously and expand the kernel side code. I also expect general bugs in that area relating to shaping, route-to and related functionality."
- Monviech, 2026-07-31: "route-to and et al are not supported with af-to, the man pages states all routing decisions are overwritten by af-to. But you are right this looks like a simple change on the surface but the waters are deep indeed."
- fichtner, 2026-07-31: "Well, the issue is that all the implementation is done in pf_route/pf_route6 so even if it looks like features do not overlap they actually do. There will be more edge cases."
- AdSchellevis, 2026-08-01: "Eventually we could flip our defaults as well for shared forwarding, when not using ipfw's rules to redirect traffic to dummynet, it should be less needed anyway. But that's more a long term discussion, do we want to maintain it in the long run, or rather have it removed at some point ..."
- AdSchellevis, issue #10570 (2026-07-18): "With our new firewall user interface in place and FreeBSD 15.x as base, we should be able to offer native NAT64 support now using the `af-to` keyword in `pf`." / "Implement the `af-to` and test its usefulness." / alternative: "Use tayga".

Roadmap https://opnsense.org/about/road-map/ (fetched 2026-10-10): release 27.1 "Planned, Jan 2027", Firewall: "Add native NAT64 support" (also "Add support for Endpoint-Independent NAT (RFC 4787)", "Migrate scrub rules to MVC and integrate with rules"). No roadmap item mentions CLAT, 464XLAT, PREF64 consumption or MAP-T/E. 26.7 (released 2026-07-15) lists "FreeBSD 15.1".

Historical attitude to IPv4-as-a-service requests: #4983 (MAP-T/MAP-E, closed/timed out) - AdSchellevis 2023-02-11: "unlikely, best check `man pf.conf` if what you need is supported."; 2024-05-19: "the starting point is implementing what's described in `man pf.conf` and open a ticket ..." (`gh/opnsense_core_4983.md:103-114`). Core's position is "expose what pf(4) offers", not "automate a transition mechanism".

FreeBSD side: af-to was imported from OpenBSD during the 15-CURRENT cycle (`opnsense-src/UPDATING:221-222`: "20251105: pf(4) now supports nat64 via the af-to keyword."; `if_pfsync.c:678-680`: "FreeBSD 14 does not support af-to"). 15.0 release notes mention af-to only for pfsync ("fixes synchronizing of states with route-to, af-to, ...", https://www.freebsd.org/releases/15.0R/relnotes/). Fix history (https://kernelsources.org/source/history/freebsd/tests/sys/netpfil/pf/nat64.sh): c6210cfd if-bound (2024-11), ca0e6934 route-to on af-to rules (2025-01), 7a372bde reply-to (2025-01), 41265f65 IPv6 gateway for IPv4 route (2025-02, PR 284946), f6f116cd outbound af-to (2025-02), d2761422 dual-AF source nodes (2025-07), 42441d34 / 938ae26f / 6353f5d9 binding, skip outbound filtering, counters (2025-09), cdbc9b76 min-ttl/set-tos (2025-12). No 2026 commits to the nat64 tests on main as of the research date (https://github.com/freebsd/freebsd-src/commits/main/tests/sys/netpfil/pf/nat64.sh).

---

## 5. Coexistence facts

### 5.1 Where core's af-to lives

Entirely inside ordinary user filter rules (model `OPNsense\Firewall\Filter`, rendered by `FilterRule.php`, emitted by `$fw->outputFilterRules()` at `filter.inc:390` into `/tmp/rules.debug`, labelled with the rule UUID). It introduces **no anchor, no table, no interface, no daemon, no sysctl**. There is nothing to collide with by name.

### 5.2 Things a plugin must not touch (facts that make them core-owned)

- `/tmp/rules.debug` and the main ruleset: fully regenerated on every `filter_configure_sync()` (`filter.inc:370-401`). Plugin input is only via the `plugins_firewall($fw)` hook (`filter.inc:189`) and the `Plugin` API: `registerAnchor()` (`Plugin.php:223`), `registerFilterRule()` (`:260`), `registerSourceNatRule()` (`:336`), `registerTable()` (`:418`).
- `system.pf_share_forward` / `net.pf.share_forward{,6}` (`system.inc:129-130`): this is exactly the knob the maintainers are debating for af-to.
- `set reassemble` / scrub settings (`filter.inc:470-505`): af-to depends on reassembly.
- Automatic outbound NAT is generated by core for every non-OpenVPN interface that has a gateway (`filter.lib.inc:176-195`, rules at `filter.inc:208-226`, `ipprotocol => 'inet'`). A virtual IPv4 WAN with a gateway gets NAT44 from core without any plugin-generated pf rule.
- The existing `os-tayga` plugin is a precedent for "no pf rules from the plugin": `opnsense-plugins/net/tayga/src/etc/inc/plugins.inc.d/tayga.inc:66-80` registers only a virtual interface group; it has no `_firewall` hook. The official how-to (https://docs.opnsense.org/manual/how-tos/tayga.html) has the user add one rule on the Tayga group and one Source NAT rule by hand.

### 5.3 What conflicts if a user enables both a tun/virtual-interface CLAT and a core af-to rule

1. **Who gets LAN IPv4 packets.** An af-to pass rule on LAN translates at ingress and "overrides the routing table" (`pf.conf.5:1372`), so matched packets never reach the IPv4 default route / virtual interface. Unmatched IPv4 traffic and all firewall-originated IPv4 still follow the routing table.
2. **IPv6 source address.** Return traffic for af-to is claimed by state lookup on WAN ingress before routing (2.3). If the af-to rule and the tun CLAT used the same IPv6 address, both would create IPv6-side states in the same tuple space (af-to keeps client source ports, 2.6; core NAT44 allocates 50001-65535), and a duplicate tuple fails with `PFRES_STATEINS`. With different addresses the two paths are independent. Sharing the NAT64 *destination* prefix is harmless.
3. **Shared forwarding.** af-to inet -> inet6 likely needs `pf_share_forward` off on 26.7 (2.5); a tun CLAT works with it on because its packets take the normal forwarding path.
4. **Egress policy.** af-to traffic bypasses WAN-out pf evaluation and ip6_output pfil hooks (2.4); tun CLAT traffic is ordinary forwarded IPv6 from the tun to WAN and is seen by all of them.
5. **rdr on LAN** + af-to rule = drop (2.8); not an issue for the tun path.

---

## 6. Which parts of a plugin model stay useful once af-to ships (facts bearing on migration)

| Capability | In PR #10638 / pf af-to? | Evidence |
|---|---|---|
| NAT64 prefix discovery | No. `af-to-destination` is a hand-typed CIDR | diff 129-135 |
| CLAT IPv6 address choice and following prefix changes | No. `af-to-source` is one literal IP; `(if)` form exists in pf but is not accepted by the model, and skips link-local-only interfaces | diff 129-131; `NetworkField.php:142-198`; `pf_lb.c:813-817` |
| IPv4 for the firewall itself | No (inbound-only rule) | section 3 |
| IPv4 default route / gateway object / automatic outbound NAT | No; af-to needs none and creates none | `pf.c:9599-9613`; `filter.lib.inc:176-195` |
| Correct IPv4 PMTUD toward LAN clients | Doubtful in inet -> inet6 direction | 2.7 |
| Per-flow port allocation on the shared IPv6 address | Not in FreeBSD 15 af-to | 2.6 |
| Policy routing / multi-WAN (route-to) for translated traffic | Rejected by PR validation | diff 105-116 |
| Fast in-kernel translation of forwarded LAN traffic | Yes, once shared forwarding is resolved | 2.3-2.5 |

Mechanics available for a later hand-over (verified in the diff, not yet merged): the PR's renderer is generic `FilterRule` code, so the same fields (`af-to-source`, `af-to-destination`, or a pre-built `af-to` string via the `parsePlain` entry) would also be honoured for rules supplied through the model/API or through `registerFilterRule()` in a plugin's `_firewall` hook (**likely**; depends on the final merged form).

---

## 7. Open questions

1. Will 27.1 change the kernel (`pf_route6` shared-forwarding branch) or the shared-forwarding default? Which FreeBSD base will 27.1 use?
2. Will the merged PR accept dynamic sources (`(interface)`, alias/table) or stay literal-only?
3. Lab test on 26.7: does inet -> inet6 af-to pass traffic with `pf_share_forward` on? Off?
4. Lab test: two LAN clients, same UDP source port to the same destination, through one af-to source address (expected collision per 2.6). Is the missing `pd->nsport = nport` intentional upstream?
5. Lab test: 1500-byte DF and non-DF IPv4 packets through af-to onto a 1492 PPPoE IPv6 link (2.7).
6. Does outbound af-to work for firewall-originated IPv4 traffic at all (section 3)?
7. Final status of FreeBSD Bugs 291617 and 284944 (Bugzilla not fetchable).
8. ICMPv6 errors from IPv6-only hops as seen by IPv4 LAN clients (traceroute) through af-to.
9. Does the OPNsense kernel ship the ipfw `nat64clat` module (`opnsense-src/sys/netpfil/ipfw/nat64/nat64clat.c` exists in the tree; kernel config/modules not in the sparse clone)?
10. PR and issue were both "updated 2026-10-04" without visible comments; cause unknown.
