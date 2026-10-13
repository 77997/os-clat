# CLAT datapath candidates on OPNsense 26.7 (FreeBSD 15 base)

Research date: 2026-10-10. Scope: facts only, for a later "virtual WAN interface" CLAT design.
This is not a design. Nothing here was executed on a real OPNsense box; every command sequence
below is derived from source reading and must be verified (see section 9).

Path abbreviations used below:

- `REFS` = `refs` (local clones, not in this repository)
- `tayga/` = `REFS/tayga` (apalrd/tayga `main`, HEAD `8a028c7`, 2026-03-14, i.e. 0.9.6 plus unreleased work)
- `src/` = `REFS/opnsense-src` (opnsense/src `stable/26.7`, HEAD `412e762`, 2026-10-09)
- `core/` = `REFS/opnsense-core` (opnsense/core `master`, HEAD `5de9cc0`, 2026-10-10)
- `plugins/` = `REFS/opnsense-plugins`, `ports/` = `REFS/opnsense-ports`, `openwrt/` = `REFS/openwrt`

Confidence tags: **[V]** verified in the primary source, **[L]** likely (inferred from strong evidence),
**[U]** unverified.

---

## 1. Executive summary

| Candidate | On OPNsense 26.7 today | Kernel / user | Real assignable ifnet | Needs firewall rules | Verdict for "virtual WAN interface" |
|---|---|---|---|---|---|
| (A) tayga on tun | Yes. `net/tayga` 0.9.6 in OPNsense ports; `os-tayga` 1.5 plugin exists | userspace, single thread on FreeBSD | **Yes** (tun ifnet, renameable) | outbound NAT44 on the tun (OPNsense can auto-generate) and **one inet6 pass-in rule on the tun** | Only candidate that yields an interface today |
| (B) ipfw `nat64clat` | Module source present (`sys/modules/ipfw_nat64`), not compiled in; core disables and flushes ipfw on every filter reload unless shaper / captive portal is configured | kernel, stateless | **No** (an ipfw action) | ipfw rules mandatory, plus pf rules (or pf is bypassed) | Not suitable |
| (C) pf `af-to` | In the 26.7 kernel and `pfctl`; no core GUI/rule support until PR #10638 (27.1) | kernel, stateful | **No** (a pf rule option, inbound only) | it *is* a firewall rule | Best datapath, but it is exactly the firewall-native path the plugin must not pre-empt |
| (D) clatd, Jool, nat46, tundra-nat64, gelatod | Not available (Linux-only or OpenBSD-only) | - | - | - | Not applicable |
| (D) netgraph / pseudo-interface | No NAT64/SIIT netgraph node, no translation pseudo-interface in FreeBSD 15 | - | - | - | Does not exist |

Ranking for the virtual-interface approach: **(A) tayga-on-tun** first and effectively alone; **(C) pf af-to**
is the future native replacement and the plugin should be shaped so it can be swapped or retired when 27.1
lands; **(B)** should be avoided; **(D)** has nothing usable.

---

## 2. Candidate A: tayga (userspace, tun)

### 2.1 What OPNsense ships

- **[V]** OPNsense ports ship **tayga 0.9.6** from `apalrd/tayga`.
  `ports/net/tayga/Makefile:1-2,16-17`: `PORTNAME= tayga`, `DISTVERSION= 0.9.6`, `USE_GITHUB= yes`, `GH_ACCOUNT= apalrd`;
  `ports/net/tayga/distinfo:1-2`: `TIMESTAMP = 1767750834`, `SHA256 (apalrd-tayga-0.9.6_GH0.tar.gz)`.
- **[V]** The package installs **no rc.d script and no user**: `ports/net/tayga/pkg-plist:1-4` is only
  `@sample etc/tayga.conf.example etc/tayga.conf`, `sbin/tayga`, two man pages. Config path is compiled as
  `${PREFIX}/etc/tayga.conf` (`Makefile:21`). `NOT_FOR_ARCHS= i386` (64-bit `time_t`).
- **[V]** FreeBSD ports upstream is also at 0.9.6 (FreshPorts `net/tayga`: "15:latest 0.9.6, 15:quarterly 0.9.6", last
  update 2026-01-26, maintainer alven@FreeBSD.org, "no SUBR information") - https://www.freshports.org/net/tayga/
- **[V]** 0.9.6 is the latest upstream release (GitHub releases page marks 0.9.6 "Latest"; notes say
  "Tayga 0.9.6 is intended to be the last release of tayga v0.9.x" and v1 "will incorporate performance improvements")
  - https://github.com/apalrd/tayga/releases
- **[V]** An OPNsense plugin already wraps it: `plugins/net/tayga/Makefile:1-5` (`PLUGIN_NAME= tayga`,
  `PLUGIN_VERSION= 1.5`, `PLUGIN_DEPENDS= tayga`). It is a NAT64/PLAT-style plugin, not a CLAT, but it is the
  precedent for tayga-on-tun on OPNsense (see 2.7).

### 2.2 0.9.6 versus the cloned `main` (important: the clone is newer than what OPNsense ships)

The local clone is `main` after 0.9.6. It was compared against the `0.9.6` tag via
`https://raw.githubusercontent.com/apalrd/tayga/0.9.6/{conffile.c,tayga.c,nat64.c}`.

| Feature | 0.9.6 (shipped) | `main` (unreleased) | Evidence |
|---|---|---|---|
| `map` with prefix lengths, `prefix`, `ipv4-addr`, `ipv6-addr`, `wkpf-strict`, `udp-cksum-mode`, `offlink-mtu`, `log`, `dynamic-pool`, `data-dir` | yes | yes | 0.9.6 `config_directives[]` (fetched); `tayga/conffile.c:714-733` |
| `map-file` + reload on SIGHUP | **no** | yes | 0.9.6 table has no `map-file`; `tayga/conffile.c:727`, `tayga/tayga.c:113-122` |
| SIGHUP behaviour | **exits** ("Exiting on signal %d") | reloads map-file | 0.9.6 `read_from_signalfd()` has no SIGHUP case; `tayga/tayga.c:113-134` |
| `workers` (multiqueue threads) | no | Linux only | `tayga/tayga.h:110-115` (`MAX_WORKERS 64` Linux, `0` FreeBSD); `tayga/conffile.c:698-703` |
| `tun-up`, `tun-ip`, `tun-route` | no | Linux only (netlink) | `tayga/tun.c:43-452` is all `#ifdef __linux__`; man page: "Only supported on Linux" (`tayga/docs/man/tayga.conf.5.md:195-207`) |
| `--syslog/--stdout/--journal`, `-u/-g/-r/-p`, `--mktun/--rmtun` | yes | yes | 0.9.6 `usage()` (fetched); `tayga/tayga.c:31-56` |
| FreeBSD `tun_setup()` | same logic (in `tayga.c`) | moved to `tun.c` | 0.9.6 `tayga.c` FreeBSD block (fetched); `tayga/tun.c:454-559` |

Consequences for a design based on the shipped package:

- **[V]** Any change to the CLAT IPv6 address or the PLAT prefix requires a **tayga restart** in 0.9.6. There is no
  reload, and SIGHUP terminates the daemon.
- **[V]** On FreeBSD `main` a `workers` line is a fatal config error:
  `slog(LOG_CRIT,"Error: `workers` (line %d) not supported on this platform",ln); return ERROR_REJECT;`
  (`tayga/conffile.c:701-702`). Never emit `workers`, `tun-up`, `tun-ip`, `tun-route` on FreeBSD
  (the latter three are parsed but silently do nothing on FreeBSD in `main`, and are unknown directives,
  hence fatal, in 0.9.6: `tayga/conffile.c:805-811` "Unknown directive").

### 2.3 Documented CLAT configuration

- **[V]** Upstream documents CLAT explicitly: `tayga/docs/clat/README.md`. Key statements:
  - line 7: "we require two addresses - one is used along with `tayga`'s `map` directive to map IPv4 user
    traffic to IPv6, the other is used by `tayga` as its own address as the source of ICMPv6 error messages";
  - line 11: "The translator (TAYGA) performs address translation for exactly one IPv4 address, usually taken
    from the DS-Lite range (192.0.0.0/29) to exactly one IPv6 address";
  - lines 24-26: `192.0.0.1/29` host side, `192.0.0.2/29` "IPv4 address of tayga itself".
- **[V]** Reference config (`tayga/docs/clat/clat-route.conf:1-10`, same shape in `clat-proxynd.conf`, `clat-masq.conf`):
  ```
  # For BSD systems, tun-devide must be named tun[0-9]
  tun-device clat
  ipv4-addr 192.0.0.2
  ipv6-addr 2001:db8:abcd::65
  map 192.0.0.1 2001:db8:abcd::64
  prefix 64:ff9b::/96
  ```
  The comment "must be named tun[0-9]" is only true for `--mktun/--rmtun` (see 2.5).
- **[V]** Reference host setup (Linux, `tayga/docs/clat/clat-route.sh:10-22`): `tayga --mktun`; link up;
  `ip addr add 192.0.0.1/29 dev clat`; `ip route add default dev clat mtu 1260`;
  `ip route add <clat6>/127 dev clat`; start tayga. Three addressing variants are documented: Proxy NDP
  (address from the on-link /64), NAT66 masquerade (`fd64::/64`), and routed prefix (DHCPv6-PD).
- **[V]** Directive semantics (`tayga/docs/man/tayga.conf.5.md`):
  - `ipv4-addr` (l.34-43): source of ICMPv4 errors, answers pings. Mandatory.
  - `ipv6-addr` (l.45-53): source of ICMPv6 errors, answers pings. Mandatory unless `prefix` is given.
  - `prefix` (l.55-70): RFC 6052 lengths only (32/40/48/56/64/96, enforced at `tayga/conffile.c:192-198`).
  - `wkpf-strict` (l.72-78): default on; with 64:ff9b::/96 refuses non-global IPv4.
  - `map ipv4[/len] ipv6[/len]` (l.80-93): static 1:1 host or subnet map (RFC 7757 EAM).
  - `udp-cksum-mode drop|fwd|calc` (l.153-157), default `drop` (`tayga/conffile.c:749`).
  - `offlink-mtu` (l.176-193), default 1280 (`tayga/conffile.c:945-946`).
  - `log drop|reject|icmp|self|dyn` (l.159-174; `tayga/conffile.c:619-623`).
- **[V]** `map` subnet rule: both sides must have the same host-bit count, and only the low 32 bits of the IPv6
  address are substituted:
  `if ((32 - prefix4) != (128 - prefix6))` -> "IPv4 and IPv6 subnet must be of the same size" (`tayga/conffile.c:461-465`);
  `addr6->s6_addr32[3] = s->map6.addr.s6_addr32[3] | (addr4->s_addr & ~map4->mask.s_addr);` (`tayga/addrmap.c:524-526`),
  reverse at `tayga/addrmap.c:666-668`. So IPv4 `/24` pairs with IPv6 `/120`, `/16` with `/112`, `/8` with `/104`.
  `docs/rfc.md:26-28` confirms: "TAYGA requires that these be exactly equal (i.e. IPv4/24 corresponds to IPv6/120, not IPv6/64)".
- **[V]** A `map 0.0.0.0/0 <x>::/96` cannot coexist with `prefix`, because `prefix` itself inserts a `0.0.0.0/0`
  map4 entry (`tayga/conffile.c:175-176,199-203`) and `insert_map4` rejects same prefix-len + same address
  (`tayga/addrmap.c:354-359`).
- **[V]** wkpf-strict detail relevant to CLAT: `is_private_ip4_addr()` (`tayga/addrmap.c:97-132`) lists 10/8,
  100.64/10, 172.16/12, 192.0.2.0/24, 192.168/16, 198.18/15, 198.51.100/24, 203.0.113/24. **192.0.0.0/29 is not in
  that list.** With `prefix 64:ff9b::/96` and strict mode, an un-NATed RFC 1918 *source* is rejected
  (`ERROR_REJECT` -> ICMPv4 unreachable code 10, `tayga/nat64.c:391-396`); with a network-specific prefix or
  `wkpf-strict no`, an un-NATed LAN source would instead be mapped *into the PLAT prefix* (the RFC6052 `0.0.0.0/0`
  entry matches every address not covered by a `map`, `tayga/addrmap.c:307-318,528-535`).
- **[V]** If `ipv6-addr` is omitted, tayga derives it from `ipv4-addr` + `prefix`
  (`tayga/conffile.c:922-943`), which for a CLAT would be an address inside the PLAT prefix
  (e.g. `64:ff9b::c000:2`). An explicit `ipv6-addr` inside 64:ff9b::/96 is refused in strict mode
  (`tayga/conffile.c:896-904`). A CLAT should always set `ipv6-addr` explicitly.
- **[V]** Hairpin is not implemented and such packets are dropped (`tayga/addrmap.c:688-692`, `tayga/docs/rfc.md:22-24`).

### 2.4 Translation correctness (RFC 7915) as implemented

- **[V]** Claimed compliance: "Translation is compliant with IETF RFC 7915, and address mapping is performed in
  accordance with RFC 6052 and RFC 7757" (`tayga/docs/man/tayga.8.md:26-27`). Documented deviations
  (`tayga/docs/rfc.md`): no translation of addresses inside ICMP extensions (l.12-14); RFC 6791 only partially
  (always uses its own `ipv4-addr` as fake source, l.38-40); non-/96 prefixes with non-zero suffix bits dropped (l.48-50).
- **[V]** 4->6 MTU / fragmentation logic (`tayga/nat64.c:365-481`):
  - `frag_size = min(offlink-mtu, tun MTU) - 40` (l.374-377).
  - DF set and not a fragment: if `tun_mtu - 20 < total_len` -> ICMPv4 type 3 code 4 with MTU `tun_mtu - 20`
    (`host_send_icmp4_error(3, 4, gcfg.mtu - MTU_ADJ, p)`, l.412-417); otherwise sent with **no** fragment header,
    regardless of `offlink-mtu`.
  - DF clear: sent whole only if the L4 payload `<= frag_size` (l.419-421), else split into IPv6 fragments of at most
    `offlink-mtu` bytes (l.441-479). With the default 1280 this means any DF=0 IPv4 packet longer than 1260 bytes is
    fragmented.
- **[V]** 6->4 (`tayga/nat64.c:850-885,983-987`): fragment header -> IPv4 fragment with DF cleared; no fragment
  header and `<= 1280` -> DF=0 with generated ident; `> 1280` -> DF=1. IPv6 packet larger than the tun MTU ->
  ICMPv6 Packet Too Big with MTU = tun MTU.
- **[V]** ICMP: echo translated in place; errors translated incl. embedded packet (`xlate_4to6_icmp_error`
  l.561-738, `xlate_6to4_icmp_error` l.1112-1279). PTB/frag-needed MTU conversion: 6->4 `mtu = min(mtu, tun_mtu) - 20`
  (l.1171-1183); 4->6 `mtu + 20`, capped to tun MTU, floored to 1280 (l.639-654). Fragmented ICMP is dropped
  (l.512-516, l.1083-1088). TTL/hop-limit 1 -> time exceeded from tayga's own address (l.765-769, l.1305-1309).
- **[V]** UDP zero checksum (`tayga/nat64.c:328-346`): `drop` (default), `fwd` (forward unchanged, invalid on IPv6),
  `calc` (compute full checksum). The existing OPNsense plugin hardcodes `udp-cksum-mode fwd` and `wkpf-strict no`
  (`plugins/net/tayga/src/opnsense/service/templates/OPNsense/Tayga/tayga.conf:5-6`).
- **[V]** Unsolicited IPv6 to the CLAT address from a source outside the PLAT prefix is not translated: source
  mapping fails -> ICMPv6 type 1 code 5 (`tayga/nat64.c:971-976`). Confirmed in practice in upstream issues #83/#98.

### 2.5 FreeBSD support status and tun mechanics

FreeBSD is a supported platform ("out-of-kernel stateless NAT64 implementation for Linux and FreeBSD",
`tayga/README.md:3`; FreeBSD patch merged in 0.9.4, FreeBSD CI issue #181 closed 2026-03-07). The FreeBSD code
path is small and has sharp edges.

**tayga side (`tayga/tun.c:454-559`, identical logic in 0.9.6):**

```c
if (strncmp(gcfg.tundev, "tun", 3))
        do_rename = 1;
if ((do_mktun || do_rmtun) && do_rename) {
        slog(LOG_CRIT, "tunnel interface name needs to match tun[0-9]+ pattern for --mktun to work\n");
        return ERROR_REJECT;
}
snprintf(devname, sizeof(devname), "/dev/%s", do_rename ? "tun" : gcfg.tundev);
gcfg.tun_fd = open(devname, O_RDWR);
...
multi_af = 1;
if (ioctl(gcfg.tun_fd, TUNSIFHEAD, &multi_af) < 0) { ... }
...
if (do_rename) { ... ioctl(fd, SIOCSIFNAME, &ifr) ... }
...
if (ioctl(fd, SIOCGIFMTU, &ifr) < 0) { ... }
gcfg.mtu = ifr.ifr_mtu;
```

- **[V]** Name starting with `tun`: tayga opens `/dev/<name>` directly; `--mktun` just opens and exits
  (the interface persists), `--rmtun` does `SIOCIFDESTROY`.
- **[V]** Any other name (e.g. `clat0`, `nat64`): tayga opens the cloning node `/dev/tun`, gets a fresh `tunN`,
  and renames it with `SIOCSIFNAME`. `--mktun/--rmtun` are refused for such names.
- **[V]** tayga has **no option to open a specific device node under a different interface name**. A pre-created,
  already-renamed interface therefore cannot be adopted. If an interface with the target name already exists
  (stale after crash or stop), the rename fails: `if (ifunit(new_name) != NULL) return (EEXIST);`
  (`src/sys/net/if.c:3154-3155`) -> tayga aborts with "Unable to rename interface". The existing plugin copes by
  destroying the interface on stop (`plugins/net/tayga/src/etc/rc.d/opnsense-tayga:36-45`: `kill -2 ${rc_pid}` then
  `ifconfig nat64 destroy`) but does not clean up before start.
- **[V]** The tun MTU is read **once at startup**; later MTU changes are not seen by tayga. The Linux path refuses
  MTU < 1280 (`tayga/tun.c:358-364`); the FreeBSD path has no such check.
- **[V]** FreeBSD has no multiqueue: `MAX_WORKERS 0`, worker code is `#ifdef __linux__` (`tayga/tayga.c:231-248,613-625`).
  The main loop does one `poll()`, one `read()`, one `writev()` per packet (`tayga/tayga.c:628-654`,
  `tayga/tun.c:562-600`).
- **[V]** FreeBSD framing: 4-byte address family in network order (`struct tun_pi { int proto; }`,
  `TUN_SET_PROTO -> htonl(_af)`, `tayga/tayga.h:80-87`), matching the kernel's TUNSIFHEAD mode
  (`*(u_int32_t *)m0->m_data = htonl(af)` in `src/sys/net/if_tuntap.c:1572-1582`; `family = ntohl(...)` l.1976-1982).
- Cosmetic **[V]**: the success message "Multi-AF mode set on %s" is logged at `LOG_CRIT` (`tayga/tun.c:521`).

**Kernel side (`src/sys/net/if_tuntap.c`):**

- **[V]** tun is `IFT_PPP`, `IFF_POINTOPOINT | IFF_MULTICAST`, default MTU `TUNMTU` 1500 (l.1029-1036, 1058; `if_tun.h:23`).
- **[V]** devfs cloning of `/dev/tun` is on by default (`static int tundclone = 1;` l.190; sysctl
  `net.link.tun.devfs_cloning`, l.205) and requires `PRIV_NET_IFCREATE` (l.590-603).
- **[V]** Exactly one opener: a second `open()` returns `EBUSY` (l.1178-1182). Multiple tayga processes cannot
  share one tun, so there is no multi-process scaling on one interface either.
- **[V]** `open()` raises link state (`if_link_state_change(ifp, LINK_STATE_UP)`, l.1204); `close()` (`tundtor`,
  l.1224-1320) does `if_down(ifp)`, **`if_purgeaddrs(ifp)`** (when `IFF_DRV_RUNNING`), and
  `if_link_state_change(ifp, LINK_STATE_DOWN)`. The interface itself survives unless it was marked transient
  (`TUN_TRANSIENT`, l.1303-1318; tayga never sets it). So **every tayga exit strips all addresses from the tun,
  marks it down and emits a link-down event** (`devctl_notify("IFNET", ifname, "LINK_DOWN")`,
  `src/sys/net/if.c:2181-2184`).
- **[V]** Kernel -> tayga: `tunoutput` returns `EHOSTDOWN` unless the device is open and the interface is UP
  (l.1538-1547). tayga -> kernel: `tunwrite` silently discards when the interface is not UP (l.2034-2036), sets
  `m->m_pkthdr.rcvif = ifp` (l.2071) and injects with `netisr_dispatch(NETISR_IP | NETISR_IPV6)` (l.1990-2011).
  **Translated packets therefore re-enter the stack as *received on the tun*** and hit pf's inbound hook on the
  tun interface.
- **[V]** IPv6 on a fresh tun is disabled by default: "Set IPv6 disabled on all interfaces but loopback by default"
  -> `nd->flags |= ND6_IFF_IFDISABLED` (`src/sys/netinet6/nd6.c:295-297`), and `ip6_input` drops everything received
  on such an interface: `if ((ND_IFINFO(rcvif)->flags & ND6_IFF_IFDISABLED)) goto bad;`
  (`src/sys/netinet6/ip6_input.c:567-569`). The flag is cleared by `ifconfig <if> inet6 -ifdisabled`, or
  automatically when an IPv6 address is added (`src/sys/netinet6/in6.c:1383-1397`). A working FreeBSD 14.3 CLAT in
  upstream issue #83 used exactly `ifconfig clat0 inet6 -ifdisabled`.

**Field reports (FreeBSD CLAT with tayga):**

- **[V]** Issue #83 (https://github.com/apalrd/tayga/issues/83), FreeBSD 14.3 jail, tayga 0.9.4. Final working host
  commands reported by the user:
  ```
  ifconfig clat0 inet 192.0.0.1/29 192.0.0.1 up
  ifconfig clat0 inet6 -ifdisabled
  route add default -iface clat0
  route -6n add -net 2400:8901:e002:7f70::64/127 -iface clat0
  ```
  with `tun-device clat0 / ipv4-addr 192.0.0.2 / ipv6-addr ...::65 / map 192.0.0.1 ...::64 / prefix .../96`.
  Root cause of the initial failure was upstream routing of the CLAT address (maintainer: "BSD does not answer
  neighbor discovery on-link", proxy NDP or a static route is needed). A later MSS problem was fixed with a pf
  `scrub ... max-mss` rule; the maintainer's alternative was an IPv4 default-route MTU of 1260.
- **[V]** Issue #98 (https://github.com/apalrd/tayga/issues/98), FreeBSD 14.3 host: same config shape; the failure was
  caused by a third-party `ndproxy` kernel module, not tayga.

### 2.6 Process options: logging, pid, chroot, privileges, signals

- **[V]** Options (`tayga/tayga.c:31-56`, same in 0.9.6): `-c FILE`, `-d` (debug, foreground, stdout),
  `-n/--nodetach`, `-u USER`, `-g GROUP`, `-r/--chroot` (chroot to `data-dir`), `-p PIDFILE`,
  `--syslog` (default) / `--stdout` / `--journal`.
- **[V]** syslog identity: `openlog("tayga", LOG_PID | LOG_NDELAY, LOG_DAEMON)` (`tayga/tayga.c:369`).
- **[V]** chroot requires `data-dir` and a non-root `-u` ("chroot is ineffective without also specifying the -u
  option", `tayga/tayga.c:424-429,456-461`). The tun is opened (and renamed) before chroot/setuid
  (`tun_setup` at l.535, chroot l.537-548, setgid/setuid l.550-567).
- **[V]** pidfile is opened before daemonising and written after (`tayga/tayga.c:470-493`), mode 0644.
- **[V]** Signals: SIGINT/SIGQUIT/SIGTERM/SIGUSR1/SIGUSR2 exit cleanly; SIGHUP reloads the map-file only in `main`
  and **exits in 0.9.6** (section 2.2).
- **[V]** No dedicated system user is created by the port (pkg-plist). `nobody` or a plugin-created user would be
  needed for `-u`.

### 2.7 How the existing os-tayga plugin plumbs the tun into OPNsense

- **[V]** `plugins/net/tayga/src/etc/rc.d/opnsense-tayga:22-34`:
  ```sh
  ${command} ${command_args}            # tayga -p /var/run/tayga.pid, tun-device nat64
  sleep 1
  ifconfig nat64 inet ${tayga_v4destination}/32 ${tayga_v4address}
  ifconfig nat64 inet6 ${tayga_v6destination}/128
  ifconfig nat64 group tayga
  route -4 add ${tayga_v4pool} -interface nat64
  route -6 add ${tayga_v6prefix} -interface nat64
  ```
  i.e. addresses and routes are applied *after* tayga has opened the device (consistent with the purge-on-close
  behaviour above), point-to-point style (`local/32 peer`, peer = tayga's `ipv4-addr`).
- **[V]** It registers only a firewall **interface group**, not an assignable interface
  (`plugins/net/tayga/src/etc/inc/plugins.inc.d/tayga.inc:66-80`: `$oic['if'] = 'tayga'; $oic['type'] = 'group';
  $oic['virtual'] = true;`).
- **[V]** The official how-to makes the user add the rules by hand: a pass rule on the "Tayga" group
  (IPv4+IPv6) and an outbound NAT rule on WAN for the pool - https://docs.opnsense.org/manual/how-tos/tayga.html
- **[V]** Restart glue: `actions_tayga.conf:1-20` runs `/usr/local/etc/rc.routing_configure` after start/restart.

### 2.8 pf interaction of a tun-based CLAT (derived from the kernel facts above)

Packet walk for LAN host -> IPv4 internet with NAT44 to 192.0.0.1 on the tun (**[L]**: each step follows from
verified code, the whole chain is untested):

1. IPv4 in on LAN (normal LAN pass rule, state).
2. Route lookup: IPv4 default route points at the tun -> pf **out on tun**: outbound NAT rewrites the source to
   192.0.0.1; passed by OPNsense's default "let out anything from firewall host itself" rule, which is a plain
   `pass out` with no source restriction (`core/src/etc/inc/filter.lib.inc:544-550`).
3. tayga reads, translates, writes an IPv6 packet (src = CLAT /128, dst = `pref64::a.b.c.d`).
4. That packet arrives **in on tun, inet6** (`rcvif = tun`). Nothing in a default ruleset passes it. **A pass rule
   `in on <tun> inet6 from <CLAT addr> to <pref64>` is required.** OpenWrt adds the equivalent rule
   (`openwrt/package/network/ipv6/464xlat/files/464xlat.sh:67-78`: `type rule, family inet6, direction in,
   src_ip $ip6addr, target ACCEPT`).
5. IPv6 forwarded, pf out on the PPPoE WAN (default pass out, state), onto the wire.
6. Return: IPv6 in on WAN matches the state from 5 -> routed by the /128 route to the tun -> pf out on tun matches
   the state from 4 -> tayga -> IPv4 written back -> **in on tun, inet** matches the NAT state from 2 -> un-NAT ->
   out on LAN matches the state from 1.

Other OPNsense ruleset facts that touch this path:

- **[V]** OPNsense emits `antispoof log for <if>` for every assigned interface before the filter rules
  (`core/src/etc/inc/filter.inc:575-578`, ordering at l.388-390). `antispoof for X` expands to
  `block drop in on ! X inet6 from <X:network> to any` (`src/share/man/man5/pf.conf.5:2805-2835`). If the CLAT /128
  is taken from the WAN /64 (the OpenWrt model) or from a LAN /64, the translated packets entering on the tun match
  that block. The generated antispoof rules are not `quick` unless requested (`src/sbin/pfctl/parse.y:1570-1585`,
  `r.quick = $2.quick`) and OPNsense does not request it, so a later matching pass rule wins. Net effect: the pass
  rule of step 4 is doubly necessary, and without it the drop is logged as an antispoof/default-deny hit.
- **[V]** Shared forwarding is on by default on new installs (`core/src/etc/config.xml.sample:43`
  `<pf_share_forward>1</pf_share_forward>`; `core/src/etc/inc/system.inc:129-130`). It only matters for route-to
  style rules on this path.
- **[V]** `set skip on` is only applied to `lo0`, `pfsync0`, VTI ipsec devices (`core/src/etc/inc/filter.inc:373-377`).

Assignability (pointer only, owned by another research topic):

- **[V]** `tun` and `tap` are in `interfaces_virtual_patterns()` (`core/src/etc/inc/interfaces.lib.inc:563-595`) and
  core registers `['pattern' => '_stf|^tap|^tun|^ue', 'volatile' => true]` (`core/src/etc/inc/plugins.inc.d/core.inc:290-291`).
  A device named e.g. `nat64` or `clat0` matches none of these patterns, so `get_interface_list()`
  (`interfaces.lib.inc:636-640`) treats it like a physical port. Plugins can declare devices through a
  `<plugin>_devices()` hook (`core/src/etc/inc/plugins.inc:94-102`, examples in `wireguard.inc:101-120`,
  `loopback.inc:53-72`).

### 2.9 Performance expectations

- **[V]** Architecture limit on FreeBSD: one thread, three syscalls and two user/kernel copies per packet, no
  batching, no GSO/GRO, no multiqueue (2.5). `tunwrite` hands the packet to `netisr_dispatch`
  (`src/sys/net/if_tuntap.c:2011`); **[L]** with the default direct dispatch policy the forwarding and pf work for
  the translated packet then runs in tayga's own thread as well.
- **[V]** Published numbers are Linux-only and for old 0.9.2:
  - slxh.eu 2021, single TCP iperf3 flow: PC Engines APU (AMD GX-412TC): tayga **199 Mbit/s** NAT64 / 197 NAT46
    (native IPv4 903); Ryzen 5 2600X: tayga **2971 / 2807 Mbit/s** (native 8478); Jool 805 and 8193 Mbit/s on the same
    machines; OpenBSD pf af-to 572 and 2354 Mbit/s - https://www1.slxh.eu/blog/2021/nat64-performance/
  - RIPE 85 "Open Source NAT64" slides describe tayga as user-space, slow and core-bound at roughly 3 Gbit/s -
    https://ripe85.ripe.net/presentations/78-ripe85-open-source-nat64.pdf (seen via search summary only, **[U]** for exact wording).
- **[V]** Upstream acknowledges it: issue #40 "Tayga's performance is significantly lower than most (all?)
  comparable projects"; the multiqueue/GSO/io_uring/eBPF work is "Currently Linux only. Other platforms can fall back
  to the existing single-packet translation" - https://github.com/apalrd/tayga/issues/40
- **[U]** No FreeBSD or OPNsense throughput measurement for tayga was found. Expect roughly single-core-bound
  throughput, in the low hundreds of Mbit/s on Atom/Jaguar-class CPUs and above 1 Gbit/s on desktop-class cores, to be
  measured (section 9).

### 2.10 Behaviour on address change

- **[V]** 0.9.6: restart only (2.2). On FreeBSD a restart closes the tun, which removes its addresses, downs it and
  flips link state (2.5), so the full interface bring-up must be replayed after every restart.
- **[V]** `main`: `map-file` entries reload on SIGHUP without touching other entries ("guaranteed to not affect
  packet processing for entries which are not modified", `tayga/docs/man/tayga.conf.5.md:137-151`;
  implementation `tayga/addrmap.c:1107-1210`). `prefix` and `ipv6-addr` are still startup-only.
- **[L]** pf NAT44 states towards 192.0.0.1 survive a tayga restart (the interface object persists when a `tunN`
  name is used), but flows die anyway when the CLAT IPv6 address changes because the PLAT's NAT64 state is keyed on it.

---

## 3. Candidate B: ipfw `nat64clat`

### 3.1 What it is

- **[V]** In-kernel stateless CLAT, part of `ipfw_nat64` (`src/sys/netpfil/ipfw/nat64/nat64clat.c`,
  `nat64clat_control.c`, shared code in `nat64_translate.c`). Man page: "XLAT464 CLAT NAT64 translator implements
  client-side stateless translation as defined in RFC6877 ... Instead of lookup tables it uses one-to-one mapping
  between IPv4 and IPv6 addresses using configured prefixes" (`src/sbin/ipfw/ipfw.8:3838-3846`).
- **[V]** Configuration: `ipfw nat64clat <name> create clat_prefix <p6/len> plat_prefix <p6/len> [log] [allow_private]`
  (`ipfw.8:3848-3883`), then a rule with the action `nat64clat <name>` (`ipfw.8:1020-1024`). A FreeBSD forum
  example: `ipfw nat64clat NAT64 create clat_prefix 2001:db8:1234:1000::/96 plat_prefix 64:ff9b::/96 log allow_private`
  and `ipfw add nat64clat NAT64 ip from any to any` - https://forums.freebsd.org/threads/nat64-464xlat.73741/
- **[V]** It is **an ipfw rule action, not an interface**: entry point `ipfw_nat64clat(struct ip_fw_chain *chain,
  struct ip_fw_args *args, ipfw_insn *cmd, int *done)` (`nat64clat.c:202-252`) is called from rule evaluation. There
  is no ifnet. It can be *matched* on an interface with ordinary ipfw `recv/xmit/via` options but cannot be bound to
  one.
- **[V]** Both prefixes must be RFC 6052 lengths (`nat64_check_prefix6`, `nat64clat_control.c:159-161`;
  lengths 32/40/48/56/64/96 in `nat64_translate.c:275-289`). The IPv4 source is always embedded into `clat_prefix`
  (`nat64clat.c:98-101`). **There is no single-/128 mode**; a /96 (in practice a dedicated /64) must be routed to the
  box, or NAT44 must run first so that all sources become one embedded address.

### 3.2 Output path and pf interplay

- **[V]** Default: re-injection. "After translation NAT64 translator by default sends packets through corresponding
  netisr queue ... Also this means, that a packet is handled by firewall twice" (`ipfw.8:3657-3669`);
  `nat64_output()` does `netisr_queue(NETISR_IP|NETISR_IPV6, m)` keeping the original `rcvif`
  (`nat64_translate.c:229-260`).
- **[V]** `net.inet.ip.fw.nat64_direct_output=1`: "after translation it will be pushed directly to outgoing
  interface" (`ipfw.8:4376-4396`); `nat64_direct_output()` calls `(*ifp->if_output)(ifp, m, dst, NULL)` after its own
  FIB lookup (`nat64_translate.c:157-227`), which **bypasses every pfil hook, including pf's outbound hook**.
- **[V]** Hook order on OPNsense is deliberately managed by `core/src/opnsense/scripts/shaper/sync_fw_hooks.py:73-98`:
  ipfw is unlinked and re-linked with `-a` when `pfilctl heads` lists it first on input or last on output.
  With the kernel list semantics in `src/sys/net/pfil.c:431-456` (append = tail of the in-list, head of the out-list)
  the resulting order is **[L]** **in: pf then ipfw; out: ipfw then pf**.
- **[L]** Consequences, by reading both paths:
  - netisr mode: the translated IPv6 packet re-enters as *input on the LAN interface* with a source in
    `clat_prefix`, and the translated IPv4 reply re-enters as *input on the WAN interface* addressed to a LAN host.
    Neither matches an existing pf state, so both need explicit pf pass rules, the second one being an inbound
    IPv4 allow on WAN.
  - direct mode: the outbound IPv6 packet never creates a pf state on WAN, so the PLAT's replies hit pf's default
    deny on WAN unless a stateless pass rule is added, after which ipfw translates and pushes straight to the LAN
    interface, again around pf.
  Either way pf rules are needed and/or pf stateful filtering is circumvented.

### 3.3 Interaction with OPNsense's own ipfw usage

- **[V]** OPNsense enables ipfw only for traffic shaper rules or captive portal zones:
  `firewall_enable="{% if cp_zones or rules %}YES{% else %}NO{% endif %}"`
  (`core/src/opnsense/service/templates/OPNsense/IPFW/rc.conf.d:20-22`).
- **[V]** On **every** `filter_configure_sync()` core runs `/usr/local/opnsense/scripts/shaper/start.sh`
  (`core/src/etc/inc/filter.inc:174-179`), which, when ipfw is not enabled by core, executes
  `/etc/rc.d/ipfw onestop` and `/sbin/ipfw -f flush` (`core/src/opnsense/scripts/shaper/start.sh:33-42`).
  `rc.d/ipfw` stop sets `net.inet.ip.fw.enable=0` (fetched from
  `https://raw.githubusercontent.com/opnsense/src/stable/26.7/libexec/rc/rc.d/ipfw`).
  **A plugin's ipfw rules would be flushed and ipfw disabled at each firewall reload.**
- **[V]** When core does enable ipfw, the ruleset is a core-owned template that starts with `flush`
  (`core/src/opnsense/service/templates/OPNsense/IPFW/ipfw.conf:21-24`), ends with `add 65533 pass ip from any to any`
  and `add 65534 deny all from any to any` (l.120-124), and has no plugin include point.
- **[V]** Kernel build: OPNsense's 26.7 kernel config includes GENERIC plus `options IPFIREWALL_DEFAULT_TO_ACCEPT`,
  `IPFIREWALL_VERBOSE`, `IPSTEALTH`, `RSS`, `device netmap`; **no `IPFIREWALL_NAT64`**
  (https://raw.githubusercontent.com/opnsense/tools/master/config/26.7/SMP). `sys/modules/ipfw_nat64` exists in
  `opnsense/src` `stable/26.7`, so `ipfw_nat64.ko` is **[L]** shipped as a module but this was not confirmed on a box.

### 3.4 Correctness notes from the code

- **[V]** "NAT64 translator follows RFC7915 when does ICMPv6/ICMP translation, unsupported message types will be
  silently dropped" (`ipfw.8:3649-3650`).
- **[V]** 4->6 fragmentation uses the IPv6 route MTU; with DF set it returns frag-needed with
  `FRAGSZ(nh->nh_mtu) + sizeof(struct ip)` = route MTU - 28 (`nat64_translate.c:1277-1282`, `FRAGSZ` at l.534).
- **[V]** UDP with zero checksum is not special-cased on 4->6: the code unconditionally does
  `*csum = cksum_add(*csum, ~nat64_cksum_convert(&ip6, ip));` (`nat64_translate.c:1308-1316`).
  **[L]** That yields a non-zero but wrong IPv6 UDP checksum instead of the drop-or-recompute behaviour RFC 7915
  describes. tayga (`calc`) and pf af-to (`pf.c:9617-9625`) both handle this case.
- **[V]** ND must be excluded from translation rules by hand (`ipfw.8:3651-3655`).

### 3.5 Verdict

No interface, mandatory ipfw rules, core actively tears ipfw down, pf is either double-traversed with extra rules
or bypassed. It conflicts with both the "virtual interface" preference and the "do not own firewall rules"
constraint.

---

## 4. Candidate C: pf `af-to` (datapath summary only)

- **[V]** Present in the 26.7 kernel and pfctl. Man page: "Translation between different address families (NAT64) is
  handled using af-to rules. Because address family translation overrides the routing table, it's only possible to
  use af-to on inbound rules, and a source address of the resulting translation must always be specified"
  (`src/share/man/man5/pf.conf.5:1367-1376`). CLAT-shaped example in the man page:
  `pass in on $v4_if inet af-to inet6 from ($v6_if) to 64:ff9b::/96` (l.3369-3374).
- **[V]** Stateful, rule-driven, in-kernel: `PFRULE_AFTO` handled in `pf_rule_apply_nat()` (`src/sys/netpfil/pf/pf.c:5640-5654`),
  header rewrite in `pf_translate_af()` (l.3652-3782), then `pf_route()/pf_route6()` do their own FIB lookup
  ("We're in the AFTO case. Do a route lookup", l.9249-9265 and l.9599-9613) and transmit. For such states the
  outbound `pf_test` on the egress interface is skipped (`skip_test = true`, l.9319-9320 and l.9666-9667).
- **[V]** Because one source address is given and a state is kept, it performs N:1 translation in one step
  (NAT44 + CLAT collapsed), so a single /128 is enough and no 192.0.0.1 hop is needed.
- **[V]** ICMP and ICMP-embedded packets are translated (`pf_change_icmp_af` at l.3785, `pf_translate_icmp_af` at
  l.3872, call sites l.8047-8919); UDP zero checksum is recomputed on 4->6 (l.9617-9625); TTL 1 produces the
  ICMP error before translation (l.3664-3677).
- **[V]** It creates **no interface**. Traffic is selected by a rule on the ingress interface, not by routing.
  Locally originated IPv4 traffic never passes an inbound rule, which is why OpenBSD's `gelatod` needs two patched
  `pair(4)` interfaces in different routing domains plus a default route through them
  (https://codeberg.org/fobser/gelatod: `ifconfig pair2 rdomain 1`, `ifconfig pair1 patch pair2`,
  `route add -host -inet default 192.0.0.1 -priority 48`, rule
  `pass in log quick on pair2 inet af-to inet6 from <v6> to 64:ff9b::/96 rtable 0`).
- **[V]** OPNsense-specific datapath risk: with shared forwarding enabled (default, see 2.8) `pf_route6()` returns
  early after tagging the mbuf (`if (V_pf_share_forward6) { ... ip6_set_fwdtag(m0, &dst, ifp) ... return (action); }`,
  l.9635-9647), before the code that actually transmits the translated packet. Maintainer comment on PR #10638:
  "This will not work well with shared forwarding. I suggest this to be something for 27.1" and "all the
  implementation is done in pf_route/pf_route6 so even if it looks like features do not overlap they actually do"
  (`REFS/gh/opnsense_core_10638.md:39-61`). **[L]** 4->6 af-to is therefore unreliable on a default 26.7 install.
- Throughput **[L]**: kernel path with normal pf state lookup, multi-core. The only measurement found is OpenBSD's
  pf (572 Mbit/s on APU, 2354 Mbit/s on Ryzen 2600X, slxh.eu 2021), not FreeBSD's.

---

## 5. Candidate D: everything else

| Name | Status on FreeBSD / OPNsense | Evidence |
|---|---|---|
| clatd | Linux Perl wrapper around tayga + iproute2; no FreeBSD port (`freebsd-ports/net/clatd` returns 404, **[V]**) | Debian control "Depends: ... tayga, libnet-ip-perl, libnet-dns-perl" (seen in search summary, **[L]**); draft-nbrr-v6ops-clat-status cites it as the Linux third-party CLAT **[V]** |
| Jool | Linux kernel modules; no FreeBSD port (`freebsd-ports/net/jool` 404) | **[V]** for absence in ports; Linux-only nature **[L]** |
| nat46 (OpenWrt) | Linux kernel module driven through `/proc/net/nat46/control` | `openwrt/package/network/ipv6/464xlat/src/464xlatcfg.c:127-131` **[V]** |
| tundra-nat64 | "an open-source IPv6-to-IPv4 & IPv4-to-IPv6 translator for Linux", userspace, multi-thread | https://github.com/vitlabuda/tundra-nat64 **[V]** |
| gelatod | "a CLAT configuration daemon for OpenBSD"; only configures OpenBSD pf af-to rules in an anchor | https://codeberg.org/fobser/gelatod **[V]** |
| netgraph | No NAT64/SIIT node (`ng_nat`, `ng_ipfw`, `ng_iface` etc. exist, none translates address families) | none of the `src/share/man/man4/ng_*.4` pages is a NAT64 node; grep for `nat64|464XLAT|CLAT|SIIT` in `src/share/man/man4` matches only `ipfirewall.4` **[V]** |
| kernel pseudo-interface | None. `sys/net` contains no translation ifnet (`nat64` appears only in `pfvar.h`) | grep in `src/sys/net` **[V]** |
| FreeBSD-native daemon in ports | Only `net/tayga` found | FreshPorts search endpoints returned HTTP 401, so an exhaustive ports search was not possible **[U]** |

IETF status draft: "BSD systems with the ipfw toolkit support CLAT" but "This support must be manually enabled within
the ipfw configuration and does not come on by default"
(https://www.ietf.org/archive/id/draft-nbrr-v6ops-clat-status-00.html) **[V]**.

---

## 6. Reference model: what OpenWrt's 464xlat actually does

All **[V]** from `openwrt/package/network/ipv6/464xlat/`:

- `464xlat.sh:40`: `ip6addr=$(464xlatcfg "$link" "$tundev" "$ip6prefix" 192.0.0.1 $ip6addr)`.
- `464xlatcfg.c:64-76`: if no prefix is configured it resolves `ipv4only.arpa` (RFC 7050) and assumes `/96`.
- `464xlatcfg.c:82-120`: the CLAT IPv6 address is derived from the WAN device's own source address with random lower
  64 bits and joined as an **anycast address on the WAN device** (`IPV6_JOIN_ANYCAST`).
- `464xlatcfg.c:127-131`: `config <name> local.style NONE local.v4 192.0.0.1/32 local.v6 <addr>/128 remote.style RFC6052 remote.v6 <prefix>`.
- `464xlat.sh:51-53`: IPv4 default route via the device with metric 2048; IPv6 `/128` route for the CLAT address.
- `464xlat.sh:58-78`: firewall data: `type nat, target SNAT, family inet, snat_ip 192.0.0.1` and an inet6 accept
  rule for `src_ip $ip6addr`.

This is the RFC 6877 section 6.3 fallback (no dedicated prefix -> NAT44 to one IPv4 address, statelessly translated
to one IPv6 address claimed on the uplink). RFC 6877 does not itself name 192.0.0.0/29 - https://www.rfc-editor.org/rfc/rfc6877.txt **[V]**.

---

## 7. Worked configuration for tayga-on-tun on FreeBSD 15 (derived, NOT executed)

Placeholders: PPPoE WAN `pppoe0`, IPv6 MTU 1492; PLAT prefix `64:ff9b::/96`; CLAT user address `CLAT6`,
tayga's own address `CLAT6_SELF` (the upstream docs use a /127 pair). Works with the shipped 0.9.6.

### 7.1 Model 1 (OpenWrt model): NAT44 to 192.0.0.1 + 1:1 map to a single /128

`/usr/local/etc/tayga-clat.conf`:

```
tun-device tun464              # or a custom name such as clat0, see the trade-off below
ipv4-addr 192.0.0.2            # tayga itself: ICMPv4 error source, answers ping; used as p2p peer / gateway
ipv6-addr <CLAT6_SELF>         # tayga itself: ICMPv6 error source; set explicitly (2.3)
map 192.0.0.1 <CLAT6>          # the one translated host
prefix 64:ff9b::/96            # PLAT prefix; RFC 6052 lengths only
udp-cksum-mode calc            # default is drop
# wkpf-strict yes              # default; keeps un-NATed RFC1918 sources from leaking when using the WKP
# offlink-mtu 1492             # default 1280; only affects DF=0 packets (2.4)
# log drop reject
```

Host side, in this order:

```sh
# (a) persistent device, only possible with a tun[0-9]+ name
/usr/local/sbin/tayga -c /usr/local/etc/tayga-clat.conf --mktun      # opens /dev/tun464 and exits
ifconfig tun464 mtu 1492                    # BEFORE the daemon starts: tayga reads the MTU once

# (b) daemon
/usr/local/sbin/tayga -c /usr/local/etc/tayga-clat.conf -p /var/run/tayga-clat.pid
#     optional: -u <user> -g <group>; -r additionally needs data-dir

# (c) after the daemon holds the device open (addresses are purged whenever it closes)
ifconfig tun464 inet 192.0.0.1 192.0.0.2 netmask 255.255.255.255 up
ifconfig tun464 inet6 -ifdisabled           # otherwise ip6_input drops tayga's IPv6 output
route -n add -inet default 192.0.0.2 -mtu 1472            # tun MTU - 20; or "-interface tun464"
route -n add -inet6 -host <CLAT6>      -interface tun464
route -n add -inet6 -host <CLAT6_SELF> -interface tun464  # optional, for tayga's own ICMPv6/ping
```

pf pieces that must exist (who creates them is a design decision):

```
nat on tun464 inet from <LAN nets> to any -> 192.0.0.1          # outbound NAT44
pass in on tun464 inet6 from { <CLAT6>, <CLAT6_SELF> } to 64:ff9b::/96   # translated traffic re-entering (2.8)
```

Notes:

- `<CLAT6>` must **not** be configured as a local address anywhere on the box, otherwise the kernel delivers the
  PLAT's replies locally instead of routing them into the tun **[L]**. It must be routed to the box by the ISP: on a
  PPP link any address inside the /64 the ISP routes down the session works without NDP; on Ethernet uplinks proxy
  NDP would be needed (upstream issue #83).
- 64:ff9b::/96 must keep following the normal IPv6 default route (never route it into the tun).
- Firewall-originated IPv4 traffic picks 192.0.0.1 as its source by normal source selection and needs no NAT **[L]**.
- Name trade-off **[V]**: `tun[0-9]+` gives a persistent ifnet across restarts and allows setting the MTU before
  start, but matches OPNsense's `^tun` volatile pattern. A custom name is created by tayga at each start with MTU
  1500, cannot use `--mktun`, and must be destroyed before the next start (`ifconfig <name> destroy`), which
  recreates the ifnet each time.

### 7.2 Model 2: dedicated prefix, stateless, no NAT44

Requires a prefix that the ISP routes to the box and that is not on-link anywhere (e.g. an otherwise unused /64 of
the delegated prefix); use a /96 inside it as CLAT prefix `P96::/96`.

```
tun-device tun464
ipv4-addr 192.0.0.2
ipv6-addr P96::c000:2                       # = P96::192.0.0.2, outside every map below
prefix 64:ff9b::/96
udp-cksum-mode calc
map 192.0.0.1        P96::c000:1            # the firewall's own IPv4 traffic
map 192.168.1.0/24   P96::c0a8:100/120      # one line per LAN subnet, host bits must match (/24 <-> /120)
# or cover all RFC1918 space:
# map 10.0.0.0/8     P96::a00:0/104
# map 172.16.0.0/12  P96::ac10:0/108
# map 192.168.0.0/16 P96::c0a8:0/112
```

```sh
# same (a) (b) as above, then:
ifconfig tun464 inet 192.0.0.1 192.0.0.2 netmask 255.255.255.255 up
ifconfig tun464 inet6 -ifdisabled
route -n add -inet default 192.0.0.2 -mtu 1472
route -n add -inet6 -net P96::/96 -interface tun464
```

pf: **no** NAT on the tun (OPNsense's automatic outbound NAT for that interface would have to be suppressed), and
`pass in on tun464 inet6 from P96::/96 to 64:ff9b::/96`.

Constraints **[V]**: no `map 0.0.0.0/0` together with `prefix` (2.3); a LAN source not covered by a `map` is
rejected only when the WKP + strict mode are in use, otherwise it is mapped into the PLAT prefix (2.3). The `/64`
variant of "one IPv6 /64 for the whole IPv4 space" is not expressible with tayga's equal-suffix rule; the unit is a /96.

### 7.3 MTU arithmetic for PPPoE (from 2.4)

| WAN IPv6 MTU | tun MTU | IPv4 MTU seen by hosts (tun MTU - 20) | TCP MSS (IPv4) |
|---|---|---|---|
| 1492 (plain PPPoE) | 1492 | 1472 | 1432 |
| 1500 (RFC 4638) | 1500 | 1480 | 1440 |
| unknown path, conservative (upstream docs) | any | route MTU 1260 | 1220 |

With DF=1 traffic tayga itself answers oversize packets with ICMPv4 frag-needed `tun MTU - 20`; with the tun left at
1500 on a 1492 link the kernel instead emits ICMPv6 PTB on forwarding, which tayga translates back (works, one extra
round trip) **[L]**.

---

## 8. Ranked recommendation for the virtual-interface approach

1. **tayga 0.9.6 on a tun interface.** The only candidate that exists as a package on 26.7 *and* yields a real ifnet
   that the normal router machinery (route, gateway, outbound NAT) can use. Translation quality is adequate
   (RFC 7915 with documented gaps). Costs: single-threaded userspace throughput; restart on any address or prefix
   change; FreeBSD tun lifecycle quirks (addresses purged on close, IPv6 disabled by default, rename/EEXIST);
   one unavoidable inet6 pass-in rule on the tun plus NAT44 (which OPNsense's outbound NAT can supply).
2. **pf af-to.** Superior datapath (kernel, stateful, N:1 in one step, proper ICMP and UDP handling) but it is a
   firewall rule without an interface, is not usable from the OPNsense rule engine before 27.1, and currently
   collides with shared forwarding. It is what the plugin should hand over to, not compete with.
3. **ipfw nat64clat.** Technically a CLAT, practically incompatible with OPNsense (section 3).
4. **Others.** Nothing available.

---

## 9. MUST verify on a real OPNsense 26.7 box

Package and process
1. `pkg search tayga` / `tayga --help` on 26.7: version really 0.9.6; unknown directives (`workers`, `map-file`,
   `tun-*`) abort start; SIGHUP terminates.
2. `-u/-g` privilege drop with an existing user; `-r` with `data-dir`; syslog lines arrive with ident `tayga`.

tun lifecycle
3. `tun[0-9]+` name: interface persists over daemon restart; addresses and UP flag are lost on close and must be
   re-applied; whether static routes via the tun survive a close.
4. Custom name: created with MTU 1500; restart fails with a stale interface until `ifconfig destroy`.
5. Link up/down events on daemon start/stop and how OPNsense (devd, `rc.linkup`, gateway monitoring) reacts when
   the tun is an assigned interface.
6. How the interface shows up in Interfaces > Assignments for a `tunN` name versus a custom name.

Kernel plumbing
7. `ifconfig <tun> inet6 -ifdisabled` is required and sufficient (no IPv6 address on the tun).
8. `route add -inet6 -host <CLAT6> -interface <tun>` is accepted with no IPv6 address on the tun.
9. CLAT /128 chosen from the PPPoE WAN /64 is actually delivered by the ISP; behaviour when the same address is
   accidentally also configured locally.

pf
10. Exact rule set needed: confirm only the inet6 pass-in on the tun is missing by default; confirm antispoof
    logging/blocking behaviour for a CLAT address inside the WAN or a LAN /64.
11. Whether automatic outbound NAT covers the tun once it is assigned with an IPv4 gateway, and translates to 192.0.0.1.
12. `reply-to`/`route-to` generation for a WAN-type tun (force-gateway rule, multi-WAN policy routing) and shared
    forwarding on/off.
13. pf `scrub`/reassembly with tayga-generated IPv6 fragments (DF=0 UDP larger than `offlink-mtu`).

Functional
14. TCP, UDP (incl. zero-checksum senders with `udp-cksum-mode calc`), ICMP echo, traceroute through the CLAT.
15. PMTUD in both directions: ICMPv4 frag-needed value from tayga, ICMPv6 PTB from the WAN translated back through
    the NAT state; large DF=0 UDP.
16. Firewall-originated IPv4 (source 192.0.0.1), DNS, gateway monitor target 192.0.0.2 (only proves tayga is alive)
    versus a remote IPv4 target.
17. PPPoE reconnect with a changed IPv6 prefix: restart ordering, time to recover, stale pf states.
18. PLAT using a network-specific prefix instead of 64:ff9b::/96 with `wkpf-strict` yes/no and un-NATed sources.

Performance
19. iperf3 TCP and UDP through the CLAT on the target hardware over real PPPoE; tayga CPU share; latency under load.

Alternatives (only if considered)
20. `kldload ipfw_nat64` availability; confirmation that a firewall reload flushes plugin ipfw rules.
21. A hand-written `pass in ... af-to` rule on 26.7 with shared forwarding on and off.

---

## 10. Sources

Local: files cited inline under `REFS/` (tayga, opnsense-src, opnsense-core, opnsense-plugins, opnsense-ports, openwrt, gh).

Web:
- https://raw.githubusercontent.com/apalrd/tayga/0.9.6/conffile.c , `/tayga.c` , `/nat64.c` (0.9.6 tag; `/tun.c` does not exist at that tag)
- https://github.com/apalrd/tayga/releases
- https://github.com/apalrd/tayga/issues/83 , https://github.com/apalrd/tayga/issues/98 , https://github.com/apalrd/tayga/issues/40
- https://www.freshports.org/net/tayga/
- https://docs.opnsense.org/manual/how-tos/tayga.html
- https://raw.githubusercontent.com/opnsense/tools/master/config/26.7/SMP
- https://github.com/opnsense/src/tree/stable/26.7/sys/modules/ipfw_nat64
- https://raw.githubusercontent.com/opnsense/src/stable/26.7/libexec/rc/rc.d/ipfw
- https://www1.slxh.eu/blog/2021/nat64-performance/
- https://forums.freebsd.org/threads/nat64-464xlat.73741/
- https://codeberg.org/fobser/gelatod
- https://github.com/vitlabuda/tundra-nat64
- https://www.ietf.org/archive/id/draft-nbrr-v6ops-clat-status-00.html
- https://www.rfc-editor.org/rfc/rfc6877.txt
