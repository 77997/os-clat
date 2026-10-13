# auto-1: Activation and deactivation rules for a self-activating CE-router CLAT

Research date: 2026-10-11. Topic: when `os-clat` turns the CLAT on and off by itself, now that the
requirement is "activate automatically when the NAT64 prefix can be discovered from RA and/or DNS".
DHCPv4 option 108 is out of scope.

`REFS` = `refs` (local clones, not in this repository)

## 0. Method and caveats

- RFC and draft text was read as fetched excerpts. Every quotation below is therefore a **short
  verbatim fragment** (under ~120 characters) with its section number; the rest of a sentence is
  paraphrased. Fragments were taken sentence by sentence so that conditions ("unless ...", "by the time ...") are not lost.
- OPNsense facts come from the local clone `REFS/opnsense-core` (master, HEAD `5de9cc0` of 2026-10-10) and
  are quoted with file:line. Earlier reports cross-checked the same files against stable/26.7.
- Android, Apple, NetworkManager and clatd facts come from upstream source files fetched by URL; function
  names are given because the fetched text carries no line numbers. OpenWrt facts come from `REFS/openwrt`.
- Confidence: **[V]** verified in a primary source, **[L]** likely (strong inference or a
  secondary reading), **[U]** unverified.
- Nothing was run on a box.

## 1. Standards: exact text and analysis

### 1.1 draft-ietf-v6ops-claton-16

Status [V]: still an Internet-Draft, version 16 (2026-03-05), IESG state "RFC Ed Queue", RFC Editor state
"Awaiting First editor", page last updated 2026-08-13, no RFC number
(https://datatracker.ietf.org/doc/draft-ietf-v6ops-claton/). Text:
https://www.ietf.org/archive/id/draft-ietf-v6ops-claton-16.txt

**Section 3 (terminology)** [V]

- Native IPv4: "IPv4 connectivity provided by the network without using any form of IPv4-as-a-Service" /
  "or IP address family translation mechanisms (such as 464XLAT)."
- IPv6-only network: "A network that does not assign IPv4 addresses to hosts and facilitates connectivity"
  / "to IPv4-only destinations using NAT64".
- "IPv6-only interface", "non-link-local IPv4" and "CLAT instance" are not defined terms.

**Section 4 (Enabling CLAT)** [V] - 7 paragraphs. Normative sentences:

| # | Verbatim fragment | Rest of the sentence |
|---|---|---|
| 4-a | "For performance and security reasons CLAT SHOULD NOT be enabled" / "(unless explicitly configured otherwise) for an interface if the node has native IPv4 connectivity" / "over that interface (see Section 5 for more details)." | complete sentence |
| 4-b | "are only applicable to the IPv6-only interfaces of a given node" | the section's scope; parenthetical: the node has no native IPv4 connectivity via that interface |
| 4-c | "an IPv6-only node SHOULD enable CLAT as soon as it receives a PREF64 option from the network" | preceded by: PREF64 "can be used as a strong indication that the network supports PLAT (NAT64) functionality" |
| 4-d | "does not require that a node MUST enable CLAT upon receiving an RA" | discussion paragraph: default enablement may be unwanted in controlled deployments |
| 4-e | "The node MAY choose to enable CLAT on a subset of its interfaces connected to networks equipped with PLAT" | multi-interface nodes |
| 4-f | "the node MUST run an independent, dedicated CLAT instance on each interface the node chooses to enable CLAT on" | |
| 4-g | "each CLAT instance MUST install a separate default IPv4 route on each CLAT-enabled interface" | |
| 4-h | "the node MAY use other mechanisms to detect the PLAT presence and obtain the NAT64 prefix" | when no PREF64 arrives; RFC 7050 is the example; "Section 3.1 of [RFC9872] discusses this approach in more detail" |
| 4-i | "the node MUST follow recommendations provided in [RFC8880]" | when RFC 7050 is used |
| 4-j | "queries for AAAA resource records of "ipv4only.arpa." MUST be sent to the DNS resolvers provided through" | ... that specific interface, not manually configured or other resolvers |
| 4-k | "it is desirable that the node enables CLAT as soon as network support for PLAT is detected" | provided native IPv4 has not been detected |
| 4-l | "Unless configured otherwise, the node MUST enable CLAT if the node has not already obtained" / "a non-link-local IPv4 address by the time it discovers the NAT64 prefix." | complete sentence |
| 4-m | "The node SHOULD NOT wait for an explicit (DHCP Option 108) or an implicit (DHCP timeouts) indication" | ... that IPv4 is absent |
| 4-n | "the node MAY delay enabling CLAT if the NAT64 prefix was discovered via DNS [RFC7050] only" | purpose: "Such a delay minimizes the chance of temporary control of traffic by an attacker"; length "is implementation specific" |
| 4-o | "Nodes implementing this delay MAY provide a configuration option to disable the delay" | |
| 4-p | "If native IPv4 connectivity becomes available later for a given interface, the node MUST disable CLAT" / "for that interface (unless explicitly configured to keep it running)" | |
| 4-q | "the node MUST follow recommendations from Section 4 of [RFC7335] to avoid IPv4 address space conflicts" | with several IPv4-continuity solutions |

**Section 5 (Disabling CLAT)** [V]

| # | Verbatim fragment | Rest |
|---|---|---|
| 5-a | "If the node is not explicitly configured to prefer CLAT over native IPv4 by an administrator," / "the node MUST disable the CLAT instance immediately upon obtaining a native IPv4 default gateway" / "on the interface served by that instance." | complete sentence |
| 5-b | (no keyword) "Disabling CLAT when native IPv4 connectivity is available can be impactful..." | it disrupts every application and flow using the CLAT |
| 5-c | "the node SHOULD support logging the reason for disabling CLAT and any other changes to CLAT configuration" | |
| 5-d | "the logging behaviour SHOULD be configurable" / "The logging SHOULD be disabled by default to avoid performance impacts" | |
| 5-e | "such behaviour MUST be explicitly enabled by the administrator via configuration and MUST NOT be a default behaviour" | "such behaviour" = preferring CLAT while native IPv4 exists |

**Section 7 / 7.1 (multiple prefixes, routers, renumbering)** [V]

- Same PIOs and NAT64 prefix from several routers: "SHOULD only create one CLAT instance using one of the
  PIOs to form a CLAT address".
- Differing information: "the node MAY create one CLAT instance for each tuple of PIO and NAT64 prefix",
  where both "MUST be advertised by the same router"; or "the node MAY create only a single CLAT instance
  using the NAT64 prefix discovered through the selected IPv6" default router. Non-normative text explains
  that a router's PIO and PREF64 must be kept bundled (BCP 38 filtering, PLAT scope).
- "Creating a single CLAT instance significantly simplifies the CLAT state machine."
- 7.1: "The CLAT node SHOULD use at least the following signals to detect link renumbering events:" (prefix
  used for the CLAT address deprecated/invalid; advertising router no longer reachable; router "ceased to
  be a router"); "the node SHOULD disable the CLAT instance(s) affected by the renumbering, and create new
  instance(s)"; "the node MAY send Router Solicitations to obtain the most up-to-date network configuration
  information" and then "MUST follow recommendations specified in Section 6.3.7 of [RFC4861]"; "The node
  MAY react to a potential renumbering event in a "make-before-break" manner".

**Section 9.2 (changes to RFC 8585 section 3.2.1)** [V]

- 464XLAT-0 (new): "The IPv6 Transition CE Router SHOULD follow recommendations provided in THIS DOCUMENT".
- 464XLAT-4 (replaced): "The IPv6 Transition CE Router MUST implement [RFC8781]" and SHOULD implement
  RFC 7050 (RFC 7050 was the MUST before).
- 464XLAT-6 (replaced): "the priority to use one or the other MUST follow this order: 1)[RFC7225]
  2)[RFC8781] and 3)[RFC7050]".
- 464XLAT-7 (new): LAN-side PREF64 and option 108 (not this topic; option 108 out of scope).

**Section 11 (security)** [V]

- "An attacker can provide the CLAT node with an IPv4 address and default gateway, causing the node to
  disable CLAT." (rogue DHCPv4; trade-off acknowledged).
- PREF64 "is less prone to such attacks than DNS-based detection"; for DNS "the risk of local attack can be
  reduced by using encrypted DNS protocols".
- Section 11 words the disable rule as a SHOULD and as "non-link-local IPv4 connectivity", while section 5
  makes it a MUST keyed on "a native IPv4 default gateway". The draft is internally loose here.

**What claton does not say** [V, by targeted query over the whole document]: nothing on what a node does
when the NAT64 prefix is withdrawn, expires, has lifetime zero or changes. Section 7.1 covers the PIO, not
the PREF64. Sections 4 and 5 never mention routers that extend IPv4 downstream; "native IPv4" is scoped to
the interface on which the CLAT instance runs.

### 1.2 RFC 8585 (https://www.rfc-editor.org/rfc/rfc8585.txt) [V]

- 3.2: "This document takes no position on simultaneous operation of one or several transition mechanisms"
  / "and/or native IPv4."
- TRANS-2: "The IPv6 Transition CE Router MUST have a GUI and either a CLI or API (or both)" / "to manually
  enable/disable each of the supported transition mechanisms."
- CONFIG-1: request options for each mechanism, "which MUST remain" / "disabled at this step."
- CONFIG-2: "MUST check for a valid match in OPTION_S46_PRIORITY," / "which allows enabling/disabling a
  transition mechanism."
- CONFIG-3: "Keep disabled all the transition mechanisms if no match is found between the priority list and
  the candidate list," / "unless a NAT64 [RFC6146] prefix has been configured, in which case, 464XLAT
  [RFC6877] MUST be enabled."
- Note: "Because 464XLAT has no DHCPv6 configuration options, it can't currently be included in the
  OPTION_S46_PRIORITY." An operator offering 464XLAT "needs to ensure that OPTION_S46_PRIORITY is not sent"
  for other mechanisms to those customers.
- 464XLAT-4 (original): "MUST implement [RFC7050]"; 464XLAT-6 (original): "1) [RFC7225] and 2) [RFC7050]".
  Both replaced by claton 9.2.
- Closing text: the prefix "could be discovered by means of the method defined in [RFC7050]" / "only if
  the service provider uses DNS64"; a provider may not trust DNS64 "because the DNS configuration at the CE
  (or hosts behind the CE) can be modified by the customer."

Analysis: RFC 8585 has no "native IPv4" test at all. Its only enable rule is CONFIG-3: a **configured**
NAT64 prefix means 464XLAT MUST be enabled. "Configured" predates RFC 8781; with claton a prefix learned
by PREF64 plays the same role (4-c, 4-l). RFC 8585 says nothing about when to disable.

### 1.3 RFC 8781 (https://www.rfc-editor.org/rfc/rfc8781.txt) [V]

- Section 4: Scaled Lifetime = "The maximum time in units of 8 seconds over which this NAT64 prefix MAY be
  used."; "The receiver MUST ignore the PREF64 option if the Length field value is not 2."; "The receiver
  MUST ignore the PREF64 option if the Prefix Length Code field is not set to one of those values."
- 4.1: "The receiver MUST multiply the Scaled Lifetime value by 8"; "A lifetime of 0 indicates that the
  prefix SHOULD NOT be used anymore."; routers: "By default, the value of the Scaled Lifetime field SHOULD
  be set to the lesser of 3 x MaxRtrAdvInterval" (divided by 8) or 8191; "It would be highly undesirable
  for the NAT64 prefix to have a lifetime shorter than the Router Lifetime".
- Section 5: "This option specifies exactly one NAT64 prefix for all IPv4 destinations."; "This option may
  appear more than once in an RA (e.g., when gracefully renumbering the network".
- 5.1: with several RA-learned prefixes, follow RFC 7050 section 3 using only non-zero-lifetime prefixes;
  "When different PREF64s are discovered using multiple mechanisms, hosts SHOULD select one source of
  information only."; "The RECOMMENDED order is:" PCP, then the RA option, then RFC 7050; "The host SHOULD
  treat the PREF64 as being specific to the network interface it was received on."
- 5.2 (routers on a link): "Routers SHOULD inspect valid PREF64 options received on a given link and verify
  the consistency." / "Routers SHOULD log such cases to system or network management."
- Section 7: "if attackers are capable of sending rogue RAs, they can perform denial-of-service or
  man-in-the-middle attacks"; securing RAs would "eliminate the problem of NAT64 prefix validation described
  in Section 3.1 of [RFC7050]."

Not in RFC 8781 [V]: what to do at expiry (only "maximum time ... MAY be used"); what an RA **without** the
option means; whether the prefix is tied to the advertising router (it is tied to the interface);
anything about CLAT or existing flows.

Supporting RFC 4861 facts [V] (https://www.rfc-editor.org/rfc/rfc4861.txt): 6.2.3 "A router MAY choose not
to include some or all options when sending unsolicited Router Advertisements." but "when responding to a
Router Solicitation ... a router SHOULD include all options"; section 10: RTR_SOLICITATION_INTERVAL 4 s,
MAX_RTR_SOLICITATIONS 3, MAX_RA_DELAY_TIME 0.5 s; 6.2.1: MaxRtrAdvInterval default 600 s, range 4-1800 s.
Consequence: a missing option in an unsolicited RA is not a withdrawal; a solicited RA is the reliable
probe; the default PREF64 lifetime is 1800 s (3 x 600).

### 1.4 RFC 7050 (https://www.rfc-editor.org/rfc/rfc7050.txt) [V]

- Section 3: "SHALL send a DNS query for AAAA resource records of the Well-Known" name; "MUST set the
  "Checking Disabled (CD)" bit to zero"; "A node MUST look through all of the received AAAA resource
  records to collect one or more Pref64::/n."; "The node MUST check on octet boundaries to ensure a 32-bit
  well-known IPv4 address value is present only once".
- Multiple prefixes: "a node SHOULD use all of them when determining whether other received IPv6 addresses
  are synthetic."; local synthesis uses them in the order received.
- Failure: "In the case of timeout, the node SHOULD retransmit the DNS query like any other DNS query";
  "In the case of a negative response (NXDOMAIN, NODATA), the node MUST obey the Time to Live (TTL)" before
  asking again.
- Caching: "The node SHALL cache the replies it receives during the Pref64::/n discovery procedure" and
  "it SHOULD repeat the discovery process ten seconds before the TTL of the Well-Known Name's" synthetic
  AAAA record expires.
- When to discover: (lowercase) "a node should perform Pref64::/n discovery only when needed"; example
  trigger "when a new network interface is connected to a new network".
- 3.1 validation: "the node SHOULD communicate with a trusted DNS64 server over a secure channel or use
  DNSSEC."; "DNSSEC validation cannot be utilized in the case of a WKP." 3.1.2 (optional, MAY): PTR lookup of
  Pref64::WKA, compare the NAT64 FQDN's domain with a trusted-domains list, DNSSEC-validate; without a
  trusted domain "the discovery procedure is not secure".
- 3.2 connectivity check: "the node SHOULD perform a connectivity check to ensure the learned Pref64::/n is
  functional."; "Clients MUST NOT send a connectivity check to an address returned by the "ipv4only.arpa."
  query."
- Section 4: "The authoritative name server for the well-known name SHALL have DNS record TTL set to at
  least 60 minutes" (that is the A record TTL; the synthetic AAAA TTL is chosen by the DNS64).
- Section 6: "A node SHOULD implement a configuration knob for disabling the Pref64::/n discovery feature."
- Section 7: a forged prefix enables "a denial-of-service (DoS) attack", flooding or interception;
  "A node SHOULD use the algorithm described in Section 3.1 to validate each" prefix; if trust cannot be
  established "it is better to fail the Pref64::/n discovery procedure."

Not in RFC 7050 [V]: what to do when re-discovery returns a different prefix or none (beyond obeying the
negative TTL); retry counts and timeouts; any statement that an unvalidated prefix must not be used.

### 1.5 RFC 8880 (https://www.rfc-editor.org/rfc/rfc8880.txt) [V]

- 3.1: the query "MUST be sent to the DNS recursive resolver address(es) the client learned via the
  configuration machinery" for that interface; "all queries for 'ipv4only.arpa' and any subdomains of that
  name MUST be sent to the recursive resolver" learned from the network, regardless of manual DNS, VPN or
  loopback resolvers; "clients MUST use interface-aware name resolution APIs."; "The NAT64 prefix is a
  per-interface property, not a per-device property."
- Section 5: "the 'ipv4only.arpa' zone MUST be an insecure delegation"; "DNSSEC-capable resolvers that
  follow this specification MUST NOT attempt to validate answers"; "The 'ipv4only.arpa' query is being used
  purely as a local client-to-middlebox communication message."
- 7.1(4): "Traditional forwarding recursive resolvers SHOULD NOT recognize 'ipv4only.arpa' as special".

Consequence: RFC 8880 removes the DNSSEC validation that RFC 7050 3.1 leaned on. The only trust anchor
for a DNS-learned prefix is "the resolver this uplink told me to use". RFC 8880 section 4 itself calls that
input "untrusted input received from the network".

### 1.6 RFC 9872 (cited by claton section 4) [V]

"Recommendations for Discovering IPv6 Prefix Used for IPv6 Address Synthesis", Informational, September
2025 (https://www.rfc-editor.org/rfc/rfc9872.txt).

- 3.1: "Endpoints SHOULD attempt to obtain PREF64 information from RAs per [RFC8781]"; "In the absence of
  the PREF64 information in RAs, an endpoint MAY choose to fall back" to RFC 7050.
- 3.2: "Network operators deploying NAT64 SHOULD provide PREF64 information in Router Advertisements per
  [RFC8781]."
- Section 4 lists the RFC 7050 weaknesses: custom resolvers break it (4.1); extra round trip (4.2);
  "There is no mechanism for an operator to force the PREF64 rediscovery on the node." (4.3); multihoming:
  "there is no reliable way for a node to map a DNS64 response" to an upstream (4.4); it is "prone to DNS
  spoofing attacks" (4.5).
- It gives no rule for RA and DNS disagreeing.

### 1.7 Derived rule set

**"No native IPv4" for a router.** The standards scope it per uplink interface, never per node:

- 4-a "native IPv4 connectivity over that interface", 4-p "for a given interface", 5-a "a native IPv4
  default gateway on the interface served by that instance", RFC 8781 5.1 and RFC 8880 3.1 "per-interface
  property".
- Native IPv4 is IPv4 "provided by the network" (section 3). A router's self-assigned RFC 1918 LAN
  addresses are not provided by any network, so they never count. Read literally, 4-l ("the node has not
  already obtained a non-link-local IPv4 address") would be false for every router with an IPv4 LAN and the
  CLAT could never start; 4-b limits the section to the IPv6-only interface, which resolves it.
- Two different triggers are named: an address (4-l, enable side) and a default gateway (5-a, disable side).
  For a router the gateway is the meaningful one: an uplink address without a gateway gives no IPv4
  connectivity, and a gateway is what would compete for the default route.
- A native IPv4 gateway on a **different** uplink is outside the MUST of 5-a. 4-e/4-f/4-g explicitly allow
  a CLAT on the IPv6-only uplink of a node that has another interface, each instance with its own IPv4
  default route. Whether to run it then is local policy ("MAY choose ... a subset"). RFC 8585 "takes no
  position".

**Activation (standards minimum)**

- A1. Per uplink. Preconditions: the uplink has usable IPv6; a NAT64 prefix is known for that uplink; the
  uplink has no native IPv4 (address/default gateway). Then the CLAT MUST be enabled unless configured
  otherwise (4-l), immediately for a PREF64-learned prefix (4-c), without waiting for DHCP timeouts (4-m).
- A2. A statically configured prefix also means "enable" (RFC 8585 CONFIG-3). It does not by itself mean
  "prefer CLAT over native IPv4": that needs its own explicit, non-default setting (5-e).
- A3. A DNS-only prefix MAY be delayed (4-n); the delay is optional and its length unspecified.
- A4. Manual enable/disable must exist in GUI plus CLI or API (TRANS-2). "Automatic" is the default state
  of that switch, not a replacement for it.

**Deactivation (standards minimum)**

- D1. Native IPv4 default gateway appears on the CLAT's uplink: MUST disable immediately (5-a, 4-p) unless
  explicitly configured to prefer the CLAT.
- D2. PREF64 lifetime 0: SHOULD NOT use the prefix any more (RFC 8781 4.1). Lifetime elapsed: the "maximum
  time ... MAY be used" has passed. An RA without the option withdraws nothing (RFC 4861 6.2.3).
- D3. RFC 7050: no deactivation rule. Re-query 10 s before TTL expiry (SHOULD); obey the negative TTL (MUST).
- D4. Renumbering of the prefix that hosts the CLAT address: SHOULD disable and recreate; make-before-break
  allowed (7.1).
- D5. Nothing regulates established flows; 5-b only notes that disabling is disruptive.

**Source precedence**

- S1. Order: (PCP,) RA PREF64, then RFC 7050 (claton 464XLAT-6 MUST; RFC 8781 5.1 RECOMMENDED; RFC 9872
  3.1). One source at a time (RFC 8781 5.1 SHOULD). PCP is not implemented here.
- S2. Disagreement between RA and DNS: no document addresses it directly. Applying S1, the RA prefix is
  used and the DNS answer is ignored. RFC 8781 5.2 suggests logging inconsistencies (written for routers
  comparing RAs, but the same spirit).
- S3. Static configuration is outside the discovery order; it overrides it (RFC 8585 CONFIG-3 wording
  "has been configured").

## 2. Proven behaviour

| | Activation trigger | Native IPv4 appears | PREF64 lifetime 0 / expiry | DNS answer gone | Re-discovery cadence | DNS-only trusted like PREF64? |
|---|---|---|---|---|---|---|
| **Android** (Nat464Xlat, IpClientLinkObserver, Dns64Configuration) | global IPv6 address, no IPv4 address on that network, a NAT64 prefix known | CLAT stopped at once | prefix removed at once (alarm at expiry, no grace); falls back to the DNS prefix if one is known | not detected: the DNS thread exits after its first success | RA: passive, expiry alarm. DNS: back-off 1 s to 3600 s until first success, then never again | Yes, no delay, no validation; RA simply wins when both exist |
| **Apple** (IPConfiguration rtadv.c) | NAT64 prefix available (PREF64 first, else "PLAT discovery") and "no IPv4 service published" | CLAT46 address removed on the IPv4-publish event | lifetime 0 drops the prefix; CLAT46 removed when no prefix is left | not established | discovery state cleared at each solicitation cycle; no retry seen in this file | not established (DNS part is outside the file read) |
| **NetworkManager 1.58** (`ipv4.clat`) | RA PREF64 only; `auto` = IPv4 method auto and no native IPv4 default route with a gateway | CLAT disabled on the next config commit, no timer | entry dropped at expiry, or when its advertising router expires; BPF program destroyed immediately | n/a (no DNS discovery) | passive RA processing | n/a |
| **clatd 2.1.0** | started by a network-up script; exits if an IPv4 default route exists after a 10 s delay; prefix from systemd-networkd PREF64 first, else one RFC 7050 query | not noticed while running | not noticed while running | not noticed | none; "(re)started whenever a network interface goes up/down" | Yes; no validation, no connectivity check |
| **OpenWrt 464xlat** | unconditional when the package is installed and no MAP/DS-Lite option was received; prefix by one DNS lookup (+1 retry after 3 s) or static | nothing; relies on route metric 2048 | n/a (no PREF64 consumer) | not noticed | none while up; failed setup is retried about every 3 s forever | Yes; /96 appended to the raw AAAA, no validation |

Evidence:

**Android** [V]
(https://android.googlesource.com/platform/packages/modules/Connectivity/+/refs/heads/main/service/src/com/android/server/connectivity/Nat464Xlat.java)
- `requiresClat()`: comment "Only run clat on networks that have a global IPv6 address and don't have a
  native IPv4"; code `lp.hasGlobalIpv6Address()` and `!lp.hasIpv4Address()`.
- `shouldStartClat()`: `return requiresClat(nai) && lp != null && lp.getNat64Prefix() != null;`
- `selectNat64Prefix()`: `return mNat64PrefixFromRa != null ? mNat64PrefixFromRa : mNat64PrefixFromDns;`
  with the comments that the RA prefix has "better security and updatability" and "If the prefix from the
  RA is withdrawn, fall back to that for reliability purposes."
- `isPrefixDiscoveryNeeded()`: `return requiresClat(mNetwork) && mNat64PrefixFromRa == null;` (DNS
  discovery only runs while there is no RA prefix).
- `update()` in STARTING/RUNNING: `stop()` when `!shouldStartClat`, comment "NAT64 prefix removed, or IPv4
  address added."; otherwise `maybeHandleNat64PrefixChange()`, which stops and re-runs `update()` when
  `selectNat64Prefix()` differs from `mNat64PrefixInUse`. No timers or grace periods in the file.
- IpClientLinkObserver
  (https://android.googlesource.com/platform/packages/modules/NetworkStack/+/refs/heads/main/src/android/net/ip/IpClientLinkObserver.java):
  expiry `now + TimeUnit.SECONDS.toMillis(opt.lifetime)`; an exact alarm at expiry; same prefix again
  extends the expiry; a **different** prefix while the current one is unexpired is ignored: "If we already
  have a prefix, continue using it and ignore the new one." because "Stopping and restarting clatd is
  disruptive because it will break existing IPv4 connections."
- Dns64Configuration
  (https://android.googlesource.com/platform/packages/modules/DnsResolver/+/refs/heads/main/Dns64Configuration.cpp):
  `.withInitialRetransmissionTime(std::chrono::seconds(1))`,
  `.withMaximumRetransmissionTime(std::chrono::seconds(3600))`; on success `recordDns64Config` then `break`
  (thread ends, no TTL refresh); `NET_CONTEXT_FLAG_USE_LOCAL_NAMESERVERS` with the comment "Prefix
  discovery must bypass private DNS because in strict mode the server generally won't know the NAT64
  prefix."; `cfg->prefix64 = IPPrefix(ipv6, 96);` and "Only /96 DNS64 prefixes are supported at this time.";
  "Use only the first result."; TODO "Keep previous prefix for a while".

**Apple** [L - one file, read as a fetched excerpt]
(https://raw.githubusercontent.com/apple-oss-distributions/bootp/main/IPConfiguration.bproj/rtadv.c)
- `rtadv_address_changed_common`: PREF64 from the RA is checked first; otherwise
  `info.perform_plat_discovery = !service_plat_discovery_complete(service_p);`. CLAT46 is set up only under
  the log text "no IPv4 service published, OK to set CLAT46". Removal runs on `IFEventID_ipv4_publish_e`
  and when the prefix list becomes empty (`prefix_count = 0` after a zero lifetime). Log strings
  "RTADV %s: CLAT46 enabled using address", "RTADV %s: PLAT discovery failed". The DNS-based discovery and
  any option-108 logic live in other files that were not read [U].

**NetworkManager** [V]
- Docs (https://networkmanager.dev/docs/api/latest/settings-ipv4.html): "NetworkManager discovers the NAT64
  prefix from IPv6 Router Advertisements;" "1 (auto) enables CLAT only when the IPv4 method is 'auto' and
  the device doesn't have a native IPv4 gateway." "2 (force) enables CLAT even if the IPv4 method is not
  'auto' and even if the device has a native IPv4 gateway." Default resolves to 0 (no); "In the future the
  default fall back value will change to 1 (auto)." NEWS 1.58: "CLAT is still disabled by default for now."
- `nm-ndisc.c` (https://raw.githubusercontent.com/NetworkManager/NetworkManager/main/src/core/ndisc/nm-ndisc.c):
  up to 8 PREF64 entries keyed by prefix, length and gateway; `clean_pref64` drops an entry when its own
  expiry or its gateway's expiry has passed (comment "no gateway no party"); only the first entry, ordered
  by router preference, is exported.
- `nm-l3cfg.c` (https://raw.githubusercontent.com/NetworkManager/NetworkManager/main/src/core/nm-l3cfg.c):
  `_l3cfg_update_clat_config` disables in AUTO when an IPv4 route with `plen == 0` and a non-zero gateway
  exists; CLAT route metric `nm_add_clamped_u32(r4->metric, 1u)` when a native default exists;
  `mtu -= 28;`. `_l3_commit_pref64`: when the prefix or addresses are missing, `_l3_clat_destroy(self);`
  with no delay; a changed prefix is written into the running BPF config (no restart). The DAD comment
  cites "draft-ietf-v6ops-claton-14".

**clatd** [V] (https://raw.githubusercontent.com/toreanderson/clatd/master/clatd and README.pod)
- `sleep($delay)` (default `v4-conncheck-delay` 10) then `ip -4 route list default`; a line matching
  `/^default /` leads to `cleanup_and_exit(0)`. README: the delay exists "to avoid a race condition where
  for example IPv6 SLAAC finshes and triggers a network-up event script" before DHCPv4 has finished.
- Prefix: networkd first ("clatd will first try to determine if systemd-networkd is aware of a PLAT
  prefix,"), then DNS64; all six RFC 6052 lengths and both well-known addresses are checked; "Multiple PLAT
  prefixes discovered (@prefixes), using the first seen"; no prefix: "No PLAT prefix could be discovered.
  Your connection probably doesn't provide" NAT64, exit 0. No main loop; it waits on TAYGA. README: "clatd
  will not attempt to perform a connectivity check to a discovered PLAT prefix before setting up the CLAT."
- `v4-defaultroute-metric` 2048, "higher than that of a native IPv4 default route added by NetworkManager."

**OpenWrt** [V] (local clone)
- `REFS/openwrt/package/network/ipv6/odhcp6c/files/dhcpv6.script:208`
  `elif [ "$IFACE_464XLAT" != 0 ] && [ -f /lib/netifd/proto/464xlat.sh ]; then` - the last fall-through
  after MAP and DS-Lite, with no NAT64 or IPv4 test.
- `REFS/openwrt/package/network/ipv6/464xlat/src/464xlatcfg.c:66-69` one `getaddrinfo("ipv4only.arpa", ...)`,
  `sleep(3)`, one retry, `return 2`; `:74` `strcat(prefix, "/96");`.
- `REFS/openwrt/package/network/ipv6/464xlat/files/464xlat.sh:52`
  `proto_add_ipv4_route "0.0.0.0" 0 "" "" 2048`; `:102-103` teardown
  `echo 192.0.0.1 > /proc/net/nf_conntrack` ("Kill conntracks SNATed to 192.0.0.1").
- The endless retry loop every ~3 s when no NAT64 exists is OpenWrt's most-reported 464xlat defect
  (openwrt/openwrt#10907, earlier report `openwrt-464xlat.md` section 8.1).

Patterns worth copying:

1. Every host implementation treats "native IPv4 present" as an immediate stop with no hold timer
   (Android, Apple, NetworkManager). Only clatd adds a start-up delay (10 s) to let DHCPv4 finish first.
2. RA-learned prefixes are strict: removed exactly at lifetime 0 or expiry (Android, NetworkManager,
   Apple). DNS-learned prefixes are sticky everywhere: nobody re-queries after the first success, so a
   DNS-learned prefix lives as long as the network attachment.
3. Android refuses to switch to a different RA prefix while the current one is still valid, to protect
   flows; NetworkManager ties the prefix to its advertising router.
4. Nobody implements the optional claton delay for DNS-only discovery, and nobody validates a DNS-learned
   prefix beyond parsing it. Android bypasses private DNS so the query reaches the network's own resolver.
5. No implementation retries a failed discovery in a tight loop except OpenWrt, where it is a known bug;
   Android backs off from 1 s to 1 hour.

## 3. "No native IPv4" as a computable predicate on OPNsense

### 3.1 What core does (facts)

- F1 [V]. A dynamic IPv4 gateway exists for an enabled, non-virtual interface exactly when
  `/tmp/<dev>_router` exists: `Gateways.php:435`
  `} elseif (($router = Autoconf::getRouter($device, $ipproto)) != null) {`; `Autoconf.php:40-44` reads
  `"/tmp/{$if}{$isuffix}_{$type}{$fsuffix}"`. The device's addresses are not checked at that point.
- F2 [V]. Writers of the IPv4 router file: `dhclient-script:44` and `:143`
  (`ifctl -i ${interface} -4rd -a ${new_routers}`), `ppp-linkup.sh:28` (IPCP up), OpenVPN, GIF/GRE.
  Removers: `dhclient-script:193` (**PREINIT**, i.e. every dhclient (re)start), `:109` (old routes on
  address change/expiry), `ppp-linkdown.sh:14`, and `interfaces.inc:908`
  (`ifctl -4c -i %s` in the interface reset).
- F3 [V]. On a PPP uplink whose IPv4 type is None, IPCP cannot come up: `interfaces.inc:1059-1066` sets
  `$ipv4_mode = 'enable'` only for `ppp`/`pppoe`/`l2tp`, and `:1172` emits `set bundle {$ipv4_mode} ipcp`.
  Native IPv4 on such an uplink is structurally impossible until the user changes the IPv4 type.
- F4 [V]. Gateway ranking: `Gateways.php:322`
  `return sprintf("%01d%04d%010d", $is_default, 256 - $prio, $this->gatewaySeq++);` and `:471`
  `krsort($this->cached_gateways);`. Order is: upstream flag, then lower priority number, then **later
  sequence first**. Dynamic gateways default to priority 254, or 255 only for device names starting with
  gre/gif/ovpn/wg/ipsec (`:412-421`). The CLAT interface is registered after the user's interfaces, so at
  254 `CLAT_GW` outranks every other default-priority dynamic gateway and every static gateway item left at
  its default 255 without the upstream flag.
- F5 [V]. `getDefaultGW()` (`Gateways.php:493-513`) returns the first entry that is not disabled, defunct,
  loopback, `force_down` or in the caller's skip list. The skip list is filled only when gateway switching
  is on: `system.inc:690` `if (isset($config['system']['gw_switch_default']) && $monitor !== 'ignore') {`.
- F6 [V]. If the chosen gateway's device has no address, core sets no default route and tries nobody else:
  `system.inc:714-716` "ROUTING: refusing to set {$ipproto} gateway on addressless ..." then `continue`.
- F7 [V]. A WAN's own IPv4 event re-evaluates the default route only for that interface unless gateway
  switching is on: `rc.newwanip:123` `system_routing_configure(false, $interfaces, true, $family);` and
  `system.inc:713`
  `if (isset($config['system']['gw_switch_default']) || empty($interface_map) || in_array($gateway['interface'], $interface_map)) {`.
  So while `CLAT_GW` is top-ranked, a native WAN that comes up does **not** take the default route by
  itself; it gets it only after the CLAT gateway is gone and an unscoped routing run happens
  (`configctl interface routes configure`, `actions_interface.conf:166-170`).
- F8 [V]. Changing the default route is delete-then-add: `system.inc:653-654`
  `mwexecfm('/sbin/route delete -%s default', [$family]);` /
  `mwexecf('/sbin/route add -%s default %s', [$family, $gateway]);`. The FIB has no IPv4 default for an
  instant on every change.
- F9 [V]. Plugin events for IPv4: `rc.newwanip:143` `plugins_configure('newwanip', false, [$interfaces, $family]);`
  is reached only when the interface has an IPv4 address (`:65-69` "Failed to detect IP for interface" then
  `return`) and the address changed or the call was forced (`:79-82`). So "native IPv4 appeared" raises an
  event; "native IPv4 disappeared" raises none.
- F10 [V]. `ifctl -4r` without `-i` lists every device that has a router file (`ifctl.sh:236-257`,
  "list all interfaces that have the requested file").
- F11 [V]. `configctl interface gateways status` (`actions_interface.conf:193-196`, no cache) prints name,
  address and dpinger status for `gatewaysIndexedByName()` (`gateway_status.php`); unmonitored gateways
  report `none` = online. `configctl interface gateways list` is cached for 20 s
  (`actions_interface.conf:186-191` `cache_ttl:20`).
- F12 [V]. The Gateways model is mounted at `//OPNsense/Gateways` (`Gateways.xml:2`) and falls back to
  the legacy `<gateways>` section (`Gateways.php:210-254`). Static gateways therefore live in one of two
  places; re-implementing the lookup in Python would duplicate core logic.

### 3.2 Candidate definitions

| Candidate | Cheap? | Reliable? | Verdict |
|---|---|---|---|
| C1. Uplink device has no non-link-local IPv4 address and no `/tmp/<dev>_router` | yes: `os.path.exists` plus the address list the supervisor already tracks through the routing socket | yes; both facts are set and cleared by core scripts (F2). Matches claton 4-l/5-a exactly. With IPv4 type None it is constant (F3) | **Necessary. This is the standards predicate.** |
| C2. No other enabled interface has an IPv4 gateway | medium: needs core's gateway list (F1, F12). A glob on `/tmp/*_router` covers dynamic gateways only | reliable if taken from the Gateways model; must additionally require an IPv4 address on the gateway's device (F6), or a leftover static gateway on an address-less interface blocks the CLAT for ever | **Needed for multi-WAN safety** (F4, F7). Not required by the standards. |
| C3. IPv4 default route in the FIB is absent or is the CLAT's own | yes: `route -n get -inet default` or the routing socket | **not as a trigger**: (a) while the CLAT is up and top-ranked the FIB default stays on the CLAT although native IPv4 has appeared (F4, F7); (b) the default route vanishes briefly on every change (F8); (c) "absent" is also what a blocked configuration looks like (F6) | Use only as a post-activation health check ("CLAT is up but is not the default route: gateway X is preferred"). |

Addresses on other devices must not be used as a signal: a static management address on the PPPoE parent
NIC (for the modem's web page), VPN tunnels and the LANs all carry IPv4 without providing an uplink.

### 3.3 Recommended predicate

```
N_uplink  := uplink device has an IPv4 address outside 169.254.0.0/16
             OR /tmp/<uplink device>_router exists and is non-empty
N_other   := some gateway g in core's list with
               g.ipprotocol == inet, g.gateway is an address, not disabled/defunct/loopback,
               g.if != tun464,
               device g.if currently has an IPv4 address
NATIVE    := N_uplink OR N_other            (mode Automatic)
NATIVE    := false                          (explicit "keep CLAT when native IPv4 exists")
```

- `N_uplink` is the claton rule (MUST). `N_other` is the router-specific extension.
- Gateways that dpinger reports as down still count as native in version 1. Dynamic gateways are
  unmonitored by default ("monitor_disable" => '1', `Gateways.php:404`), so "down" is rarely available, and
  treating down as absent would make the CLAT follow dpinger loss flaps. Using the CLAT as IPv4 fail-over is
  the job of the explicit coexistence mode (3.6).
- A gateway that outranks the CLAT but sits on an address-less device (F6) is not native; it is a
  configuration fault to report ("stale IPv4 gateway X prevents any IPv4 default route").

### 3.4 Facts available to the Python supervisor

| Fact | How | Cost | Notes |
|---|---|---|---|
| Uplink device name, uplink IPv4 type, whether any interface expects dynamic IPv4 | rendered into the supervisor's own config file by the plugin template at every reconfigure | none at run time | changes only with config.xml |
| IPv4/IPv6 addresses per device, link state, device arrival/departure | routing socket (RTM_NEWADDR/DELADDR/IFINFO/IFANNOUNCE), which the supervisor already needs | none | catches "native IPv4 disappeared", for which core raises no event (F9) |
| `/tmp/<dev>_router`, `/tmp/<dev>_routerv6`, `/tmp/<dev>_prefixv6`, nameserver files | `os.path.exists` / read; `ifctl -4r` lists all devices with a router file (F10) | negligible | no file-change notification; read at every reconcile |
| Core's ranked gateway list incl. static gateways, priority, upstream flag, dpinger status | a small PHP helper shipped by the plugin that instantiates `\OPNsense\Routing\Gateways` and prints JSON (same pattern as core's `gateways.php`/`gateway_status.php`) | one PHP start (about 0.1-0.3 s) | call only from the debounced reconcile, and only when the cheap facts changed or every 60 s |
| "IPv4 appeared on interface X" | existing `newwanip` hook with family `inet` (F9) | none | accelerator only |
| FIB IPv4 default route | routing socket or `route -n get -inet default` | negligible | health check only (C3) |

### 3.5 Hysteresis

The asymmetry follows the standards: "native appeared" is a MUST-disable-immediately; "native gone" has
no deadline.

| Edge | Rule | Why |
|---|---|---|
| NATIVE false -> true | act after the normal 2 s event debounce; no extra hold | claton 5-a "immediately"; F7: native IPv4 cannot take the default route until the CLAT gateway is withdrawn |
| NATIVE true -> false | require NATIVE to stay false for `T_native_hold` = 60 s before the CLAT may activate | dhclient removes the router file at PREINIT (every dhclient start: link bounce, interface apply) and on an address change, and re-adds it at BOUND (F2; a plain RENEW with an unchanged address does not touch the file); a PPPoE renegotiation with IPCP removes and re-adds it (ppp-linkdown/-linkup). 60 s rides out a link bounce, a dhclient restart and a redial, and still lets the CLAT take over when native IPv4 is really gone |
| Start-up, NATIVE false, but some enabled interface is configured for dynamic IPv4 (`ipaddr` in dhcp/ppp/pppoe/l2tp) and has not produced a gateway yet | wait `T_v4_settle` = 10 s after daemon start or after that interface's link-up | avoids an up-then-down flap when PREF64 arrives before the DHCPv4 lease; clatd uses the same 10 s for the same race. Deviation from 4-m (SHOULD NOT wait), justified by the cost of a flap on a router (routing run, filter reload, state kill) |
| Start-up, NATIVE false, no interface expects dynamic IPv4 (the ISP's standard customer: WAN IPv4 = None) | no delay at all | 4-c, 4-l, 4-m |
| Uplink (PPPoE) drops and returns, no IPCP | not a NATIVE event at all (F3). Handled by SUSPENDED/REVALIDATING in section 4, without teardown | the predicate does not move, so it cannot flap |

Restart rate limit: at most one full bring-up per 30 s, and after 5 bring-ups in 10 minutes back off for
5 minutes with a visible error state. This bounds any oscillation that the rules above did not foresee.

### 3.6 Multi-WAN: stay down, or come up at lower priority?

Recommendation for version 1: **stay down by default** while any other usable native IPv4 gateway exists;
offer coexistence only as an explicit advanced setting.

Reasons:

1. "Lower priority" is not available without persistent configuration. A dynamic gateway on `tun464` gets
   priority 254 and, being registered last, wins every tie (F4). Priority 255 is given only to
   gre/gif/ovpn/wg/ipsec device names. The only way to rank the CLAT below native IPv4 is a
   `gateway_item` for the CLAT interface written into config.xml, which the zero-touch model has avoided
   so far.
2. With the CLAT gateway present at 254, native IPv4 on another WAN never becomes the default route (F4,
   F7), which is the opposite of what a multi-WAN user expects and of claton's intent (4-a: performance
   and security).
3. The standards allow either choice: 4-e "MAY choose to enable CLAT on a subset of its interfaces"; RFC
   8585 "takes no position on simultaneous operation".
4. The CLAT gateway is unmonitored and its peer is tayga itself, so gateway switching can never fail away
   from it; in a fail-over design it must be the last tier, which again needs explicit priorities.

Coexistence mode (explicit, not default; this is claton's "explicitly configured" case, 5-e): the CLAT runs
whenever its own uplink qualifies (`N_other` ignored, `N_uplink` still honoured unless the user also forces
that). The administrator ranks `CLAT_GW` in System > Gateways (an entry for the CLAT interface with
priority 255 or a gateway group tier). The status page must say when `CLAT_GW` outranks a native gateway.
Whether the plugin may create that gateway entry itself is a design decision (open question 3).

## 4. Deactivation on prefix loss

### 4.1 Rules

Prefix identity is (prefix, length). Each source keeps its own entry; selection runs after every change.

**RA entry (RFC 8781)**

- P1. Valid while lifetime > 0, not expired, and received from the uplink's current default router.
  Removed at once on lifetime 0 (RFC 8781 4.1) and at expiry. An RA without option 38 changes nothing
  (RFC 4861 6.2.3).
- P2. Refresh: the listener is long-running, so unsolicited RAs refresh the entry. If the remaining
  lifetime falls below max(30 s, lifetime/4) without a refresh, send one RS burst (up to 3, 4 s apart, stop
  at the first RA; RFC 4861 section 10, claton 7.1). With the RFC 8781 default lifetime of 3 x
  MaxRtrAdvInterval this fires only when two unsolicited RAs were missed or carried no option.
- P3. No grace beyond the lifetime: RFC 8781 calls it the "maximum time" of use, and Android, Apple and
  NetworkManager all remove at expiry.

**DNS entry (RFC 7050)**

- P4. Re-query 10 s before TTL expiry (RFC 7050 SHOULD), with the refresh interval clamped to
  [60 s, 24 h]. Query every resolver learned on the uplink.
- P5. Positive answer with the same prefix: refresh. Positive answer with a different prefix: see P9.
- P6. Negative answer (NODATA/NXDOMAIN) from all uplink resolvers in two consecutive rounds at least
  max(negative TTL, 30 s) apart: entry removed. One negative round, or negative from only some resolvers:
  keep. (RFC 7050 only requires obeying the negative TTL; two rounds guard against one misconfigured
  resolver.)
- P7. Timeout, SERVFAIL or unreachable resolvers are not evidence that NAT64 is gone: keep the entry
  ("sticky"), retry with back-off, and drop it only after `T_stale_max` = 1 h without any successful
  confirmation. Every surveyed implementation keeps a DNS-learned prefix for the whole attachment.

**Selection and switching**

- P8. Order: static, RA, DNS (S1, S3). If the selected prefix is unchanged, a change of source is only a
  relabel: nothing restarts.
- P9. Stickiness within a source: a different prefix from the same source does not replace the one in use
  while that one is still valid (Android). Across sources the RA wins: when a valid RA prefix differs from
  the DNS prefix in use, restart with the RA prefix; when the RA is in use and DNS disagrees, ignore DNS
  and log the inconsistency once per distinct pair.
- P10. RA entry removed: fall back to the DNS entry (query at once if there is none). Same prefix: carry on.
  Different prefix: restart. Nothing: deactivate. After an explicit lifetime 0 there is no further grace;
  after an expiry the RS burst of P2 has already been the grace.

**Uplink loss and return (keep-last-known across a PPP reconnect)**

- P11. Uplink down (device gone or no IPv6 default router): state SUSPENDED. Keep tayga, the tun, the
  routes and the router file. Do not evaluate prefix expiry or DNS while suspended: nothing can be
  learned and nothing can flow. LAN hosts get fast ICMP errors from tayga instead of time-outs.
- P12. Uplink back: state REVALIDATING for `W_reval` = 30 s. Send the RS burst and a DNS round
  immediately. The entries from the previous session are "stale but usable". Outcomes:
  same prefix confirmed by any source, CLAT address pair unchanged -> RUNNING without a restart;
  different prefix or pair -> restart; a solicited RA without option 38 **and** a confirmed negative DNS
  answer -> deactivate; no evidence either way within 30 s (resolvers unreachable) -> keep running on the
  stale DNS entry under P7, but a stale RA entry is dropped at the end of the window (a working BNG
  answers an RS within 0.5 s, RFC 4861 MAX_RA_DELAY_TIME).

### 4.2 Established flows

| Change | Effect on flows | Action |
|---|---|---|
| Source relabel, same prefix | none | none |
| Uplink flap, same prefix and same CLAT address | TCP survives if the outage is shorter than the endpoints' and the PLAT's time-outs; NAT44 states on the box are untouched | none (P11/P12) |
| Prefix or prefix length changed | all CLAT flows break: tayga 0.9.6 must be restarted (no reload) and the PLAT side is a different mapping | restart; kill pf states on `tun464` so LAN hosts fail fast |
| CLAT address pair changed (PD renumbering) | all CLAT flows break (the PLAT's sessions are keyed on the old IPv6 source) | restart; kill states (claton 7.1: disable and recreate) |
| Deactivation (prefix lost, native IPv4 appeared, disabled) | all CLAT flows break; flows cannot migrate to a native path because the source address changes (claton 5-b) | withdraw the router file, run an unscoped routing and filter update, kill states on `tun464`, stop tayga. OpenWrt does the same ("Kill conntracks SNATed to 192.0.0.1") |

## 5. Edge cases

| Case | Rule | Basis |
|---|---|---|
| DNS-only discovery through a hostile or misconfigured resolver | (1) Query only resolvers learned on the uplink (`ifctl -6n -i <dev>`), never Unbound or user-set servers (RFC 8880 3.1, claton 4-j). (2) Plausibility filter, below. (3) Settle delay: do not activate on a DNS-only prefix until the RA probe is done, i.e. the first solicited RA from the default router has arrived (with or without option 38) or the RS burst has ended (about 13 s). (4) No connectivity check against the returned address (RFC 7050 3.2 MUST NOT). | claton 4-n allows the delay; on a PPP link the resolver addresses and the RA come from the same BNG, so the DNS answer is not materially less trusted than the RA; the delay mainly prevents a restart when the RA arrives a moment later |
| Plausibility filter (both sources) | Length in {32,40,48,56,64,96}; bits 64-71 zero for lengths other than 96; mask to length; reject unspecified, loopback, link-local, multicast, IPv4-mapped and 2001:db8::/32; reject anything overlapping a prefix the box itself uses (delegated prefix, WAN /64, LAN /64s, the CLAT pair); for DNS additionally require 192.0.0.170/171 at an octet boundary exactly once per answer and parse every AAAA | RFC 6052 2.2; RFC 7050 section 3; the overlap test stops translated traffic from being routed into a LAN |
| PREF64 and DNS64 give different prefixes | Use the RA prefix; ignore DNS; log once | S1, S2; Android `selectNat64Prefix()` |
| DNS-only CLAT is running and an RA later announces a different prefix | Restart with the RA prefix (cross-source precedence, P9). The settle delay makes this rare | 464XLAT-6 MUST |
| Several PREF64 options in one RA | Keep all non-zero entries; select the one in use if still present, otherwise the first in option order | RFC 8781 5/5.1 (renumbering case); Android stickiness; clatd "using the first seen". tayga takes one prefix |
| Several routers | Accept PREF64 only from the uplink's current IPv6 default router; drop the entry when that router's lifetime ends or the default router changes | claton section 7 (keep a router's information bundled; single instance via the selected default router); NetworkManager "no gateway no party". A PPP link has one router, so this is defensive |
| Prefix length changes | It is a different prefix: P9 applies (ignored while the old one is valid from the same source; restart once the old one is withdrawn or expires) | identity is (prefix, length) |
| Discovery succeeds before the delegated prefix has arrived | State WAIT_ADDR: no tayga start. Wait for the PD up to `T_pd_wait` = 30 s after uplink-up before falling back to the WAN SLAAC /64; once running on the fallback, do not move to the PD until the next restart for another reason | the ISP always delegates; the PD-change hook (`rc.newwanipv6:125`) and the reconcile poll end the wait; avoids an immediate restart |
| Discovery only possible after IPv6 is up at boot | State WAIT_UPLINK until the uplink device exists, has a link-local address and an IPv6 default router; then RS at once, DNS as soon as resolvers are listed. DNS to a global resolver needs a global source address, which on a PD-only WAN exists only after the PD has been assigned to a LAN, so DNS failures here are normal and are retried on every address/route event and with back-off | boot order: deferred WAN events are replayed before rc.d services start (earlier report) |
| No NAT64 at all (customer of another ISP installs the plugin) | DISCOVERING for ever with back-off: RS burst once per uplink-up, then passive listening; DNS at 1, 2, 4 ... up to 300 s, and after a negative answer at max(negative TTL, 60 s) capped at 1 h. One log line per state change, none per attempt | avoids OpenWrt's 3 s loop; Android backs off to 1 h; RFC 7050 negative-TTL MUST |
| Stale IPv4 gateway on an address-less interface outranks the CLAT | Not "native"; CLAT activates but core installs no default route (F6). Report as a fault with the gateway's name | 3.3 |
| Another user of 192.0.0.0/29 (DS-Lite, os-tayga) | Preflight failure, do not activate | claton 4-q, RFC 7335 section 4 |

## 6. Settings once activation is automatic

Keep:

| Setting | Values / default | Why it must stay |
|---|---|---|
| **Mode** | Automatic (default) / Disabled | RFC 8585 TRANS-2 requires a manual enable/disable in the GUI and API. Replaces both "Enabled" and "Activation" of the draft design |
| Uplink interface | default `wan` | the per-interface scope of every rule above |
| NAT64 prefix (advanced) | empty = discover | RFC 8585 CONFIG-3; escape hatch when neither RA nor DNS is offered. Setting it switches discovery off and activates without discovery, still subject to the native-IPv4 rule |
| DNS discovery (advanced) | on | RFC 7050 section 6 SHOULD: a knob to disable it. Off = RA only |
| Keep CLAT when native IPv4 exists (advanced) | off | claton 5-e: allowed only as explicit, non-default configuration. This is also the multi-WAN coexistence switch |
| Log level (advanced) | state changes only | claton 5-c/5-d: logging of reasons, configurable. One line per transition has no performance cost |
| CLAT IPv6 address, MSS clamp, automatic firewall rule, automatic interface registration, IPv4 addresses, UDP checksum mode, MTU override | unchanged | not activation-related |

Remove:

- The separate "Enabled" checkbox and the "Activation: auto / always" selector (merged into Mode plus the
  one advanced checkbox).
- The "Discovery methods: PREF64 + RFC 7050" multi-select. PREF64 needs no off switch: it is the MUST
  mechanism, has precedence and is harmless when absent.
- The "assume the well-known prefix" switch from design section 6; typing `64:ff9b::/96` into the static
  prefix field does the same, and a hard-coded prefix is not wanted.
- No knob for the DNS-only settle delay (claton 4-o is a MAY; the delay ends by itself within about 13 s).
- No timers in the GUI; they are constants in the supervisor.

Default after installation: Mode = Automatic. This is safe because of the gates: without a discovered
prefix, or with native IPv4, the plugin stays dormant.

## 7. Recommended state machine

### 7.1 Inputs

```
MODE      Automatic | Disabled            (+ flag KEEP_WITH_NATIVE)
UP6       uplink device present, link-local address, IPv6 default router known
P         selected prefix (source, prefix/len) per section 4; P_ok = selected and plausible
A6        CLAT /127 pair derivable (PD present, or SLAAC /64 after T_pd_wait)
NATIVE    section 3.3, filtered by section 3.5  (NATIVE* below)
GEN       hash(P, A6 pair, WAN IPv6 MTU)        (what tayga was started with)
```

### 7.2 States and transitions

| State | Meaning | Event / condition | Action | Next |
|---|---|---|---|---|
| DISABLED | Mode = Disabled | Mode -> Automatic | start listeners | WAIT_UPLINK |
| PREFLIGHT_FAILED(reason) | cannot run (tayga missing, 192.0.0.0/29 in use, uplink IPv4 type PPPoE without IPCP so IPv6 never starts) | cause cleared (re-checked every reconcile) | | WAIT_UPLINK |
| WAIT_UPLINK | no usable IPv6 uplink | UP6 | RS burst; DNS round when resolvers known; start `T_pd_wait` | DISCOVERING |
| DISCOVERING | UP6, no valid prefix | P_ok | | HOLD_NATIVE if NATIVE*, else PENDING |
| | no prefix | back-off per section 5; keep listening | DISCOVERING |
| | not UP6 | | WAIT_UPLINK |
| HOLD_NATIVE | prefix may be known; native IPv4 present; CLAT dormant | NATIVE false continuously for `T_native_hold` | | PENDING (or DISCOVERING if no P_ok) |
| | prefix events | update entries only | HOLD_NATIVE |
| PENDING | prefix known, no native IPv4; waiting for guards | all guards true: A6; `T_v4_settle` elapsed if dynamic IPv4 is expected; DNS-only settle done if P.source = DNS; rate limit allows | bring-up (design section 8 steps 1-7), record GEN | RUNNING |
| | NATIVE* | | HOLD_NATIVE |
| | prefix lost | | DISCOVERING |
| | A6 missing after `T_pd_wait` and no fallback | status "waiting for delegated prefix" | PENDING |
| RUNNING | tayga up, router file present | NATIVE* (debounced 2 s) | teardown | HOLD_NATIVE |
| | Mode -> Disabled | teardown | DISABLED |
| | prefix lost per P1-P10 | teardown | DISCOVERING |
| | GEN changed (prefix switch per P9/P10, pair, MTU) | restart (teardown of datapath, bring-up), kill states | RUNNING |
| | source relabel, refresh, RA without option, DNS disagreement | update bookkeeping, log if new | RUNNING |
| | not UP6 | freeze prefix timers | SUSPENDED |
| | tayga exited | remove router file | ERROR |
| SUSPENDED | was RUNNING, uplink lost; datapath kept | UP6 | RS burst + DNS round; start `W_reval` | REVALIDATING |
| | NATIVE* or Mode -> Disabled | teardown | HOLD_NATIVE / DISABLED |
| REVALIDATING | uplink back, inputs from the previous session provisional | same prefix confirmed and same pair | | RUNNING |
| | different prefix or pair | restart | RUNNING |
| | confirmed absence (solicited RA without option 38 and negative DNS), or stale RA entry unconfirmed at end of `W_reval` with no DNS entry | teardown | DISCOVERING |
| | `W_reval` over, only an unconfirmed DNS entry | continue under P7 | RUNNING |
| ERROR(retry_at) | bring-up failed or tayga crashed | timer (5, 10, 20 ... 300 s) | | WAIT_UPLINK |

Teardown = remove the router file, run an unscoped routing and filter update, kill states on `tun464`,
stop tayga, delete the /127 route. The interface record and the pass rule stay registered while Mode is
Automatic; a dormant CLAT has no address and no router file, hence no gateway and no NAT rule (F1).

### 7.3 Timers

| Timer | Value | Source of the value |
|---|---|---|
| Event debounce | 2 s | existing design |
| Reconcile poll | 60 s | existing design |
| RS burst | up to 3 RS, 4 s apart, stop at first RA | RFC 4861 section 10 |
| RA refresh probe | when remaining < max(30 s, lifetime/4) | design choice (P2) |
| DNS-only settle | until first solicited RA or end of RS burst (about 13 s) | claton 4-n (MAY) |
| DNS discovery back-off | 1, 2, 4 ... 300 s; after a negative answer max(negative TTL, 60 s), cap 1 h | RFC 7050 section 3; Android 1 s-3600 s |
| DNS refresh | TTL - 10 s, clamped to 60 s-24 h | RFC 7050 section 3 |
| DNS negative confirmation | 2 rounds, at least max(negative TTL, 30 s) apart | design choice (P6) |
| `T_stale_max` | 1 h | design choice (P7) |
| `T_native_hold` | 60 s | estimate from F2 (dhclient PREINIT/BOUND, PPP redial); dhclient timing not read from source (open question 6) |
| `T_v4_settle` | 10 s, only if dynamic IPv4 is expected somewhere | clatd `v4-conncheck-delay` |
| `T_pd_wait` | 30 s | design choice |
| `W_reval` | 30 s | RS burst plus margin |
| Restart rate limit | 1 per 30 s; 5 per 10 min then 5 min pause | design choice |
| Error back-off | 5 s doubling to 300 s | existing design |

The values marked "design choice" are not derived from a standard; they should be constants that the lab
phase can tune, not settings.

## 8. Changes this implies for DESIGN.md

- Section 1/10: "tick enable" becomes "install"; Mode defaults to Automatic.
- Section 4 D9: order stays static > PREF64 > RFC 7050; add the switching rules P8-P10.
- Section 4 D11: "stay down while the uplink has native IPv4" becomes the two-part predicate of 3.3.
- Section 6: drop "assume the well-known prefix"; add plausibility filter, DNS-only settle, negative
  confirmation, stickiness.
- Section 7.2: `clat_interfaces()` returns the record whenever Mode is Automatic, not only when the CLAT is
  up; activation must not write config.xml.
- Section 8: states become those of 7.2 (adds HOLD_NATIVE hysteresis, PENDING guards, SUSPENDED,
  REVALIDATING); teardown must trigger an unscoped routing run (F7).
- Section 9: preflight "another IPv4 gateway is upstream or below 254" splits into "native IPv4 present
  (dormant, normal)" and "stale gateway blocks the default route (fault)".

## 9. Open questions

1. ISP: does the BNG put PREF64 into solicited RAs on the PPP link, with which lifetime and RA interval?
   Which TTL do the resolvers give the synthetic AAAA for ipv4only.arpa? Are the resolvers handed out as
   global addresses (DHCPv6) or as link-local RDNSS?
2. Lab: with only a link-local address plus a PD on the WAN, which source address does a DNS query to a
   global resolver get before the PD is assigned to a LAN, and does the BNG accept it?
3. Design: may the plugin write a `gateway_item` (priority 255) for the CLAT interface so that a
   coexistence mode can rank the CLAT below native IPv4 automatically, or must the user do that?
4. Design: is "Mode = Automatic right after installation" acceptable, also for a later submission to
   opnsense/plugins, where services normally ship disabled?
5. Lab: the equal-priority tie-break (F4) and the scoped routing run (F7) are code readings; confirm that
   a second WAN's DHCPv4 lease does not take the default route while `CLAT_GW` exists, and that it does
   after teardown plus `configctl interface routes configure`.
6. FreeBSD dhclient timing on OPNsense (time-out and retry defaults, how long the router file is absent on
   a renew) was not read from source; `T_native_hold` = 60 s is an estimate.
7. Apple's DNS-based PLAT discovery (retry, TTL handling, trust) was not read; only `rtadv.c` was.
8. Is a registered but dormant `clat` interface (no address, no gateway) free of side effects in the GUI
   and in the generated rules? Code reading says it is inert; not tested.
9. claton is still in the RFC Editor queue; AUTH48 may change the wording of sections 4, 5 and 11 (the
   MUST/SHOULD mismatch noted in 1.1).
10. Should gateways that dpinger reports as down stop counting as native (automatic IPv4 fail-over to the
    CLAT)? Deliberately excluded from version 1.
