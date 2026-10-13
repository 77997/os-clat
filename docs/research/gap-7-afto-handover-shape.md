# Gap 7: what survives a switch to pf `af-to` if the virtual WAN interface must stay

Research date: 2026-10-11. Facts only, no design. Nothing in this report was executed on a FreeBSD or
OPNsense box; every "works" below means "the code path was traced and no blocker was found".

Path abbreviations

- `REFS` = `refs` (local clones, not in this repository)
- `src/` = `REFS/opnsense-src` (opnsense/src `stable/26.7`, FreeBSD 15.1 base), `core/` = `REFS/opnsense-core` (master),
  `gh/` = `REFS/gh`
- `WEB-SRC/<path>` = `https://raw.githubusercontent.com/opnsense/src/stable/26.7/<path>`, fetched 2026-10-11. Used for
  `sys/netinet/*`, `sys/netgraph/*`, `sys/dev/wg/*`, `tests/*`, which are not in the sparse clone. Line numbers are
  those of the fetched file.

Confidence: **[V]** verified in the primary source, **[L]** likely (inferred from verified code, untested),
**[U]** unverified.

---

## 0. Answers in one table

| # | Question | Answer | Conf. |
|---|---|---|---|
| a | Does 15.1 pf accept and forward `pass out on <vif> inet ... af-to inet6 from <clat6> to <pref64>`? | pfctl: no direction check exists, the rule parses. Kernel: the outbound branch is address-family symmetric and the trace finds no blocker **when shared forwarding is off, the state is floating and no NAT rule matched first**. No upstream test sends a single inet-to-inet6 packet through af-to, in either rule direction. | parse **[V]**, forwarding **[L]** |
| b | Which daemon-less ifnet can carry the IPv4 default route? | Not a tun: `fib4_lookup()` returns NULL for an ifnet with `IFCAP_LINKSTATE` whose link state is not UP. Usable without a process: `lo` clone, `disc`, `edsc`, `epair`, memberless `bridge`, `ng_iface` (and `wg`/`gif` with caveats). `lo` and `disc` are `IFF_LOOPBACK` and fail source address selection for firewall-originated sockets. | **[V]** per mechanism, **[L]** end to end |
| c | Does the `pf_route6()` shared-forwarding branch still short-circuit it? | Yes. The branch is unconditional and is reached from the outbound hook too. The IPv4 caller then treats the IPv6 mbuf as IPv4. Broken with the OPNsense default `pf_share_forward=1` for inbound and outbound rules alike. | **[V]** code, **[L]** runtime |
| d | Can `from` be `(ifname)` or a table? | Yes in pfctl and kernel: `(if)`, `(if:0)`, `<table>`. Both follow address changes without a ruleset reload. `to` must stay a literal prefix. The PR's model field accepts a literal IP only. | **[V]** |
| e | Would the PR's `parsePlain` entry let a plugin pass `af-to` through `registerFilterRule()`? | Yes, verbatim and unvalidated, including `direction => out` and dynamic sources. Traps: automatic `reply-to`, automatic outbound NAT on the same interface, interface must be in the mapping. | **[V]** against the open diff |
| f | Any maintainer statement that 27.1 covers inet to inet6? | No. Only the PR author's "adds both NAT64 and NAT46 capabilities as it seems" plus a rule-loading test. Roadmap and issue say NAT64 only. No milestone, no comment since 2026-08-01. | **[V]** |

---

## 1. (a) Outbound `af-to` inet -> inet6 on a virtual interface

### 1.1 pfctl accepts it **[V]**

- Grammar: `src/sbin/pfctl/parse.y:2993-3014`

  ```
  | AFTO af FROM port_redirspec TO port_redirspec {
        ...
        filter_opts.nat = $4;  filter_opts.nat->af = $2;
        filter_opts.rdr = $6;  filter_opts.rdr->af = $2;
        remove_invalid_hosts(&($4->host), &(filter_opts.nat->af));
        ...
        filter_opts.marker |= FOM_AFTO;
  ```
- Rule action: `parse.y:2702-2703` `if ($9.marker & FOM_AFTO) { r.naf = $9.nat->af; }` with no look at `r.direction`.
- All af-to consistency checks in pfctl (grep of `PFRULE_AFTO|FOM_AFTO` in `src/sbin/pfctl`):
  `parse.y:5321-5323` "must indicate different address family with af-to"; `5371-5376` "dup-to must not be used on
  af-to rules"; `5390-5392` "af-to is not supported on match rules"; `5404-5412` "nat-to and rdr-to require keep
  state" / "require a direction" (satisfied by an explicit `out`).
- Kernel load check `src/sys/netpfil/pf/pf_ioctl.c:2199-2225` (`pf_rule_checkaf`) only compares `r->af` with `r->naf`.
- "only possible to use af-to on inbound rules" exists in the man page (`src/share/man/man5/pf.conf.5:1372-1376`) and in
  the OPNsense PR validation, not in pfctl or the kernel.

### 1.2 Upstream evidence is the mirror image only **[V]**

- Commit f6f116cd "pf: Make af-to work on outbound interface" (2025-02-23,
  https://github.com/freebsd/freebsd-src/commit/f6f116cd.patch): "When an af-to state is created for an outbound rule
  do not reverse the NAT state key, making it work just like if it was created for a normal NAT rule."
- Test setup, `WEB-SRC/tests/sys/netpfil/pf/nat64.sh:68-84`:

  ```sh
  # AF translation happens post-routing, traffic must be directed
  # towards the outbound interface using routes for the original AF.
  jexec rtr route add -inet6 64:ff9b::/96 -iface ${epair_link}a;
  ...
  "pass in  on ${epair}b from any to 64:ff9b::/96" \
  "pass out on ${epair_link}a from any to 64:ff9b::/96 af-to inet from (${epair_link}a)"
  ```
  The rule sits on the interface that is also the real egress for the translated family. `tcp_out_if_bound`
  (nat64.sh:264-266) expects the af-to state bound to `${epair_link}a`, where the IPv4 reply arrives.
- `grep -n "af-to inet6"` over `nat64.sh` (opnsense stable/26.7 and freebsd main) returns nothing. `nat64.py` has one
  rule, `pass in on %s inet6 af-to inet from 192.0.2.1` (line 101). Seven other pf test files checked on main
  (`route_to.sh if_bound.sh pfsync.sh table.sh frag6.sh icmp.py sctp.py`) contain no `af-to inet6`.
  The only inet-to-inet6 coverage found is parser-level: `src/sbin/pfctl/tests/files/pf1024.in`
  (`pass in inet af-to inet6 from 2001:db8::1`) and `pf1025.in`.
- A virtual interface that is *not* the egress of the translated family is a topology no upstream test uses.

### 1.3 Kernel trace, forward direction, shared forwarding OFF **[L]**

Scenario: IPv4 default route points at `<vif>`; rule `pass out on <vif> inet from any to any af-to inet6 from <clat6> to <pref64>/96`.

1. LAN ingress: ordinary `pass in` on LAN, state S1.
2. `ip_tryforward()` finds the route, then calls the output hook with the vif:
   `WEB-SRC/sys/netinet/ip_fastfwd.c:408-410` `pfil_mbuf_fwd(V_inet_pfil_head, &m, nifp, NULL)`. The MTU test against
   `nifp->if_mtu` comes later (line 499), after pf.
3. `pf_test(AF_INET, PF_OUT, PFIL_FWD, vif)`. Before rule evaluation (`src/sys/netpfil/pf/pf.c:11082-11091`):

   ```c
   if (af == AF_INET && dir == PF_OUT && pflags & PFIL_FWD &&
       pd.df && (*m0)->m_pkthdr.len > ifp->if_mtu) {
           icmp_error(*m0, ICMP_UNREACH, ICMP_UNREACH_NEEDFRAG, 0, ifp->if_mtu);
           *m0 = NULL;
           return (PF_DROP);
   }
   ```
   So for forwarded DF packets the **vif MTU** produces a correct ICMPv4 "fragmentation needed" before translation.
   The inbound-on-LAN form has no equivalent (the previous report, `pf-af-to-roadmap.md` 2.7, found the
   `pf_route6()` oversize branch emits an ICMPv6-typed error with the IPv4 family). DF=0 oversize packets are not
   covered by this check.
4. Old-style NAT is evaluated first (`pf.c:5985-6005`, `pf_get_translation`). If a `nat on <vif>` rule matched,
   the af-to rule fails (`pf.c:5640-5643`):

   ```c
   if (r->rule_flag & PFRULE_AFTO) {
           /* Don't translate if there was an old style NAT rule */
           if (ctx->nr != NULL)
                   return (PFRES_TRANSLATE);
   ```
   A `no nat` match leaves `ctx->nr` NULL (`src/sys/netpfil/pf/pf_lb.c:990-995`), so it does not trigger this.
5. State creation, direction OUT, key not reversed (`pf.c:1778-1792`, else-branch). `action = PF_AFRT` (`pf.c:6137-6138`).
6. `pf_test` case `PF_AFRT` (`pf.c:11438-11457`): `pf_translate_af()` then `pf_route6(r, kif->pfik_ifp, s, &pd, inp)`.
7. `pf_route6()`:
   - `pf.c:9549`: `(pd->act.rt == PF_REPLYTO) == (r_dir == pd->dir)` is `false == true`, block skipped.
     `pd->act.rt` is only set when the rule has route-to/reply-to (`pf.c:6070-6088`).
   - `pf.c:9599-9613`: plain `fib6_lookup(M_GETFIB(m0), &ip6->ip6_dst, ...)`, i.e. the IPv6 default route (PPPoE).
   - `pf.c:9617-9625`: UDP zero checksum is filled in.
   - `pf.c:9666-9702`: `skip_test` stays false (`s->direction == PF_OUT`) but the `pf_test(AF_INET6, PF_OUT, ...)`
     call is inside `if (pd->dir == PF_IN)`. **For an outbound af-to rule no pf evaluation happens on the real egress
     interface.** WAN `out` rules, NPTv6/outbound NAT66 and WAN scrub never see the packet; no second state is created.
   - `pf.c:9750-9756`: `nd6_output_ifp(ifp, ifp, md, &dst, NULL)`.
8. Back in the IPv4 caller the hook reports `PFIL_CONSUMED` (`pf_ioctl.c:6778-6788`), `ip_tryforward` jumps to `drop:`
   with `m == NULL` (`ip_fastfwd.c:575-578`).

OPNsense-specific deviation **[V]**: OPNsense moved the hop-limit decrement out of the `pd->dir == PF_IN` block
(`pf.c:9649-9650`, comment "do not mangle the IP header until hardcoded send path is used"; upstream stable/15 has
`ip6->ip6_hlim -= IPV6_HLIMDEC;` inside `if (pd->dir == PF_IN)`,
https://raw.githubusercontent.com/freebsd/freebsd-src/stable/15/sys/netpfil/pf/pf.c lines 9512-9522). With an outbound
rule the hop limit is therefore decremented once by `ip_tryforward` (as IPv4 TTL) and once more by pf. Same in
`pf_route()` (`pf.c:9302-9303`). Cosmetic (traceroute hop count), not a blocker.

### 1.4 Kernel trace, reply direction **[L]**

1. IPv6 reply arrives on PPPoE. `pf_find_state()` (`pf.c:1937-1957`) finds the af-to state through its wire key only if
   `s->kif == V_pfi_all || s->kif == pd->kif || s->orig_kif == pd->kif`.
   - Floating policy (OPNsense default; `set state-policy if-bound` is emitted only when configured,
     `core/src/etc/inc/filter.inc:329-331`): `kif == all`, match.
   - if-bound: `BOUND_IFACE()` returns the rule interface for an outbound af-to state (`pf.c:447-463`, the "all"
     exception is only for `st->direction == PF_IN`), and the later re-bind in `pf_route6()` requires
     `s->kif == V_pfi_all` (`pf.c:9657-9664`). The state stays bound to the vif, the reply on PPPoE does not match
     and falls to the WAN ruleset. **With if-bound states a vif-anchored outbound af-to rule gets no replies**
     unless the rule itself carries `keep state (floating)`. OPNsense can render that per rule
     (`core/src/opnsense/mvc/app/library/OPNsense/Firewall/FilterRule.php:303-305`, `state-policy`).
2. `pf_test_state` selects the IPv4 key and returns `PF_AFRT` (`pf.c:7367-7392`); `pf_route()` runs.
3. `pf_route()`: FIB lookup on the IPv4 destination (`pf.c:9249-9265`); the shared-forwarding switch only acts on
   `rt_af == AF_INET`, which plain af-to never sets (`pf.c:9280-9300`, `default: /* XXX support AF_INET6 */`).
   `skip_test` is false, `pd->dir == PF_IN`, so `pf_test(AF_INET, PF_OUT, PFIL_FWD, ifp, ...)` runs on the LAN
   interface (`pf.c:9319-9354`) and matches S1.
4. Firewall-originated flows: the destination is the vif's own IPv4 address, the FIB returns `lo0`,
   `pf_test` on `lo0` returns at once because of `set skip on lo0` (`pf.c:11027-11029`, `filter.inc:373`),
   then `M_SKIP_FIREWALL` is set (`pf.c:9356-9357`) and the packet is looped to `ip_input`.

### 1.5 Firewall-originated IPv4 through an outbound rule **[L]**

`ip_output()` runs the same output hook with the socket's inpcb (`WEB-SRC/sys/netinet/ip_output.c:109-135,703-738`);
`PFIL_CONSUMED` ends `ip_output` (`return 1; /* Finished */`). Delayed checksums: `pf_translate_af()` remaps the
offload flags (`pf.c:3734-3745`, `CSUM_TCP -> CSUM_TCP_IPV6` etc.) and `pf_route6()` finishes them
(`pf.c:9707-9712`). The source address is the vif's IPv4 address, so the vif needs one. Upstream has no test for
host-originated af-to traffic.

### 1.6 Conditions that must all hold for 1.3-1.5

| Condition | Evidence | Who controls it on OPNsense |
|---|---|---|
| `net.pf.share_forward6 = 0` | section 3 | core setting `system.pf_share_forward`, default 1 |
| state floating (global or per rule) | 1.4 | core setting / rule option |
| no old-style `nat` match on the vif | 1.3 step 4 | core automatic outbound NAT, section 6.2 |
| no automatic `reply-to` on the rule | section 5.3 | rule flag `disablereplyto` |
| vif route usable (`RT_LINK_IS_UP`) | section 2 | ifnet type |
| vif MTU <= WAN IPv6 MTU - 20, TCP MSS clamp | 1.3 step 3; DF=0 oversize still lost | interface settings |

---

## 2. (b) Which ifnet can carry the IPv4 default route without a daemon

### 2.1 The gate: `RT_LINK_IS_UP` inside `fib4_lookup()` **[V]**

- `src/sys/net/route.h:385-386`

  ```c
  #define RT_LINK_IS_UP(ifp)  (!((ifp)->if_capabilities & IFCAP_LINKSTATE) \
                               || (ifp)->if_link_state == LINK_STATE_UP)
  ```
- `WEB-SRC/sys/netinet/in_fib.c:119-130` (FIB_ALGO variant; the radix variant at 157-170 is identical in effect)

  ```c
  nh = dp->f(dp->arg, key, scopeid);
  if (nh != NULL) {
          nh = nhop_select(nh, flowid);
          /* Ensure route & ifp is UP */
          if (RT_LINK_IS_UP(nh->nh_ifp)) { ... return (nh); }
  }
  RTSTAT_INC(rts_unreach);
  return (NULL);
  ```
  Same in `src/sys/netinet6/in6_fib.c:127-138`. `NH_IS_VALID()` is the same macro (`src/sys/net/route/nhop.h:155`).
- Every IPv4 consumer goes through it before the pf output hook: `ip_findroute()` in `ip_fastfwd.c` (fetch),
  `ip_output.c:476-491,515-529`, `in_pcbladdr()` (`WEB-SRC/sys/netinet/in_pcb.c:1247-1249`), pf's own af-to lookups
  (`pf.c:9253`, `9602`).
- No `IFF_UP` or link test exists in `ip_output.c` or `ip_fastfwd.c` apart from this (grep of both files for
  `IFF_UP|LINK_STATE|RT_LINK_IS_UP` returns nothing).

### 2.2 tun without a process is unusable **[V]**

- `src/sys/net/if_tuntap.c:1043,1047`: `ifp->if_capabilities |= IFCAP_LINKSTATE | IFCAP_MEXTPG;`
- Link goes UP only in `tunopen` (`if_tuntap.c:1204`), DOWN in `tundtor` (`1291`). A never-opened tun is
  `LINK_STATE_UNKNOWN` (ifnet is `M_ZERO` allocated, `src/sys/net/if.c:424,509`; `LINK_STATE_UNKNOWN` is 0,
  `src/sys/net/if.h:184`), an opened-then-closed one is DOWN. Both fail `== LINK_STATE_UP`.
- Result: a default route via such a tun makes `fib4_lookup()` return NULL ("no route"), so the packet never reaches
  pf's output hook. `tunoutput`'s `EHOSTDOWN` (`if_tuntap.c:1538-1547`) is not even reached.
- `RT_LINK_IS_UP` reads `if_capabilities`, not `if_capenable`, so the capability cannot be switched off from userland.
- A tun held open by any process (tayga or a trivial holder) is link-UP and works, but that is not daemon-less.

### 2.3 Candidates

| ifnet | `IFCAP_LINKSTATE` / when UP | flags | availability on 26.7 | forwarded traffic | firewall-originated |
|---|---|---|---|---|---|
| `tun` never opened | yes / never | P2P | `device tuntap` in GENERIC | **no** (2.2) | no |
| `lo` clone (`loN`) | yes / UP when `IFF_UP` (`if_loop.c:131-132,354-357,389-392`) | `IFF_LOOPBACK` (`if_loop.c:127`) | built in; core device type (`core/src/etc/inc/plugins.inc.d/loopback.inc:53-74`) | yes **[L]** | **no** (2.4) |
| `disc` | no | `IFF_LOOPBACK` (`if_disc.c:101`), output frees the mbuf (`170-193`) | module `if_disc` | yes **[L]** | **no** (2.4) |
| `edsc` | no | `IFF_BROADCAST \| IFF_MULTICAST \| IFF_SIMPLEX` (`if_edsc.c:116`) | module `if_edsc` | yes **[L]** | yes **[L]** |
| `epair` (one end) | no (`if_epair.c:632-636`) | `IFF_BROADCAST \| IFF_SIMPLEX \| IFF_MULTICAST` (`631`) | module `if_epair`; the ifnet upstream uses for outbound af-to tests | yes **[L]** | yes **[L]** |
| `bridge` without members | no (`bridge_linkcheck` sets DOWN, `if_bridge.c:4452-4476`, irrelevant without the capability) | Ethernet | module; core device type (`core.inc:156`) | yes **[L]** | yes **[L]** |
| `ng_iface` | no; `WEB-SRC/sys/netgraph/ng_iface.c:547` `IFF_SIMPLEX\|IFF_POINTOPOINT\|IFF_NOARP\|IFF_MULTICAST` | P2P, like tun | netgraph modules (mpd5 already uses them); node persists without hooks (`src/share/man/man4/ng_iface.4:106-122`: "does not go away when all hooks have been disconnected") | yes **[L]** | yes **[L]** |
| `wg` | yes (`WEB-SRC/sys/dev/wg/if_wg.c:281`), UP on `ifconfig up` (`2922`) | `IFF_NOARP \| IFF_MULTICAST` (`3023`) | module; core device type (`wireguard.inc:119`) | yes **[L]** | yes **[L]**, but it is a WireGuard instance |
| `gif` | yes (`if_gif.c:158-159`), UP only once tunnel endpoints are set (`690-700`) | P2P | GENERIC; core device type (`core.inc:176`) | only with a dummy tunnel | same |

Module availability **[L]**: `if_bridge if_disc if_edsc if_epair if_tuntap if_wg netgraph ipfw_nat64` are in the default
`SUBDIR` list (`WEB-SRC/sys/modules/Makefile:155-172,289,484-507,634`); OPNsense's `src.conf` has no
`MODULES_OVERRIDE`/`WITHOUT_MODULES` (https://raw.githubusercontent.com/opnsense/tools/master/config/26.7/src.conf,
37 lines) and the kernel config is `include GENERIC` plus options
(https://raw.githubusercontent.com/opnsense/tools/master/config/26.7/SMP). Presence of the `.ko` files on an installed
box was not checked.

Why "yes" for forwarded traffic: pf's output hook runs before `if_output`, ARP and the MTU test (1.3 step 2), and an
af-to match consumes the packet, so the dummy's own output routine and L2 resolution are never used. Packets that do
*not* match the af-to rule fall through to the dummy's `if_output` (discarded by `disc`/`edsc`, looped back by `lo`,
ARP-queued on Ethernet types).

Core device types that need no daemon: `^lo`, `^bridge`, `^gif`, `^gre`, `^lagg`, vlan, `^vxlan`, `^wg`, `^ipsec`
(`core/src/etc/inc/plugins.inc.d/core.inc:156-291`, `loopback.inc:69`, `vxlan.inc:52`, `wireguard.inc:119`,
`ipsec.inc:226`). `disc`, `edsc`, `epair`, `ng` are not known to core; a plugin would declare them through its own
`_devices()` hook.

### 2.4 `IFF_LOOPBACK` breaks firewall-originated IPv4 **[V]**

`WEB-SRC/sys/netinet/in_pcb.c:1356-1382` (`in_pcbladdr`, unbound source):

```c
/* The outgoing interface is marked with 'loopback net', so a route to ourselves is here.
 * Try to find the interface of the destination address and then take the address from there. */
if ((nh->nh_ifp->if_flags & IFF_LOOPBACK) != 0) {
        ia = ifatoia(ifa_ifwithdstaddr(sintosa(&dst), ...));
        if (ia == NULL) ia = ifatoia(ifa_ifwithnet(sintosa(&dst), 0, ...));
        if (ia == NULL) ia = ifatoia(ifa_ifwithaddr(sintosa(&dst)));
        if (!prison_flag(cred, PR_IP4)) {
                if (ia == NULL) { error = ENETUNREACH; goto done; }
```
With the default route on a `lo` clone or `disc`, a socket connecting to an Internet address without binding a source
gets `ENETUNREACH`. Forwarded traffic is unaffected. So the loopback types satisfy "LAN devices" but not "the firewall
itself".

### 2.5 Device name can stay constant across ifnet types **[V]**

Any ifnet can be renamed (`SIOCSIFNAME`); tayga itself renames its cloned tun when `tun-device` does not start with
`tun` (`REFS/tayga/tun.c:454-559`, see `clat-datapaths.md` 2.5). OPNsense rules, gateways and NAT refer to the logical
interface key and resolve the device through `interfaceMapping[...]['if']`
(`core/src/opnsense/mvc/app/library/OPNsense/Firewall/Rule.php:310-326,402-414`). The dynamic-gateway mechanism has no
device-type restriction (`opnsense-gateways-nat.md` 1.3: "`/tmp/<device>_router` exists ... no device-name restriction").

---

## 3. (c) Shared forwarding still short-circuits it **[V code, L runtime]**

### 3.1 pf side

`src/sys/netpfil/pf/pf.c:9635-9647`, reached for every `pf_route6()` call that survives the lookup, regardless of rule
direction or af-to:

```c
if (V_pf_share_forward6) {
        if (!IP6_HAS_NEXTHOP(m0)) {
                if (ip6_set_fwdtag(m0, &dst, ifp)) { action = PF_DROP; goto bad; }
                if (pd->act.rt == PF_DUPTO) ip6_forward(m0, 1);
        }
        return (action);          /* PF_PASS, pd->m still set */
}
```
`pf_test` then does `*m0 = pd.m; goto out;` (`pf.c:11456-11457`) and `pf_check_out`/`pf_check_in` return `PFIL_PASS`
with the translated IPv6 mbuf (`pf_ioctl.c:6778-6849`). Defaults: `core/src/etc/config.xml.sample:43`
`<pf_share_forward>1</pf_share_forward>`, mapped to both sysctls at `core/src/etc/inc/system.inc:129-130`.

The tag: `src/sys/netinet6/ip6_output.c:3370-3429` stores a `sockaddr_in6` plus `if_index` under
`PACKET_TAG_IPFORWARD` and sets `M_IP6_NEXTHOP`; `src/sys/netinet6/in6.h:654-655` defines `M_IP6_NEXTHOP` and
`M_IP_NEXTHOP` as the same bit (`M_PROTO2`).

### 3.2 What the IPv4 callers do with that mbuf

- Outbound rule, fast path, `WEB-SRC/sys/netinet/ip_fastfwd.c:415-444`: `ip = mtod(m, struct ip *)` on an IPv6 header;
  `IP_HAS_NEXTHOP(m)` is true; `ip_get_fwdtag()` copies the first 16 bytes of the `sockaddr_in6` into a `sockaddr_in`
  and takes the egress ifp from the tag (`ip_output.c:1651-1678`; the family `KASSERT` is compiled out in a release
  kernel); then `(*nifp->if_output)(nifp, m, gw, &ro)` at line 508 with an `AF_INET` sockaddr. The IPv6 packet is
  handed to the PPPoE ifnet as IPv4.
- Outbound rule, `ip_output()` (slow path and firewall-originated), `ip_output.c:136-167`: the "destination changed"
  test compares IPv4-offset bytes of an IPv6 header, sets `M_SKIP_FIREWALL` and re-loops as IPv4.
- Inbound rule (the form PR #10638 emits). Forwarded packets reach `ip_tryforward()` first
  (`WEB-SRC/sys/netinet/ip_input.c:611-628`). Its input hook (`ip_fastfwd.c:315-323`) is followed by
  `ip = mtod(m, struct ip *)`, the IPv4 TTL test and `ip->ip_ttl -= IPTTLDEC` on what is now an IPv6 header
  (`357-376`), then `if (IP_HAS_NEXTHOP(m) && !ip_get_fwdtag(m, &ndst, &nifp))` (`384-386`) and the IPv4 send path.
  The slow path does the same in `ip_input.c:652-686`: `if (m->m_flags & M_IP_NEXTHOP) { ip_forward(m, 1); return; }`.

In no case is the packet transmitted as IPv6. This upgrades the previous report's inference (it had no `sys/netinet`)
and extends it to outbound rules. The reply direction (inet6 -> inet through `pf_route()`) is not deferred
(`pf.c:9280-9300`).

### 3.3 Status of the kernel work **[V]**

opnsense/src `stable/26.7` commit list for `sys/netpfil/pf/pf.c`
(https://github.com/opnsense/src/commits/stable/26.7/sys/netpfil/pf/pf.c, fetched 2026-10-11): latest entries are
2026-10-03 "pf: mark non-port packets to require IP checksumming #312", 2026-08-19/20 state-key re-optimisation; the
shared-forwarding commits are 2026-06-25 "pf|ipfw|netinet6?: shared IP forwarding" and 2026-07-10/12 touch-ups. Nothing
after PR #10638 (2026-07-31) touches af-to or shared forwarding. Branch enumeration through the GitHub HTML page was
incomplete, so a development branch cannot be ruled out **[U]**.

---

## 4. (d) Dynamic `from`

### 4.1 pfctl **[V]**

- `port_redirspec -> redir_host -> host` (`parse.y:4517-4549`); `host` includes `dynaddr` and `'<' STRING '>'`
  (`parse.y:3716-3745`), `dynaddr` is `'(' STRING ')'` with `:network|:broadcast|:peer|:0` modifiers (`3762-3813`).
- `remove_invalid_hosts()` only drops nodes whose `af` is set and different (`parse.y:7294-7323`); dynaddr and table
  nodes have `af == 0` and stay.
- `apply_redirspec()` (`parse.y:6139-6148`): a table or a multi-address dynaddr turns the pool into round-robin;
  other pool types reject them ("tables are not supported by pool type"). `(if:0)` on a name ending in a digit is not
  "multi-address" (`DYNIF_MULTIADDR`, `parse.y:522-524`) and keeps pool type none.
- Upstream: `pf1026.ok` prints `af-to inet from (epair0a) round-robin`; `nat64.sh:706-723` accepts
  `af-to inet from <wanaddr> round-robin|random` and rejects `bitmask`; `nat64.sh:763-769` runs traffic through
  `table <wanaddrs> { 192.0.2.2/31 }` + `af-to inet from <wanaddrs> round-robin`. All inet6 -> inet.

### 4.2 Kernel **[V]**

- Source selection goes through `pf_get_sport()` -> `pf_map_addr_sn(pd->naf, ...)` (`pf_lb.c:358,1295-1296`).
- `(if)`: round-robin over the interface's dynamic table, link-local skipped: `pf_lb.c:813-817`
  `pfr_pool_get(rpool->cur->addr.p.dyn->pfid_kt, ..., wanted_af, pf_islinklocal, true)`.
  The table holds every inet/inet6 address of the interface (`pf_if.c:718-784`); there is no filter for tentative,
  deprecated, temporary or anycast addresses (no `IN6_IFF_` test in `pf_if.c`). On a WAN with SLAAC + privacy +
  DHCPv6 addresses, `(wan)` rotates over all global ones.
- `(if:0)`: first IPv4 and first non-link-local IPv6 only (`pf_if.c:751-761`), used directly as
  `pfid_addr6` (`pf_lb.c:617-625`).
- Updates without reload: `pfi_ifaddr_event` is registered on `ifaddr_event` (`pf_if.c:181-182,1177-1193`) and refreshes
  the dynamic tables; a `<table>` is changed with `pfctl -t ... -T replace` and read per packet by `pfr_pool_get`
  (`pf_lb.c:808-812`).
- No address: `PFRES_MAPFAILED` (`pf_lb.c:618-622,865-866`), packet dropped.
- `to` must be a literal: `pf_get_transaddr_af()` takes the prefix length straight from the pool entry's
  address/mask union, `pf_lb.c:1335-1338`

  ```c
  prefixlen = in6_mask2len((struct in6_addr *)&r->rdr.cur->addr.v.a.mask, NULL);
  inet_nat64(pd->naf, &pd->ndaddr, &ndaddr, &naddr, prefixlen);
  ```
  For a table or dynaddr entry those bytes are the name, not a mask. Likewise, without `to`, the prefix comes from
  `r->nat.cur->addr.v.a.mask` (`pf_lb.c:1354-1359`), so a table `from` should always be paired with an explicit `to` **[L]**.
- Existing states keep the old source address (state keys are fixed at creation); they are not migrated.
  af-to states are not recoverable from mid-stream packets (`pf.conf.5:2108-2118`, quoted in `pf-af-to-roadmap.md` 2.3).

### 4.3 What the two OPNsense paths can express **[V]**

- PR #10638 model field: `af-to-source` is `NetworkField` with `NetMaskAllowed=N` (`gh/opnsense_core_10638.diff:129-131`);
  `NetworkField::isValidInput()` ends in `filter_var($value, FILTER_VALIDATE_IP, ...)`
  (`core/src/opnsense/mvc/app/models/OPNsense/Base/FieldTypes/NetworkField.php:142-198`). Literal IP only: no `(if)`,
  no table, no alias (so not the existing "Dynamic IPv6 Host" alias type either, `Alias.xml:38`).
- A dynamic `(vif)` source needs the CLAT address configured **on** an interface. With tayga it must **not** be a
  local address (it is routed into the tun, `clat-datapaths.md` 7.1). The same datum, opposite placement.

---

## 5. (e) `af-to` through `registerFilterRule()`

### 5.1 Mechanics **[V against the open diff, not merged]**

- `core/src/opnsense/mvc/app/library/OPNsense/Firewall/Plugin.php:260-279`: `registerFilterRule($prio, $conf, $defaults)`
  merges defaults and does `new FilterRule($this->interfaceMapping, $this->gatewayMapping, $conf)`. No model, no
  validation.
- `Rule.php:337-361` (`ruleToText`) walks `$procorder`; for each key it passes `$rule[$tag]` to the handler.
- The PR adds one entry (`gh/opnsense_core_10638.diff:45`): `'af-to' => 'parsePlain, af-to ',`.
  `parsePlain` (`Rule.php:211-217`) returns `$prefix . $value . $suffix . ' '` unchanged.
- The PR's conversion block (`diff:53-60`) only *sets* `$rule['af-to']` when `af-to-source` is non-empty; a key named
  `af-to` supplied directly is rendered as is.
- All restrictions (pass only, "only valid for inbound rules", explicit family, state required, no route-to/reply-to)
  are in `Filter.php::performValidation` (`diff:72-117`), i.e. they bind MVC/API rules only.
- `direction` is rendered by `'parseReplaceSimple,:in|any:'` (`FilterRule.php:44`): `out` passes through.

So after the PR, as written, a plugin hook could emit for example

```
pass out quick on <vif> inet from {any} to {any} keep state ( floating ) label "..." af-to inet6 from (<vif>) to 64:ff9b::/96
```
through `['type'=>'pass','direction'=>'out','interface'=>'<logical>','ipprotocol'=>'inet','statetype'=>'keep',
'state-policy'=>'floating','disablereplyto'=>true,'af-to'=>'inet6 from (<dev>) to 64:ff9b::/96']`. Whether the merged
form keeps the `af-to` key name is unknown. Before the PR the key is ignored: master's `$procorder` has no `af-to`
(`FilterRule.php:41-74`), and the only `af-to` string in core master is the reserved alias name
(`AliasNameField.php:50`).

### 5.2 Without the PR

Plugins can register a pf anchor and load arbitrary rules into it: `Plugin.php:223-252`, placed at
`filter.inc:388,391`. gelatod on OpenBSD works exactly this way ("into which it will add address family translation
rules", anchor `clat`; https://codeberg.org/fobser/gelatod). Both routes mean the plugin owns a pf rule.

### 5.3 Traps on a plugin-registered rule **[V] for the generator, [L] for the kernel effect**

1. Automatic reply-to. `FilterRule.php:169-193`: unless `disablereplyto` is set (or the global option), any rule whose
   direction is not `any` on an interface with an IPv4 gateway gets `reply-to ( <if> <gw> )`, `out` rules included.
   pfctl accepts reply-to with af-to (`parse.y:5371-5376`). In `pf_route()` the reply-to interface is kept when
   `r->naf == AF_INET6` (`pf.c:9197-9200`), so translated replies would be pushed out of the vif instead of the LAN.
2. Automatic outbound NAT. `filter_auto_source_nat()` adds `nat on <if> inet ...` for every mapped interface with a
   gateway whose device is not `ovpn*` (`core/src/etc/inc/filter.lib.inc:176-195`, rules at `filter.inc:208-226`,
   old-style syntax `SNatRule.php:39,50`). On the vif this is exactly the case of 1.3 step 4: drop with
   `PFRES_TRANSLATE`.
3. The interface must exist in the mapping or the rule is disabled ("Interface {$interface} not found",
   `Rule.php:320-324`).
4. A non-quick or late rule loses to core's generic `pass out` rules; registered rules are quick by default
   (`FilterRule.php:233-236`).

---

## 6. What survives, by af-to shape

Three shapes exist in the sources. A is what core's PR and the man page describe. B is the variant considered for the plugin. C is the
only prior art that combines a virtual interface with af-to (OpenBSD).

- **A. inbound on LAN**: `pass in on <lan> inet ... af-to inet6 from <ip> to <pref64>` (`pf.conf.5:3369-3374`, PR #10638).
- **B. outbound on the vif**: `pass out on <vif> inet ... af-to inet6 from ... to <pref64>` (section 1).
- **C. pair + inbound on the far end**: default route into one end of a virtual pair, inbound af-to on the other end.
  gelatod: `ifconfig pair2 rdomain 1`, `ifconfig pair1 patch pair2`, `route add -host -inet default 192.0.0.1 -priority 48`,
  `pass in log quick on pair2 inet af-to inet6 from <v6> to 64:ff9b::/96 rtable 0`; its README: "To make this work with
  localy generated traffic ... gelatod requires two pair(4) interfaces in different routing domains".

### 6.1 Object by object

| Object of the tun/tayga design | A (core form) | B (outbound on vif) | C (pair, FreeBSD analog) |
|---|---|---|---|
| virtual ifnet | unused | needed, but another ifnet type than an unopened tun (2.2, 2.3) | needed: `epair` (both ends) |
| logical interface record / device name | unused | reusable (2.5) | reusable for the near end; far end is a second device |
| vif IPv4 address (192.0.0.x) | unused | needed for firewall-originated traffic (1.5) | needed |
| IPv4 default route, gateway entry, `<dev>_router` file | bypassed: translation happens before the FIB lookup ("overrides the routing table", `pf.conf.5:1372`) | **kept**: the route is what steers packets to the rule (nat64.sh:73-76 comment) | kept |
| gateway peer / monitor target | none | nothing answers the peer address; an echo to it is itself translated and sent to the PLAT **[L]** | same **[L]** |
| automatic outbound NAT44 on the vif | not involved | **must be absent** (1.3 step 4, 5.3 item 2) | evaluated in a different hook (out on near end) than af-to (in on far end); reply path unverified, see 6.3 |
| inet6 pass-in rule on the tun | gone | gone (packets never re-enter on the vif) | gone |
| CLAT /128 routed into the tun | gone | gone; address is a literal, or local on an interface for `(if)` (4.3) | same as B |
| CLAT IPv6 address (datum) | needed, literal in core's model | needed, literal / `(if)` / table (section 4) | needed |
| PLAT prefix (datum) | needed, literal | needed, literal (4.2) | needed, literal |
| MTU: vif MTU as IPv4 path MTU | n/a (LAN MTU, wrong-family error in `pf_route6`) | **kept** for DF packets (1.3 step 3) | near end: ordinary IPv4 MTU check by the stack **[L]** |
| per-interface MSS clamp | on LAN only | on the vif (scrub runs in the same `pf_test`) **[L]** | on the near end **[L]** |
| tayga process, `tayga.conf`, restart on renumber | gone | gone | gone |
| firewall-originated IPv4 | **not covered** (`pf-af-to-roadmap.md` 3) | covered on non-loopback ifnets **[L]** | covered in the OpenBSD original; FreeBSD **[U]** |
| needs shared forwarding off | yes | yes | yes |
| expressible in PR #10638's model | yes | **no** ("only valid for inbound rules", diff:87-91) | yes in form (inbound, literal source) |
| WAN `out` rules / NPTv6 see the translated packet | no (skip_test) | no (no egress pf_test for outbound rules, 1.3 step 7) | no |
| port re-allocation per flow on the shared IPv6 address | no (`pf-af-to-roadmap.md` 2.6) | no (same function) | only if NAT44 on the near end can be kept |

### 6.2 Mixed operation (A for LAN + vif/tayga for the firewall itself)

Already established in `pf-af-to-roadmap.md` 5.3: possible only with two different IPv6 source addresses, otherwise
both paths create IPv6-side states in one tuple space and inserts fail with `PFRES_STATEINS`.

### 6.3 Shape C on FreeBSD is unproven **[U]**

No FreeBSD precedent was found (web search 2026-10-11; FreeBSD forum threads use tayga or ipfw). Facts that bear on it:

- pf honours `rtable` for the translated lookup: `pf.c:6067-6068` `M_SETFIB(pd->m, pd->act.rtableid)`, and
  `pf_route6` looks up in `M_GETFIB(m0)` (`pf.c:9602`).
- The far end needs L2 delivery (static ARP or its own address in another FIB).
- If NAT44 is applied on the near end, the af-to reply is addressed to the near end's own IPv4 address;
  `pf_route()` resolves that to `lo0` and sets `M_SKIP_FIREWALL` (`pf.c:9356-9357`), and `pf_test` then passes such
  mbufs untouched (`pf.c:11031-11033`). The NAT44 state would never see the reply unless the reply is forced back
  through the pair by FIB separation.
- epair forwards through its own task queues (`if_epair.c:251-330`), an extra hop compared with B.

---

## 7. (f) Maintainer statements **[V]**

- PR #10638 (https://github.com/opnsense/core/pull/10638, fetched 2026-10-11): Open, 1 commit `b9f0e06`, no milestone,
  label `feature`, assignee fichtner (since 2026-08-06), review by AdSchellevis pending, last comment 2026-08-01.
  Live `.diff` still touches the same 4 files with the same hunks as `gh/opnsense_core_10638.diff`.
- The only words on direction are the author's: "This adds both NAT64 and NAT46 capabilities as it seems."
  (`gh/opnsense_core_10638.md:23`), backed by `pfctl -s rules` output of one inet -> inet6 rule
  (`md:31,34`). No traffic test.
- fichtner: "This will not work well with shared forwarding. I suggest this to be something for 27.1"; "we simply
  need to test this rigorously and expand the kernel side code" (`md:40,48`). AdSchellevis: "Eventually we could flip
  our defaults as well for shared forwarding ... or rather have it removed at some point" (`md:65`).
- Issue #10570 (https://github.com/opnsense/core/issues/10570): Open, labels `feature`+`roadmap`, no milestone, no
  comments; text speaks of "native NAT64 support" only (`gh/opnsense_core_10570.md:19-27`).
- Roadmap (https://opnsense.org/about/road-map/): 27.1 "Next release - Jan 2027", Firewall: "Add native NAT64
  support". No mention of NAT46, CLAT, 464XLAT, af-to or shared forwarding.
- Forum thread "Native NAT64 support" (https://forum.opnsense.org/index.php?topic=50096.0 and `.15`): no team
  statement on af-to scope. Side datum: user Napsterbater, 2026-02-21, on os-tayga: "now I'm able to max out my
  2 Gbps internet service with NAT64 traffic, again on the same hardware" (hardware and version not given; an
  anecdote, not a measurement).
- Nobody from the project has said anything about outbound af-to, host-originated traffic, dynamic sources, PREF64
  consumption or a virtual interface.

---

## 8. Incidental observations **[V]**

- `ip6_set_fwdtag()` allocates the tag with `sizeof(*dst)` (a `sockaddr_in6`) but writes a `struct ip6_fwdtag`
  (`sockaddr_in6` + `u_short if_index`), `src/sys/netinet6/ip6_output.c:3370-3401`. Outside this topic.
- OPNsense's unconditional TTL/hop-limit decrement in `pf_route()`/`pf_route6()` affects every outbound
  route-to/af-to rule (1.3).

---

## 9. Lab checks that would turn [L] into [V]

1. `pfctl -nf` with `pass out on <dev> inet af-to inet6 from <lit>|(dev)|<tbl> to 64:ff9b::/96` on 26.7.
2. `ifconfig epair create` / `disc0` / `ngctl mkpeer iface dummy inet`: route `default -iface <dev>`, outbound af-to,
   `net.pf.share_forward=0 net.pf.share_forward6=0`: forwarded TCP/UDP/ICMP; `pfctl -ss -vv`.
3. Same with shared forwarding on (expected failure, section 3).
4. Same with `set state-policy if-bound` (expected: no replies, 1.4).
5. Same with core's automatic outbound NAT active on the device (expected drop, 1.3 step 4).
6. Firewall-originated `fetch -4`/`ping` on `epair`/`ng` versus `lo1`/`disc0` (expected `ENETUNREACH` on the latter).
7. DF 1500-byte packet with vif MTU 1472: ICMPv4 need-frag from pf (1.3 step 3); DF=0 oversize UDP.
8. Renumber: change the address behind `(dev)` / the table while flows run; observe states.
9. A never-opened `tun` as route target: `route get` / `netstat -rs` "unreachable" counter (2.2).
10. Throughput of B against tayga on the same hardware.

## 10. Sources

Local: `src/sys/netpfil/pf/{pf.c,pf_lb.c,pf_if.c,pf_ioctl.c}`, `src/sys/net/{pfvar.h,route.h,route/nhop.h,if.c,if.h,
if_tuntap.c,if_loop.c,if_disc.c,if_edsc.c,if_epair.c,if_bridge.c,if_gif.c}`, `src/sys/netinet6/{in6_fib.c,in6.h,
ip6_output.c,ip6_input.c}`, `src/sbin/pfctl/parse.y`, `src/sbin/pfctl/tests/files/pf102[4-7].*`,
`src/share/man/man5/pf.conf.5`, `src/share/man/man4/ng_iface.4`; `core/src/opnsense/mvc/app/library/OPNsense/Firewall/
{FilterRule,Rule,Plugin,SNatRule}.php`, `core/src/etc/inc/{filter.inc,filter.lib.inc,system.inc}`,
`core/src/etc/inc/plugins.inc.d/{core,loopback}.inc`, `core/src/etc/config.xml.sample`; `gh/opnsense_core_10638.{md,diff}`,
`gh/opnsense_core_10570.md`; earlier reports `pf-af-to-roadmap.md`, `clat-datapaths.md`, `opnsense-gateways-nat.md`.

Web (2026-10-11): `WEB-SRC/sys/netinet/{ip_fastfwd.c,ip_output.c,ip_input.c,in_fib.c,in_pcb.c,ip_var.h}`,
`WEB-SRC/sys/netgraph/ng_iface.c`, `WEB-SRC/sys/dev/wg/if_wg.c`, `WEB-SRC/sys/net/pfil.c`, `WEB-SRC/sys/modules/Makefile`,
`WEB-SRC/tests/sys/netpfil/pf/{nat64.sh,nat64.py}`; freebsd-src `main` `tests/sys/netpfil/pf/{nat64.sh,nat64.py,Makefile}`
and `stable/15` `sys/netpfil/pf/pf.c`; commits f6f116cd and 938ae26f (`.patch`);
https://github.com/opnsense/core/pull/10638 (+ `.diff`), https://github.com/opnsense/core/issues/10570,
https://opnsense.org/about/road-map/, https://github.com/opnsense/src/commits/stable/26.7/sys/netpfil/pf/pf.c,
https://raw.githubusercontent.com/opnsense/tools/master/config/26.7/{SMP,src.conf},
https://codeberg.org/fobser/gelatod, https://forum.opnsense.org/index.php?topic=50096.0 and `.15`.
