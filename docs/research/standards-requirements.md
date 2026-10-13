# Standards requirements for a CE-router CLAT (464XLAT) - auditable checklist

Research date: 2026-10-10. Scope: normative requirements and recommendations that apply to a
customer-edge router acting as CLAT behind an IPv6-only (IPv6CP-only) PPPoE WAN, plus what proven CLAT
implementations do for address selection and MTU. This is a fact base, not a design.

## 0. Method and caveats

- RFCs and drafts were read from rfc-editor.org / ietf.org / datatracker.ietf.org as fetched excerpts, so
  requirement wording below is a **close paraphrase with the RFC 2119
  keyword preserved**; the section number is always given so the exact sentence can be audited in the
  source. Where a document uses lowercase "should/must" (RFC 6877) this is flagged.
- Code facts come from the local read-only clones under `refs/` (not in this repository) or from
  upstream source URLs.
- Confidence labels: **verified** = primary source read; **likely** = strong inference;
  **unverified** = could not confirm.

## 1. Document inventory and status (as of 2026-10-10)

| Document | Title (short) | Status | Relevance |
|---|---|---|---|
| RFC 6877 | 464XLAT architecture | Informational; no RFC 2119 section, all keywords lowercase (verified) | Defines CLAT/PLAT, prefix handling, DNS proxy |
| RFC 8585 | IPv6 CE requirements for IPv4aaS | Informational, but written with RFC 2119 keywords; extends RFC 7084 (verified) | The CE-router requirement set (464XLAT-1..6, TRANS, CONFIG, L-1) |
| draft-ietf-v6ops-claton-16 | CLAT node behaviour and recommendations | Proposed Standard, IESG-approved 2026-03-06, in RFC Editor queue, no RFC number yet; last datatracker event 2026-08-13 (verified) | Updates RFC 6877 and RFC 8585; address, DAD, MTU, enable/disable rules |
| RFC 7915 | IP/ICMP translation algorithm (SIIT) | Standards Track, obsoletes RFC 6145 (verified) | Translator behaviour, MTU, fragmentation, ICMP, UDP checksum |
| RFC 6052 | IPv4-embedded IPv6 addresses | Standards Track (verified text; status likely) | Prefix lengths, WKP restrictions, checksum neutrality |
| RFC 7050 | NAT64 prefix discovery via ipv4only.arpa | Standards Track (text verified) | DNS-based Pref64 discovery |
| RFC 8880 | Special-use name ipv4only.arpa | Standards Track, updates RFC 7050 (verified) | Which resolver to query, forwarder behaviour, no DNSSEC |
| RFC 8781 | PREF64 RA option (type 38) | Standards Track (verified text) | RA-based Pref64 discovery, precedence |
| RFC 7335 | IPv4 Service Continuity Prefix 192.0.0.0/29 | Standards Track, updates RFC 6333 (verified) | CLAT IPv4 address |
| RFC 8683 | NAT64/464XLAT deployment guidelines | Informational, uses RFC 2119 keywords in a few places (verified) | DNS64 vs no DNS64, dedicated /64, DNS proxy |
| RFC 4638 | PPPoE MTU/MRU > 1492 | Informational, with IESG caution note (verified) | PPPoE 1500 MTU negotiation |
| RFC 5072 | IPv6 over PPP | Standards Track (text verified) | DAD/IID on PPP links, minimum MTU |
| RFC 7084 | Basic IPv6 CE requirements | Informational (text verified) | Baseline that RFC 8585 requires (PPP, PD, unnumbered WAN) |
| RFC 8925 | DHCPv4 option 108 (IPv6-only preferred) | Standards Track (text verified) | LAN-side option 108 referenced by claton |
| draft-ietf-v6ops-464xlat-optimization-06 | 464XLAT/MAP-T optimization | Internet-Draft, last updated 2026-07-06; datatracker shows contradictory state ("Active" and "Dead WG Document") (verified as shown) | Optional optimisation; not a requirement source |

Sources: https://datatracker.ietf.org/doc/draft-ietf-v6ops-claton/ and `/history/`;
https://datatracker.ietf.org/doc/draft-ietf-v6ops-464xlat-optimization/ ; RFC text at
https://www.rfc-editor.org/rfc/rfcNNNN.txt.

claton timeline (datatracker history): -00 2024-07-09; WGLC 2025-07-30; IETF Last Call 2025-11-07;
IESG evaluation 2025-11-25; -16 2026-03-05; approved 2026-03-06; RFC Editor queue 2026-03-09;
RPC status "Awaiting First editor" 2026-08-13. Authors: Colitti, Linkova, Jensen. Header line: Updates
6877, 8585 (if approved).

## 2. Findings per document

### 2.1 RFC 6877 (464XLAT) - Informational, lowercase keywords

URL: https://www.rfc-editor.org/rfc/rfc6877.txt

- Section 2 (terminology): the CLAT does stateless translation (RFC 6145, now RFC 7915), should route and
  forward, and is expected to provide gateway functions such as DHCP server and DNS proxy. It does not
  provide IPv4-only-node to IPv6-only-node communication.
- Section 6.3 (IPv6 prefix handling):
  - The CLAT must know its own IPv6 prefixes. It should acquire a /64 for the uplink, a /64 for the
    downlinks, and a **dedicated /64** for sending/receiving statelessly translated packets.
  - When a dedicated /64 is not available from DHCPv6-PD, the CLAT **may perform NAT44** for all LAN IPv4
    packets so they appear from a single IPv4 address, which is then statelessly translated to **one
    interface IPv6 address claimed by the CLAT via NDP** and defended with DAD.
  - The CLAT must discover the PLAT-side translation prefix; it may use the discovery heuristic (now
    RFC 7050). A future mechanism (then "a DHCPv6 option", in practice RFC 8781) is anticipated.
- Section 6.4 (DNS proxy): the CLAT should implement an RFC 5625 DNS proxy, should announce itself as DNS
  server (DHCP or other means), should proxy for IPv4 and IPv6 LAN clients; DNS queries that clients send
  elsewhere must still be allowed and are translated like any other traffic.
- Section 6.5: a router with CLAT should also offer the usual router services (DHCP with RFC 1918
  addresses, DHCPv6, RA/NDP, DNS).
- Section 7.2: translation is stateless end-to-end at the CLAT only when a dedicated /64 exists;
  otherwise the CLAT is stateful (NAT44) plus stateless.
- Section 8: CLAT security considerations are those of the stateless translator (RFC 6145 section 7);
  the CLAT may comply with RFC 6092 (simple security in CPE).
- Not covered at all: MTU, fragmentation, TCP MSS, PREF64 RA option.

### 2.2 RFC 8585 (IPv6 CE router IPv4aaS requirements)

URL: https://www.rfc-editor.org/rfc/rfc8585.txt. Informational, but uses MUST/SHOULD. Requires compliance
with RFC 7084 (section 3).

- L-1 (section 3.1): MUST implement a DNS proxy per RFC 5625.
- TRANS-1 (section 3.2): MUST support the DHCPv6 S46 priority option (RFC 8026).
- TRANS-2: MUST have a GUI and either a CLI or an API to manually enable/disable each supported
  transition mechanism.
- TRANS-3: with more than one LAN subnet, MUST allow appropriate subnetting/address configuration across
  interfaces.
- CONFIG-1..3: mechanisms stay disabled while options are requested; OPTION_S46_PRIORITY is evaluated per
  RFC 8026 section 1.4; if nothing matches, everything stays disabled **unless a NAT64 prefix has been
  configured, in which case 464XLAT MUST be enabled**.
- Note after CONFIG-3: 464XLAT has no DHCPv6 option and cannot appear in OPTION_S46_PRIORITY; an operator
  offering 464XLAT must not send that option for other mechanisms to the same customers.
- Section 3.2.1 intro: a CE intended for the retail market MUST support CLAT; if supported it MUST be
  implemented per RFC 6877.
- 464XLAT-1: MUST perform IPv4 NAT on CLAT-translated traffic **unless a dedicated /64 was acquired**
  (DHCPv6-PD or other means).
- 464XLAT-2: SHOULD support IGD-PCP IWF (RFC 6970).
- 464XLAT-3: if PCP is implemented, MUST implement RFC 7291; MAY probe default gateway/NAT64 as PCP
  server; MUST use plain IPv6 mode for PCP requests.
- 464XLAT-4: MUST implement RFC 7050 to discover the PLAT prefix(es).
- 464XLAT-5: if PCP is implemented, MUST follow RFC 7225.
- 464XLAT-6: when several discovery methods are offered, priority MUST be RFC 7225 then RFC 7050.
- Closing text of 3.2.1: RFC 7050 only works if the provider runs DNS64; a provider that does not
  use or trust DNS64 may use RFC 7225 instead.
- Section 5 (UPnP): if WANIPConnection:2 cannot be served through the IPv4aaS interface, port-mapping
  requests must be rejected with error 729.
- Section 8: DHCP packets MUST NOT be forwarded between LAN and WAN.
- The words "MTU" and "fragment" do not occur in RFC 8585 (verified by targeted query).

RFC 7084 baseline items that matter for PPPoE (https://www.rfc-editor.org/rfc/rfc7084.txt):
WLL-2 (PPP WAN MUST support IPv6 over PPP), WLL-3 (NCPs MUST be independent, i.e. IPv6CP without IPCP is
a legitimate state), W-4/WPD-1 (PD requesting router), WAA-7 (if no global WAN address from SLAAC or
DHCPv6, MUST create a global address from the delegated prefix on an internal virtual interface),
WAA-9 (weak host model), WPD-5 (packets to unassigned parts of the delegated prefix must be dropped;
null route), L-2 (a separate /64 per LAN interface). RFC 7084 does not mention MTU either.

### 2.3 draft-ietf-v6ops-claton-16 (approved, RFC Editor queue)

URL: https://www.ietf.org/archive/id/draft-ietf-v6ops-claton-16.txt

Section 4 (enabling):
- SHOULD NOT enable CLAT on an interface with native IPv4 unless explicitly configured.
- An IPv6-only node SHOULD enable CLAT as soon as it receives PREF64.
- A node MAY enable CLAT on a subset of interfaces; then it MUST run an independent instance per
  interface, and each instance MUST install its own IPv4 default route on that interface.
- Without PREF64 the node MAY use other mechanisms such as RFC 7050; then it MUST follow RFC 8880, and
  the ipv4only.arpa AAAA queries MUST go to the resolvers provided through that specific interface, not
  to manually configured or other resolvers.
- Unless configured otherwise, the node MUST enable CLAT if it has no non-link-local IPv4 address by the
  time it discovers the NAT64 prefix, and SHOULD NOT wait for option 108 or DHCP timeouts.
- To mitigate RFC 7050 section 7 attacks, the node MAY delay enabling when the prefix came from DNS only;
  MAY offer a knob to disable that delay.
- If native IPv4 appears later, the node MUST disable CLAT for that interface unless configured to keep
  it.
- With several IPv4-continuity solutions, MUST follow RFC 7335 section 4.

Section 5 (disabling):
- Unless an administrator explicitly configured "prefer CLAT", the node MUST disable the instance
  immediately when a native IPv4 default gateway is obtained on that interface. Preferring CLAT over
  native IPv4 MUST be explicit configuration and MUST NOT be default.
- SHOULD support logging the reason for disabling and other CLAT configuration/signal changes; logging
  SHOULD be configurable and SHOULD be off by default.

Section 6.1 (IPv4 address):
- SHOULD use 192.0.0.0/29 (RFC 7335); SHOULD use a different local IPv4 address per instance; MUST NOT
  send packets to the network from the local CLAT IPv4 addresses; SHOULD use netmask 255.255.255.255.

Section 6.2.1 (obtaining the IPv6 address):
- A node **extending IPv4 downstream** (a router) MUST either (a) obtain a dedicated prefix meeting
  RFC 6052 section 2.2 (for example via DHCPv6-PD) and statelessly translate downstream IPv4 addresses
  into it, or (b) perform stateful NAT44 to a single IPv4 address and statelessly translate that to a
  single dedicated IPv6 address.
- If the instance uses a single IPv4 address (including the NAT44 case) it **SHOULD NOT obtain a
  dedicated prefix**.
- Without a dedicated prefix the instance MUST obtain a dedicated IPv6 address used exclusively for CLAT.
- If that address comes from SLAAC, the IID SHOULD be chosen so the CLAT IPv6 address is
  checksum-neutral.
- SHOULD use a different IID on different networks and SHOULD generate a new random CLAT address at each
  change of network attachment (privacy).

Section 6.2.2 (behaviour of the CLAT address):
- MUST treat CLAT addresses like any other IPv6 address (RFC 4861/4862); MUST perform DAD for each
  dedicated CLAT address; MUST answer unicast and multicast Neighbor Solicitations for it; SHOULD send
  gratuitous NAs if RFC 9131 is supported; MUST register it via RFC 9686 when that is enabled and the
  network supports it.

Section 7 / 7.1 (multiple prefixes, renumbering):
- With several routers advertising the same PIOs and NAT64 prefix: SHOULD create one instance. With
  differing info: MAY create one per (PIO, NAT64 prefix) tuple (both MUST come from the same router) or a
  single one via the selected default router. PIO choice SHOULD follow RFC 6724 source selection.
- SHOULD detect renumbering (prefix deprecated/invalid; advertising router unreachable or no longer a
  router) and SHOULD disable and recreate the affected instance; MAY do make-before-break; MAY send RS
  (then MUST follow RFC 4861 section 6.3.7).

Section 8 (MTU): the instance SHOULD present an IPv4 MTU **28 bytes smaller than the IPv6 MTU** of the
interface it runs on (20 bytes header difference plus 8 bytes Fragment header that RFC 7915 section 4.1
adds when an already-fragmented IPv4 packet is translated). The section does not mention 1280, 1260,
TCP MSS or PMTUD.

Section 9.1: relaxes RFC 6877 section 6.3's requirement to acquire a dedicated /64.

Section 9.2 (changes to RFC 8585 section 3.2.1):
- New 464XLAT-0: the CE SHOULD follow the claton document.
- 464XLAT-4 replaced: CE **MUST implement RFC 8781 and SHOULD implement RFC 7050**.
- 464XLAT-6 replaced: discovery priority MUST be RFC 7225, then RFC 8781, then RFC 7050.
- New 464XLAT-7: a CE performing CLAT SHOULD include the PREF64 option with the PLAT prefix in RAs on its
  LAN interfaces; if it is a DHCP server it SHOULD enable option 108 (RFC 8925) processing and SHOULD
  have a knob to disable that.

Section 11: disabling CLAT when native IPv4 exists is the security-motivated default.

### 2.4 RFC 7915 (SIIT translation algorithm)

URL: https://www.rfc-editor.org/rfc/rfc7915.txt

IPv4 to IPv6 (section 4):
- Section 4 intro: PMTUD is mandatory in IPv6, optional in IPv4; IPv6 routers never fragment. For DF=0
  packets the translator MUST ensure the result does not exceed the IPv6-side path MTU, by fragmenting to
  fit 1280-byte IPv6 packets. MUST NOT add a Fragment header to unfragmented packets (atomic fragments
  were deprecated relative to RFC 6145, section 2).
- Section 4.1: for DF=0 packets that would exceed "lowest-ipv6-mtu" (**default 1280**), the translator
  SHOULD fragment so each IPv6 packet including Fragment header fits; the example limit for the IPv4
  payload is 1232 bytes (1280 - 40 - 8). The translator **MUST provide a configuration function** to
  raise this threshold when the administrator knows the real minimum IPv6 MTU in the network.
- Section 4.1: DF=1 and too large for the next hop: MUST send ICMPv4 Fragmentation Needed.
- Section 4.1: TTL to Hop Limit; MUST check for zero and send Time Exceeded like any router.
- Section 4.2: ICMPv4 Fragmentation Needed to ICMPv6 Packet Too Big with
  MTU = max(1280, min(MTU_in_msg + 20, MTU_v6_nexthop, MTU_v4_nexthop + 20)); MUST NOT be below 1280.
- Section 4.4: SHOULD be able to send ICMPv4 errors (type 3 code 13) when dropping; sending/rate
  limiting should be configurable.
- Section 4.5: MUST recompute TCP/ICMP checksums and UDP checksums when present unless the mapping is
  checksum-neutral; MUST forward all transport protocols. **UDP with zero checksum**: SHOULD offer a
  configuration choice between dropping (with a management event) and computing a full IPv6 checksum;
  a first fragment of a fragmented zero-checksum UDP packet SHOULD be dropped by a stateless translator.

IPv6 to IPv4 (section 5):
- Section 5 intro / 5.1: translated IPv4 packet of **1260 bytes or less gets DF=0**, larger gets DF=1
  (stated as MUST in the section 5 intro). PMTUD across the translator works end to end for paths whose
  MTU is at least 1280 (1260 on the IPv4 side).
- Section 5.1: illegal source addresses (for example ::1) SHOULD be silently dropped.
- Section 5.1.1: IPv6 fragments are translated to IPv4 fragments with DF cleared; if the result exceeds
  the IPv4 next-hop MTU the translator MUST fragment; fragments carrying further extension headers
  SHOULD be dropped and logged.
- Section 5.2: ICMPv6 Packet Too Big to ICMPv4 Fragmentation Needed with
  MTU = min(MTU_in_msg - 20, MTU_v4_nexthop, MTU_v6_nexthop - 20).
- Section 5.4: generated ICMPv6 errors use type 1 code 1.
- Section 5.5: MUST recompute TCP, UDP and ICMP checksums unless checksum-neutral.

General:
- Section 6: MUST support RFC 6052 address mapping (default); SHOULD support EAM (RFC 7757); SHOULD
  support RFC 6791 for ICMPv6 errors whose IPv6 source is not translatable (for example a Packet Too Big
  from an ISP router's native IPv6 address).
- Section 1.4: three mechanisms handle packet size: PMTUD, fragmentation, and transport negotiation such
  as TCP MSS. This is the only mention of MSS; **no MSS clamping behaviour is specified anywhere**.
- Section 7: ICMPv6 Packet Too Big is frequently dropped by networks, producing PMTUD black holes.
- Section 8: no new security issues beyond IPv4/IPv6; address issues are in RFC 6052.

### 2.5 RFC 6052 (address format)

URL: https://www.rfc-editor.org/rfc/rfc6052.txt

- Section 2.1: Well-Known Prefix 64:ff9b::/96.
- Section 2.2: prefix length can only be 32, 40, 48, 56, 64 or 96. Bits 64-71 (the "u" octet) MUST be
  zero; with a /96 NSP the administrator MUST ensure bits 64-71 are zero. Suffix bits SHOULD be zero and
  SHOULD be ignored by translators on receipt.
  IPv4 bit positions: /32 -> 32-63; /40 -> 40-63 + 72-79; /48 -> 48-63 + 72-87; /56 -> 56-63 + 72-95;
  /64 -> 72-103; /96 -> 96-127.
- Section 3.1: the WKP MUST NOT represent non-global IPv4 addresses (RFC 1918 etc.); translators MUST NOT
  translate such packets and MUST drop them. The WKP SHOULD NOT be used for IPv4-translatable addresses.
- Section 4.1/4.2: the WKP is checksum-neutral; an NSP is checksum-neutral only if chosen so that its
  one's-complement sum is 0 or 0xffff.
- Section 5: reverse-path checks against spoofing; packets with embedded IPv4 addresses should get the
  same filtering as the embedded address (lowercase).

### 2.6 RFC 7050 and RFC 8880 (ipv4only.arpa discovery)

URLs: https://www.rfc-editor.org/rfc/rfc7050.txt , https://www.rfc-editor.org/rfc/rfc8880.txt

RFC 7050:
- Section 3: node SHALL send an AAAA query for ipv4only.arpa; MUST set the CD bit to zero; MUST examine
  all returned AAAA records and collect every Pref64::/n; for each, MUST look for the well-known IPv4
  addresses **192.0.0.170 / 192.0.0.171** at each RFC 6052 position on octet boundaries and require the
  value to appear only once (this is how the prefix length is derived; it is not always /96).
- Section 3: one prefix -> SHALL use it; several -> SHOULD use all for detecting synthesis and (for local
  synthesis) use them in the order received. No WKA found -> discovery failed.
- Section 3: negative answer (NXDOMAIN/NODATA) -> no synthesis available, wait for the negative TTL
  before re-querying; timeout -> retransmit. Replies SHALL be cached; the node **SHOULD repeat discovery
  10 seconds before the TTL** of the synthetic AAAA expires.
- Section 3.1: SHOULD use a trusted DNS64 over a secure channel or DNSSEC to validate; the WKP itself
  cannot be validated.
- Section 3.2: after learning a prefix, SHOULD check connectivity (ICMPv6 echo, retries at 1 s and 2 s)
  against an operator-provided target. Section 3.2.1: clients **MUST NOT** send connectivity checks to an
  address returned by the ipv4only.arpa query.
- Section 4: the authoritative TTL SHALL be at least 60 minutes.
- Section 5: operators wanting several prefixes return several AAAA records; DNS64 servers MUST NOT
  interfere with queries for the well-known name.
- Section 6: a node SHOULD have a knob to disable the discovery.
- Section 7: a forged prefix enables DoS, flooding and interception.

RFC 8880 (updates RFC 7050):
- Section 3.1: the query must reach the DNS64 resolver recommended by that network; a manually configured
  public resolver or VPN resolver will not know the local prefix.
- Section 7.1 item 3 (name resolution APIs/libraries): MUST treat ipv4only.arpa as special; the query
  **MUST be sent to the recursive resolver address(es) learned from the network on that interface**,
  regardless of manual DNS configuration, VPN overrides or loopback resolvers; on multihomed hosts MUST
  use interface-aware APIs.
- Section 7.1 item 4: DNS64 resolvers MUST answer ipv4only.arpa authoritatively (192.0.0.170/171 plus
  synthesized AAAA; NXDOMAIN for subdomains) and MUST NOT look up NS records. **Traditional forwarding
  resolvers SHOULD NOT treat the name as special** (they must forward it upstream).
- Section 5: ipv4only.arpa MUST be an insecure delegation; DNSSEC-validating resolvers MUST NOT attempt
  to validate AAAA answers for it. Consequence: the DNSSEC validation idea of RFC 7050 section 3.1 is not
  available for the WKP path.

### 2.7 RFC 8781 (PREF64 RA option)

URL: https://www.rfc-editor.org/rfc/rfc8781.txt

- Section 4: option type 38; Length MUST be 2 and receivers MUST ignore other lengths. 13-bit Scaled
  Lifetime in units of 8 seconds (max 65528 s). PLC values 0..5 map to /96, /64, /56, /48, /40, /32;
  receivers MUST ignore the option for any other PLC. A lifetime of 0 means the prefix SHOULD NOT be used
  any more.
- Section 5: one option carries exactly one NAT64 prefix for all IPv4 destinations; the option may appear
  several times in an RA.
- Section 5.1: hosts SHOULD treat PREF64 as specific to the receiving interface. When prefixes are
  learned through several mechanisms, hosts SHOULD use only one source, in the order **PCP (RFC 7225),
  then RA PREF64, then RFC 7050**.
- Section 5.2: routers SHOULD check consistency of PREF64 options seen on a link and SHOULD log
  inconsistencies.
- Section 7: relies on RA security (RA-Guard); a wrong prefix is DoS/MITM.
- The RFC does not use the word CLAT; 464XLAT is named in section 2 as a consumer of the prefix.

### 2.8 RFC 7335 (192.0.0.0/29)

URL: https://www.rfc-editor.org/rfc/rfc7335.txt

- Section 3: with a host/CPE-embedded CLAT, an IPv4 address must be configured for the IPv4 stack.
- Section 4: a locally unique IPv4 address must be assigned; 192.0.0.0/29 (originally DS-Lite B4 space,
  never emitted on the wire) is generalised to all IPv4-continuity solutions. A host **MUST NOT enable two
  active IPv4 continuity solutions simultaneously in a way that overlaps 192.0.0.0/29**.
- Section 6: IANA special-purpose registry entry "IPv4 Service Continuity Prefix": Source true,
  Destination true, Forwardable true, Global false.

### 2.9 RFC 8683 (deployment guidelines) - Informational

URL: https://www.rfc-editor.org/rfc/rfc8683.txt

- Section 4.3: with DNS64, most traffic uses a single translation and only literals/IPv4-only apps use
  the CLAT; **without DNS64 all IPv4 traffic goes through the CLAT** (double translation) and DNSSEC is
  never broken. The CLAT overhead is described as not perceptible for a broadband CE.
- Section 4.4: foreign DNS (manual config, DoT/DoH, VPN split DNS) may not provide DNS64; a CLAT makes
  those cases work, except when the CLAT itself cannot obtain its parameters.
- Section 4.5: WKP MUST NOT represent non-global IPv4; an NSP is then required.
- Section 4.8: a dedicated /64 allows the more efficient stateless mode; otherwise stateful NAT44 then
  stateless NAT46. On broadband the dedicated prefix is easy when a shorter PD is delegated.
- Section 4.1.4 / 5: CEs SHOULD include a DNS proxy and validator; CEs with CLAT SHOULD support
  DHCPv6-PD and SHOULD internally reserve one /64 for stateless NAT46. The summary recommends not using
  DNS64 at all where DNSSEC breakage matters, and translating all IPv4 at the CLAT.

### 2.10 PPP documents: RFC 4638 and RFC 5072

RFC 4638 (https://www.rfc-editor.org/rfc/rfc4638.txt):
- Section 3: PPPoE header 6 octets + PPP protocol ID 2 octets, so MRU is capped at 1492 on 1500-byte
  Ethernet.
- Section 4: PPP-Max-Payload tag (0x0120). A client wanting more than 1492 MUST send it in PADI and PADR;
  a capable server MUST echo it in PADO and PADS.
- Section 5.1: MRU MUST NOT be negotiated above 1492 unless both ends signalled the tag; without the tag
  the 1492 limit MUST stay.
- Section 5.2: SHOULD be able to send MRU-sized LCP Echo-Requests to verify the path; on failure MAY
  retry at 1492 and then MUST NOT send more than 1492 for the session.
- The RFC does not name a specific Ethernet frame size (1508 is the arithmetic consequence, not a quote).

RFC 5072 (https://www.rfc-editor.org/rfc/rfc5072.txt):
- Section 2: PPP links carrying IPv6 MUST allow an information field at least as large as the IPv6
  minimum link MTU (1280).
- Section 5: when the IID is negotiated in IPV6CP, DAD on the link-local address is redundant; DAD on
  global addresses may also be redundant, but only if the RA prefixes are exclusive to the PPP link and
  the access router does not autoconfigure addresses from them. Under those conditions the RFC
  RECOMMENDS DupAddrDetectTransmits default to zero. It SHOULD NOT be assumed the negotiated IID is used
  for global addresses.
- The RFC does not state that NDP address resolution is unnecessary on PPP.

### 2.11 RFC 8925 (option 108) - only as referenced by claton 464XLAT-7

URL: https://www.rfc-editor.org/rfc/rfc8925.txt
- Section 3.3: a DHCPv4 server MUST NOT return option 108 unless the pool is configured as IPv6-mostly;
  SHOULD be configurable per pool. Section 3.4: V6ONLY_WAIT default 1800 s, minimum 300 s.

### 2.12 draft-ietf-v6ops-464xlat-optimization-06

URL: https://datatracker.ietf.org/doc/draft-ietf-v6ops-464xlat-optimization/
Proposes avoiding the second translation for dual-stack destinations: (5.1) DNS/routing-based at the
operator, no CE change; (5.2) CE DNS-proxy creates EAM entries, needs stateful NAT46 at the CE;
(5.3) operator-pushed EAM. Not approved; datatracker state is inconsistent. Not a requirement source
for a first implementation.

## 3. What proven CLAT implementations do

| Implementation | Trigger / prefix discovery | CLAT IPv4 address | CLAT IPv6 address | IPv4 MTU | Evidence / confidence |
|---|---|---|---|---|---|
| Android (ClatCoordinator + libclat) | Requires /96 NAT64 prefix (throws otherwise) | first free from 192.0.0.4/29 (`INIT_V4ADDR_STRING = "192.0.0.4"`, prefix len 29) | Interface's global /64 (via connect+getsockname towards the prefix, rejects link-local/ULA), random low 64 bits, then **checksum-neutral** adjustment of bytes 11-12; not assigned to the kernel, received via packet socket + anycast join | detected IPv6 route MTU to the PLAT prefix, clamped to [IPv6 min MTU, 1500+28], then **minus 28** (`MTU_DELTA = 28`) | android.googlesource.com ClatCoordinator.java and clatutils.cpp; verified (IPv6 min MTU value 1280 likely) |
| Apple (XNU) | macOS 12: option 108 + PREF64; macOS 13+: broader (secondary sources) | 192.0.0.2 (secondary source) | Separate autoconf address created from the same RA PIO when the interface is marked CLAT46: `in6_pfx_newpersistaddr(..., is_clat46=TRUE, CLAT46_COLLISION_COUNT_OFFSET)`, IID from `in6_cga_generate`, flag `IN6_IFF_CLAT46` | not established | apple-oss-distributions/xnu bsd/netinet6/nd6_rtr.c verified for address creation; DAD likely (goes through `in6_update_ifa`); trigger/IPv4/MTU unverified |
| Linux clatd (toreanderson) | RFC 7050 via system resolver or `dns64-servers`; PREF64 only indirectly via systemd-networkd (`cmd-networkctl`); `plat-fallback-prefix` | `clat-v4-addr` default 192.0.0.1 | `clat-v6-addr` default `shared` (reuses the host's primary address, marks flows with nftables ctmark 0xc1a7); `derived` mode replaces 0xfffe in an EUI-64 IID with 0xc1a7 or uses a random IID; **no DAD** (README lists it as an RFC 6877 violation); PD not implemented | `v4-defaultroute-mtu` default **1260** (TAYGA's 1280 minus 20); `v4-defaultroute-advmss` default MTU minus 40; default-route metric 2048 | raw.githubusercontent.com/toreanderson/clatd/master/README.pod; verified |
| NetworkManager 1.58 (released 2026-07-20) | `ipv4.clat` no/auto/force (still off by default); NAT64 prefix from RAs only; `auto` only when no native IPv4 gateway | /32 from a 192.0.0.x reservation pool | Picks an NDISC /64 (RFC 6724 rules, cites claton section 7); IID via stable-privacy generator (`NM_UTILS_STABLE_TYPE_CLAT`); **not configured in the kernel**, claimed with `IPV6_JOIN_ANYCAST`; sends one DAD probe citing claton-14 but does not wait for a reply | min(link MTU, RA MTU), floor 1280, then **minus 28**; metric above any native default route | NetworkManager NEWS, settings docs, src/core/nm-l3cfg.c; verified. BPF datapath cannot fragment v4->v6 (maintainer statement on LKML, secondary) |
| systemd-networkd | No CLAT in any release. Draft PR #41412 (opened 2026-03-29, still open/draft 2026-09): `CLAT=yes`, PREF64 or manual prefix only, BPF with TUN fallback | 192.0.0.1/32, default route metric 2048 (PR) | not described in PR | reviewer notes BPF path subtracts 28 and TUN path 20 (inconsistent) | github.com/systemd/systemd/issues/23674 and pull/41412; verified as unmerged |
| OpenWrt `464xlat` (netifd proto + kmod-nat46) | Auto-created as dynamic interface `<wan6>_4` by the DHCPv6 script when no MAP/DS-Lite applies; prefix from `ip6prefix` option or `getaddrinfo("ipv4only.arpa")` and **"/96" is always appended** | fixed 192.0.0.1, with SNAT of forwarded IPv4 to 192.0.0.1 declared as proto firewall data | WAN source address towards 2001:db8::, keep upper 64 bits, **random lower 64 bits**, claimed with `IPV6_JOIN_ANYCAST`; no DAD, no checksum neutrality; override via `ip6addr` | none set by the proto script; IPv4 default route metric 2048 | local clone, see below; verified |
| TAYGA (apalrd) as translator | n/a (translator only) | docs use host 192.0.0.1 and TAYGA 192.0.0.2 | docs show three patterns: proxy-NDP address in the WAN /64, NAT66 masquerade, routed/PD prefix; docs explicitly skip DAD and random IID | examples set `ip route add default dev clat mtu 1260`; `offlink-mtu` default 1280 | local clone, see below; verified |

Local clone evidence (OpenWrt):
- `refs/openwrt/package/network/ipv6/464xlat/files/464xlat.sh:40` calls
  `464xlatcfg "$link" "$tundev" "$ip6prefix" 192.0.0.1 $ip6addr`; lines 46-48 move the `local` rule and
  add a `prelocal` rule for the CLAT address; line 52 `proto_add_ipv4_route "0.0.0.0" 0 "" "" 2048`;
  line 53 adds the /128 route; lines 61-66 declare `type nat / target SNAT / snat_ip 192.0.0.1`;
  lines 67-78 add an inet6 accept rule for `src_ip $ip6addr`; lines 110-113 list the options
  `ip6prefix`, `ip6addr`, `tunlink`, `zone`. No MTU option exists.
- `refs/openwrt/package/network/ipv6/464xlat/src/464xlatcfg.c:64-76` resolves `ipv4only.arpa` with
  `getaddrinfo` and does `strcat(prefix, "/96")`; lines 106-114 randomise `s6_addr32[2]` and `[3]`;
  line 119 `setsockopt(sock, SOL_IPV6, IPV6_JOIN_ANYCAST, ...)`; lines 127-131 write the nat46 rule
  `local.style NONE local.v4 %s/32 local.v6 %s/128 remote.style RFC6052 remote.v6 %s`.
- `refs/openwrt/package/network/ipv6/odhcp6c/files/dhcpv6.script:208-220` creates the dynamic
  `proto "464xlat"` interface named `${INTERFACE}_4` with `tunlink "$INTERFACE"`; it is the last branch
  after MAP and DS-Lite; lines 155-158: `DYNAMIC=0` suppresses it.
- `refs/openwrt/package/network/ipv6/464xlat/Makefile:15` `DEPENDS:=@IPV6 +kmod-nat46 +ip`.

Local clone evidence (TAYGA):
- `refs/tayga/docs/clat/README.md:5` says the example scripts are not best practice and skip random
  SLAAC address generation and DAD; lines 36-59 describe the proxy-NDP, NAT66 and routed-prefix patterns;
  line 7 says two IPv6 addresses are needed (one mapped for user traffic, one for TAYGA's own ICMPv6).
- `refs/tayga/docs/clat/clat-proxynd.conf:4-10`: `ipv4-addr 192.0.0.2`, `ipv6-addr 2001:db8:feed::6`,
  `map 192.0.0.1 2001:db8:feed::7`, `prefix 64:ff9b::/96`.
- `refs/tayga/docs/clat/clat-proxynd.sh:22-24`: `ip addr add 192.0.0.1/29 dev clat` and
  `ip route add default dev clat mtu 1260`.
- `refs/tayga/tayga.conf.example:148-166`: `offlink-mtu`, default 1280, example `#offlink-mtu 1492`;
  DF=0 IPv4 packets larger than this are fragmented.
- `refs/tayga/tayga.h:184,187`: `#define MTU_ADJ 20u`, `#define MTU_MIN 1280`.
- `refs/tayga/nat64.c:374-377`: fragment size = min(`ipv6_offlink_mtu`, tun MTU) minus IPv6 header;
  `nat64.c:411-417`: unfragmented DF=1 packet larger than tun MTU minus 20 gets ICMPv4 type 3 code 4 with
  MTU = tun MTU minus 20; `nat64.c:402-410`: comment explaining that DF is not honoured for
  already-fragmented IPv4 packets because the Fragment header needs 8 more bytes than the IPv4 sender
  was told about (this is exactly the 20-versus-28 problem claton section 8 addresses).
- `refs/tayga/tayga.conf.example:117-129`: `udp-cksum-mode drop|fwd|calc`, default `drop`.
- `refs/tayga/docs/rfc.md:34-40`: RFC 6791 partially implemented; untranslatable ICMPv6 sources are
  mapped to TAYGA's own `ipv4-addr`. Lines 48-54: non-/96 prefixes supported; WKP strictness
  (`wkpf-strict`) drops non-global IPv4 with 64:ff9b::/96 by default.

Other survey source: draft-nbrr-v6ops-clat-status-00 (2025-07-21, expired) says BSD CLAT exists but is
manual (ipfw, or the gelatod daemon), Linux has no official support, Windows only on cellular, macOS
native since macOS 13 (https://www.ietf.org/archive/id/draft-nbrr-v6ops-clat-status-00.html).

## 4. Requirements checklist

Level column: keyword as used by the source. "(lc)" = lowercase keyword in an Informational RFC.
"claton" = draft-ietf-v6ops-claton-16 (approved Proposed Standard, not yet published).

### A. Enablement and lifecycle

| ID | Level | Requirement | Source |
|---|---|---|---|
| A1 | MUST | GUI plus CLI or API to manually enable/disable the mechanism | RFC 8585 s3.2 TRANS-2 |
| A2 | MUST | Enable 464XLAT when a NAT64 prefix has been configured (and no S46 priority match) | RFC 8585 s3.2 CONFIG-3 |
| A3 | MUST | Support S46 priority option processing; mechanisms disabled until evaluated | RFC 8585 s3.2 TRANS-1, CONFIG-1/2 |
| A4 | SHOULD NOT | Enable CLAT on an interface that has native IPv4, unless explicitly configured | claton s4, s11 |
| A5 | SHOULD | Enable CLAT as soon as PREF64 is received on an IPv6-only uplink | claton s4 |
| A6 | MUST | Unless configured otherwise, enable CLAT if no non-link-local IPv4 exists when the NAT64 prefix is discovered; SHOULD NOT wait for option 108 / DHCP timeout | claton s4 |
| A7 | MAY | Delay enabling when the prefix was learned by DNS (RFC 7050) only; MAY provide a knob to disable the delay | claton s4 |
| A8 | MUST | Disable the instance immediately when a native IPv4 default gateway appears on that interface, unless the admin explicitly configured otherwise; "prefer CLAT" MUST NOT be default | claton s4, s5 |
| A9 | MUST | One independent CLAT instance per uplink interface, each installing its own IPv4 default route on that interface | claton s4 |
| A10 | SHOULD | Log reasons for disabling and other CLAT state/signal changes; logging SHOULD be configurable and SHOULD be off by default | claton s5 |
| A11 | SHOULD | Detect renumbering (PIO deprecated/invalid, advertising router gone) and disable/recreate the instance; MAY make-before-break | claton s7.1 |
| A12 | SHOULD | CE follows the claton document | claton s9.2 (new 464XLAT-0) |
| A13 | MUST NOT | Run two IPv4-continuity solutions with overlapping 192.0.0.0/29 use (for example DS-Lite B4 and CLAT) | RFC 7335 s4; claton s4 |

### B. NAT64 (PLAT) prefix discovery

| ID | Level | Requirement | Source |
|---|---|---|---|
| B1 | must (lc) | CLAT must discover the PLAT-side prefix | RFC 6877 s6.3 |
| B2 | MUST / SHOULD | Implement RFC 8781 (MUST) and RFC 7050 (SHOULD). Before claton: RFC 7050 MUST | claton s9.2 replacing RFC 8585 464XLAT-4 |
| B3 | MUST | Source priority: RFC 7225 (PCP), then RFC 8781, then RFC 7050; use only one source | claton s9.2 (464XLAT-6); RFC 8781 s5.1 (SHOULD) |
| B4 | MUST | Ignore PREF64 option when Length is not 2 or PLC is not 0..5; map PLC to /96,/64,/56,/48,/40,/32 | RFC 8781 s4 |
| B5 | SHOULD NOT | Use a prefix whose PREF64 lifetime is 0; lifetime unit is 8 s | RFC 8781 s4.1 |
| B6 | SHOULD | Treat PREF64 as specific to the receiving interface | RFC 8781 s5.1 |
| B7 | MUST | Accept only RFC 6052 prefix lengths 32/40/48/56/64/96; u-octet (bits 64-71) zero | RFC 6052 s2.2 |
| B8 | SHALL / MUST | RFC 7050 procedure: AAAA for ipv4only.arpa, CD bit zero, inspect all AAAA records, locate 192.0.0.170/171 at every RFC 6052 position (derive length, do not assume /96) | RFC 7050 s3 |
| B9 | SHALL / SHOULD | Cache result; re-run discovery 10 s before the AAAA TTL expires; after a negative answer wait for its TTL | RFC 7050 s3 |
| B10 | MUST | Send ipv4only.arpa queries to the resolvers learned from the network on that uplink interface, never to manually configured, VPN or loopback resolvers | RFC 8880 s7.1(3); claton s4 |
| B11 | MUST NOT | Send connectivity checks to addresses returned by the ipv4only.arpa query | RFC 7050 s3.2.1 |
| B12 | SHOULD | Verify connectivity through a learned prefix by other means | RFC 7050 s3.2 |
| B13 | SHOULD | Provide a knob to disable Pref64 discovery | RFC 7050 s6 |
| B14 | MUST NOT | DNSSEC-validate AAAA answers for ipv4only.arpa (zone is an insecure delegation) | RFC 8880 s5 |
| B15 | MUST NOT | Translate WKP (64:ff9b::/96) addresses embedding non-global IPv4; drop them | RFC 6052 s3.1; RFC 8683 s4.5 |
| B16 | info | RFC 7050 works only if the provider operates DNS64 | RFC 8585 s3.2.1 closing text |

### C. CLAT addressing

| ID | Level | Requirement | Source |
|---|---|---|---|
| C1 | SHOULD | CLAT IPv4 address from 192.0.0.0/29, netmask /32, distinct per instance | claton s6.1; RFC 7335 s4 |
| C2 | MUST NOT | Send packets onto the network with the local CLAT IPv4 address as source | claton s6.1 |
| C3 | MUST (either/or) | Router extending IPv4 downstream: (a) dedicated RFC 6052-conformant prefix (for example from PD) with stateless translation of LAN IPv4 addresses, or (b) stateful NAT44 to one IPv4 address then SIIT to one dedicated IPv6 address | claton s6.2.1 |
| C4 | MUST | Perform NAT44 on CLAT traffic unless a dedicated /64 was acquired | RFC 8585 464XLAT-1 |
| C5 | should / may (lc) | Acquire a dedicated /64 for translation; when unavailable NAT44 to a single address claimed via NDP | RFC 6877 s6.3 (relaxed by claton s9.1) |
| C6 | SHOULD NOT | Obtain a dedicated prefix when the instance uses a single IPv4 address (incl. NAT44 mode) | claton s6.2.1 |
| C7 | MUST | Without a dedicated prefix: a dedicated IPv6 address used exclusively for CLAT | claton s6.2.1 |
| C8 | SHOULD | Choose the IID so the CLAT IPv6 address is checksum-neutral (SLAAC case) | claton s6.2.1 |
| C9 | SHOULD | Different IID per network; new random address on each change of attachment | claton s6.2.1, s12 |
| C10 | MUST | Treat the CLAT address as a normal IPv6 address: DAD, answer unicast and multicast NS | claton s6.2.2 |
| C11 | SHOULD | Gratuitous NA for the CLAT address if RFC 9131 is supported | claton s6.2.2 |
| C12 | SHOULD | With several PIOs choose via RFC 6724 rules; one instance when routers advertise identical info | claton s7 |
| C13 | SHOULD | CE with CLAT supports DHCPv6-PD and reserves one /64 for stateless NAT46 | RFC 8683 s5 (in tension with C6) |
| C14 | MUST | If WAN has no global address, create one from the delegated prefix on an internal interface | RFC 7084 WAA-7 |

### D. Translation behaviour (translator component)

| ID | Level | Requirement | Source |
|---|---|---|---|
| D1 | MUST | RFC 6052 stateless address mapping; SHOULD support RFC 6791 and EAM | RFC 7915 s6 |
| D2 | MUST | DF=0 IPv4 packets must not exceed the IPv6 path MTU: fragment (SHOULD to lowest-ipv6-mtu, default 1280) | RFC 7915 s4, s4.1 |
| D3 | MUST | Provide configuration to raise lowest-ipv6-mtu above 1280 | RFC 7915 s4.1 |
| D4 | MUST NOT | Add a Fragment header to unfragmented packets | RFC 7915 s4 |
| D5 | MUST | DF=1 packet too big: ICMPv4 Fragmentation Needed | RFC 7915 s4.1 |
| D6 | MUST | Translate Frag Needed <-> Packet Too Big with the +/-20 MTU formulas; never below 1280 on the IPv6 side | RFC 7915 s4.2, s5.2 |
| D7 | MUST | IPv6->IPv4: DF=0 if result is 1260 bytes or less, else DF=1 | RFC 7915 s5, s5.1 |
| D8 | MUST | Translate IPv6 fragments to IPv4 fragments; fragment further on IPv4 if needed | RFC 7915 s5.1.1 |
| D9 | SHOULD | Configurable handling of zero-checksum UDP (drop or compute) | RFC 7915 s4.5 |
| D10 | MUST | Recompute transport checksums unless mapping is checksum-neutral; forward all transport protocols | RFC 7915 s4.5, s5.5 |
| D11 | MUST | Decrement/check TTL / Hop Limit and send Time Exceeded | RFC 7915 s4.1 |
| D12 | SHOULD | Be able to send ICMP errors when dropping; configurable/rate-limited | RFC 7915 s4.4, s5.4 |

### E. MTU

| ID | Level | Requirement | Source |
|---|---|---|---|
| E1 | SHOULD | IPv4 MTU presented by the CLAT = IPv6 MTU of the uplink minus 28 | claton s8 |
| E2 | MUST | PPP link must carry at least 1280 | RFC 5072 s2 |
| E3 | MUST NOT | Negotiate PPPoE MRU above 1492 unless PPP-Max-Payload was exchanged in both directions | RFC 4638 s3, s5.1 |
| E4 | none | TCP MSS clamping is not required by any of these documents | RFC 7915 s1.4 (only mention of MSS) |

### F. LAN-side services

| ID | Level | Requirement | Source |
|---|---|---|---|
| F1 | MUST | DNS proxy per RFC 5625 | RFC 8585 s3.1 L-1; RFC 6877 s6.4 (lc should) |
| F2 | should (lc) | Announce the CE as DNS server; proxy for IPv4 and IPv6 clients; still translate DNS sent elsewhere | RFC 6877 s6.4 |
| F3 | SHOULD NOT | A forwarding resolver treats ipv4only.arpa specially (it must be forwarded upstream) | RFC 8880 s7.1(4) |
| F4 | SHOULD | Include PREF64 with the PLAT prefix in LAN RAs when acting as CLAT | claton s9.2 (464XLAT-7) |
| F5 | SHOULD | If DHCPv4 server: enable option 108 processing, with a knob to disable | claton s9.2 (464XLAT-7); RFC 8925 s3.3 |
| F6 | should (lc) | Provide usual router services (DHCP with RFC 1918, DHCPv6, RA, DNS) | RFC 6877 s6.5 |
| F7 | MUST | Multi-LAN subnetting support | RFC 8585 TRANS-3 |
| F8 | SHOULD | IGD-PCP IWF; if PCP then RFC 7291 and plain IPv6 mode (MUST) | RFC 8585 464XLAT-2/3 |
| F9 | MUST | If UPnP IGD:2 cannot be served through the IPv4aaS interface, reject mappings with error 729 | RFC 8585 s5 |
| F10 | SHOULD | CE includes DNS proxy and validator | RFC 8683 s5 |

### G. Security

| ID | Level | Requirement | Source |
|---|---|---|---|
| G1 | may (lc) | CLAT may comply with RFC 6092 | RFC 6877 s8 |
| G2 | MUST NOT | Forward DHCP packets between LAN and WAN | RFC 8585 s8 |
| G3 | info | Forged Pref64 (DNS or RA) gives DoS/MITM; RA path relies on RA-Guard-style protection | RFC 7050 s7; RFC 8781 s7 |
| G4 | info | Reverse-path checks; filter IPv4-embedded addresses like the embedded IPv4 address | RFC 6052 s5 |

## 5. PPPoE-specific callouts

1. IPv6CP-only is a standard-conformant state: NCPs are independent (RFC 7084 WLL-3). No IPCP means no
   native IPv4 default gateway, so claton A6 applies (enable CLAT once the prefix is known) and A8 never
   triggers unless IPCP later comes up.
2. WAN IPv6 MTU is 1492 by default and 1500 only with RFC 4638 negotiated end to end.

   | WAN IPv6 MTU | CLAT IPv4 MTU per claton s8 (minus 28) | IPv4 TCP MSS (MTU minus 40) | "minus 20" convention (clatd/TAYGA) | MSS at minus 20 |
   |---|---|---|---|---|
   | 1492 (plain PPPoE) | **1464** | **1424** | 1472 | 1432 |
   | 1500 (RFC 4638) | 1472 | 1432 | 1480 | 1440 |
   | 1280 (floor) | 1252 | 1212 | 1260 | 1220 |

   Arithmetic derived here; inputs are verified (28 from claton s8, Android `MTU_DELTA`, NetworkManager
   `mtu -= 28`; 20 from RFC 7915 formulas, `MTU_ADJ 20u`, clatd default 1260). Native IPv6 TCP MSS over
   1492 is 1432, so the minus-28 rule costs 8 bytes of MSS on unfragmented traffic in exchange for
   never needing to re-fragment already-fragmented IPv4.
3. Translator defaults assume 1280: RFC 7915 lowest-ipv6-mtu, TAYGA `offlink-mtu`, clatd 1260. On a
   1492 link these fragment every DF=0 IPv4 packet above 1260 bytes unless the threshold is raised
   (RFC 7915 s4.1 requires the knob; TAYGA has it, example value 1492 in `tayga.conf.example:166`).
4. Return direction: packets from the PLAT can arrive as IPv6 fragments (PLAT applies its own
   lowest-ipv6-mtu to DF=0 traffic) and the path relies on ICMPv6 Packet Too Big from the BNG reaching
   the PLAT. RFC 7915 s7 warns PTB is often filtered. Nothing normative mandates MSS clamping, but
   clatd sets `advmss` and the 1492 bottleneck is invisible to LAN hosts with MTU 1500.
5. ICMPv6 errors from ISP routers (non-Pref64 sources) need RFC 6791 handling (RFC 7915 s6 SHOULD);
   TAYGA maps them to its own IPv4 address.
6. CLAT IPv6 address on PPP: DAD is still a MUST in claton s6.2.2. RFC 5072 s5 treats DAD on PPP as
   redundant only under two conditions (prefix exclusive to the link; access router does not
   autoconfigure from it). If the PPP WAN is unnumbered (link-local + PD only), there is no WAN /64 to
   take an address from; RFC 7084 WAA-7 then points to the delegated prefix, and WPD-5 (null route for
   the delegated prefix) means the CLAT address/prefix needs an explicit more-specific route.
7. RFC 7050 on PPPoE: the resolvers that matter are the ones the ISP hands out on the PPP/IPv6 uplink
   (RA RDNSS / DHCPv6). A CE running its own full recursive resolver will not see DNS64 synthesis, so
   the probe must bypass it (B10). If the ISP runs no DNS64, only PREF64 or static configuration works
   (B16).

## 6. Tensions between documents

- Dedicated /64: RFC 6877 s6.3 (should) and RFC 8683 s5 (SHOULD reserve a /64) versus claton s6.2.1
  (SHOULD NOT obtain a dedicated prefix when a single IPv4 address is used) and s9.1 (explicit
  relaxation). RFC 8585 464XLAT-1 is neutral: NAT44 is mandatory only without a dedicated /64.
- Discovery priority: RFC 8585 (7225 then 7050; 7050 MUST) versus claton (7225, 8781, 7050; 8781 MUST,
  7050 SHOULD). RFC 8781 s5.1 already ranks RA above DNS.
- MTU delta: claton s8 says 28; RFC 7915 formulas, TAYGA and clatd use 20; systemd's draft PR uses both.
- Validation: RFC 7050 s3.1 recommends DNSSEC/secure channel; RFC 8880 s5 makes the zone insecure and
  forbids validating the AAAA answer. claton's answer is the optional enable-delay for DNS-only prefixes.
- /96 assumption: OpenWrt and Android only handle /96; RFC 6052, RFC 7050 and RFC 8781 require/allow six
  lengths.

## 7. Open questions (not established)

- Whether draft-ietf-v6ops-claton has received an RFC number after 2026-08-13; AUTH48 edits could still
  change wording.
- Apple: CLAT IPv4 MTU rule, whether DAD is completed before use, exact trigger logic (not read from
  source).
- OpenWrt: default MTU of the nat46 device (kmod-nat46 is not in the local clone).
- Android: value of `IPV6_MIN_MTU` constant (expected 1280) and behaviour if MTU detection fails.
- NetworkManager: whether the stable-privacy IID is additionally made checksum-neutral (not seen in the
  parts of nm-l3cfg.c that were read).
- Deployment facts only the ISP can supply: PREF64 in RAs on the PPP link, DNS64 presence, PD size,
  numbered versus unnumbered WAN, RFC 4638 support, PLAT prefix length, IPv6 path MTU between BNG and
  PLAT and the PLAT's own lowest-ipv6-mtu.
