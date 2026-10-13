# OpenWrt `464xlat` package: end-to-end reverse engineering

Research date: 2026-10-10. Scope: facts only, no design.

Confidence legend: **[V]** verified (primary source read), **[L]** likely (inferred from strong evidence), **[U]** unverified.

`REFS` = `refs` (local clones, not in this repository)

## 0. Sources read

| What | Where | Pin |
|---|---|---|
| 464xlat package | `REFS/openwrt/package/network/ipv6/464xlat/{Makefile,files/464xlat.sh,src/464xlatcfg.c}` | PKG_RELEASE 13 |
| odhcp6c glue | `REFS/openwrt/package/network/ipv6/odhcp6c/files/{dhcpv6.sh,dhcpv6.script}`, `Makefile` | odhcp6c `10a52220aec9d45803518d8cc4d63e552484ed61` (2026-06-27) |
| odhcp6c C source | `https://raw.githubusercontent.com/openwrt/odhcp6c/10a52220aec9d45803518d8cc4d63e552484ed61/src/{ra.c,script.c,odhcp6c.h}` (+ `master`) | same |
| netifd | `https://raw.githubusercontent.com/openwrt/netifd/06d06c86d757196e56bb13a1a8d6d69df7cad04d/{scripts/netifd-proto.sh,interface.c,proto-ext.c,ubus.c}` | pinned in `REFS/openwrt/package/network/config/netifd/Makefile:9` |
| firewall4 | `https://raw.githubusercontent.com/openwrt/firewall4/b6e5157527d361f99ad52eaa6da273cb0f2dfd59/root/usr/share/ucode/fw4.uc`, `.../templates/{redirect.uc,ruleset.uc}` | pinned in `REFS/openwrt/package/network/config/firewall4/Makefile:13` |
| nat46 kernel module | `https://raw.githubusercontent.com/ayourtch/nat46/adb2f72e6fb81ee11b54513d384b68e3c3d93464/nat46/modules/{README,nat46-netdev.c,nat46-core.c}` | pinned in `https://raw.githubusercontent.com/openwrt/openwrt/main/package/kernel/nat46/Makefile` |
| LuCI protocol | `https://raw.githubusercontent.com/openwrt/luci/master/protocols/luci-proto-ipv6/htdocs/luci-static/resources/protocol/464xlat.js` | master |
| ppp glue | `https://raw.githubusercontent.com/openwrt/openwrt/main/package/network/services/ppp/files/{ppp.sh,lib/netifd/ppp6-up}` | main |
| Linux kernel | `https://raw.githubusercontent.com/torvalds/linux/v6.12/net/ipv6/{anycast.c,ndisc.c,addrconf.c}` | v6.12 |

Package composition **[V]** (`464xlat/Makefile:15,37-42`): depends on `@IPV6 +kmod-nat46 +ip`; installs exactly two files, `/lib/netifd/proto/464xlat.sh` (netifd protocol handler, 118 lines of shell) and `/sbin/464xlatcfg` (154-line C helper). There is no daemon doing translation: translation is done in-kernel by the out-of-tree `nat46` module; `464xlatcfg` only configures it and then parks a child process that holds one socket open.

---

## 1. Trigger: what creates the interface, when, options, names

### 1.1 Two ways an interface with `proto 464xlat` comes to exist

**(a) Automatic, from the DHCPv6/RA client script** **[V]** — `odhcp6c/files/dhcpv6.script:155-221`:

```sh
# If the flag '$DYNAMIC' is set to '0' (default=1), then the dynamic
# interfaces for the proto 'map', 'dslite' or '464xlat' are not
# created, even if the requirements are met.
[ "$DYNAMIC" = 0 ] && return
...
if [ "$IFACE_MAP" != 0 ] && [ -n "$MAPTYPE" ] && [ -n "$MAPRULE" ]; then
	... proto map ...
elif [ -n "$AFTR" ] && [ "$IFACE_DSLITE" != 0 ] && [ -f /lib/netifd/proto/dslite.sh ]; then
	... proto dslite ...
elif [ "$IFACE_464XLAT" != 0 ] && [ -f /lib/netifd/proto/464xlat.sh ]; then
	[ -z "$IFACE_464XLAT" -o "$IFACE_464XLAT" = 1 ] && IFACE_464XLAT=${INTERFACE}_4
	json_init
	json_add_string name "$IFACE_464XLAT"
	json_add_string ifname "@$INTERFACE"
	json_add_string proto "464xlat"
	json_add_string tunlink "$INTERFACE"
	json_add_string _addrsig "$addrsig"
	[ -n "$ZONE_464XLAT" ] || ZONE_464XLAT=$ZONE
	[ -n "$ZONE_464XLAT" ] && json_add_string zone "$ZONE_464XLAT"
	[ -n "$IFACE_464XLAT_DELEGATE" ] && json_add_boolean delegate "$IFACE_464XLAT_DELEGATE"
	json_close_object
	ubus call network add_dynamic "$(json_dump)"
fi
```

Consequences:

- Priority is MAP (S46 options present) > DS-Lite (AFTR option present) > 464XLAT. MAP and DS-Lite are gated on a DHCPv6 signal; **464XLAT is gated on nothing but the package being installed**. It is the unconditional fall-through. **[V]**
- There is **no check for a NAT64 prefix, PREF64, DNS64, or the absence of native IPv4** before the interface is created. **[V]**
- `setup_interface` runs on every odhcp6c event `bound`, `informed|updated|rebound`, and `ra-updated` (when any address/prefix is present) — `dhcpv6.script:231-245`. So `add_dynamic` is re-issued on every such event. **[V]**
- `ZONE` defaults to the firewall zone of the parent: `[ -n "$ZONE" ] || ZONE=$(fw3 -q network $INTERFACE 2>/dev/null)` (`dhcpv6.script:174`). **[V]**

**(b) Manual UCI section** **[V]** (form confirmed in forum threads and the 2017 lede-dev thread; options from `464xlat.sh:106-114`):

```
config interface 'clat'
	option proto '464xlat'
	option ip6prefix '64:ff9b::/96'   # optional
	option tunlink 'wan6'             # optional
	option zone 'wan'                 # practically required, see 5.3
```

### 1.2 Options and defaults

`464xlat.sh:106-114` **[V]**:

```sh
proto_464xlat_init_config() {
	no_device=1
	available=1
	proto_config_add_string "ip6prefix"
	proto_config_add_string "ip6addr"
	proto_config_add_string "tunlink"
	proto_config_add_string "zone"
}
```

| Option (on the 464xlat interface) | Default | Meaning |
|---|---|---|
| `ip6prefix` | empty → autodetect via DNS | NAT64/PLAT prefix **with** `/len`, passed verbatim to nat46 as `remote.v6` |
| `ip6addr` | empty → derived | CLAT IPv6 address (single address, no `/len`); bypasses derivation |
| `tunlink` | empty → `network_find_wan6` | logical upstream IPv6 interface |
| `zone` | empty → `fw3 -q network $iface`; `-` means none | firewall zone for the CLAT interface |

There is **no `mtu` option, no IPv4 address option, no metric option** in the handler. **[V]** `192.0.0.1` and metric `2048` are hard-coded (`464xlat.sh:40,52,65`). Hans Dedecker (maintainer, 2017): "you cannot specify an IPv4 address" (https://lists.infradead.org/pipermail/lede-dev/2017-October/009191.html). **[V]**

Options on the parent `proto dhcpv6` interface (`dhcpv6.sh:34-35,49,196-214`) **[V]**:

| Option | Default | Effect |
|---|---|---|
| `iface_464xlat` | unset = auto | `0` disables; `1`/unset → name `<parent>_4`; any other string = logical name to use |
| `zone_464xlat` | parent's zone | zone for the dynamic CLAT interface |
| `dynamic` | `1` | `0` suppresses all dynamic 4in6 interfaces (added Nov 2025, openwrt/openwrt PR #20368, commit `32c46b5`) |
| `delegate` | `1` | `0` → `delegate 0` propagated to the CLAT interface |

### 1.3 Names

- Logical interface: `<parent>_4`, e.g. `wan6_4`. **[V]** (`dhcpv6.script:209`)
- Linux netdev: `464-<logical>`, e.g. `464-wan6_4`. **[V]** (`464xlat.sh:25` `local link="464-$cfg"`)
- On PPPoE the chain is three levels **[V]**: `ppp6-up` creates dynamic `wan_6` (`proto dhcpv6`, `ifname @wan`) when `AUTOIPV6` is set (`ppp.sh:101-103,155`; `ppp6-up`: `json_add_string name "${PPP_IPPARAM}_6"` … `ubus call network add_dynamic`), and `dhcpv6.script` then creates `wan_6_4`, device `464-wan_6_4`. Matches log lines `Interface 'wan_6_4' is now down` in openwrt/openwrt#10907.
- IFNAMSIZ hazard **[V]**: `464-` + logical name must be ≤ 15 chars. openwrt/openwrt#18599 (open): `'464-pppoe_digi6_4' is longer than 15 chars, truncating` → `Failed to initalize device` → up/down loop.
- LuCI registers the pattern as virtual: `network.registerPatternVirtual(/^464-.+$/)`; shown as "Virtual dynamic interface (464XLAT (CLAT))". **[V]**

### 1.4 How netifd treats it

- `ubus call network add_dynamic` → `netifd_add_dynamic()` → `interface_alloc(name, msg, true)` + `interface_add()` (netifd `ubus.c:130-163`). **[V]**
- `no_device=1` → `PROTO_FLAG_NODEV`: the `ifname "@wan6"` attribute is not used to claim a device; the link to the parent is made by the script itself: `( proto_add_host_dependency "$cfg" "::" "$tunlink" )` (`464xlat.sh:32`). **[V]**
- Host dependency semantics (netifd `proto-ext.c:53-126,564-599`) **[V]**: the dependency attaches to the named interface only when it is `IFS_UP`; when that interface emits `IFEV_DOWN`/`IFEV_UP_FAILED`/`IFEV_FREE` the dependant gets `IFPEV_LINK_LOST` + `PROTO_CMD_TEARDOWN`.
- Dynamic interfaces are removed, not just downed, on teardown: `if (iface->dynamic) __set_config_state(iface, IFC_REMOVE);` (netifd `interface.c:357-358,405-406`). **[V]**

---

## 2. NAT64 prefix discovery

`464xlatcfg.c:61-76` **[V]**:

```c
prefix[sizeof(prefix) - 1] = 0;
strncpy(prefix, argv[3], sizeof(prefix) - 1);

if (!prefix[0]) {
	struct addrinfo hints = { .ai_family = AF_INET6 }, *res;
	if (getaddrinfo("ipv4only.arpa", NULL, &hints, &res) || !res) {
		sleep(3);
		if (getaddrinfo("ipv4only.arpa", NULL, &hints, &res) || !res)
			return 2;
	}
	struct sockaddr_in6 *sin6 = (struct sockaddr_in6*)res->ai_addr;
	inet_ntop(AF_INET6, &sin6->sin6_addr, prefix, sizeof(prefix) - 4);
	strcat(prefix, "/96");
	freeaddrinfo(res);
}
```

Facts:

1. **Only two sources**: static `ip6prefix`, else RFC 7050 DNS query for AAAA of `ipv4only.arpa` through the router's own libc resolver. **[V]**
2. **No PREF64 (RFC 8781)**. odhcp6c at the pinned commit parses only these RA options (`ra.c:595-726`): `ND_OPT_MTU`, `ND_OPT_ROUTE_INFORMATION`, `ND_OPT_PREFIX_INFORMATION`, `ND_OPT_RECURSIVE_DNS`, `ND_OPT_DNSSL`, `ND_OPT_CAPTIVE_PORTAL`. No string `pref64`/`PREF64`/`nat64` in `ra.c`, `script.c`, `odhcp6c.h`; the state enum (`odhcp6c.h:429-458`) has no PREF64 state; the env vars exported to the script (`script.c:531-562`) are `SERVER RDNSS SNTP_IP NTP_IP NTP_FQDN SIP_IP DOMAINS SIP_DOMAIN AFTR MAPE MAPT LW4O6 CAPTIVE_PORTAL_URI PREFIXES ADDRESSES RA_ADDRESSES RA_ROUTES RA_DNS RA_DOMAINS RA_HOPLIMIT RA_MTU RA_REACHABLE RA_RETRANSMIT PASSTHRU OPTION_<n>`. Same on odhcp6c `master` today. Zero PRs matching "pref64" in openwrt/odhcp6c. **[V]** (OpenWrt can *send* PREF64 from odhcpd via `ra_pref64`, but cannot *consume* it.)
3. **Retries**: exactly one retry after `sleep(3)`; then exit code 2 → script reports `CLAT_CONFIG_FAILED` (`464xlat.sh:41-44`). **[V]**
4. **Validation: none.** **[V]**
   - First `getaddrinfo` result only; other AAAA records ignored.
   - The **whole 128-bit AAAA** is used with a hard-coded `/96` — it is not masked. Real-world result seen in the wild: `remote.v6 64:ff9b::c000:aa/96` (https://forum.openwrt.org/t/464xlat-bug-missing-ipv4/249579). nat46's RFC6052 code only uses the first 96 bits, so this works.
   - No check that the low 32 bits are the well-known 192.0.0.170/171; no handling of /32,/40,/48,/56,/64 NAT64 prefixes (nat46 itself supports "32, 40, 48, 56, 64, 96" per `nat46/modules/README`); no DNSSEC, no RFC 7050 §3 verification, no TTL-based refresh.
5. **Discovered once per setup**; never refreshed while the interface is up. **[V]** (no timer, no renew handler in `464xlat.sh`)
6. Field experience: autodetect is the top reported failure. "464xlat never worked for him unless that prefix was set explicitly" (Leo-PL, openwrt/openwrt#10907); "auto detection of the NAT64 Prefix doesn't seem to be working … manually set the prefix to 64:ff9b::/96 … it starts working" (forum). With two upstreams the resolver may ask the non-DNS64 one (openwrt/openwrt#21092, open, labelled confirmed bug). **[V]** for the reports, **[L]** for root causes.

---

## 3. CLAT IPv6 address selection and inbound capture

### 3.1 Which /64 and which IID

`464xlatcfg.c:78-117` **[V]**:

```c
do {
	...
	sock = socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6);
	ICMP6_FILTER_SETBLOCKALL(&filt);
	setsockopt(sock, IPPROTO_ICMPV6, ICMP6_FILTER, &filt, sizeof(filt));
	setsockopt(sock, SOL_SOCKET, SO_BINDTODEVICE, argv[2], strlen(argv[2]));
	memset(&saddr, 0, sizeof(saddr));
	saddr.sin6_family = AF_INET6;
	saddr.sin6_addr.s6_addr32[0] = htonl(0x2001);
	saddr.sin6_addr.s6_addr32[1] = htonl(0xdb8);
	if (connect(sock, (struct sockaddr*)&saddr, sizeof(saddr)) ||
			getsockname(sock, (struct sockaddr*)&saddr, &saddrlen))
		return 3;

	if (!IN6_IS_ADDR_LINKLOCAL(&saddr.sin6_addr) || argv[5])
		break;

	close(sock);
	sleep(3);
	i++;
} while (i < 3);

struct ipv6_mreq mreq = {saddr.sin6_addr, if_nametoindex(argv[2])};
if (!argv[5]) {
	if (IN6_IS_ADDR_LINKLOCAL(&mreq.ipv6mr_multiaddr))
		return 5;

	srandom(mreq.ipv6mr_multiaddr.s6_addr32[0] ^ mreq.ipv6mr_multiaddr.s6_addr32[1] ^
			mreq.ipv6mr_multiaddr.s6_addr32[2] ^ mreq.ipv6mr_multiaddr.s6_addr32[3]);
	mreq.ipv6mr_multiaddr.s6_addr32[2] = random();
	mreq.ipv6mr_multiaddr.s6_addr32[3] = random();
} else if (inet_pton(AF_INET6, argv[5], &mreq.ipv6mr_multiaddr) != 1) {
	return 1;
}
```

- **Prefix**: the upper 64 bits of whatever source address the kernel would pick for a packet leaving the tunlink device (`argv[2]` = `network_get_device tundev "$tunlink"` = `l3_device` of the tunlink). No use of a delegated prefix as such, no dedicated /64, no /96. **[V]**
- **Quirk**: the probe destination is not `2001:db8::`. `s6_addr32[0] = htonl(0x2001)` yields bytes `00 00 20 01`, so the address is `0:2001:0:db8::`. It is still global-scope unicast, so it follows the default route. `connect()` fails (exit 3) if the tunlink device has no route covering it. **[V]** (arithmetic on lines 92-93)
- **IID**: `srandom(XOR of the four 32-bit words of the chosen source address)`, then two `random()` calls fill the low 64 bits. Deterministic per (source address, libc); 31 random bits per word, stored in host byte order; no EUI-64, no RFC 7217, no reserved-IID avoidance. **[V]**
- **Retry**: if the chosen source is link-local, retry up to 3 times at 3 s intervals; then exit 5. With `ip6addr` set the loop exits immediately and the address is taken verbatim. **[V]**
- **WAN with only a link-local address (typical PPPoE + DHCPv6-PD without a WAN GUA)** **[L]**: Linux source selection enumerates every netdev unless `use_oif_addrs_only` is set, and the scope rule precedes the outgoing-interface rule (`addrconf.c:1501-1517,1848-1892`: `IPV6_SADDR_RULE_SCOPE` before `IPV6_SADDR_RULE_OIF`; `for_each_netdev_rcu(net, dev)`). So `getsockname()` returns a global address from another interface, normally the LAN address carved from the delegated prefix. The CLAT address then lives in the **LAN /64** while being anycast-joined on the **WAN** device. This is an accident of Linux semantics, not an explicit design decision; kernel logic verified, combined behaviour not tested.

### 3.2 Making the address "exist": anycast join, no DAD

`464xlatcfg.c:119-125` **[V]**:

```c
if (setsockopt(sock, SOL_IPV6, IPV6_JOIN_ANYCAST, &mreq, sizeof(mreq)))
	return 3;
inet_ntop(AF_INET6, &mreq.ipv6mr_multiaddr, buf, sizeof(buf));
fputs(buf, stdout);
```

- The address is **not configured as an interface address** anywhere. It is joined as an **anycast** address on the tunlink (WAN) device.
- Kernel effect (`net/ipv6/anycast.c:283-340`) **[V]**: `addrconf_f6i_alloc(net, idev, addr, true, ...)` + `ip6_ins_rt()` install a local anycast route; `addrconf_join_solict()` joins the solicited-node multicast group. No DAD code path is invoked.
- NDP: `ndisc_recv_ns()` answers Neighbour Solicitations whose target satisfies `ipv6_chk_acast_addr(net, dev, &msg->target)`, with the anycast/proxy random delay (`net/ipv6/ndisc.c:907-927`). **[V]** So on an Ethernet-type WAN the router answers NS for the CLAT address without ndppd/proxy-NDP config; on PPP it is irrelevant.
- For a host (forwarding off) the join requires the address to match an on-link prefix (`anycast.c:127-137`); a router may join any address. **[V]**
- The membership lives as long as the socket. That is the sole reason for the lingering process (`464xlatcfg.c:133-151`): the forked child closes stdio, `setsid()`, `pause()`s until SIGTERM, then writes `del <name>` to nat46 and exits; the parent rewrites the pid file with the child's pid. **[V]**

### 3.3 Capturing inbound IPv6 for that address

The anycast join puts a route in table `local`, which would deliver packets to the host stack. The script re-orders policy routing so a private table is consulted first (`464xlat.sh:46-53`) **[V]**:

```sh
ip -6 rule del from all lookup local
ip -6 rule add from all lookup local pref 1
ip -6 rule add to $ip6addr lookup prelocal pref 0
echo "$ip6addr" > /tmp/464-$cfg-anycast

proto_init_update "$link" 1
proto_add_ipv4_route "0.0.0.0" 0 "" "" 2048
proto_add_ipv6_route $ip6addr 128 "" "" "" "" 128
```

- `prelocal` is table 128: `/etc/iproute2/rt_tables` in base-files has `128	prelocal`. **[V]**
- `proto_add_ipv6_route` signature is `(target, mask, gw, metric, valid, source, table)` (netifd-proto.sh), so the last line is `<clat6>/128 dev 464-<cfg> table 128`. **[V]**
- Net effect: any IPv6 packet whose destination is the CLAT address is routed to the nat46 netdev before `local` is consulted. Hans Dedecker: traffic "must reach the nat46 module through the xlat interface, which requires a rule that checks the prelocal table before local" (lede-dev 2017). **[V]**
- This globally moves the IPv6 `local` rule from pref 0 to pref 1 for the whole system. **[V]**

---

## 4. IPv4 side

| Item | Value | Evidence |
|---|---|---|
| CLAT IPv4 | `192.0.0.1/32`, hard-coded | `464xlat.sh:40` `464xlatcfg "$link" "$tundev" "$ip6prefix" 192.0.0.1 $ip6addr` **[V]** |
| IPv4 address on the netdev | **none** | no `proto_add_ipv4_address` in `464xlat.sh`; `ip addr show dev 464-lan6_4` in the forum shows only an fe80 address **[V]** |
| IPv4 route | `0.0.0.0/0 dev 464-<cfg>`, no gateway, metric **2048** | `464xlat.sh:52`; `proto_add_ipv4_route(target, mask, gw, source, metric)` **[V]** |
| netdev type | `ARPHRD_NONE`, `IFF_NOARP \| IFF_POINTOPOINT` | `nat46-netdev.c` `nat46_netdev_setup()` **[V]** |
| netdev MTU | **16384** (module default; package never changes it) | `dev->mtu = 16384; /* iptables does reassembly. ... */`; forum output `<POINTOPOINT,NOARP,UP,LOWER_UP> mtu 16384` **[V]** |
| LuCI `mtu` field | present in UI (placeholder 1280) but not declared in `proto_464xlat_init_config` | `464xlat.js` vs `464xlat.sh:106-114` **[V]**; effect on the device: none **[L]** |

- **Default-route behaviour**: a second, low-priority default route. If native IPv4 exists with the usual metric 0 it wins and CLAT is an idle fallback; nothing removes or suppresses the CLAT interface. **[V]** for the metric, **[L]** for the outcome.
- **Native IPv4 present, no NAT64**: the interface is still created and fails forever (see 8.1). Proposal in openwrt/openwrt#10907: "netifd should not activate an implicit 464xlat when the same physical interface already has an IPv4 address" — only patched for QMI. **[V]**
- **Router-originated IPv4**: because the netdev has no IPv4 address, locally generated packets take a source from another interface and depend on the SNAT rule. On a box with no IPv4 address anywhere (or firewall off) it fails: forum 25.12.2 report, fixed by hand with `ip addr add 192.0.0.1/32 dev 464-lan6_4`. **[V]** report, **[L]** explanation.
- **MTU/fragmentation in the translator** **[V]** (`nat46-core.c:1868-2011`): `nat46_ipv4_input()` only adds an IPv6 Fragment header when the IPv4 packet is already a fragment (`frag_off & 0x3FFF` non-zero); it never fragments and never checks the egress MTU — the source contains `// FIXME: check if you can not fit the packet into the cached MTU`. The translated packet is re-injected with `netif_rx(new_skb)`; size enforcement is left to the normal IPv6 forwarding path (ICMPv6 PTB back to the CLAT address, which nat46 translates to ICMPv4 frag-needed with MTU−20, `nat46-core.c:1129-1170`).
- The same class of defect is filed for MAP-T on the same module: openwrt/openwrt#25192 (opened 2026-09-15, open, confirmed bug) — "a 1500-byte IPv4 packet becomes a 1520-byte IPv6 packet … the path is a black hole", `mtu_fix` does not help because clamping follows the 16384 device MTU; fix that worked: `ip link set dev "$link" mtu "$mtu"` after the nat46 config. 464xlat.sh has the same omission. **[V]** issue, **[L]** applicability to 464xlat.

---

## 5. NAT44 and firewall: what is injected, and how

### 5.1 Mechanism

Rules are **not** written to `/etc/config/firewall`. They are attached to the netifd interface as `data` (`464xlat.sh:55-80`) and firewall4 pulls them from ubus (`fw4.uc:596-680`) **[V]**:

```js
ifaces = bus.call("network.interface", "dump");
...
let net = { up: ifc.up, device: ifc.l3_device ?? ifc.device, physdev: ifc.device, zone: ifc.data?.zone };
...
if (type(ifc.data?.firewall) == "array") {
	for (let rulespec in ifc.data.firewall) {
		push(rules, { ...rulespec,
			name: ... `ubus:${ifc.interface}[${ifc.proto}] ${rulespec.type || 'rule'} ${n}` ...,
			device: rulespec.device ?? ifc.l3_device ?? ifc.device });
```

They live exactly as long as the interface is up; firewall reload picks them up/drops them.

### 5.2 What is injected

`464xlat.sh:55-80` **[V]**:

```sh
proto_add_data
[ -n "$zone" ] && json_add_string zone "$zone"

json_add_array firewall
	[ -z "$zone" ] && zone=$(fw3 -q network $iface 2>/dev/null)

	json_add_object ""
		json_add_string type nat
		json_add_string target SNAT
		json_add_string family inet
		json_add_string snat_ip 192.0.0.1
	json_close_object
	[ -n "$zone" ] && {
		json_add_object ""
			json_add_string type rule
			json_add_string family inet6
			json_add_string proto all
			json_add_string direction in
			json_add_string dest "$zone"
			json_add_string src "$zone"
			json_add_string src_ip $ip6addr
			json_add_string target ACCEPT
		json_close_object
	}
json_close_array
proto_close_data
```

Three things:

1. **Zone membership** (`data.zone`): `fw4.uc:2053-2058` appends every ubus network whose `zone` equals the zone name to `zone.network`. The CLAT netdev becomes a member of (normally) `wan`, so the existing `lan → wan` forwarding lets LAN IPv4 out through it. **[V]**
2. **Stateful NAT44**: SNAT of all IPv4 leaving the CLAT netdev to `192.0.0.1`. With no `src` zone the rule goes in the global `srcnat` chain (`fw4.uc:3133` ``chain: snat.src?.zone ? `srcnat_${snat.src.zone.name}` : "srcnat"``), matched on `oifname` (`templates/redirect.uc`: `{%+ if (redirect.device): -%} oifname {{ fw4.quote(redirect.device, true) }}`), ahead of the per-zone masquerade jump (`ruleset.uc:307-320`). Effective nft: `meta nfproto ipv4 oifname "464-wan6_4" snat 192.0.0.1`. **[V]** This is mandatory because nat46 is configured `local.style NONE` with a single /32↔/128 pair: any other IPv4 source fails with `[nat46] Could not translate v4->v6` (`nat46-core.c:756-761,1946-1949`). **[V]**
3. **IPv6 forward accept**: family inet6, `src` = `dest` = zone, `src_ip` = CLAT address, restricted to `iifname` = the CLAT netdev (`direction in` → `fw4.uc:1100-1107,2513-2514`: `r[r.direction ? "oifnames" : "iifnames"] = [ r.device.device ]`). **[V]** Needed because the translated IPv6 packet re-enters the stack from the CLAT netdev and must be forwarded to the real WAN netdev, both in zone `wan`, whose intra-zone forward policy is normally reject. **[L]** (purpose inferred). Return traffic relies on conntrack. Every flow therefore has two conntrack entries (IPv4 NAT44 + IPv6 forward). **[L]**

### 5.3 Zone pitfalls

- Commit `470f5b3` (2019) "464xlat: don't set default firewall zone to wan": before it, `[ -z "$zone" ] && zone="wan"`. **[V]**
- The fallback `fw3 -q network $iface` uses `$iface` (`$2`, the device argument, empty for a `no_device` proto), not `$cfg`. **[V]** code; consequence **[L]**: a manual section without `option zone` gets SNAT but neither zone membership nor the IPv6 accept rule. Reported: "The 464xlat netifd script is not properly getting the firewall zone of the interface", workaround `option zone 'wan'` (openwrt/openwrt#16381).
- `fw3` is still called by name; on fw4 systems it is a compatibility symlink (noted in PR #19936 review; openwrt/openwrt#9542 tracks leftover fw3 calls). **[L]**

---

## 6. Exact nat46 configuration

`464xlatcfg.c:127-131` **[V]**:

```c
FILE *nat46 = fopen("/proc/net/nat46/control", "w");
if (!nat46 || fprintf(nat46, "add %s\nconfig %s local.style NONE local.v4 %s/32 local.v6 %s/128 "
		"remote.style RFC6052 remote.v6 %s\n", argv[1], argv[1], argv[4], buf, prefix) < 0 ||
		fclose(nat46))
	return 4;
```

Instantiated for the default automatic case:

```
add 464-wan6_4
config 464-wan6_4 local.style NONE local.v4 192.0.0.1/32 local.v6 <CLAT-IPv6>/128 remote.style RFC6052 remote.v6 <NAT64-prefix>/<len>
```

e.g. `remote.v6 64:ff9b::/96` (static) or `remote.v6 64:ff9b::c000:aa/96` (autodetected). Teardown writes `del 464-wan6_4`.

Semantics from `nat46/modules/README` **[V]**: `style NONE` "always fails, unless you configure a /32 IPv4 prefix and a /128 IPv6 prefix - at which point it starts to function as a single 1:1 translation rule"; `style RFC6052` maps "the entire IPv4 internet as an IPv6 prefix", allowed lengths 32, 40, 48, 56, 64, 96.

Data path **[V]** (`nat46-netdev.c`): one netdev handles both directions. `nat46_netdev_xmit()` dispatches on `skb->protocol` to `nat46_ipv4_input()` or `nat46_ipv6_input()`; each builds the translated packet and calls `netif_rx(new_skb)`, i.e. the translated packet appears as *received on the nat46 device* and goes through the full routing + netfilter path again. This "route into a device, get the other family back out of the same device" model is why routing alone steers traffic.

---

## 7. Teardown, renew, prefix change

### 7.1 Teardown

`464xlat.sh:85-104` **[V]**:

```sh
proto_464xlat_teardown() {
	local cfg="$1"
	local link="464-$cfg"

	[ -f /tmp/464-$cfg-anycast ] || return
	local ip6addr=$(cat /tmp/464-$cfg-anycast)

	464xlatcfg "$link"

	rm -rf /tmp/464-$cfg-anycast
	[ -n "$ip6addr" ] && ip -6 rule del to $ip6addr lookup prelocal

	if [ -z "$(ls /tmp/464-*-anycast 2>&-)" ]; then
		ip -6 rule del from all lookup local
		ip -6 rule add from all lookup local pref 0
	fi

	# Kill conntracks SNATed to 192.0.0.1
	echo 192.0.0.1 > /proc/net/nf_conntrack
}
```

- `464xlatcfg <name>` with no further args: read `/var/run/<name>.pid`, `kill(pid, SIGTERM)`, unlink, exit 0 (`464xlatcfg.c:41-52`). The child then writes `del <name>` and exits; closing its socket drops the anycast membership. **[V]**
- State is kept in two files: `/var/run/464-<cfg>.pid` and `/tmp/464-<cfg>-anycast`. **[V]**
- The `local` rule is restored to pref 0 only when no other CLAT instance remains — multi-instance aware. **[V]**
- Conntrack flush added by commit `289c468` (2022): "Existing conntracks will continue to be SNATed to 192.0.0.1 even after 464xlat interface gets teared down." **[V]**
- netifd removes routes and the ubus firewall data with the interface. **[L]**
- Possible race **[L]**: on re-setup `464xlatcfg` signals the old child and immediately continues; the old child's `del` and the new `add` are not serialised.

### 7.2 Renew

No renew handler (`renew_handler` not set; no `proto_464xlat_renew`). NAT64 prefix and CLAT address are computed once per setup. **[V]**

### 7.3 Upstream down/up and prefix change

- Parent goes down (PPP drop, DHCPv6 unbound): `teardown_interface` sends link-down for the parent (`dhcpv6.script:226-229,242-244`) → host dependency fires → CLAT torn down and, being dynamic, removed → recreated by the next `setup_interface`. The `bound` event explicitly does teardown-then-setup (`dhcpv6.script:232-235`). **[V]**
- Address change **without** the parent going down (`updated`, `rebound`, `ra-updated`): `add_dynamic` is re-sent with a new `_addrsig`. netifd reloads an existing interface only if a declared attribute differs: `uci_blob_check_equal(if_old->config, if_new->config, if_old->proto_handler->config_params)` (netifd `interface.c:1563-1565`), plus zone/device/parent comparisons. `_addrsig` is not among the handler's declared params (`ip6prefix ip6addr tunlink zone`). So by code reading a pure address/prefix change does **not** restart the CLAT, and the old CLAT address (old prefix) stays configured in nat46. **[L]** (not runtime-tested; `_addrsig` appears to be a vestigial trigger.) Consistent with user reports: "if the WAN IPv6 address changes, translation breaks" (https://forum.openwrt.org/t/how-to-use-464xlat-in-openwrt/228408).
- NAT64 prefix change: never detected while up. **[V]**

---

## 8. Known bugs and limitations

| # | Problem | Evidence | Conf. |
|---|---|---|---|
| 8.1 | **Endless setup loop / log spam** when setup fails (no DNS64, no GUA, name too long). `Interface 'wan6_4' is now down` / `is setting up now` every ~3 s (matches `sleep(3)`). netifd tears down when the setup script exits still in `S_SETUP` (`proto-ext.c:148-153`) and restarts with no back-off. Appears on every DHCPv6 WAN that has the package installed but no NAT64. | openwrt/openwrt#10907 (open since 2022), #21092 (open), PR #19936/#20368 commit message | V (reports) / L (mechanism) |
| 8.2 | **NAT64 prefix autodetection unreliable**; depends entirely on DNS64 on the router's resolver; multi-WAN picks the wrong resolver. No PREF64. | #10907, #21092, forum 65642, 228408 | V |
| 8.3 | **Flow offloading breaks LAN clients**: with "NAT offload" on, only ICMP passes; disabling offload fixes it at the cost of throughput (~30 Mbps reported). | openwrt/openwrt#16381 (open, confirmed bug, 23.05) | V (report), root cause U |
| 8.4 | **MTU**: nat46 netdev MTU 16384, never set; translator does not fragment or check MTU; +20 bytes per packet. Filed for MAP-T as a PMTU black hole with `mtu_fix` ineffective. | `nat46-netdev.c`, `nat46-core.c:2001-2002`, openwrt/openwrt#25192 | V / L for 464xlat |
| 8.5 | **ICMP error source**: when the IPv6 source of an ICMPv6 error is not translatable, nat46 substitutes the destination: `*pv4saddr = *pv4daddr` (`nat46-core.c:1584-1589`). Older report of clients discarding frag-needed with their own address as source. | openwrt/openwrt#8469 (FS#2555, closed without linked fix) | V |
| 8.6 | **Fragment handling** open issues in nat46 (#35 "IP Fragmentation Issue", #24 "Issue observed from received fragments"). | https://github.com/ayourtch/nat46/issues | V (existence) |
| 8.7 | **Security**: nat46 #76 (opened 2026-08-12, still open, first fix reverted): kernel heap overflow in ICMPv6 error translation, "Remote, unauthenticated, single-packet trigger" for packets addressed to a configured translation address. OpenWrt pins nat46 at `adb2f72` (2025-11-04), which predates it. | https://github.com/ayourtch/nat46/issues/76 | V (report) |
| 8.8 | **Interface name > 15 chars** → never comes up. | openwrt/openwrt#18599 | V |
| 8.9 | **No IPv4 address on the CLAT netdev** → router-originated IPv4 fails unless SNAT applies. | forum 249579 (25.12.2) | V |
| 8.10 | **Single 192.0.0.1 / single IPv6 address**: one NAT44 port space for the whole LAN; not configurable. | lede-dev 2017, openwrt/openwrt#5807 | V |
| 8.11 | **WAN address change** leaves a stale CLAT address. | 7.3, forum 228408 | L |
| 8.12 | **Zone lookup bug** for manual sections. | 5.3, #16381 | L |
| 8.13 | Historic breakage 15.05→17.01 from a netifd revert (missing prelocal rule); #7651 (19.07.1) still open without diagnosis. | #5807, #7651, lede-dev | V |
| 8.14 | **Auto-creation cannot be turned off from LuCI**; `iface_464xlat '0'` reportedly not reaching nested dynamic interfaces. `dynamic '0'` added Nov 2025. | PR #20368, #10907 | V |

DNS: nothing in the package touches DNS for clients. DNS64 is needed only so the router can resolve `ipv4only.arpa` at setup; LAN clients keep using ordinary A records. **[V]** (no DNS code in either file)

---

## 9. User-facing UX

**Automatic path** — what the user does: install `464xlat` (pulls `kmod-nat46`, `ip`). Nothing else. With a `proto dhcpv6` WAN (including the auto-created `wan_6` on PPPoE) the CLAT interface, IPv4 default route, SNAT, IPv6 accept rule and zone membership all appear by themselves. "Installing the package creates a 464-wan6_4 interface automatically, which becomes the IPv4 default route … the network config has no 464 entry at all" (forum 228408). **[V]**

Preconditions the user does not see but must hold **[V]**: DNS64 reachable from the router (or set `ip6prefix`); a global IPv6 source address selectable for the WAN device (or set `ip6addr`); an IPv6 default route via the WAN device; logical name ≤ 11 chars.

**Manual path** — LuCI protocol "464XLAT (CLAT)" (`464xlat.js`) exposes only: `ip6prefix` ("NAT64 Prefix", hint "Leave empty to autodetect", datatype `cidr6`), `tunlink` ("Tunnel Link"), `mtu` (unused by the backend). It does **not** expose `ip6addr` or `zone` in that form; `iface_464xlat`/`zone_464xlat`/`dynamic` are not in LuCI either. Error surfaced: `CLAT_CONFIG_FAILED` → "CLAT configuration failed". **[V]**

**Status/diagnostics** available to the user: the interface row, `cat /proc/net/nat46/control`, the IPv4 route. No dedicated status page, no counters beyond netdev stats, no indication of which NAT64 prefix was learned other than the control file. **[V]**

Error codes **[V]**: script `NO_WAN_LINK` (no tunlink and no IPv6 default route), `CLAT_CONFIG_FAILED` (any non-zero from the helper). Helper exit codes: 1 bad args/pid file/`ip6addr`; 2 DNS failed; 3 socket/connect/anycast join failed; 4 nat46 control write failed; 5 only link-local source available.

---

## 10. Copy vs. leave behind

### Behaviours that are platform-neutral and worth copying 1:1

1. A **separate logical interface per upstream** named after the parent (`<parent>_4`), with its own L3 device, carrying an IPv4 default route — so routing/NAT/gateway machinery treats CLAT as "another WAN".
2. **Lifecycle bound to the upstream IPv6 interface**: up only after the parent is up with a usable global source; down (and state flushed) when the parent goes down.
3. **Low-priority IPv4 default** (metric 2048) so native IPv4, when present, wins without special-casing.
4. **CLAT IPv4 from 192.0.0.0/29** (`192.0.0.1`), with stateful NAT44 from LAN ranges to that single address in front of a stateless 1:1 (/32↔/128) translator.
5. **Stateless translator config shape**: local = one IPv4 ↔ one IPv6; remote = RFC 6052 prefix.
6. **Option surface**: `ip6prefix` (empty = autodetect), `ip6addr` override, `tunlink`, plus a per-parent on/off switch.
7. **Deterministic CLAT address derived from the WAN address** (stable across restarts for the same prefix).
8. **Flush NAT44 states on teardown** (commit `289c468`).
9. Multi-instance awareness (per-instance state files; shared global state restored only when the last instance goes away).
10. Named error states surfaced in the UI (`NO_WAN_LINK`, `CLAT_CONFIG_FAILED`).

### Behaviours that are OpenWrt weaknesses (documented above) rather than features

- Unconditional auto-creation with no NAT64 evidence, and no back-off on failure (8.1).
- DNS-only discovery, single retry, no validation, no PREF64, no refresh (section 2).
- No MTU handling at all (8.4).
- No IPv4 address on the CLAT device (8.9).
- No reaction to WAN address/prefix change without a parent bounce (7.3).
- No DAD/collision avoidance for the CLAT IID; implicit borrowing of the LAN /64 when WAN has no GUA (3.1).

### Linux/netifd-specific mechanisms (not portable as-is)

| Mechanism | Why Linux-only |
|---|---|
| `nat46` kernel module, `/proc/net/nat46/control`, single netdev that returns the other family via `netif_rx()` | out-of-tree Linux module |
| `IPV6_JOIN_ANYCAST` on a held socket to get NDP answers + a local route without an interface address | Linux socket option (`SOL_IPV6`), kernel anycast list |
| `ip -6 rule` re-ordering (`local` to pref 1, `to <addr> lookup prelocal pref 0`) and table 128 | Linux policy routing; `prelocal` is an OpenWrt rt_tables entry |
| `SO_BINDTODEVICE` + `connect()`/`getsockname()` probe relying on Linux cross-interface source selection | Linux saddr selection (`use_oif_addrs_only` off) |
| netifd proto handler API (`proto_init_update`, `proto_add_host_dependency`, `add_dynamic`, `no_device`, `available`) | netifd/ubus |
| Firewall rules as ubus interface `data.firewall` consumed by fw4; `data.zone` zone membership | netifd + firewall4 |
| `echo 192.0.0.1 > /proc/net/nf_conntrack` | OpenWrt kernel patch for conntrack flush by address |
| `fw3 -q network <iface>` zone lookup | fw3/fw4 CLI |
| Flow-offload interaction (8.3) | nftables flowtable |

---

## 11. Not established

- Whether `_addrsig` ever triggers a reload at runtime (code reading says no).
- Actual behaviour on a PPPoE WAN with link-local only + PD (kernel logic says the LAN GUA is borrowed; not tested).
- Root cause of the flow-offload failure (#16381).
- Whether the nat46 #76 overflow is reachable in the exact `local.style NONE` CLAT configuration.
- Whether netifd applies a generic `mtu` attribute to the l3 device of a `no_device` proto (reports and the MAP-T issue say the device stays at 16384).
- Real-world behaviour of UDP/non-DF IPv4 packets larger than (IPv6 path MTU − 20) through nat46.
