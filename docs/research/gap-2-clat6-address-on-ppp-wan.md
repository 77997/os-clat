# Gap 2: where the CLAT /128 and tayga's own address can live on a PPPoE WAN

Research date: 2026-10-11. Research only, no design. Nothing here was executed on an OPNsense box.

Question: for each WAN shape (SLAAC /64 on `pppoeN`; IA_NA /128 plus PD; link-local plus PD only), where can
the CLAT /128 (`CLAT6`) and tayga's second address (`CLAT6_SELF`, tayga `ipv6-addr`) live so that return
traffic reaches the box when the only local plumbing is a /128 route into the tun?

Path abbreviations:

- `REFS` = `refs` (local clones, not in this repository)
- `src/` = `REFS/opnsense-src` (opnsense/src `stable/26.7`), `core/` = `REFS/opnsense-core` (master),
  `plugins/` = `REFS/opnsense-plugins`, `tayga/` = `REFS/tayga`, `openwrt/` = `REFS/openwrt`
- `TR-187` = Broadband Forum TR-187 Issue 2 (February 2013), https://www.broadband-forum.org/pdfs/tr-187-2-0-0.pdf.
  The PDF was converted with `pdftotext` and its text read directly (working copy, not in this repository);
  page numbers below are the PDF's own footers.

Confidence tags: **[V]** verified in the primary source (a local file, or the quoted text in a fetched
excerpt), **[L]** likely (inferred from verified facts, or from a fetched excerpt that does not settle it),
**[U]** unverified.

Caveat on web sources: RFC, draft, vendor and GitHub pages were read as fetched excerpts. Quotes from them are short
and line numbers approximate; re-open the URL before quoting anything user-facing. Files in the local clones and
the TR-187 text were read directly.

---

## 1. Bottom line

| Sub-question | Answer | Confidence |
|---|---|---|
| (a) Does a BNG forward an arbitrary IID of the session's SLAAC /64 down the PPP session without ND/NUD? | No IETF document guarantees it (RFC 5072 silent; RFC 4861 treats point-to-point "just like multicast links"). The BNG specification that applies to PPPoE, TR-187, says PPP interfaces do not use ND for link-layer address resolution, requires a unique /64 per session and prefix-granular anti-spoofing. Nokia, Cisco, accel-ppp/Linux and OPNsense's own ndp-proxy-go documentation all describe or imply "whole /64 goes to the session, no probing". No counter-example was found, but none of this proves the ISP's BNG. | likely |
| (b) If NS must be answered, can FreeBSD 15 proxy-NDP do it on the netgraph PPP ifnet? | The kernel has no type restriction: an `LLE_PUB` entry can be created on an `ng_iface` ifnet through a raw routing-socket or netlink message, and `nd6_ns_input` would then send a proxy NA. But `ndp -s ... proxy` cannot create it (it derives the interface from the route and needs an Ethernet-like type and a 6-byte MAC), the kernel answers only NS that are delivered locally (multicast), never unicast NUD probes, never sends DAD probes, and emits a Target Link-Layer option with an empty address. Nobody has demonstrated it. Treat "BNG requires NS for WAN /64 addresses" as not solvable with stock tools. | likely (code reading only) |
| (c) Does claton s6.2.2 (MUST DAD, MUST answer NS) apply to an address from a delegated prefix that is on-link nowhere? | The text has no carve-out and is silent on PD-derived and PPP cases. Both stated rationales (collision containment / devices that want to see a DAD packet; first-hop router NUD) presuppose an address inside a prefix that is on-link on the uplink. For an address in a routed, off-link prefix no node ever performs address resolution, NUD or DAD against it, so the MUSTs can only be met vacuously. They do apply in letter to an address taken from the WAN /64 or from a LAN /64. | verified text, likely interpretation |
| (d) Which /64 of the PD is safe when every prefix ID may be in use or the PD is a single /64? | None needs to be free. A /128 route into the tun is more specific than both ifctl's PD blackhole and any connected /64, so `CLAT6` works in any /64 of the PD, including one that is on-link on a LAN. What remains is address uniqueness inside that /64 (random 64-bit IID, avoid reserved IIDs) and, optionally, defending the address on an Ethernet LAN. An unused /64 is cleaner (no hosts, no antispoof match, blackhole fallback) but cannot be reserved except by being an interface in config. | verified mechanics |

Per WAN shape:

| WAN shape | Candidate home for `CLAT6` / `CLAT6_SELF` | What makes return traffic arrive | Residual risk |
|---|---|---|---|
| SLAAC /64 on `pppoeN` (no PD) | random IID in the WAN /64 | BNG forwards the whole /64 to the session (section 3) | BNG-dependent; if the BNG resolved each IID the CPE cannot answer (section 4). No plugin event when the SLAAC address appears or changes. |
| SLAAC /64 + PD | PD (any /64, see section 6) or WAN /64 | PD: BNG route for the whole delegated prefix, next hop = CPE (TR-187 R-41/R-44) | PD path has no ND dependency at all |
| IA_NA /128 + PD | PD only | same | The IA_NA neighbourhood is unusable: BNG anti-spoofing "MUST match the exact 128-bit IPv6 address" (TR-187 R-37) and only that /128 is routed |
| link-local + PD only | PD only | same | none specific |
| IA_NA only, no PD, no SLAAC prefix | nothing | - | Not servable by a route-only tayga CLAT; needs NAT66 to the IA_NA address or a stateful translator using the WAN address (pf af-to) |
| PD is a single /64 | inside that /64 (on a LAN or unassigned) | BNG route for the PD | shares a /64 with LAN hosts if it is assigned to a LAN |

---

## 2. CPE-side kernel facts (FreeBSD 15 base, `src/`)

### 2.1 An address that is configured locally is never forwarded into the tun

- **[V]** OPNsense defaults `net.inet6.ip6.forwarding=1` and `net.inet6.ip6.redirect=0`
  (`core/src/etc/inc/system.inc:115,119`), so `ip6_input` uses the fast path:
  `if (V_ip6_forwarding != 0 && V_ip6_sendredirects == 0 ...) { if ((m = ip6_tryforward(m)) == NULL) return;`
  (`src/sys/netinet6/ip6_input.c:739-751`).
- **[V]** `ip6_tryforward` refuses anything local and hands it back to the slow path
  (`src/sys/netinet6/ip6_fastfwd.c:109-117`):
  ```c
  if ((m->m_flags & (M_BCAST | M_MCAST)) != 0 ||
      ip6->ip6_nxt == IPPROTO_HOPOPTS ||
      IN6_IS_ADDR_MULTICAST(&ip6->ip6_dst) ||
      IN6_IS_ADDR_LINKLOCAL(&ip6->ip6_dst) ||
      IN6_IS_ADDR_LINKLOCAL(&ip6->ip6_src) ||
      IN6_IS_ADDR_UNSPECIFIED(&ip6->ip6_dst) ||
      IN6_IS_ADDR_UNSPECIFIED(&ip6->ip6_src) ||
      in6_localip_fib(&ip6->ip6_dst, M_GETFIB(m)))
          return (m);
  ```
- **[V]** The slow path delivers locally when the destination is configured on *any* interface, not only the
  receiving one (`ip6_input.c:838-861`): `ia = in6ifa_ifwithaddr(&ip6->ip6_dst, 0 /* XXX */, false); if (ia != NULL) { ... ours = 1; goto hbhcheck; }`.
  `in6ifa_ifwithaddr` walks the global address hash with no interface or flag filter
  (`src/sys/netinet6/in6.c:1659-1678`), so an `anycast`-flagged address, an address on `lo0`, or an address on
  the tun itself are all "ours".
- Consequence **[V]**: "kernel owns the address (does DAD, answers NS)" and "kernel forwards the address into the
  tun" are mutually exclusive on FreeBSD without a firewall redirect. If `CLAT6` is ever configured as a local
  address, the PLAT's replies are consumed by the host stack. The visible symptom differs from a silent return-path
  loss: the box itself answers (TCP RST, ICMPv6 port unreachable) **[L]**.
- **[V]** `ip6_input.c:850-855` (`V_ip6_sav`, "source address validation") only drops packets whose *source* is
  one of our own addresses and whose destination is local; it does not affect forwarded translated packets.

### 2.2 A /128 route into the tun needs no neighbour discovery on the CPE and beats everything else

- **[V]** Forwarding uses a plain FIB lookup and calls the interface output routine directly
  (`ip6_fastfwd.c:62-93,188-199,303-305`): `nh = fib6_lookup(...)`, then
  `error = (*nifp->if_output)(nifp, m, (struct sockaddr *)&dst, NULL);`. For a tun that is `tunoutput`; there is
  no lltable/ND step (ND resolution lives in the L2 output routines such as `ether_output`).
- **[V]** Longest-prefix match: a /128 host route is more specific than
  - the on-link WAN /64 on `pppoeN` (SLAAC, PIO with L=1),
  - a connected LAN /64,
  - ifctl's blackhole for the delegated prefix: `route add -${AF} -blackhole ${CONTENT} ::1` for every stored
    prefix whose length is not 64 (`core/src/opnsense/scripts/interfaces/ifctl.sh:287-292`; removal in
    `flush_routes`, `ifctl.sh:37-55`, deletes only that exact prefix).
  The blackhole is only hit when no more specific route exists: `if (nh->nh_flags & NHF_BLACKHOLE) { ... m_freem(m); return (EHOSTUNREACH); }` (`ip6_fastfwd.c:77-81`).
- **[V]** What happens to `CLAT6` when the /128 route is missing (tayga stopped, route lost):
  - inside a non-/64 PD and outside every on-link /64: blackholed silently (safe);
  - inside a LAN /64: ND on the LAN, then ICMPv6 unreachable;
  - inside the WAN /64: the packet matches the on-link /64 and is sent back out `pppoeN`. `src/sys/netinet6/ip6_forward.c`
    and `ip6_fastfwd.c` contain no point-to-point "same link" check (grep for `IFF_POINTOPOINT` in `ip6_forward.c`
    finds nothing), so the CPE does not implement the RFC 4443 s3.1 rule "the packet MUST NOT be forwarded back
    onto the arrival link" (https://www.rfc-editor.org/rfc/rfc4443.txt). The packet ping-pongs until the hop limit
    expires unless the BNG stops it **[L]**.
  This also applies to `CLAT6_SELF` if it sits in the WAN /64 without its own /128 route.

### 2.3 Which Neighbor Solicitations the kernel answers

`nd6_ns_input` (`src/sys/netinet6/nd6_nbr.c:254-281`) **[V]**:

```c
/*
 * Target address (taddr6) must be either:
 * (1) Valid unicast/anycast address for my receiving interface,
 * (2) Unicast address for which I'm offering proxy service, or
 * (3) "tentative" address on which DAD is being performed.
 */
...
        ifa = (struct ifaddr *)in6ifa_ifpwithaddr(ifp, &taddr6);
/* (2) check. */
proxy = 0;
if (ifa == NULL) {
        if ((ifa = nd6_proxy_fill_sdl(ifp, &taddr6, &proxydl)) != NULL)
                proxy = 1;
}
if (ifa == NULL) {
        /* We've got an NS packet, and we don't have that address assigned for us.  We MUST silently ignore it. */
        goto freeit;
}
```

- **[V]** Case (1) is per receiving interface (`in6ifa_ifpwithaddr(ifp, ...)`): an address configured on another
  interface (loopback, tun) is not answered on `pppoeN`.
- **[V]** Case (2) needs a neighbour-cache entry on that same ifnet with both flags
  (`nd6_nbr.c:372-394`): `ln = nd6_lookup(taddr6, LLE_SF(AF_INET6, 0), ifp); ... if ((ln->la_flags & (LLE_PUB | LLE_VALID)) == (LLE_PUB | LLE_VALID))`,
  and a usable link-local address on the interface (`in6ifa_ifpforlinklocal(ifp, IN6_IFF_NOTREADY|IN6_IFF_ANYCAST)`).
- **[V]** A route-only address (the tayga model) matches none of the three cases: every NS for it is silently
  ignored.
- **[V]** A unicast NS addressed to a non-local target never reaches `nd6_ns_input` at all. With a link-local
  source it is excluded from the fast path (`ip6_fastfwd.c:113`), is not "ours" in `ip6_input`, and is given to
  `ip6_forward`, which drops it on the source scope check because the /128 route points at a different interface
  (`src/sys/netinet6/ip6_forward.c:225-245`: `if (inzone != outzone) { ... icmp6_error(mcopy, ICMP6_DST_UNREACH, ICMP6_DST_UNREACH_BEYONDSCOPE, 0); goto bad; }`).
  Multicast NS (solicited-node) are always passed up: `if (IN6_IS_ADDR_MULTICAST(&ip6->ip6_dst)) { ours = 1; ...}`
  (`ip6_input.c:828-832`).

---

## 3. (a) What a BNG does with the session's SLAAC /64

### 3.1 IETF documents: no guarantee either way

- **[V]** RFC 5072 (IPv6 over PPP) does not discuss NS/NA address resolution, NUD, link-layer address options or
  how the access router routes an advertised prefix. Section 5 only treats DAD: redundant for the link-local
  address; for global addresses possibly redundant if "the prefixes advertised ... are exclusive to the PPP link"
  and the access router does not autoconfigure addresses from them, in which case it is RECOMMENDED that
  DupAddrDetectTransmits "is set to zero by the system management" (https://www.rfc-editor.org/rfc/rfc5072.txt).
- **[V]** RFC 4861 (https://www.rfc-editor.org/rfc/rfc4861.txt): s3.2 "point-to-point - Neighbor Discovery handles
  such links just like multicast links."; s7.2 "Address resolution is performed only on addresses that are
  determined to be on-link"; no exemption for links without link-layer addresses; s7.2.2: after failed resolution
  "The sender MUST return ICMP destination unreachable indications with code 3"; s7.3: NUD "is used for all paths
  between hosts and neighboring nodes", including router-to-host; s7.2.3: an NS is answered only for an address
  assigned to the receiving interface, a proxied address, or a tentative address.
- Reading: an implementation that followed RFC 4861 literally on a PPP interface could send NS for each
  destination IID of an on-link /64 and drop traffic when nobody answers. Nothing in the RFCs forbids that.

### 3.2 Broadband Forum TR-187 Issue 2 (the BNG/RG specification for IPv6 over PPP) **[V]**

- Section 5.2, p.19: "Note that PPP interfaces do not use Neighbor Discovery mechanisms for Link-layer address
  resolution. In PPP there is no concept of link-layer addresses, so all IPv6 on-link datagrams are sent to the
  PPP peer (the BRAS/BNG) for processing. ... Router Solicitations and Router Advertisements are still required on
  PPP links for the purpose of router discovery as are other functions of Neighbor Discovery."
- Section 5.2, p.19: "The PPP link can be unnumbered (i.e. only using link-local addresses) or the BNG can assign
  IPv6 addresses to the remote peer via SLAAC or DHCPv6. The BNG end of the PPP interface will typically only have
  a link-local IPv6 address." and "Whenever the Framed-IPv6-Prefix attribute is returned from RADIUS, the BNG
  includes this prefix as On-Link and Autonomous in the Router Advertisement Prefix Information Option. If this
  attribute is omitted, the BNG will not send a Prefix Information Option."
- Section 5.2, p.18: "Duplicate Address Detection is not required for the link-local address or any address
  derived from the interface identifier on the PPP link."
- Requirements (pp.29-31):
  - R-29: "When SLAAC is used to number the WAN link, the prefix contained in the Framed-IPv6-Prefix attribute MUST
    be sent by the BNG to the RG in router advertisements (RAs.) These prefixes MUST be /64."
  - R-40: "The BNG MUST NOT share a /64 prefix across multiple PPP sessions."
  - R-55: "If the BNG provides a PIO (SLAAC numbered model) in the Router Advertisements, this option MUST contain
    a unique global-scope IPv6 /64 prefix for each PPP session. The BNG MUST set the PIO A-Flag (autonomous) bit to
    true (1)."
  - R-56: "The BNG MUST treat each PPP session as a separate IPv6 link".
  - R-38: "The BNG MUST support IPv6 anti-spoofing for any prefix contained in a Router Advertisement Prefix
    Information Option." (prefix granularity)
  - R-37: "The BNG MUST support IPv6 anti-spoofing on any host or WAN interface address assigned through the DHCPv6
    IA_NA option. The anti-spoofing entry MUST match the exact 128-bit IPv6 address."
  - R-36: "The BNG MUST support IPv6 anti-spoofing on any delegated prefix contained in a DHCPv6 Prefix-Delegation
    message. Anti-spoofing MUST allow any IPv6 address within the prefix."
  - R-41 / R-44: on an IA_PD reply the BNG "MUST add a route (allocated IPv6 prefix contained in the IA_PD, next
    hop contained in the peer-address field)" (relay) or "next hop contained in the destination address of the
    DHCPv6 Reply" (server) "to the relevant BNG routing table".
  - R-54: "When a PPP session is ended, the BNG MUST remove all the routes associated with that session from the
    routing table, for both addresses and delegated prefixes."
  - R-60: "The BNG MUST support all ND functions." (this leaves NUD formally in scope)
- Reading: a TR-187 BNG has a session-exclusive /64, treats the session as its own link, does not resolve
  link-layer addresses on it and validates sources per prefix. That is the "whole /64 is forwarded to the session"
  model, although TR-187 never states the forwarding rule for the PIO prefix as a numbered requirement (it does for
  the delegated prefix, R-41/R-44).

### 3.3 Implementations and vendor documentation

| Implementation | Evidence | Confidence |
|---|---|---|
| Nokia SR OS (7750) | Triple Play guide, "PPPoE host": Framed-IPv6-Prefix "should contain a /64 prefix for the client"; after IPv6CP "the BNG transmits a Router Advertisement to the PPPoE host containing the suggested prefix"; "all addresses within the prefix are forwarded toward the client." https://infocenter.nokia.com/public/7750SR225R1A/topic/com.nokia.Triple_Play_Service_Delivery_Architecture_Guide/pppoe_host-ai9jxkmbaw.html . Advanced Configuration Guide, ESMv6 PPPoE dual stack hosts: route table shows the whole prefix as a subscriber-management route (`2001:DB8:C001:101::/64 Remote Sub Mgmt [group-int-1]`), and "DAD is normally only performed by dual stack IPoE hosts and not by dual stack PPPoE hosts." https://documentation.nokia.com/html/0_add-h-f/93-0267-HTML/7X50_Advanced_Configuration_Guide/ESMv6_PPPoE_dual_stack_hosts.html | V (fetched excerpt) |
| Cisco IOS / IOS XE | "AAA Support for IPv6": Framed-IPv6-Prefix "is used for virtual access only and indicates an IPv6 prefix (and corresponding route) to be configured."; "The NAS will create a corresponding route for the prefix."; for the Cisco VSA "a corresponding route (marked as a per-user static route) is installed". https://www.cisco.com/en/US/docs/ios-xml/ios/sec_usr_aaa/configuration/15-2s/ip6-aaa-support.html | V (fetched excerpt); absence of ND on Virtual-Access is L |
| accel-ppp on Linux | `accel-pppd/ipv6/nd.c`: for each prefix `build_ip6_addr(a, ses->ipv6->intf_id, &addr);` then `ip6addr_add(ses->ifindex, &addr, a->prefix_len);` i.e. the BNG side gets `prefix::<server intf-id>/64` on the ppp device, which creates a connected /64. The module only handles RS/RA (`ICMP6_FILTER_SETPASS(ND_ROUTER_SOLICIT, &filter);`). On-link flag default 1 (`AdvOnLinkFlag`). https://raw.githubusercontent.com/accel-ppp/accel-ppp/master/accel-pppd/ipv6/nd.c . Linux `ndisc_constructor()`: `if (!dev->header_ops) { neigh->nud_state = NUD_NOARP; neigh->ops = &ndisc_direct_ops; neigh->output = neigh_direct_output; }` and `else if (dev->flags&IFF_POINTOPOINT) { neigh->nud_state = NUD_NOARP; ...}` https://raw.githubusercontent.com/torvalds/linux/master/net/ipv6/ndisc.c . So a Linux BNG forwards every IID of the /64 into the session with no NS and no NUD. | V for each file; L that ppp devices take the `!header_ops` branch |
| Juniper Junos (MX) | NDRA pools are /64 ("For NDRA pools, specify the range by setting a prefix length of 64"); for static pp0 "the prefix configured for router advertisement must match the source address specified under family inet6", i.e. the BNG side holds an address inside the /64 on a point-to-point unit. No statement about ND toward the subscriber or about the route type was found. https://www.juniper.net/documentation/us/en/software/junos/subscriber-mgmt-sessions/topics/topic-map/dual-stack-pppoe-access-best-practices.html | V for the quotes; forwarding behaviour U |
| Huawei ME60/NE40E, ZTE, MikroTik, Cisco IOS XR | nothing usable found | U |
| OPNsense `os-ndp-proxy-go` 1.5 (official plugin, used with PPPoE WANs that only get a /64) | Form help: "Ethernet interfaces are fully supported, point-to-point (PPPoE) devices are experimental." and for "Respond to prefixes": "Respond to unknown upstream Neighbor Solicitations ... The option is a no-op on point-to-point upstreams." (`plugins/net/ndp-proxy-go/src/opnsense/mvc/app/controllers/OPNsense/NdpProxy/forms/general.xml:31,37`). OPNsense manual: on PPPoE the upstream ISP router "never probes GUAs via Neighbor Discovery"; NS/NA forwarding is disabled on point-to-point links by design. https://docs.opnsense.org/manual/ndp-proxy-go.html . Upstream README: "a PPPoE uplink does not perform Neighbor Discovery (ND) for downstream addresses." https://raw.githubusercontent.com/monviech/ndp-proxy-go/main/README.md | V (local file) + V (fetched excerpt) |
| OpenWrt `464xlat` | CLAT address = upper 64 bits of the kernel-selected source for the WAN device + random IID, `IPV6_JOIN_ANYCAST` on the WAN device, /128 route in table `prelocal` (`openwrt/package/network/ipv6/464xlat/src/464xlatcfg.c:82-120`, `files/464xlat.sh:46-53`). Linux answers NS for anycast targets (`ipv6_chk_acast_addr` branch in `ndisc_recv_ns`), so OpenWrt answers *multicast* NS for the CLAT address; unicast packets to it (including unicast NUD probes) are routed to the nat46 device by the `prelocal` rule. | V |
| LANCOM LCOS (commercial CPE with CLAT) | CLAT modes: "DHCPv6-PD" for providers "such as DSL or cable": "The subnet ID can be used to control which subnet of the delegated prefix should be used for the CLAT prefix."; "WWAN" (cellular): "The CLAT prefix is formed from the /64 WAN prefix."; "Static". https://www.lancom-systems.de/docs/LCOS/Refmanual/EN/topics/lcos_ipv4_tunnel_464XLAT.html | V (fetched excerpt) |

No report was found of a PPPoE BNG that requires NS answers for individual addresses of the session /64, and no
field report of OpenWrt 464xlat on a PPPoE WAN (searches on the OpenWrt forum and issue tracker returned only
LTE and LAN-AP cases) **[U]**.

### 3.4 Side facts that matter when using the WAN /64

- **[V]** The BNG may itself own one address of the /64: accel-ppp assigns `prefix::<server intf-id>` (above);
  Junos static pp0 needs an inet6 address inside the RA prefix. TR-187 says the BNG end "will typically only have
  a link-local". A CLAT IID must therefore not be a small fixed value; RFC 5072 s5's second condition for skipping
  DAD (router does not autoconfigure from the prefix) is not met on such BNGs.
- **[V]** Reserved IIDs (RFC 5453): `0000:0000:0000:0000` (subnet-router anycast) and
  `FDFF:FFFF:FFFF:FF80`-`FDFF:FFFF:FFFF:FFFF`; "such reserved interface identifiers MUST NOT be used"
  (https://www.rfc-editor.org/rfc/rfc5453.txt).
- **[V]** Source validation on the BNG is per prefix for the PIO /64 (R-38) and for the PD (R-36), but exact
  /128 for IA_NA (R-37). An address "next to" the IA_NA is dropped upstream and is not routed downstream.
- **[V]** The kernel SLAAC address on `pppoeN` is flagged `autoconf` with 64 bits and is visible through
  `interfaces_addresses()` (`core/src/etc/inc/interfaces.inc:3958-3974`: keys `autoconf`, `bits`, `tentative`,
  `deprecated`, `detached`). It is removed at every IPv6CP down (`ppp-linkdown.sh:20` `ifctl -i ${IF} -f`), and the
  whole `pppoeN` ifnet is destroyed (`ppp-linkdown.sh:10` `ngctl shutdown ${IF}:`).

---

## 4. (b) Can FreeBSD 15 answer NS for a routed address on the PPPoE ifnet?

### 4.1 The interface

- **[V]** OPNsense PPPoE devices are netgraph `ng_iface` ifnets: `ifp = if_alloc(IFT_PROPVIRTUAL);`,
  `ifp->if_flags = (IFF_SIMPLEX|IFF_POINTOPOINT|IFF_NOARP|IFF_MULTICAST);`, `ifp->if_addrlen = 0; /* XXX */`,
  `ifp->if_hdrlen = 0;` (https://raw.githubusercontent.com/opnsense/src/stable/26.7/sys/netgraph/ng_iface.c, read
  as a fetched excerpt; `sys/netgraph` is not in the local sparse clone).

### 4.2 Kernel path for a proxy entry (all **[V]** by reading, never run)

1. Every ifnet gets an IPv6 lltable (`ext->lltable = in6_lltattach(ifp);`, `src/sys/netinet6/in6.c:2629`).
2. Routing-socket path: `if (rtm->rtm_flags & RTF_LLDATA) { error = lla_rt_output(rtm, &info); goto flush; }`
   (`src/sys/net/rtsock.c:1135-1138`). `lla_rt_output` (`src/sys/net/if_llatbl.c:965-1065`) takes the interface
   from the gateway `sockaddr_dl` (`ifp = ifnet_byindex(dl->sdl_index);`), allocates the entry, computes the link
   header and sets `if ((rtm->rtm_flags & RTF_ANNOUNCE)) lle->la_flags |= LLE_PUB;`. There is no interface-type
   check.
3. `in6_lltable_alloc` -> `in6_lltable_rtcheck` (`in6.c:2292-2327,2390-2435`) accepts the address when the route
   for it does not point at this interface as long as `ifaof_ifpforaddr(l3addr, ifp)` returns something. On a
   point-to-point interface that function falls back to the first address of the family
   (`src/sys/net/if.c:2036-2079`: `if (ifa_maybe == NULL) ifa_maybe = ifa; ... ifa = ifa_maybe;`), so any inet6
   address on `pppoeN` (the link-local is enough) satisfies it.
4. The link header for a zero-length link-layer address is produced by the default encap handler
   (`src/sys/net/if.c:3954-3977`: `memmove(req->buf, req->lladdr, req->lladdr_len);` with
   `ereq.lladdr_len = ifp->if_addrlen;`, `if_llatbl.c:411-432`), and `lltable_set_entry_addr` sets
   `lle->la_flags |= LLE_VALID;` (`if_llatbl.c:342-350`).
5. `in6_lltable_post_resolved` joins the solicited-node group: `if ((lle->la_flags & LLE_PUB) == LLE_PUB) in6_join_proxy_ndp_mc(llt->llt_ifp, &lle->r_l3addr.addr6);`
   (`in6.c:2558-2564,2713-2731`).
6. `nd6_ns_input` then answers through `nd6_proxy_fill_sdl` (section 2.3).
7. Netlink path (the one `ndp(8)` uses on FreeBSD 15): `rtnl_handle_newneigh` requires an `NDA_LLADDR`
   attribute whose length equals the interface's address length (`int addrlen = if_getaddrlen(attrs.nda_ifp); if (attrs.nda_lladdr->nla_len != sizeof(struct nlattr) + addrlen)` -> "NDA_LLADDR address length (%d) is different from expected (%d)"),
   maps `NTF_PROXY` to `LLE_PUB` and `NTF_STICKY` to `LLE_STATIC`
   (https://raw.githubusercontent.com/opnsense/src/stable/26.7/sys/netlink/route/neigh.c, fetched excerpt **[L]**).
   On `ng_iface` the attribute must therefore be empty.

### 4.3 Why this is not a usable mechanism

- **[L]** `ndp -s nodename etheraddr [temp] [proxy]` cannot target `pppoeN`. `set()` calls
  `set_nl(0, sin, &sdl_m, host)` with interface index 0; `guess_ifindex()` takes the outgoing interface of the FIB
  route for the address and accepts it only if `has_l2()` is true, i.e. `valid_type(link.ifi_type)`, which lists
  only `IFT_ETHER`, `IFT_FDDI`, `IFT_ISO88023/4/5`, `IFT_L2VLAN`, `IFT_BRIDGE`; otherwise it falls back to the
  next hop's address interface. `sdl_alen` is 6 after a successful MAC parse, which the kernel rejects on an
  interface with address length 0. (https://raw.githubusercontent.com/opnsense/src/stable/26.7/usr.sbin/ndp/ndp.c
  and `/ndp_netlink.c`, fetched excerpts.) With the /128 route in place the route lookup resolves to the tun anyway.
  A purpose-built routing-socket or netlink sender would be required.
- **[V]** Only multicast NS are answered; unicast NUD probes for a non-local target are dropped in `ip6_forward`
  (section 2.3). RFC 4861 s7.3.3: after failed probes the entry "SHOULD be deleted" and traffic restarts with
  multicast resolution, so a BNG that does NUD would produce a short loss on every NUD cycle.
- **[V]** No DAD probe is ever sent for a proxied address (the DAD machinery is driven by interface addresses).
- **[V]** The proxy NA carries a Target Link-Layer Address option with no address in it. For a proxy NA the code
  takes the address from the entry when `sdl->sdl_alen == ifp->if_addrlen` (0 == 0), so `mac` is non-NULL and an
  8-byte option is appended (`optlen = sizeof(struct nd_opt_hdr) + ifp->if_addrlen; optlen = (optlen + 7) & ~7;`,
  `nd6_nbr.c:1058-1089`). For the box's own addresses on a PPP interface no option is sent, because
  `nd6_ifptomac()` returns NULL for non-Ethernet types (`nd6_nbr.c:1129-1142`). How a BNG reacts to that option is
  unknown **[U]**.
- **[V]** The entry dies with the ifnet. `pppoeN` is destroyed at every link-down (`ngctl shutdown ${IF}:`), and
  proxy entries are purged whenever addresses are purged (`in6_purge_proxy_ndp(ifp)` in `if_purgeaddrs()`,
  `src/sys/net/if.c:1002-1016`). It would have to be re-created in every PPP session.
- **[V]** The one OPNsense component whose job is to answer upstream NS, `ndp-proxy-go`, deliberately does nothing
  on point-to-point upstreams (section 3.3).
- **[V]** Other inbound checks an NS must pass on `pppoeN`: source must be a neighbour unless
  `net.inet6.icmp6.nd6_onlink_ns_rfc4861` is set (link-local sources always are, `src/sys/netinet6/nd6.c:1263-1280`),
  and a Source Link-Layer option, if present, must have the length `((ifp->if_addrlen + 2 + 7) & ~7)` = 8 bytes
  (`nd6_nbr.c:193-211,288-294`).

Answer: possible inside the kernel on paper, not reachable with shipped tools, incomplete against NUD, and
untested. If a BNG really needs NS answers for WAN /64 addresses, FreeBSD 15 proxy-NDP is not a dependable fix.

---

## 5. (c) Scope of draft-ietf-v6ops-claton-16 section 6.2.2

Source: https://www.ietf.org/archive/id/draft-ietf-v6ops-claton-16.txt (fetched excerpt, close paraphrase).

- **[V]** s6.2.1: a node extending IPv4 downstream MUST either use a dedicated RFC 6052 prefix (for example via
  DHCPv6-PD) with stateless translation of downstream addresses, or NAT44 to one IPv4 address translated to "one
  dedicated IPv6 address". With a single IPv4 address it "SHOULD NOT obtain a dedicated prefix". Without a
  dedicated prefix it MUST obtain a dedicated IPv6 address used only for CLAT. If the address comes from SLAAC the
  IID SHOULD make it checksum-neutral; a new random address SHOULD be generated when the network attachment
  changes.
- **[V]** s6.2.2: the node MUST treat CLAT addresses like any other address per RFC 4861/4862; "MUST perform DAD
  for each dedicated CLAT address"; MUST handle unicast and multicast NS for CLAT addresses the same way as for
  non-CLAT addresses; SHOULD send gratuitous NAs if RFC 9131 is supported; MUST register via RFC 9686 where
  enabled.
- **[V]** Stated rationales: DAD limits connectivity loss on a collision and "some network devices require a DAD
  packet from the client before granting access"; NS handling because otherwise the first-hop router's NUD
  (RFC 4861 s7.3.3) deletes the cache entry and traffic is dropped while resolution restarts.
- **[V]** The section says nothing about addresses from a delegated prefix that is assigned to no link, nothing
  about point-to-point links or PPP, and has no exemption clause.

Interpretation by case **[L]**:

| Where `CLAT6` comes from | Letter of s6.2.2 | Do the rationales arise? |
|---|---|---|
| PD /64 that is on-link nowhere | applies (no carve-out) | No. RFC 4862 s5.4 scopes DAD to "all unicast addresses prior to assigning them to an interface" and describes it as verifying "the uniqueness of the addresses on a link" (https://www.rfc-editor.org/rfc/rfc4862.txt). The address is never assigned to an interface and its prefix has no link. The BNG forwards the PD to the route's next hop (the CPE, TR-187 R-41/R-44); under RFC 4861 next-hop determination it never resolves or probes `CLAT6` itself. The MUSTs can only be satisfied vacuously, exactly as for any routed address behind a router. |
| WAN SLAAC /64 on PPP | applies | Formally yes (on-link prefix on the uplink). In practice RFC 5072 s5 and TR-187 s5.2 regard DAD on PPP as unnecessary when the prefix is session-exclusive, and RFC 4862 s5.4 lists `DupAddrDetectTransmits` = 0 as an exception. NS/NUD only matters if the BNG probes (section 3). A route-only tayga address cannot do DAD or answer NS (sections 2.3, 4). |
| LAN /64 shared with hosts (single-/64 PD, or all IDs used) | applies | Partly. The uplink never probes it (routed PD). A LAN host could in theory configure the same address; nothing defends it unless a proxy-NDP entry exists on the LAN. Collision probability with a random 64-bit IID is negligible. |

Other standards context already in `standards-requirements.md`: RFC 6877 s6.3 and RFC 8683 s5 prefer a dedicated
/64 from PD; RFC 7084 WAA-7 (no WAN GUA -> use an address from the delegated prefix on an internal interface) and
WPD-5 (null-route the delegated prefix). OPNsense implements WPD-5 with the ifctl blackhole.

---

## 6. (d) The delegated prefix on OPNsense

### 6.1 Upstream side

- **[V]** TR-187 R-41/R-44: the BNG installs a route for the whole delegated prefix with the CPE as next hop;
  R-36: anti-spoofing "MUST allow any IPv6 address within the prefix"; R-54: routes vanish with the session.
  Reachability of any PD address at the CPE therefore does not depend on ND toward that address.

### 6.2 CPE side: how the PD is consumed (all **[V]**)

- Stored in `/tmp/<wandev>_prefixv6`, read with `ifctl -6p -i <wandev>` or `Autoconf::getPrefix()`; several
  prefixes are possible (one per `id-assoc pd`, `core/src/etc/inc/interfaces.inc:3019-3027`). The file can be
  stale after a PPP drop (see `opnsense-pppoe-ipv6only.md` 2.7). The *actual* length is in the file; the config
  value `dhcp6-ia-pd-len` (= 64 minus the requested length) is only a hint/assumption.
- Null route for every stored prefix that is not a /64 (`ifctl.sh:287-292`). A /64 PD is **not** blackholed
  (`"${CONTENT##*/}" != "64"`); if it is also not assigned to an interface, unassigned addresses in it follow the
  default route back to the ISP.
- Prefix-ID consumers written into `dhcp6c.conf` (`interfaces.inc:2936-2964`):
  - the WAN itself when "Optional prefix ID" is set: `prefix-interface {$wanif} { sla-id {$wancfg['dhcp6-prefix-id']}; sla-len {$wancfg['dhcp6-ia-pd-len']}; }`;
  - every enabled interface with `ipaddrv6` in `['idassoc6', 'track6']` and `track6-interface` = the WAN
    (`link_interface_to_track6()`, `interfaces.inc:3586-3608`): `sla-id {$lancfg['track6-prefix-id']}`.
- Further consumers that are *not* `prefix-interface` lines: `track6_prefix_range` ("Reserved prefix range" for
  downstream delegation; a block of IDs starting at the interface's own ID, `core/src/www/interfaces.php:53-58,71-82`,
  `Idassoc.php:69-87`), and anything in an advanced/override dhcp6c configuration
  (`interfaces_has_prefix_only()` shows the relevant keys: `adv_dhcp6_config_file_override`,
  `adv_dhcp6_config_advanced`, `interfaces.inc:4022-4041`), plus static addresses or VIPs an admin carved from the
  PD by hand.
- Uniqueness of IDs is only validated when an interface is saved in the legacy GUI page
  (`interfaces.php:39-92`: "You specified an IPv6 prefix ID that is already in use.", "... out of range.").
  `dhcp6c` itself validates nothing: `pif->sla_id = (uint32_t)cfl->num;` with no range or duplicate check
  (https://raw.githubusercontent.com/opnsense/dhcp6c/master/config.c, fetched excerpt **[L]**).
- `dhcp6c` address computation (https://raw.githubusercontent.com/opnsense/dhcp6c/master/prefixconf.c, fetched excerpt
  **[L]**): `pip->plen = prefix->plen + pif->sla_len;` and, when that would exceed 64 bits of prefix,
  `pif->sla_len = 128 - pif->ifid_len - prefix->plen;`. With a /64 delegation every prefix-interface silently
  gets the same /64 regardless of its ID. `dhcp6c` installs no route for the delegated prefix.
- `Idassoc::prefix()` (`core/src/opnsense/mvc/app/library/OPNsense/Interface/Idassoc.php:125-182`) reports
  `prefix_on_link`, `prefix_allocated`, `prefix_associated`, `prefix_valid` for `idassoc6` interfaces only (not for
  legacy `track6`, not for the WAN's own prefix ID), and returns a fake `dead:beef:N::/48` when no prefix exists.
- There is no registry through which a non-interface consumer could reserve a prefix ID. The only thing core
  treats as an allocation is an assigned interface carrying `track6-interface` + `track6-prefix-id`.
  Related fact **[L]**: the OPNsense dhcp6c fork does not fail on an interface without a 6-byte link-layer address;
  it logs "failed to get default IF ID for %s, using random ID" and continues (`config.c`, fetched excerpt). Whether a
  tun can sensibly be a tracking interface in core (radvd/DHCPv6 side effects of `interface_track6_configure()`)
  was not examined **[U]**.
- Core precedent for "WAN has no GUA": in prefix-only mode `interfaces_routed_address6()` widens the search to
  tracking interfaces (`interfaces.inc:4070-4077`: "extend the search scope for a non-NA mode to tracking
  interfaces"), i.e. core itself borrows a LAN GUA as the WAN's routed address. OpenWrt's 464xlat ends up in the
  same place by accident of Linux source selection (`openwrt-464xlat.md` 3.1: CLAT address in the LAN /64,
  anycast-joined on the WAN device) **[L]**.

### 6.3 What "safe" reduces to

Because of 2.2, no /64 has to be free. Facts per placement:

| Placement of `CLAT6` in the PD | Routing | Collision exposure | pf antispoof | If the /128 route is missing |
|---|---|---|---|---|
| a /64 that is on-link nowhere | /128 over blackhole | none (no hosts, no pools) | no rule matches (antispoof is generated per assigned interface from its networks, `core/src/etc/inc/filter.inc:575-578`; `src/sbin/pfctl/parse.y:1570-1658`) | silent blackhole |
| the /64 placed on the WAN device by `dhcp6-prefix-id` | /128 over connected /64 on `pppoeN` | only the WAN's own address lives there | `antispoof for pppoeN` matches packets from that /64 entering on the tun (non-quick block, overridden by a later pass) | ping-pong on the PPP link (2.2) |
| a LAN /64 | /128 over connected /64 on the LAN | LAN hosts (SLAAC, DHCPv6 pools, static) | `antispoof for <lan>` matches likewise | ND on the LAN, then unreachable |
| PD is a /64 not assigned anywhere | /128, no blackhole underneath | none | none | follows the default route back to the ISP |

- Whether a given /64 is on-link anywhere can be read from the FIB instead of from config: an unused /64 of a
  non-/64 PD resolves to the blackhole route installed by ifctl, an in-use one to an interface route
  (`route -n get -inet6 <addr>`). This also catches advanced dhcp6c configs and hand-made static addressing, but
  not ID ranges reserved for downstream delegation that currently have no lease **[L]**.
- Defending an address inside an Ethernet LAN /64 is possible with stock tools in principle: `ndp -s <addr> <mac>
  proxy` works on Ethernet-type interfaces (`valid_type`), and `nd6_ns_input` answers DAD probes for proxied
  targets. Ordering matters because `ndp` picks the interface from the route for the address, which would be the
  tun once the /128 route exists (section 4.3) **[L]**, not tested.
- Comparators: LANCOM lets the admin pick the subnet ID of the delegated prefix for the CLAT prefix (explicit,
  no auto-detection); RFC 8683 s5 says a CE "SHOULD internally reserve one /64"; OpenWrt uses whatever /64 the
  kernel's source selection yields plus a random IID.

---

## 7. tayga's second address (`ipv6-addr`)

All **[V]** from `tayga/`:

- Purpose (`docs/clat/README.md:7`): "we require two addresses - one is used along with `tayga`'s `map` directive
  to map IPv4 user traffic to IPv6, the other is used by `tayga` as its own address as the source of ICMPv6 error
  messages. For simplicity, all examples use two addresses in a `/127` pair".
- Uses in code: destination of pings to tayga (`nat64.c:1297-1303`); source of ICMPv6 errors generated by tayga,
  `host_send_icmp6(0, &gcfg.local_addr6, &orig->ip6->src, ...)` (`nat64.c:808-827`), raised for unmappable
  destination (`nat64.c:958-962`), unmappable source, type 1 code 5 (`971-974`), Packet Too Big against the tun MTU
  (`983-985`), routing header (`1102-1105`), hop limit 1 (`1305-1307`); and "fake source" for ICMPv4 errors whose
  IPv4 source has no mapping (`nat64.c:705-709`).
- Constraints: must not be link-local, multicast or start with a zero byte (`addrmap.c:65-85`,
  `conffile.c:157-161`); must not be inside 64:ff9b::/96 in strict mode (`conffile.c:895-904`); must not collide
  with a `map` entry or the `prefix` (`conffile.c:906-921`); if omitted it is derived from `ipv4-addr` + `prefix`
  (`conffile.c:922-943`). A ULA would be accepted.
- Consequences **[L]**: user traffic never uses `CLAT6_SELF`; return reachability of it is not needed for the
  CLAT to work. It only needs to be (i) different from `CLAT6`, (ii) a source the BNG's anti-spoofing accepts if
  tayga's ICMPv6 errors should survive (same /64 as `CLAT6` satisfies R-36/R-38), (iii) not left dangling in an
  on-link /64 without a route into the tun (2.2). The upstream recipe covers both with one route:
  `ip route add <clat6>/127 dev clat` (`docs/clat/clat-route.sh`, see `clat-datapaths.md` 2.3) and FreeBSD issue
  #83 used `route -6n add -net <...>::64/127 -iface clat0`.
- Neither address may be configured on a kernel interface (2.1). Note that os-tayga's "IPv6 NAT64 interface
  address" on the tun is a third, kernel-side address, not tayga's `ipv6-addr`
  (`plugins/net/tayga/src/etc/rc.d/opnsense-tayga:22-34`).

---

## 8. Reconciling the earlier reports

| Earlier statement | Status after this research |
|---|---|
| community-prior-art: "CLAT address inside the on-link WAN /64 needs NDP proxying or NAT66; prefer PD" | True for multi-access uplinks. Its evidence (tayga issues #83/#98, FreeBSD forum) is Ethernet/virtio hosts where the upstream router does address resolution. Not evidence about PPP. PD remains the placement with zero ND dependency. |
| clat-datapaths: "on a PPP link any address inside the /64 the ISP routes down the session works without NDP" | Supported by TR-187 s5.2, Nokia, Cisco, accel-ppp/Linux and OPNsense's ndp-proxy-go documentation; not guaranteed by RFC 5072/4861 and not verifiable for an unnamed BNG. Should be read as "likely, BNG-dependent". |
| standards: "DAD is still a MUST; MUST answer NS" | Correct as text. Cannot be implemented for a route-only address on FreeBSD (2.3, 4); vacuous for an off-link PD address (5); on PPP both RFC 5072 and TR-187 treat DAD as unnecessary for a session-exclusive prefix. |
| clat-datapaths: "never make the address local" | Confirmed in code (2.1). It is the reason DAD/NS by the kernel and forwarding into the tun exclude each other. |

Evidence strength of each placement for the return path:

1. PD, /64 on-link nowhere: guaranteed by PD semantics (R-36, R-41/R-44) and by local longest-prefix match. No ND
   anywhere. Events exist when the PD changes (`newwanip` with a reason, `opnsense-pppoe-ipv6only.md` 2.6).
2. PD, inside an in-use /64 (WAN prefix-id /64, then a LAN /64): same upstream guarantee; shares the /64.
3. WAN SLAAC /64: BNG-dependent (section 3); no IETF guarantee; no plugin event on SLAAC changes
   (`opnsense-pppoe-ipv6only.md` 2.6); possible BNG-owned address in the /64; ping-pong when the route is missing.
4. Next to an IA_NA /128: never (R-37).

---

## 9. Symptoms that distinguish the failure causes (derived, **[L]**)

| Cause | Outbound translated packet | What comes back |
|---|---|---|
| BNG does not deliver `CLAT6` (WAN /64 IID not forwarded, or stale prefix) | leaves `pppoeN`, PLAT answers | nothing arrives on `pppoeN` for `CLAT6`; looks like a PLAT fault |
| BNG anti-spoofing rejects the source (address outside the PIO /64 and PD, or near an IA_NA) | leaves `pppoeN`, dropped at the BNG | nothing; PLAT never sees it |
| `CLAT6` configured as a local address | leaves and is answered | reply arrives on `pppoeN` and the box itself answers it (RST / ICMPv6), tayga sees nothing |
| /128 route missing | leaves and is answered | reply is blackholed (PD), bounced on the PPP link (WAN /64) or sent to ND (LAN /64) |
| PLAT fault / wrong pref64 | leaves | nothing, also for native tests below |

Differential checks that follow from the facts: a native IPv6 ping from the box to `pref64::<public IPv4>` tests
the PLAT without touching `CLAT6`; a packet capture on `pppoeN` for destination `CLAT6` separates "BNG never
delivered" from "delivered but lost locally"; a ping from an outside IPv6 host to `CLAT6_SELF` (answered by tayga
when it is routed into the tun) tests exactly the BNG-to-tun return path without involving the PLAT.

---

## 10. Open questions

For the ISP:

1. Which shape(s) does the BNG provide on the IPv6CP-only session: RA PIO /64 (A=1), IA_NA, IA_PD, or
   combinations? What PD length, and is it stable across sessions?
2. BNG vendor and software. Does it forward the whole RA /64 to the session without neighbour resolution or NUD
   (expected for TR-187 conformant BNGs)? Does it own an address inside that /64?
3. Anti-spoofing granularity actually configured for the PIO /64, IA_NA and PD.
4. Can a PD always be provided to OPNsense customers? That removes the only
   BNG-dependent case.

To verify on an OPNsense 26.7 box:

5. `route add -inet6 -host <addr> -interface <tun>` for an address inside the on-link WAN /64 and inside a LAN /64
   really takes precedence, and coexists with the ifctl blackhole across prefix updates (`ifctl -6pu` deletes and
   re-adds only the PD route).
6. On a real PPPoE session with `CLAT6` in the WAN /64: capture on `pppoeN` to see whether the BNG ever sends NS
   for it, and whether traffic keeps flowing for longer than the BNG's NUD timers.
7. Whether stray packets to an unrouted address of the WAN /64 really loop between CPE and BNG.
8. Whether an `LLE_PUB` entry can be created on `pppoeN` at all (custom routing-socket message), what the proxy NA
   looks like on the wire, and whether `ndp -s <addr> <mac> proxy` works for an address in a LAN /64 before and
   after the /128 route exists.
9. Behaviour of a tun as an `idassoc6`/`track6` interface (dhcp6c random IID fallback, side effects in core).

Not established from sources:

10. Juniper, Huawei, ZTE, MikroTik, Cisco IOS XR behaviour for IIDs of the PPPoE SLAAC /64.
11. Any field report of OpenWrt 464xlat on a PPPoE WAN (with or without a WAN GUA).
12. How a BNG treats a proxy NA with an empty Target Link-Layer option on PPP.
13. Final RFC text of claton (still in the RFC Editor queue); AUTH48 could add or change scope language for s6.2.2.

---

## 11. Sources

Local clones (read directly): `src/sys/netinet6/{ip6_input.c,ip6_fastfwd.c,ip6_forward.c,nd6_nbr.c,nd6.c,in6.c}`,
`src/sys/net/{if.c,if_llatbl.c,rtsock.c}`, `src/sbin/pfctl/parse.y`;
`core/src/etc/inc/{interfaces.inc,filter.inc,system.inc}`, `core/src/www/interfaces.php`,
`core/src/opnsense/scripts/interfaces/{ifctl.sh,ppp-linkdown.sh,ppp-ipv6.php}`,
`core/src/opnsense/mvc/app/library/OPNsense/Interface/Idassoc.php`;
`plugins/net/ndp-proxy-go/{pkg-descr,src/opnsense/mvc/app/controllers/OPNsense/NdpProxy/forms/general.xml,src/opnsense/service/templates/OPNsense/NdpProxy/ndp_proxy_go}`;
`tayga/{conffile.c,addrmap.c,nat64.c,docs/clat/README.md}`;
`openwrt/package/network/ipv6/464xlat/{src/464xlatcfg.c,files/464xlat.sh}`.
Earlier reports in this directory: `clat-datapaths.md`, `standards-requirements.md`, `community-prior-art.md`,
`opnsense-pppoe-ipv6only.md`, `openwrt-464xlat.md`.

Web:
- TR-187 Issue 2: https://www.broadband-forum.org/pdfs/tr-187-2-0-0.pdf (read as text)
- https://www.ietf.org/archive/id/draft-ietf-v6ops-claton-16.txt
- https://www.rfc-editor.org/rfc/rfc5072.txt , rfc4861.txt , rfc4862.txt , rfc4443.txt , rfc5453.txt
- https://infocenter.nokia.com/public/7750SR225R1A/topic/com.nokia.Triple_Play_Service_Delivery_Architecture_Guide/pppoe_host-ai9jxkmbaw.html
- https://documentation.nokia.com/html/0_add-h-f/93-0267-HTML/7X50_Advanced_Configuration_Guide/ESMv6_PPPoE_dual_stack_hosts.html
- https://www.cisco.com/en/US/docs/ios-xml/ios/sec_usr_aaa/configuration/15-2s/ip6-aaa-support.html
- https://www.juniper.net/documentation/us/en/software/junos/subscriber-mgmt-sessions/topics/topic-map/dual-stack-pppoe-access-best-practices.html
- https://raw.githubusercontent.com/accel-ppp/accel-ppp/master/accel-pppd/ipv6/nd.c , `/accel-pppd/ifcfg.c` , `/accel-pppd/accel-ppp.conf.5`
- https://raw.githubusercontent.com/torvalds/linux/master/net/ipv6/ndisc.c
- https://docs.opnsense.org/manual/ndp-proxy-go.html , https://raw.githubusercontent.com/monviech/ndp-proxy-go/main/README.md
- https://www.lancom-systems.de/docs/LCOS/Refmanual/EN/topics/lcos_ipv4_tunnel_464XLAT.html
- https://raw.githubusercontent.com/opnsense/src/stable/26.7/sys/netgraph/ng_iface.c , `/usr.sbin/ndp/ndp.c` , `/usr.sbin/ndp/ndp_netlink.c` , `/sys/netlink/route/neigh.c`
- https://raw.githubusercontent.com/opnsense/dhcp6c/master/config.c , `/prefixconf.c`
