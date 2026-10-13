# Gap 4 — How a plugin can learn PREF64 (RA option 38) on `pppoeN` on OPNsense 26.7 / FreeBSD 15

Research date: 2026-10-11. Research only, no design.

**Path convention.** `refs/` = local clones (not in this repository).
`src` = `refs/opnsense-src` (opnsense/src `stable/26.7`), `core` = `refs/opnsense-core` (opnsense/core master).
Files outside the sparse clone were read from `raw.githubusercontent.com/opnsense/src/stable/26.7/...`.

**Confidence labels.** *verified* = the primary source was read (local clone, or a fetched excerpt of the upstream
file; quotes are short). *likely* = follows from that source but was not run. *unverified* = from a search
summary only, or not checked against a source. **Nothing here was run on a live OPNsense box.**

---

## 0. Headline answers

| Question | Answer | Confidence |
|---|---|---|
| (a) Does a raw ICMPv6 socket get RAs on `pppoeN` while rtsold and the kernel also use them? | Yes by code path. `icmp6_input()` copies every RA, gives one copy to the kernel (`nd6_ra_input`) and delivers the other to **every** raw ICMPv6 socket whose filter passes type 134. rtsold's socket is just one of those sockets. Delivery does not depend on `accept_rtadv`. | code path verified; end-to-end likely |
| (a) Do core's default pf rules pass them? | Yes. Automatic "IPv6 RFC4890 requirements" rules (priority 1, quick) pass type 134 inbound from `fe80::/10` to `fe80::/10,ff02::/16` and type 133 outbound from `(self)`. Not present if "Disable RFC4890 requirement rules" is ticked or IPv6 is disallowed. | verified |
| (b) How is an RA triggered? | Send an 8-byte Router Solicitation to `ff02::2%pppoeN` with hop limit 255 from a raw ICMPv6 socket. rtsold does this only at its own start (max 3 RS, 4 s apart) and never again once it is idle. | verified (code) |
| (b) How often does a BNG send unsolicited RAs? | RFC 4861 default every 200–600 s (max allowed 1800 s). Junos default 600 s; Nokia SR OS subscriber default 900–1800 s. Unsolicited RAs MAY omit options; solicited RAs SHOULD carry all of them. | verified (RFC, vendor docs) |
| (c) Lifetime / PLC / withdrawal | `lifetime_s = field & 0xFFF8`, `plc = field & 7`, length table `[96,64,56,48,40,32]`; ignore the option if option length != 2 or PLC > 5; lifetime 0 = stop using; missing option in one RA is not a withdrawal. | verified (RFC 8781, 4 implementations) |
| (d) Existing parser? | Four readable ones (systemd, libndp/NetworkManager, Android, radvd's `radvdump`). The decode is about 15 lines. `radvdump` is **already installed** on OPNsense and prints PREF64. odhcp6c, dhcpcd, FreeBSD rtsold (26.7 and FreeBSD main) and base tcpdump do not parse it. | verified |
| (e) Does `drill` accept `fe80::1%pppoe0`? | No. ldns parses the server with plain `inet_pton(AF_INET6)` and its sockaddr conversion never sets `sin6_scope_id`. dnspython (a core dependency) handles `%scope`. | verified (code) / likely (dnspython end to end) |

---

## 1. (a) Receive path — traced

### 1.1 From the netgraph PPP ifnet to a raw socket

| Step | Code | What it does |
|---|---|---|
| 1 | `sys/netgraph/ng_iface.c` (stable/26.7, fetched) | Constructor: `ifp->if_flags = (IFF_SIMPLEX|IFF_POINTOPOINT|IFF_NOARP|IFF_MULTICAST);`. Receive: `isr = NETISR_IPV6;` then `netisr_dispatch(isr, m);` (BPF is tapped first with `ng_iface_bpftap`, `DLT_NULL`). No `SIOCGIFMEDIA` support (default case returns EINVAL). |
| 2 | `src/sys/netinet6/ip6_input.c:567-569` | `if ((ND_IFINFO(rcvif)->flags & ND6_IFF_IFDISABLED)) goto bad;` — the only interface flag that drops the packet before ICMPv6. |
| 3 | `ip6_input.c:828-832` | Multicast destination: `ours = 1;` (no further check here). Unicast to our link-local is matched at `:838`. |
| 4 | pf (pfil hook in `ip6_input`) | See 1.3. |
| 5 | `src/sys/netinet6/icmp6.c:491-500` | For a multicast destination the **interface** must be a member: `inm = in6m_lookup(ifp, &ip6->ip6_dst); if (inm == NULL) { ... goto freeit; }`. |
| 6 | `src/sys/netinet6/in6.c:1124-1125`, `:703-710` | The kernel joins `ff02::1` on the interface when an IPv6 address is configured on an `IFF_MULTICAST` interface: `if ((ifp->if_flags & IFF_MULTICAST) != 0) { error = in6_update_ifa_join_mc(...)`; "Join link-local all-nodes address." `mltaddr = in6addr_linklocal_allnodes;`. mpd5 puts `fe80::<ifid>/64` on `pppoeN` at IPv6CP up, so the membership exists. |
| 7 | `icmp6.c:790-808` | `case ND_ROUTER_ADVERT:` ... `n = m_copym(m, 0, M_COPYALL, M_NOWAIT); nd6_ra_input(m, off, icmp6len); m = n; if (m == NULL) goto freeit; break;` — the kernel consumes the original, a **copy** continues. |
| 8 | `icmp6.c:908-909` | `/* deliver the packet to appropriate sockets */ icmp6_rip6_input(&m, *offp);` |
| 9 | `icmp6.c:1880-1896` (`icmp6_rip6_match`) | A PCB matches if it is IPv6, `inp_ip_p == IPPROTO_ICMPV6`, and its bound local / connected foreign address (if any) equal the packet's. There is **no interface criterion**. |
| 10 | `icmp6.c:1933-1992` | Loop over all matching PCBs: `if (ICMP6_FILTER_WILLBLOCK(icmp6->icmp6_type, inp->in6p_icmp6filt)) continue;` then a per-socket copy (`m_copym`), `ip6_savecontrol(inp, n, &opts)` when control options were requested, `m_adj(n, off)` ("strip intermediate headers", so the socket reads from the ICMPv6 header), `sbappendaddr_locked(...)`. |

Consequences:

- Any number of raw ICMPv6 sockets receive the same RA. rtsold's receive socket is created the same way
  (`src/usr.sbin/rtsold/rtsol.c:108`, `socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6)`, filter
  `ICMP6_FILTER_SETBLOCKALL` + `ICMP6_FILTER_SETPASS(ND_ROUTER_ADVERT, &filt)` at `:132-135`). A second listener
  does not take packets away from it. (verified)
- Delivery to sockets is independent of `accept_rtadv`: that flag is tested inside `nd6_ra_input()`
  (`src/sys/netinet6/nd6_rtr.c:380-381`, `if (!(ndi->flags & ND6_IFF_ACCEPT_RTADV)) goto freeit;`), which only
  frees the kernel's copy. So a listener also works when the WAN IPv6 type is `pppoev6`/static (no
  `accept_rtadv`, no rtsold) — but then nothing sends an RS for it. (verified)
- The socket is not tied to an interface, so it survives `pppoeN` being destroyed and re-created.
  `core/src/opnsense/scripts/interfaces/ppp-linkdown.sh:10` runs `ngctl shutdown ${IF}:` on every link-down, so
  the ifindex of `pppoeN` is not stable; match the receiving interface **by name** from `IPV6_PKTINFO`
  (rtsold does `if_indextoname(pi->ipi6_ifindex, ...)`, `rtsol.c:202-225`). (likely)
- The kernel and rtsold ignore option 38: `src/sys/netinet6/nd6.c:516-523` ("Unknown options must be silently
  ignored" + `nd6log` debug line), `rtsol.c:520-522` (`default: /* nothing to do for other options */`). FreeBSD
  `main` rtsold has the same two cases (RDNSS, DNSSL) and the same default branch
  (`https://raw.githubusercontent.com/freebsd/freebsd-src/main/usr.sbin/rtsold/rtsol.c`). (verified)
- FreeBSD has no Linux-style "unknown ND option to userspace" channel:
  `sys/netlink/route/common.h` (stable/26.7) has `NL_RTM_NEWNDUSEROPT = 68, /* not supported */`. (verified)

### 1.2 Socket requirements

- Privilege: `src/sys/netinet6/raw_ip6.c:668`, `error = priv_check(td, PRIV_NETINET_RAW);` in `rip6_attach()`.
  The opener must be root (configd actions and rc scripts are). (verified)
- Default filter is pass-all: `raw_ip6.c:687-688`, `ICMP6_FILTER_SETPASSALL(inp->in6p_icmp6filt);`.
- Setting the filter: `icmp6.c:2678-2692`, `case ICMP6_FILTER:` requires `optlen == sizeof(struct icmp6_filter)`
  (else `EMSGSIZE`).
- Constants (`src/sys/netinet6/in6.h`): `ICMP6_FILTER 18` (`:415`), `IPV6_RECVPKTINFO 36` (`:446`),
  `IPV6_RECVHOPLIMIT 37` (`:447`), `IPV6_PKTINFO 46` (`:466`), `IPV6_HOPLIMIT 47` (`:467`),
  `IPV6_MULTICAST_HOPS 10` (`:410`).
- Filter layout (`sys/netinet/icmp6.h`, stable/26.7): `struct icmp6_filter { u_int32_t icmp6_filt[8]; };`
  `ICMP6_FILTER_SETPASS(type, filterp)` = `icmp6_filt[(type) >> 5] |= (1 << ((type) & 31))`. On FreeBSD a set
  bit means **pass** (Linux is the opposite). For type 134: word 4, bit 6.
- No `SO_BINDTODEVICE` on FreeBSD; rtsold filters by the `IPV6_PKTINFO` ifindex (`rtsol.c:115-129`, `:277`).
  odhcp6c's Linux code uses `SO_BINDTODEVICE` and an explicit `IPV6_ADD_MEMBERSHIP` for all-nodes, neither of
  which is needed here.

**Python 3** (core depends on Python; `core/Mk/version.mk:102-109` lists `py${CORE_PYTHON}-*` packages):

- `socket.socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6)`, `recvmsg()` with ancillary data, and the constants
  `IPV6_RECVPKTINFO`, `IPV6_PKTINFO`, `IPV6_RECVHOPLIMIT`, `IPV6_HOPLIMIT`, `IPV6_MULTICAST_HOPS`,
  `IPPROTO_ICMPV6` are exported by CPython when the platform defines them
  (`https://raw.githubusercontent.com/python/cpython/3.11/Modules/socketmodule.c`: each under its own `#ifdef`;
  docstring `recvmsg(bufsize[, ancbufsize[, flags]]) -> (data, ancdata, msg_flags, address)`). (verified)
- `ICMP6_FILTER` is **not** exported by CPython 3.11 (the identifier does not occur in `socketmodule.c`); use the
  literal `18` at level `IPPROTO_ICMPV6` with a 32-byte native-endian buffer. (verified absence; value from
  `in6.h:415`)
- No third-party module is needed. No Python or PHP file in the core, plugins or ports clones currently opens an
  ICMPv6 raw socket (grep for `ICMP6_FILTER|IPV6_RECVPKTINFO` over `*.py,*.php,*.inc` under `refs/`: no match).

**PHP sockets** (`php${CORE_PHP}-sockets` is a core dependency, `core/Mk/version.mk:97`): possible but worse.
`socket_set_option()`'s default branch does `ov = zval_get_long(arg4); optlen = sizeof(ov); opt_ptr = &ov;`
(`https://raw.githubusercontent.com/php/php-src/PHP-8.3/ext/sockets/sockets.c`), so a 32-byte `icmp6_filter`
cannot be passed; the kernel would answer `EMSGSIZE`. The socket would stay pass-all and receive every ICMPv6
message addressed to the box (NS/NA, echo, errors), to be filtered in userland. `socket_recvmsg()` support for
`IPV6_PKTINFO`/`IPV6_HOPLIMIT` was not checked. (likely)

### 1.3 pf: core's automatic ICMPv6 rules

`core/src/etc/inc/filter.lib.inc:224-266` (identical block on `stable/26.7`, fetched):

```php
if (empty($config['system']['no_ipv6_rfc4890_req'])) {
    ...
    $fw->registerFilterRule(1,
        ['ipprotocol' => 'inet6', 'protocol' => 'ipv6-icmp', 'icmp6-type' => '128,129,133,134,135,136',
            'statetype' => 'keep', 'descr' => 'IPv6 RFC4890 requirements (ICMP)', 'from' => '(self)',
            'to' => 'fe80::/10,ff02::/16', 'direction' => 'out', 'disabled' => $ipv6_disabled, ...],
        $defaults['pass']);
    $fw->registerFilterRule(1,
        ['ipprotocol' => 'inet6', 'protocol' => 'ipv6-icmp', 'icmp6-type' => '128,133,134,135,136',
            'statetype' => 'keep', 'descr' => 'IPv6 RFC4890 requirements (ICMP)', 'from' => 'fe80::/10',
            'to' => 'fe80::/10,ff02::/16', 'direction' => 'in', 'disabled' => $ipv6_disabled, ...],
        $defaults['pass']);
```

- Inbound RA (type 134, source link-local, destination `ff02::1` or our link-local) matches the second rule.
  Outbound RS (type 133 from the box to `ff02::2`) matches the first. No interface is given, so they apply to
  `pppoeN` as to every interface.
- They are `quick`: `core/src/opnsense/mvc/app/library/OPNsense/Firewall/FilterRule.php:233-235`
  ("all rules are quick by default except floating").
- They sort before "Block private networks from WAN" (`from fd00::/8,fe80::/10`, priority 5,
  `filter.lib.inc:360-368`): rules are emitted with `ksort($this->filterRules)`
  (`core/.../Firewall/Plugin.php:372`, `:388`).
- Two ways they disappear: `system.no_ipv6_rfc4890_req` (GUI: Firewall > Settings > Advanced, "Disable RFC4890
  requirement rules" — help text: "no automatic RFC4890 requirement rules will be created, blocking IPv6 without
  additional rules configured", `core/src/www/system_advanced_firewall.php:752-757`), and `!is_ipv6_allowed()`
  (rules disabled, plus "Block all IPv6", `filter.lib.inc:204-214`). In both cases rtsold and kernel SLAAC break
  too, so this is not a plugin-specific risk.

Result: the plugin needs **no pf rule of its own** to receive RAs or send RSs. (verified)

---

## 2. (b) Triggering an RA, and how often one arrives unasked

### 2.1 What rtsold does (and does not do)

OPNsense runs one shared `/usr/sbin/rtsold -aiu -p /var/run/rtsold.pid -A rtsold_script.sh -R
rtsold_resolvconf.sh` and kills/restarts it on every `interface_dhcpv6_configure()`
(`core/src/etc/inc/interfaces.inc:2816-2829`).

- `-a` picks interfaces that are UP, not loopback, `IFF_MULTICAST`, have an inet6 address, are not
  `ND6_IFF_IFDISABLED` and have `ND6_IFF_ACCEPT_RTADV` (`src/usr.sbin/rtsold/rtsold.c:861-898`). `pppoeN`
  qualifies only for WAN IPv6 types `dhcp6`/`slaac` (those get `accept_rtadv`, `interfaces.inc:2452`).
- State machine (`rtsold.c:637-651`, `:730-750`; constants `src/sys/netinet6/nd6.h:179-181`:
  `MAX_RTR_SOLICITATION_DELAY 1`, `RTR_SOLICITATION_INTERVAL 4`, `MAX_RTR_SOLICITATIONS 3`):
  `IFS_DELAY` (0 s with `-i`) → `IFS_PROBE`: `cap_rssend()`, up to 3 RS, 4 s apart → on the first RA
  `ifi->state = IFS_IDLE` (`rtsol.c:536-539`).
- In `IFS_IDLE` without `-m` the timer is stopped: `ifi->timer = tm_max; /* stop timer(valid?) */`
  (`rtsold.c:723-728`). The 60 s `PROBE_INTERVAL` (`rtsold.c:97`, set at `:463` when the interface has no media
  ioctl, which is the case for ng_iface) is only evaluated when that timer fires, i.e. never without `-m`.
  **rtsold does not solicit again** until it is restarted. (verified by code reading)
- How it sends (`src/usr.sbin/rtsold/cap_sendmsg.c:174-193`, `:104-118`): destination
  `IN6ADDR_LINKLOCAL_ALLROUTERS_INIT` (`ff02::2`) with `dst.sin6_scope_id = linkid`, ancillary `IPV6_PKTINFO`
  (ifindex) and `IPV6_HOPLIMIT` = 255. The RS body is 8 bytes; a source link-layer option is added only for
  `IFT_ETHER`/`IFT_L2VLAN` (`src/usr.sbin/rtsold/if.c:259-268`), so on `pppoeN` it is the bare header
  (`rtsold.c:535-539`: type 133, code 0, cksum 0, reserved 0).
- The FreeBSD kernel sends no RS by itself; rtsold (or `rtsol`) is the only sender in base.

Consequence: a listener started after rtsold's burst has missed the solicited RA and would wait for the next
periodic one. It has to solicit itself.

### 2.2 Sending an RS from the plugin's own socket

Facts needed to do it correctly:

- `rip6_send()` computes the ICMPv6 checksum for `IPPROTO_ICMPV6` raw sockets (`raw_ip6.c:500-526`,
  `/* Compute checksum. */ ... *p = in6_cksum(m, ip6->ip6_nxt, sizeof(*ip6), plen);`). The sender leaves it 0.
- Destination zone: `sa6_embedscope(dstsock, use_defzone)` (`raw_ip6.c:426-434`); pass the ifindex as
  `sin6_scope_id` (Python address tuple `('ff02::2', 0, 0, ifindex)`). Without a zone, `sa6_checkzone()` returns
  `EADDRNOTAVAIL` (`src/sys/netinet6/scope6.c:596-601`).
- Hop limit: multicast packets default to `V_ip6_defmcasthlim` unless the socket or an option overrides it
  (`src/sys/netinet6/ip6_output.c:641-649`). Routers discard an RS whose hop limit is not 255 (RFC 4861 6.1.1),
  so set `IPV6_MULTICAST_HOPS` = 255 or pass an `IPV6_HOPLIMIT` cmsg as rtsold does.
- Source address: chosen by `in6_selectsrc_socket()` (`raw_ip6.c:473-474`) — the link-local of `pppoeN`.
- pf: allowed by the first rule in 1.3.
- Alternative without own code: `/sbin/rtsol pppoe0` (the one-shot personality of the same binary,
  `rtsold.c:127-135`). It was used manually in opnsense/core#10828 ("a manual `rtsol pppoe0` fixed it at once").
  Caveat: its default RDNSS script is `/sbin/resolvconf` (`rtsold.c:84`), which would be invoked with the
  RA's DNS servers unless `-R` is overridden. It also prints nothing about option 38.

### 2.3 Router side (RFC 4861, `https://www.rfc-editor.org/rfc/rfc4861.txt`)

- 6.2.6: a solicited RA is delayed by a random 0..`MAX_RA_DELAY_TIME` (0.5 s); "A router MAY choose to unicast the
  response directly to the soliciting host's address"; multicast RAs are "rate limited to no more than one
  advertisement every MIN_DELAY_BETWEEN_RAS seconds" (3 s).
- 6.2.3: "A router MAY choose not to include some or all options when sending unsolicited Router
  Advertisements." but "when responding to a Router Solicitation or while sending the first few initial" RAs
  "a router SHOULD include all options".
- 6.2.1 / 10: `MaxRtrAdvInterval` 4..1800 s, default 600 s; `MinRtrAdvInterval` default 0.33 × Max;
  `AdvDefaultLifetime` default 3 × Max (max 9000 s); first `MAX_INITIAL_RTR_ADVERTISEMENTS` (3) RAs at most
  `MAX_INITIAL_RTR_ADVERT_INTERVAL` (16 s) apart.
- 6.3.7 (host): after an RS and a valid RA with non-zero Router Lifetime "the host MUST desist from sending
  additional solicitations on that interface" until the next (re)initialisation event. An extra RS at plugin
  start therefore goes slightly beyond the letter of 6.3.7; `rtsol(8)` run by hand and OPNsense's rtsold
  restarts do the same.
- 6.3.4: "the receipt of a Router Advertisement MUST NOT invalidate all information received in a previous
  advertisement"; hosts "accept the union of all received information".

### 2.4 Observed BNG defaults on subscriber/PPP interfaces

| Platform | Unsolicited RA interval | Source | Confidence |
|---|---|---|---|
| Juniper Junos (NDRA, dynamic PPPoE) | `max-advertisement-interval` default 600 s, configurable up to 1800 s; first three RAs at <= 16 s, or a random range (example 3–9 s) from 18.2R1; RAs "in response to router solicitations" | `https://www.juniper.net/documentation/us/en/software/junos/subscriber-mgmt-sessions/topics/topic-map/ipv6-wan-link-addressing-ndra.html` | verified |
| Nokia SR OS (subscriber RA) | `maxInterval` default 1800 s (900..1800), `minInterval` default 900 s, `routerLifetime` default 4500 s | `https://network.developer.nokia.com/static/xml_reference/25.8/rtr/class_IPv6SubscriberRouterAdvertisement.html` | verified |
| One UK ISP's LNS | "approximately once an hour (every 4096 seconds)" | search-result summary of support.aa.net.uk | unverified |

No BBF TR-187 text on RA timing was retrieved. Neither vendor page above mentions PREF64; no Juniper, Cisco,
Nokia or Huawei BNG documentation for sending PREF64 was found by search (only Arista, LANCOM, odhcpd). Whether
this ISP's BNG can send it at all is a question for the ISP.

So without an RS the first PREF64 can be 10–30 minutes away, and periodic RAs may omit the option. An RS gets a
full RA within about half a second.

---

## 3. (c) Scaled lifetime, PLC, withdrawal

### 3.1 Wire format

FreeBSD's own definition (`sys/netinet/icmp6.h`, stable/26.7):

```c
#define ND_OPT_PREF64			38	/* RFC 8781 */
struct nd_opt_pref64 {		/* PREF64 option (RFC 8781) */
	uint8_t		nd_opt_pref64_type;
	uint8_t		nd_opt_pref64_len;
	/* bits 0-12 are the SL, bits 13-15 are the PLC */
	uint16_t	nd_opt_pref64_sl_plc;
	char		nd_opt_prefix[12];
} __packed;
```

RA as read from the raw socket: 16-byte header (`struct nd_router_advert` = 8-byte ICMPv6 header with hop limit,
flags and router lifetime, then reachable and retransmit timers), then options `type(1) len(1, units of 8
bytes) ...`.

RFC 8781 (`https://www.rfc-editor.org/rfc/rfc8781.txt`):

- s4: "The receiver MUST ignore the PREF64 option if the Length field value is not 2."
- s4: PLC 0..5 = /96, /64, /56, /48, /40, /32; "The receiver MUST ignore the PREF64 option if the Prefix Length
  Code field is not set to one of those values."
- s4 prefix field: "Contains bits 0 - 95 of the NAT64 prefix." (nothing is said about bits beyond the prefix
  length, so a receiver should mask them itself).
- s4.1: "The receiver MUST multiply the Scaled Lifetime value by 8"; "The maximum lifetime of the NAT64 prefix
  is thus 65528 seconds."; router default is "the lesser of 3 x MaxRtrAdvInterval [RFC4861] divided by 8, or
  8191" (1800 s at the RFC default interval, 5400 s at Nokia's 1800 s).
- s4.1: "A lifetime of 0 indicates that the prefix SHOULD NOT be used anymore."
- s5: "This option may appear more than once in an RA" (renumbering); apply RFC 7050 section 3 handling
  "limited to the NAT64 prefixes that have a nonzero lifetime."
- s5.1: "The host SHOULD treat the PREF64 as being specific to the network interface it was received on." and the
  RECOMMENDED source order PCP, then RA, then RFC 7050.
- s3: "It is possible to change the NAT64 prefix at any time".
- s7: protection is RA-Guard (RFC 6105) on the access network.

RFC 9872 (Informational, Sept 2025, `https://www.rfc-editor.org/rfc/rfc9872.txt`): "Endpoints SHOULD attempt to
obtain PREF64 information from RAs per [RFC8781]"; they "MAY choose to fall back to the mechanism defined in
[RFC7050]" only when RAs lack it; RFC 8781 "allows notifying hosts about PREF64 changes immediately by sending
an RA with updated information", whereas an RFC 7050 result stays cached until its TTL or a reconnect.

### 3.2 The decode, as four implementations do it

All four use the same shortcut: because the lifetime sits in the top 13 bits and the unit is 8 s, masking gives
seconds directly.

| Implementation | Lifetime | PLC to length | Validation | Source |
|---|---|---|---|---|
| systemd | `PREF64_SCALED_LIFETIME_MASK 0xfff8`, `PREF64_PLC_MASK 0x0007`; `(lifetime_and_plc & PREF64_SCALED_LIFETIME_MASK) * USEC_PER_SEC`; stores `lifetime` and `valid_until` | table 96,64,56,48,40,32 | option length must be `2*8`; PLC >= 6 → `-EINVAL`; prefix masked to length | `src/libsystemd-network/ndisc-option.c`, `.h` (systemd main) |
| libndp (used by NetworkManager) | `ntohs(pref64->nd_opt_pref64_lft_plc) & ND_OPT_PREF64_LFT_MASK` | `if (plc == 0) return 96; return 72 - plc * 8;` | `if (pref64->nd_opt_pref64_len != 2) return false;` `if (plc > 5) return false;`; copies `plen / 8` prefix bytes | `https://raw.githubusercontent.com/jpirko/libndp/master/libndp/libndp.c` |
| NetworkManager | `_nm_ndisc_lifetime_to_expiry(now_msec, ndp_msg_opt_pref64_lifetime(msg, offset))`, stored with the RA's gateway address in `NMNDiscPref64` (only `#if HAVE_CLAT`) | from libndp | `nm_assert(NM_IN_SET(pref64.plen, 96, 64, 56, 48, 40, 32))` | `src/core/ndisc/nm-lndp-ndisc.c` (NM main) |
| Android | `lifetime = scaledLifetimePlc & 0xfff8;` | `plcToPrefixLength(scaledLifetimePlc & 7)`; other values throw "Invalid prefix length code" and `parse()` returns null | `TYPE = 38`, `LENGTH = 2` | `packages/modules/Connectivity/.../netlink/StructNdOptPref64.java` |
| radvd `radvdump` | `prefix_lifetime = lifetime_preflen & 0xFFF8;` | `prefix_length_code = lifetime_preflen & 7;` switch 0→96 .. 5→32, else "Invalid (reserved) nat64prefix length code" | option length must equal the struct size | `https://raw.githubusercontent.com/radvd-project/radvd/v2.20/radvdump.c` |

Untested illustration of the same arithmetic on the raw bytes of one option (`o` = the 16 option bytes):

```python
if o[0] == 38 and o[1] == 2:
    field = (o[2] << 8) | o[3]
    lifetime_s = field & 0xFFF8          # 0 .. 65528
    plc = field & 0x7                    # > 5: ignore the option
    plen = (96, 64, 56, 48, 40, 32)[plc]
    prefix = o[4:16] + b'\0' * 4         # then mask to plen bits
```

### 3.3 State-tracking facts

- Identity of an entry is (receiving interface, prefix/length); RFC 8781 5.1 makes it interface-specific.
  NetworkManager additionally records the advertising router.
- Expiry = receive time + lifetime; every RA that carries the option refreshes it. Use a monotonic clock
  (rtsold uses `CLOCK_MONOTONIC_FAST` for RDNSS expiry, `rtsol.c:342`, `:448-453`).
- Lifetime 0 = remove now.
- An RA **without** the option is not a withdrawal (RFC 4861 6.2.3 and 6.3.4, quoted in 2.3). Only lifetime 0 or
  expiry ends an entry.
- Several entries with non-zero lifetime may coexist; RFC 8781 s5 points to RFC 7050 section 3 for choosing.
- A PPP session drop is not signalled by any RA. On OPNsense the IPv6CP-down script destroys the interface
  (`ppp-linkdown.sh:10`) and calls `configctl -d interface newipv6 ${IF}` without a reason (`:25`), which the
  previous report showed does not reach `plugins_configure('newwanip')`. State learned on the old session is
  therefore only invalidated by its own lifetime unless the consumer checks the interface itself.
- RA validity checks a receiver has to apply itself on a raw socket (RFC 4861 6.1.2; rtsold does the same at
  `rtsol.c:247-273`): code 0, hop limit 255 (needs `IPV6_RECVHOPLIMIT`), link-local source, length >= 16, no
  zero-length option. The kernel has already verified the checksum (`icmp6.c:505-512`).
- OPNsense already has a GUI validator for the six legal lengths on the sending side:
  `core/src/opnsense/mvc/app/models/OPNsense/Radvd/Radvd.php:65-86` ("Prefix size must be one of 32, 40, 48, 56,
  64 or 96.").

---

## 4. (d) Existing parsers and tools

| Candidate | PREF64 on receive? | Notes | Confidence |
|---|---|---|---|
| FreeBSD/OPNsense rtsold, kernel, dhcp6c | No | section 1.1; header constant only | verified |
| FreeBSD `main` rtsold | No | only `case ND_OPT_RDNSS:` / `case ND_OPT_DNSSL:` | verified |
| OpenWrt odhcp6c `src/ra.c` (master) | No | handles MTU, route info, prefix info, RDNSS, DNSSL, captive portal. Useful only as a template for socket setup: `socket(AF_INET6, SOCK_RAW | SOCK_CLOEXEC, IPPROTO_ICMPV6)`, `ICMP6_FILTER_SETPASS(ND_ROUTER_ADVERT, &filt)`, RS to `ALL_IPV6_ROUTERS` with `if (++rs_attempt <= 3)` / `alarm(4)`, validity `if (hlim != 255 || len < sizeof(*hdr) || hdr->icmp6_code)` | verified |
| dhcpcd `dhcpcd-definitions.conf` (master) | No | `definend` entries stop at 31 (DNSSL); no `definend 38` | verified |
| base tcpdump (FreeBSD stable/15 `contrib/tcpdump/print-icmp6.c`) | No | no `ND_OPT_PREF64`; option 38 prints as unknown | verified |
| systemd `ndisc-option.c` | Yes | LGPL-2.1-or-later | verified |
| libndp + NetworkManager | Yes | LGPL-2.1+ / GPL-2.0+ | verified |
| Android `StructNdOptPref64.java` | Yes | Apache-2.0 | verified |
| **radvd `radvdump`** | **Yes, and it is on the box** | radvd is a core dependency (`core/Mk/version.mk:110`); OPNsense ports `net/radvd` is `PORTVERSION= 2.20` and its `pkg-plist` contains `sbin/radvdump`. v2.20 `radvdump.c` prints `# based on Router Advertisement from %s`, `# received by interface %s`, and `nat64prefix %s/%d` with `AdvValidLifetime %u;`. It opens its own raw socket (`open_icmpv6_socket()`), loops forever printing every RA from every interface, and sends no RS. | verified (source and plist); running it on `pppoeN` not tested |
| ndisc6 `rdisc6` | not established | not a core dependency | unverified |

Porting is not really needed: the option is fixed-size and FreeBSD's BSD-licensed `struct nd_opt_pref64` already
documents the layout. `radvdump` answers the earlier report's open question 6 ("any tool shipped with OPNsense
26.7 that can decode PREF64 from a received RA") and gives a zero-code way to check what the BNG sends:
run `/usr/local/sbin/radvdump` and, in another shell, `rtsol pppoe0`.

---

## 5. (e) RFC 7050 and scoped link-local resolvers

### 5.1 `drill` cannot use `fe80::1%pppoe0`

- rtsold stores link-local RDNSS addresses with the zone: `rtsol.c:410-415`,
  `snprintf(nsbuf, sizeof(nsbuf), "%s%c%s", ntopbuf, SCOPE_DELIMITER, ifi->ifname);` — this is what ends up in
  `/tmp/pppoe0:slaac_nameserverv6` through `rtsold_resolvconf.sh:57-63,80`.
- `contrib/ldns/drill/drill.c` (stable/26.7): `serv = argv[i] + 1;` → `serv_rdf = ldns_rdf_new_addr_frm_str(serv);`
  → on NULL: `cmdline_dname = ldns_dname_new_frm_str(serv);`, `ldns_get_rr_list_addr_by_name(...)` through the
  resolv.conf resolver, and on failure `error("%s `%s\'", "could not find any address for the name:", serv);`.
  No `sin6_scope_id`, `if_nametoindex` or zone handling anywhere in the file.
- `contrib/ldns/str2host.c`: `ldns_str2rdf_aaaa` calls `inet_pton(AF_INET6, (char*)str, address) != 1` on the
  untouched string and returns `LDNS_STATUS_INVALID_IP6`; `inet_pton` does not accept `%zone`.
- `contrib/ldns/net.c`, `ldns_rdf2native_sockaddr_storage_port`, AAAA case: sets `ss_family`, `sin6_port`,
  `memcpy(&data_in6->sin6_addr, ...)` after `memset(data, 0, sizeof(struct sockaddr_storage))`; "sin6_scope_id"
  does not occur in the file. A nameserver is held as a bare 16-byte rdf, so the zone could not be carried even
  if parsing accepted it; the kernel then refuses a zoneless link-local destination (`scope6.c:596-601`,
  `EADDRNOTAVAIL`).
- Core's wrapper has the same limit: `core/src/opnsense/scripts/system/query_dns.py:64-69` builds
  `['/usr/bin/drill', domain, '@%s' % server, qtype]`.

Conclusion: `drill ipv4only.arpa @fe80::1%pppoe0 AAAA` fails ("could not find any address for the name").
Confidence: verified by code reading of three of the four links (the body of `ldns_rdf_new_addr_frm_str` was not
fetched); not run.

Scope of the problem: only **link-local RDNSS from RAs** carry a zone. DHCPv6-supplied servers in
`/tmp/pppoe0_nameserverv6` are written as dhcp6c reports them; if the ISP hands out global resolver addresses,
`drill` works for those.

### 5.2 What does handle the zone

- dnspython is a core dependency (`core/Mk/version.mk:103`, `py${CORE_PYTHON}-dnspython`; used by
  `core/src/opnsense/scripts/filter/lib/__init__.py:27`). `dns/inet.py` `low_level_address_tuple`:
  `i = address.find("%")` ... `return (addrpart, port, 0, socket.if_nametoindex(scope))`, and
  `dns/ipv6.py` `inet_aton(text, ignore_scope=True)` does `parts = btext.split(b"%")` and drops the suffix
  (`https://raw.githubusercontent.com/rthalley/dnspython/main/dns/inet.py`, `.../dns/ipv6.py`). A direct
  `dns.query.udp()` to `fe80::1%pppoe0` is therefore expected to work; an unknown interface name raises
  `OSError` from `if_nametoindex`. (likely; main branch read, packaged version not checked, not run)
- Plain Python `socket` also accepts the 4-tuple `(addr, 53, 0, ifindex)`.
- A direct query also gives what RFC 7050 needs and `drill` text output makes awkward: all AAAA records, their
  TTL (re-discovery "10 seconds before the TTL" expires), and control over the CD bit.

---

## 6. Facts that bear on "listener, one-shot probe, or RFC 7050 + static only"

These are constraints, not a recommendation.

1. Receiving PREF64 needs no new package, no pf rule and no kernel change: Python stdlib + root is enough
   (sections 1.2, 1.3).
2. A solicited RA SHOULD contain all options and arrives within about 0.5 s of an RS (2.3). So PREF64 can be
   sampled on demand by a short-lived process: open socket, set filter, send RS, read RAs for `pppoeN` for a few
   seconds, exit. RFC 4861's own retry schedule is 3 RS at 4 s.
3. What a short-lived probe cannot see: an unsolicited RA that changes the prefix or carries lifetime 0 between
   probes. With a stored expiry it still stops using a prefix when the lifetime runs out. Typical lifetimes are
   1800–5400 s (3.1).
4. A long-running listener is the only way to react to unsolicited changes immediately. Precedent for a
   long-running script in core: `mwexecfb('/usr/local/opnsense/scripts/routes/gateway_watcher.php %s', [...],
   ['pidfile' => '/var/run/gateway_watcher.pid'])` (`core/src/etc/inc/plugins.inc.d/dpinger.inc:288-293`), which
   expands to `/usr/sbin/daemon -f -p <pidfile> ...` (`core/src/etc/inc/util.inc:971-985`; `restart` adds
   `-rR`).
5. Periodic RAs alone are not dependable for refresh (may omit options, 10–30 min apart); either way the
   consumer has to send RSs.
6. `radvdump` gives a ready-made decoder but only as free-running text output for all interfaces.
7. RFC 7050 through `drill`/`configctl dns query` fails for link-local RDNSS; dnspython or a raw UDP query is
   needed for that case.
8. claton (per the earlier standards report) makes RFC 8781 a MUST and RFC 7050 a SHOULD; RFC 9872 says
   endpoints SHOULD use RA PREF64 and MAY fall back to RFC 7050.

---

## 7. Design implications

1. Do not add firewall rules for RA/RS; core's automatic RFC 4890 rules already cover both directions. Document
   that "Disable RFC4890 requirement rules" breaks discovery (as it breaks SLAAC).
2. Use Python 3 stdlib, not PHP, for the socket: PHP cannot set `ICMP6_FILTER`. Hard-code `ICMP6_FILTER = 18`
   and remember that on FreeBSD a set bit passes.
3. Run it as root (configd action or rc/daemon); raw sockets need `PRIV_NETINET_RAW`.
4. Always send your own RS (hop limit 255, zone = `pppoeN`); never rely on rtsold's burst or on periodic RAs.
5. Request `IPV6_RECVPKTINFO` and `IPV6_RECVHOPLIMIT`; accept only code 0, hop limit 255, link-local source, and
   the expected interface **name** (ifindex changes when mpd5 re-creates the node).
6. Decode with `field & 0xFFF8` / `field & 7`; ignore option length != 2 and PLC > 5; mask the prefix to its
   length; keep (interface, prefix/len, expiry).
7. Treat lifetime 0 as immediate removal; do not treat a missing option as removal; drop entries at expiry.
8. Because link-down produces no plugin event and no RA, re-validate on link-up (new RS) rather than trusting
   state from the previous session.
9. Do not make the plugin depend on rtsold's flags, pid file or scripts; it can coexist with any number of other
   ICMPv6 listeners.
10. A listener also works when the WAN IPv6 type gives no `accept_rtadv` (PPPoEv6/static); socket delivery does
    not depend on that flag.
11. For RFC 7050, do not shell out to `drill`/`configctl dns query` when the resolver is a scoped link-local;
    use dnspython or a raw UDP socket, and take the server list from `ifctl -6n -i pppoeN`.
12. `radvdump` + `rtsol pppoeN` is a no-code acceptance test for "does this BNG send PREF64"; put it in the
    troubleshooting documentation.
13. Keep a static prefix setting regardless: none of the BNG vendor pages found mention PREF64, and RFC 7050
    needs DNS64 at the ISP.

---

## 8. Open questions

1. Does the ISP's BNG send PREF64 on the PPP link (solicited and unsolicited), with which lifetime and RA
   interval? (ISP)
2. Do the ISP's resolvers do DNS64, and are they delivered by DHCPv6 (global addresses) or by RA RDNSS
   (possibly link-local)? (ISP)
3. NAT64 prefix and length (well-known `64:ff9b::/96` or network-specific, /96 or shorter)? (ISP)
4. Live confirmation on 26.7: Python raw ICMPv6 socket on `pppoeN` receives the RA; own RS is answered; behaviour
   across a PPP reconnect.
5. Does the BNG rate-limit or ignore repeated RSs on a PPP session?
6. Does `radvdump` 2.20 run cleanly on OPNsense with a netgraph PPP interface present (it exits on receive
   errors)?
7. Python minor version shipped with 26.7 (`CORE_PYTHON` is derived from the installed `python3`) and the
   packaged dnspython version.
8. Whether PHP `socket_recvmsg()` supports the IPv6 ancillary types (only relevant if PHP were chosen).
9. Whether FreeBSD or OPNsense plan PREF64 support in rtsold (none in FreeBSD `main` today; no OPNsense issue
   was searched for).
10. Is an immediate reaction to unsolicited PREF64 changes a requirement for v1, or is "probe at link-up, then
    before expiry" acceptable?

---

## 9. Sources

Local clone (path:line as cited above): `src/sys/netinet6/{icmp6.c,raw_ip6.c,ip6_input.c,ip6_output.c,in6.c,
in6.h,nd6.c,nd6.h,nd6_rtr.c,scope6.c}`, `src/usr.sbin/rtsold/{rtsol.c,rtsold.c,rtsock.c,if.c,cap_sendmsg.c,
rtsold.8}`, `core/src/etc/inc/{filter.lib.inc,interfaces.inc,util.inc,plugins.inc.d/dpinger.inc}`,
`core/src/opnsense/mvc/app/library/OPNsense/Firewall/{FilterRule.php,Plugin.php}`,
`core/src/www/system_advanced_firewall.php`, `core/src/opnsense/scripts/interfaces/{ppp-linkdown.sh,
rtsold_resolvconf.sh}`, `core/src/opnsense/scripts/system/query_dns.py`, `core/Mk/version.mk`,
`core/src/opnsense/mvc/app/models/OPNsense/Radvd/Radvd.php`.

Fetched:
- `https://raw.githubusercontent.com/opnsense/src/stable/26.7/sys/netinet/icmp6.h`
- `https://raw.githubusercontent.com/opnsense/src/stable/26.7/sys/netgraph/ng_iface.c`
- `https://raw.githubusercontent.com/opnsense/src/stable/26.7/sys/netlink/route/common.h`
- `https://raw.githubusercontent.com/opnsense/src/stable/26.7/contrib/ldns/{drill/drill.c,net.c,str2host.c}`
- `https://raw.githubusercontent.com/opnsense/core/stable/26.7/src/etc/inc/filter.lib.inc`
- `https://raw.githubusercontent.com/opnsense/ports/master/net/radvd/{Makefile,pkg-plist}`
- `https://raw.githubusercontent.com/radvd-project/radvd/v2.20/radvdump.c` (and `master`)
- `https://raw.githubusercontent.com/freebsd/freebsd-src/main/usr.sbin/rtsold/rtsol.c`
- `https://raw.githubusercontent.com/freebsd/freebsd-src/stable/15/contrib/tcpdump/print-icmp6.c`
- `https://raw.githubusercontent.com/openwrt/odhcp6c/master/src/ra.c`
- `https://raw.githubusercontent.com/systemd/systemd/main/src/libsystemd-network/ndisc-option.{c,h}`
- `https://raw.githubusercontent.com/jpirko/libndp/master/libndp/libndp.c`
- `https://raw.githubusercontent.com/NetworkManager/NetworkManager/main/src/core/ndisc/nm-lndp-ndisc.c`
- `https://android.googlesource.com/platform/packages/modules/Connectivity/+/refs/heads/main/staticlibs/device/com/android/net/module/util/netlink/StructNdOptPref64.java`
- `https://raw.githubusercontent.com/NetworkConfiguration/dhcpcd/master/src/dhcpcd-definitions.conf`
- `https://raw.githubusercontent.com/python/cpython/3.11/Modules/socketmodule.c`
- `https://raw.githubusercontent.com/php/php-src/PHP-8.3/ext/sockets/sockets.c`
- `https://raw.githubusercontent.com/rthalley/dnspython/main/dns/{inet.py,ipv6.py}`
- `https://www.rfc-editor.org/rfc/rfc4861.txt`, `rfc8781.txt`, `rfc9872.txt`
- Juniper and Nokia pages in 2.4
