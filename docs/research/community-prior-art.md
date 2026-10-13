# Community prior art and field reports: CLAT on OPNsense / pfSense / plain FreeBSD

Research date: 2026-10-10. Scope: what people have actually built, what broke, and how they worked around it.
This file does NOT propose a design. Sibling reports in this directory cover the mechanisms themselves
(openwrt-464xlat.md, clat-datapaths.md, os-tayga-and-packaging.md, opnsense-gateways-nat.md, pf-af-to-roadmap.md, ...).

## Method and confidence legend

- "verified" = the primary page (or the file in the local clone) was fetched and read.
  Caveat: web pages were read as fetched excerpts. Config lines, commands and log lines below are
  reproduced as fetched; prose is paraphrased. Re-open the URL before quoting anything user-facing.
- "likely" = inferred from strong evidence (for example a search-engine snippet of a page that could not be opened).
- "unverified" = could not be established; also listed under Open questions.
- Local clone root: `refs/` (not in this repository).
- Sources that could not be opened: redmine.pfsense.org issue pages (JS shell only), bugs.freebsd.org (Anubis bot wall),
  forum.netgate.com search (login wall), RIPE85 PDF (binary). OPNsense forum search worked via
  `https://forum.opnsense.org/index.php?action=search2;search=<term>` but is rate limited (HTTP 403 after a few calls).

## 0. Bottom line

1. There is no existing CLAT for OPNsense or pfSense, neither in core, nor as an official plugin, nor as a third-party
   plugin or published script. The opnsense/plugins issue tracker returns zero hits for "clat OR 464xlat". (verified)
2. Users have asked OPNsense staff for it directly (Aug 2024). The answer was that a CLAT exists in ipfw(4) but the
   maintainers doubt the long-term wisdom of adding ipfw NAT next to pf. (verified)
3. The only working "CLAT on FreeBSD" reports use the apalrd fork of tayga on a tun device (`clat0`, 192.0.0.1 on the
   host, 192.0.0.2 for tayga, IPv4 default route into the tun). They are host CLATs, not router CLATs. (verified)
4. The only OPNsense report of ipfw `nat64clat` (Dec 2021) never got return traffic through pf and was abandoned. (verified)
5. The closest UX precedent on OPNsense is DS-Lite: a GIF device, assigned as an interface, plus a manually created
   gateway. It works, and its failure modes are extremely well documented: boot ordering, WAN IPv6 address not yet
   present, prefix change on PPPoE reconnect, no event when a SLAAC address changes. These apply 1:1 to a CLAT device
   whose IPv6 side depends on the WAN prefix. (verified)
6. Two third-party OPNsense plugins for Japanese IPv4-over-IPv6 exist (2026). They are the best "what to study"
   material, and they also show what to avoid: own pf anchors for NAT and scrub, an interface that shows as offline,
   and a gateway the user has to create by hand. (verified)
7. Tayga throughput: about 200 Mbit/s NAT64 on a PC Engines APU class CPU and about 3 Gbit/s on a desktop Ryzen
   (Linux, single TCP flow, 2021). One OPNsense user reports saturating 2 Gbit/s with tayga 0.9.6 (Feb 2026, hardware
   not stated). Upstream multi-queue workers are Linux only; FreeBSD stays single threaded. (verified)

## 1. Source catalogue

Each entry: URL, date, what they did, what broke, workaround.

### 1.1 OPNsense: requests for CLAT / 464XLAT / IPv6-only WAN

| # | Source | Date | What | What broke / answer |
|---|--------|------|------|---------------------|
| A1 | https://forum.opnsense.org/index.php?topic=42081.msg208307 (thread "[CALL FOR TESTING] PPPoE restructuring and IPv6 improvements", replies 48 and 49) | 2024-08-15 | User FireKahuna asks whether CLAT support could land in 25.1, arguing that a true IPv6-only deployment is not possible without it. | franco (OPNsense lead) answers that it exists in ipfw(4), that nobody has asked much about it, and that he is unsure whether adding NAT in ipfw next to pf is smart long term. No commitment. (verified) |
| A2 | https://forum.opnsense.org/index.php?topic=26022.0 "nat64clat anyone?" | 2021-12-16/17 | User ctr tries ipfw `nat64clat` on OPNsense 21.7 because tayga is user space. | Outbound translated traffic reaches his own PLAT and a reply returns. With `direct_output=1` the session never appears in pf and the reply is rejected on the outside interface. With `direct_output=0` the IPv6 session is in the pf state table, nothing is logged as blocked, yet the reply still does not get through. He also notes the command does not accept every /96. Zero replies, unresolved. (verified) |
| A3 | https://forum.opnsense.org/index.php?topic=48055.0 "NAT46 - Workarounds Beyond Reverse Proxy?" | 2025-07-23/25 | Maurice (author of the OPNsense tayga how-to) states that the os-tayga GUI only allows a NAT64 configuration and that other modes are possible only through scripts. He explicitly asks the poster whether a CLAT on OPNsense is what is wanted. | The poster hand-wrote a startup script; the `ifconfig nat46 inet` local and destination addresses were swapped. FreeBSD syntax is `ifconfig <if> inet <local> <dest>`. (verified) |
| A4 | https://forum.opnsense.org/index.php?topic=35757.msg174309 (German board, "PPPOE mit Draytek Vigor 167") | 2023-09-06/07 | Maurice: an IPv6-only WAN with or without PPPoE is now normal, transition setups such as DS-Lite and 464XLAT will spread, OPNsense will need better integration, OpenWrt already handles them well. franco at that time: selecting IPv4 "None" with PPPoEv6 did not validate. | Superseded by the 25.1 PPP restructuring, see A5 and D6. (verified) |
| A5 | https://forum.opnsense.org/index.php?topic=42081.0 | 2024-08-09 | franco announces the PPP restructuring for 25.1 whose goal is to allow IPv6-only PPP deployments including DHCPv6, and to remove the confusing "Use IPv4 connectivity" switch. Test patch `3a9f98843b` for 24.7.1. | Positive tests from M-Net and Deutsche Telekom users. (verified) |
| A6 | https://forum.opnsense.org/index.php?topic=35876.msg174583 | 2023-09-10 | Maurice mentions he no longer uses DS-Lite and switched to 464XLAT. | He never describes how he implemented it. (verified; implementation unknown) |
| A7 | https://github.com/opnsense/plugins/issues?q=is%3Aissue+clat+OR+464xlat | 2026-10-10 | Tracker search. | 0 results. (verified) |
| A8 | https://github.com/opnsense/core/issues/10570 (local: refs/gh/opnsense_core_10570.md) and PR #10638 (refs/gh/opnsense_core_10638.md lines 39-58) | 2026-07-18 / 2026-07-31 | Roadmap issue "Firewall: Rules - NAT64 support" via pf `af-to`; PR adds af-to to filter rules, described as adding both NAT64 and NAT46. | fichtner: will not work well with shared forwarding, suggests 27.1, expects further bugs around shaping and route-to. Monviech: route-to and friends are not supported together with af-to. Neither thread mentions CLAT. (verified) |
| A9 | https://forum.opnsense.org/index.php?topic=52522.0 "NAT64 Support via af-to" | 2026-07-23 | User asks for af-to in the GUI to get off tayga for speed. | franco: from code review it may be hit and miss together with shared forwarding. (verified) |

### 1.2 OPNsense: os-tayga (NAT64) field reports that transfer to a tayga-based CLAT

| # | Source | Date | What broke | Workaround / fix |
|---|--------|------|------------|------------------|
| B1 | https://forum.opnsense.org/index.php?topic=43685.0 "Tayga NAT64" | 2024-10/11 | User put the outbound NAT rule on the Tayga interface (and swapped source and translation) instead of on WAN. Traceroute stopped after the tayga hop. | Rule must be on WAN with source = tayga IPv4 pool. Doc commit 8b7ee66 (2024-11-06) added the hint. Maurice also says assigning the nat64 interface is not required. (verified) |
| B2 | https://forum.opnsense.org/index.php?topic=27511.0 | 2022-03/04 | Reply packets seen on `nat64` but never delivered to the LAN, intermittently. | Root cause: the "IPv6 NAT64 interface address" was reused from another interface; the rc script's `ifconfig` failed silently so the tun had no IPv6 address. Fix: a dedicated address (a ULA is fine). Doc PR opnsense/docs#391. (verified) |
| B3 | https://forum.opnsense.org/index.php?topic=38268.0 | 2024-01-22 | After enabling tayga the firewall's own IPv6 traffic (firmware updates, plugin search) broke. | Source address selection picked the tun's "IPv6 NAT64 interface address" (the 2001:db8 documentation default, numerically lowest GUA). Workaround: use a ULA there. Poster asks whether the address can be excluded from source selection. No reply. (verified) |
| B4 | https://forum.opnsense.org/index.php?topic=51893.0 | 2026-05-15 | SYN-ACK visible on WAN and on `nat64`, never on the LAN VLAN; `netstat -s -p ip6` shows a growing "failures of source address selection" counter. | Unresolved, zero replies. (verified) |
| B5 | https://forum.opnsense.org/index.php?topic=50096.0 and .15 "Native NAT64 support" | 2025-12 to 2026-02 | VoWiFi (IPsec NAT-T) over tayga failed because tayga's default `udp-cksum-mode drop` discards UDP with zero checksum. | `udp-cksum-mode fwd`, shipped as os-tayga 1.4 with OPNsense 26.1.1 together with tayga 0.9.6 (plugins PR #5183). apalrd (tayga maintainer) posts in the thread: tayga is single threaded and not very performant; `calc` degrades to `drop` for fragments and costs performance. Maurice notes that restarting tayga alone was not enough to apply the patch, the config had to be re-applied or the box rebooted. (verified) |
| B6 | https://forum.opnsense.org/index.php?topic=52598.0 | 2026-07/08 | The firewall's own SSH to GitHub left through the Tayga interface. | Expected: the firewall's resolver had DNS64 enabled, so the firewall itself uses NAT64. If unwanted, give the firewall a non-DNS64 resolver in System / Settings / General. (verified) |
| B7 | https://forum.opnsense.org/index.php?topic=50675.0 | 2026-02-03 | GUI reachable from VLANs that were blocked for IPv4, with connections sourced from the tayga pool. | IPv4 block rules must be duplicated for the mapped IPv6 destinations (prefix::a.b.c.d/120). Same class of issue in pfSense redmine #16241. (verified) |
| B8 | https://forum.opnsense.org/index.php?topic=50089.0 | 2025-12-13/14 | User believes a GUA translation prefix is reachable from outside; live view shows the automatic rule on `nat64` passing packets with foreign sources. Same user runs tayga as a CLAT on a Linux desktop. | Maurice: the nat64 "let out anything" rule is the kernel handing packets to tayga, and default rules let some ICMPv6 error types in. Not fully settled. (verified) |
| B9 | https://github.com/opnsense/docs/commit/b6a0f1a and PR opnsense/docs#847 | 2026-02-06 | Until then the how-to required a manual Firewall / Settings / Normalization rule on the Tayga interface, with the stated reason being proper handling of fragmented packets. Several forum users list "the normalizer" among the mandatory steps (topics 43200, 47373, 43685). | Removed because opnsense/core@630ab19 added a global scrub rule. Current master: `set reassemble yes` (refs/opnsense-core/src/etc/inc/filter.inc:476). (verified) |
| B10 | https://github.com/opnsense/plugins/issues/5778 | 2026-10-10 | After 26.7.5 to 26.7.6 "Apply" in Services / Tayga fails with "Service tayga failed to start" although the process runs. | configd actions for start/stop/restart are declared `type:script_output`; since core commit bed9f78 the return value matters. Change them to `type:script`. Still unfixed in the clone: refs/opnsense-plugins/net/tayga/src/opnsense/service/conf/actions.d/actions_tayga.conf:4,10,19. (verified) |
| B11 | https://github.com/opnsense/plugins/issues/5503 | 2026-06-15, open | HA: tayga settings not present on the secondary after XMLRPC sync. Reporter points at the sync id `taygavpn`. | Monviech could not reproduce (section `OPNsense.tayga` is correct, refs/opnsense-plugins/net/tayga/src/etc/inc/plugins.inc.d/tayga.inc:56-64). Unresolved. (verified) |
| B12 | https://github.com/opnsense/plugins/issues/5594 (open), PR #5705 (open) | 2026-07/09 | Entering a CIDR suffix in the IPv6 interface address field breaks startup (a second /128 gets appended). | Validation PR pending. (verified, list view only) |
| B13 | https://github.com/opnsense/plugins/issues/2094 | 2020-2021 | "interface nat64 does not exist": tayga did not start because the auto-derived IPv6 address was invalid with the well-known prefix. | Enter the IPv6 address explicitly; how-to corrected. (likely, from search snippet and list view) |
| B14 | https://github.com/opnsense/plugins/issues/5338 "[Tayga] Adding support for NAT46" | 2026-03-20, closed not planned by the inactivity bot 2026-09-16 | User wants inbound IPv4 to IPv6-only hosts. | Another user got it working with existing features: a static tayga mapping plus a DNAT rule to the pool address plus a WAN pass rule. No maintainer comment. (verified) |

How the existing plugin integrates (local clone, verified):
- `tayga_interfaces()` registers only an interface group, `'type' => 'group'`, `'virtual' => true`, `'networks' => array()`
  (refs/opnsense-plugins/net/tayga/src/etc/inc/plugins.inc.d/tayga.inc:66-80). No assignable device, no gateway.
- The rc script starts tayga, sleeps one second, then configures the tun by hand and adds static routes
  (refs/opnsense-plugins/net/tayga/src/etc/rc.d/opnsense-tayga:22-34):
  ```
  ifconfig nat64 inet ${tayga_v4destination}/32 ${tayga_v4address}
  ifconfig nat64 inet6 ${tayga_v6destination}/128
  ifconfig nat64 group tayga
  route -4 add ${tayga_v4pool} -interface nat64
  route -6 add ${tayga_v6prefix} -interface nat64
  ```
- The start action also re-runs routing: `command:/usr/local/etc/rc.d/opnsense-tayga start; /usr/local/etc/rc.routing_configure`
  (actions_tayga.conf:2).
- Template: `tun-device nat64`, `udp-cksum-mode fwd`, `wkpf-strict no`
  (refs/opnsense-plugins/net/tayga/src/opnsense/service/templates/OPNsense/Tayga/tayga.conf:3-6).
- Plugin version 1.5, depends on the `tayga` package (refs/opnsense-plugins/net/tayga/Makefile:2-4); the OPNsense ports
  tree has tayga 0.9.6 from apalrd (refs/opnsense-ports/net/tayga/Makefile:2,17).
- The user must still add by hand: a pass rule on the Tayga group (IPv4+IPv6) and a source NAT rule on WAN
  (https://docs.opnsense.org/manual/how-tos/tayga.html, verified).

### 1.3 OPNsense: DS-Lite over GIF, the "virtual tunnel WAN" precedent

Recipe that the community converged on (verified from D1, D3, D6, D8):
1. WAN gets IPv6 (DHCPv6 and/or SLAAC). Since 25.1: WAN IPv4 type "None", PPPoE as a separate Point-to-Point device.
2. Interfaces / Other Types / GIF: parent = WAN, remote = AFTR IPv6 literal (FQDN is rejected by validation),
   tunnel local 192.0.0.2, tunnel remote 192.0.0.1.
3. Assign the gif as OPTx, enable it, set MTU/MSS.
4. Create a gateway by hand; on pfSense people disable gateway monitoring because 192.0.0.1 does not answer.

| # | Source | Date | What broke | Workaround / fix |
|---|--------|------|------------|------------------|
| D1 | https://forum.opnsense.org/index.php?topic=35876.0 | 2023-09-10/12 | IPv4 dead after every reboot. Boot log: `inet6 tunnel '' '2a02:8071:2000::4002'` fails with "Name does not resolve"; the GIF is configured before WAN has a GUA and nothing reconfigures it afterwards. gif0 ends up with MTU 1280 and no outer addresses. | Any re-save of the GIF fixes it until the next boot. franco: GIF tunnels were only re-linked on rc.newwanip (IPv4), rc.newwanipv6 needed the same. Patch 315153a07 (23.7.3 era). Maurice: the static host route to the GIF remote is needed for multi-WAN. (verified) |
| D2 | https://github.com/opnsense/core/issues/7713 "DS-Lite not coming up after a reboot" | 2024-08-03, still open, assigned fichtner, label cleanup, milestone now 27.1 | Log line `Device gif0 missing required local address, skipping now.` after boot. With DHCPv6 "request prefix only" the WAN has no GUA at all. Sept 2026 reports: tunnel breaks on every PPPoE reconnect; DHCPv6 reconnects but the GIF does not follow. | Workarounds reported: toggle LAN IPv6 mode, set a WAN prefix ID so WAN gets a GUA, point the GIF at a tracking LAN instead of WAN, flip the GIF source and back. fichtner: rc.newwanipv6 is supposed to call `link_interface_to_gif()`; the GIF must be assigned as an interface; suspects a race. Commit 598809955 (PPPoE vs IPv6 race) did not help one reporter. (verified) |
| D3 | https://forum.opnsense.org/index.php?msg=185904 "DS-Lite on 23.7.6+" (page 2) | 2024-01 to 2024-04 | ISP delegates a prefix but gives no WAN address (no IA_NA, no SLAAC), so the GIF has no local address. A WAN virtual IP out of the delegated prefix was added but the GIF still refused it. | User workaround: 30 s sleep inside a `10-newwanip` hook that configures the GIF, plus a late boot script. franco: SLAAC is stateless, addresses come and go without notification, triggers are hard to find, netlink would need a daemon or cron. Manual command used: `ifconfig gif0 inet6 tunnel <local> 2001:f60:0:200::1:1 mtu 1460`. (verified) |
| D4 | https://github.com/opnsense/core/issues/10598 | 2026-07 to 2026-09, open | Prefix change: IPv6 stops until WAN is re-saved. DS-Lite comment (L0udy, 2026-09-21): after the outer source changed, IPv4 over DS-Lite lost 100% while native IPv6 worked; a watchdog that rebuilds gif0 with the current PPPoE global address repaired it. HA comment (kohly, 2026-09-30): both HA nodes lost IPv6 at a SLAAC prefix change, pf states showed NO_TRAFFIC, filter reload recovered in about 10 s. | fichtner: RA and DHCPv6 are not synchronized; rtsold only starts DHCPv6 and does not watch RA changes. `configctl interface reconfigure wan` plus filter reload as manual recovery. (verified) |
| D5 | https://github.com/opnsense/core/issues/10828 (local refs/gh/opnsense_core_10828.md lines 17-37, 842-849, 1128, 1281) | 2026-09-02 to 2026-09-18, closed, milestone 27.1 | On PPPoE the SLAAC address appeared only after more than ten minutes unless `rtsol pppoe0` was run by hand. Cause: `accept_rtadv` was not yet set on pppoe0 when rtsold started from ppp-ipv6.php. | Fixed by core commit f1924c8 / 9e18f5c, shipped in 26.7.4. Anything that waits for the PPPoE WAN GUA on 26.7.0 to 26.7.3 could wait a long time. (verified) |
| D6 | https://forum.opnsense.org/index.php?topic=51906.0 and https://gist.github.com/tobinger/89b3f4d7cdddf98571e20876792eb081 | 2026-05-15/20 | Migration from pfSense: WAN IPv4 = PPPoE plus IPv6 = DHCPv6 on an ISP without IPCP. dhcp6c never started on pppoe0, `/var/etc/dhcp6c.conf` 0 bytes, no error shown, dpinger even showed the IPv6 gateway online. User wrote `/usr/local/etc/rc.syshook.d/start/99-dslite-gif-rebuild`. | Correct setup: WAN IPv4 type None, PPPoE device under Interfaces / Point-to-Point, IPv6 DHCPv6. Then core handles everything and the hook script must be removed. franco: this was the 25.1 PPP work; IPv4 has to come through a GIF after IPv6 is up, or the box runs IPv6-only. franco would like an automatic AFTR setup later; dhcp6c-script already exposes the AFTR name and ifctl needs minimal plumbing. (verified) |
| D7 | https://forum.opnsense.org/English_Forums/Development_and_Code_Review/Dual_Stack_Lite_(DS-Lite)_Support (topic 7788) and PRs https://github.com/opnsense/core/pull/2382 , https://github.com/opnsense/core/pull/4335 | 2018-04 to 2021-10 | Contributor noctarius tried to add DS-Lite as an "IPv4 configuration type" of the WAN (creates the gif, inner 192.0.0.2/192.0.0.1, default route, dynamic gateway, AFTR via DHCPv6 option 64). | Review feedback 2018: more loosely coupled, move code into interfaces.inc, predictable device name with a `dslite_` prefix, avoid state files, the rc.newwanipv6 hook approach was praised. Closed 2019 for conflicts, re-submitted 2020, closed 2021 on timeout. Tester report 2021: the IPv4 type silently reverted to None on save and dhcp6c rejected the raw option line. Maintainers later chose plain GIF plus core fixes. (verified) |
| D8 | https://xmms.jp/blog/index.php?entry=entry200817-003557 (pfSense 2.4.5-p1, transix DS-Lite and fixed IP) | 2020-08-16 | Gateway marked down because the peer does not answer; AFTR hostname not accepted; DNS servers from dhcp6c not applied to the system; for fixed IP service the interface ID cannot be set so a VIP `<prefix>::feed` is hardcoded and used as GIF parent. | Disable gateway monitoring; use the AFTR IPv6 literal; clamp MTU/MSS on the OPT interface; policy routing per rule for running DS-Lite and fixed IP side by side. (verified) |
| D9 | https://github.com/opnsense/core/issues/9761 | 2026-02-08, fixed (commit e98e55e / 2c1d5cb, milestone 26.7) | On a box whose WAN is DS-Lite plus a VPN uplink, rules made in the new rules GUI lacked the automatic `reply-to`, so replies left through the default gateway. | Fixed in core. Shows that tunnel-uplink users depend on automatic reply-to and that the new rules GUI regressed it once in 26.1. (verified) |

### 1.4 MAP-E / MAP-T: opnsense/core#4983 (local: refs/gh/opnsense_core_4983.md)

- Request opened 2021-05-11, timed out twice, finally closed 2025-07-13 (lines 1-2, 208-216).
- Maintainer position (fichtner 2022-08-25, lines 52-73; AdSchellevis 2023/2024, lines 103-114): OPNsense can offer what
  pf(4) offers (`map-e-portset` on nat rules); requirements and GUI are unclear; whoever wants it should prototype
  against pf.conf and note that the generated ruleset is `/tmp/rules.debug`.
- Working manual MAP-E on OPNsense (schmitmd, 2025-04-20, lines 121-145), the integration pattern is device + address + NAT:
  1. compute MAP-E parameters from the DHCPv6 prefix;
  2. add the CE IPv6 address as a virtual IP on WAN;
  3. GIF with MTU 1460, local = that VIP, remote = BR, inner local and remote both the shared IPv4, /32;
  4. NAT rule, which the GUI cannot express, so it was pasted into `/tmp/rules.debug` and loaded with `pfctl -f`:
     `nat log on gif0 inet from (ix1:network) to any tag map_e_egress -> 106.72.42.64 map-e-portset 4/8/150`
- What broke (lines 145, 190-199):
  - Outbound NAT had to be switched to Manual so the automatic rules do not clobber the tunnel NAT.
  - "Disable force gateway" had to be ticked, otherwise the firewall's own IPv4 traffic bypassed the port-set NAT.
  - ICMP echo does not work, map-e-portset only handles TCP/UDP; PMTUD trouble followed.
  - A hand-edited `/tmp/rules.debug` does not survive a filter reload (implied by the mechanism).
- Maintainer offered pointers for adding a field to the legacy outbound NAT page (lines 156-180); no PR ever came.
- Japanese write-ups referenced in the thread (lines 91-96, 108) are for FreeBSD/OpenBSD/OpenWrt, not OPNsense. No
  Japanese blog was found that documents MAP-E on OPNsense end to end. (verified for the thread; absence = likely)

### 1.5 Third-party OPNsense plugins for IPv4-over-IPv6 (study these)

**kawaii-not-kawaii/ds-lite-opnsense** (https://github.com/kawaii-not-kawaii/ds-lite-opnsense, README and
`os-dslite/src/etc/inc/plugins.inc.d/dslite.inc` read via raw.githubusercontent.com; 45 commits, 2 stars; tested on
25.1, 26.1.4 and 26.7.1; not in any pkg repo, installed with a curl one-liner or `pkg add -f`). (verified)

- Modes: DS-Lite, fixed IP (IPIP), experimental MAP-E via pf `map-e-portset` (refuses to start if pf lacks it).
- Device: FreeBSD `gif`, default `gif0`, configurable only in advanced mode; refuses to take over a device it did not
  create; ownership recorded in `/var/run/dslite_owned_tunnel` and `/var/run/dslite_owned_route`.
- Hooks in dslite.inc: `'newwanip' => ['dslite_configure_renew:3']`, `'vpn' => ['dslite_configure_boot:3']`; the renew
  handler ignores `inet` and unrelated interfaces; `dslite_cron()` adds `configctl -d dslite prefix_update` every 30
  minutes (fixed IP mode only).
- Interface registration: `dslite_interfaces()` returns `'if' => $device, 'type' => 'gif', 'virtual' => false,
  'enable' => true`. README admits the result shows as offline in the GUI because it is registered without addressing.
- Firewall: `$fw->registerAnchor('dslite/*', 'nat')`, `('dslite/*', 'rdr')`, `('dslite/*', 'fw')`; the plugin loads its
  own `nat on <tunnel> from any to any -> <ipv4>` and `match ... scrub (max-mss N)` into those anchors. README tells
  users to leave outbound NAT on Automatic and not to add a manual rule, otherwise traffic is translated twice.
- Gateway: not created. README: the user must add one under System / Gateways, "Far Gateway" is mandatory, monitor IPs
  must be unique, and the plugin re-pins a host route for the monitor IP on every rebuild so probes cannot leave
  through another uplink. Gateway shows offline for the first one to two minutes after boot.
- Known problems listed by the author: the `<interface> address` alias never resolves in port forwards for a
  plugin-registered interface (rule is emitted commented out), menu appears only after logging out and in again,
  MAP-E untested on a live line.
- MTU 1460. Throughput figures for the in-kernel gif path: about 2.29 Gbit/s per IPv4 flow on a 10G line, native IPv6
  3.65 Gbit/s in the same window.

**unchained-llc/os-ocnfixedip** (https://github.com/unchained-llc/os-ocnfixedip, fork of the above, OPNsense 26.1+). (verified)

- Deliberately narrower: only the tunnel and its default route. Gateway, outbound NAT, firewall rules and MSS
  normalization are left to the user (documented steps: upstream gateway on the assigned TUNNEL interface with
  monitoring disabled, one outbound NAT rule per LAN, normalization rule with max MSS 1420).
- Hard-coded `gif0`, peer 192.0.0.1; changes the system IPv4 default route itself; hooks rc.newwanipv6 (inet6 only),
  ignores repeated configure events within three seconds, retries WAN address detection to ride out DHCPv6 renewal races.
- Health model worth copying: tunnel running, default route via tunnel, MTU matches, WAN alias present, IPv6 ping to
  the far end, IPv4 and IPv6 internet pings, DF and fragmentation probes.

### 1.6 Plain FreeBSD: tayga as CLAT

| # | Source | Date | What they did | What broke | Workaround |
|---|--------|------|---------------|------------|------------|
| F1 | https://github.com/apalrd/tayga/issues/57 | 2025-05-25/26 | First FreeBSD 14.2 build of the apalrd fork. | BSD make vs GNU make, missing version.h in the tarball. Maintainer notes: tayga does not configure the tun on FreeBSD, the user must bring it up and add addresses and routes; the test suite depends on netlink and was not run on FreeBSD. | Build from main; fixed in PR #62. (verified) |
| F2 | https://github.com/apalrd/tayga/issues/83 | 2025-06-16/17 | FreeBSD 14.3 jail, tayga 0.9.4 as CLAT. Config: `tun-device clat0`, `ipv4-addr 192.0.0.2`, `ipv6-addr <pfx>::65`, `map 192.0.0.1 <pfx>::64`, `prefix <nat64>/96`. Host side: `ifconfig clat0 inet 192.0.0.1/29 192.0.0.1 up`, `ifconfig clat0 inet6 -ifdisabled`, `route add default -iface clat0`, `route -6n add -net <pfx>::64/127 -iface clat0`. | (1) Nothing came back: the upstream had no route for the CLAT IPv6 address. (2) After that, HTTPS to some sites stalled: MSS/MTU. | (1) Static host route on the outer host. (2) `scrub in on vtnet0 all fragment reassemble no-df random-id min-ttl 20 max-mss 1220`, or as the maintainer prefers, MTU 1260 on the IPv4 default route so non-TCP is covered too. Pinging tayga's own 192.0.0.2 works and is useful as a liveness check. (verified) |
| F3 | https://github.com/apalrd/tayga/issues/98 | 2025-06-20/22 | Same on a non-jail FreeBSD 14.3 host whose CLAT address sits inside the on-link WAN /64. | Translated packets left, replies never came back (upstream router does neighbor discovery for the CLAT address and nobody answers). Also: tayga rejects IPv6 sources that are neither inside pref64 nor statically mapped, with ICMPv6 unreachable code 5. | Either the `net/ndproxy` kernel module, or the "masq" variant: ULA `fd64::/64` on the tun plus `nat on vtnet0 inet6 from fd64::/64 to any -> (vtnet0)` in pf. Maintainer: traceroute/PMTUD log lines about a fake source are harmless. (verified) |
| F4 | https://forums.freebsd.org/threads/best-way-to-provide-nat64.95130/ | 2024-09 to 2025-07 | zirias@ (FreeBSD developer) runs tayga NAT64 with pf NAT44 behind it; says (Oct 2024) there is no out-of-the-box CLAT on FreeBSD and clatd (Perl, Linux) would need substantial porting. The net/tayga port then had no rc script. mumu (2025-07-11) reports CLAT working on 14.3-R with the apalrd fork: `clat0` with 192.0.0.1 and an IPv4 default route through it. | - | - (verified) |
| F5 | https://forums.freebsd.org/threads/nat64-with-ipfw-issues.70366/ and https://forums.freebsd.org/threads/freebsd-nat64-w-tayga.87971/ | 2019 to 2023 | tayga 0.9.2 + pf NAT + unbound DNS64 on FreeBSD 11.2. | Some IPv4-only sites would not load. Pinging NAT64 addresses from the tayga host itself failed. A single on-link /64 did not work for the translation prefix, a routed prefix did. | `net.inet.tcp.mssdflt=1440` and `scrub in on $ext_if no-df random-id max-mss 1440`; add a second IPv6 address on the tun for host-originated traffic. (verified) |
| F6 | https://github.com/apalrd/tayga/issues/132 | 2025-08-16/17 | clatd 2.1.0 + tayga 0.9.5 on Debian with pref64 = 64:ff9b::/96. | tayga exits: an auto-derived `ipv6-addr` falls into the well-known prefix, which it refuses. | Fixed on main (commit 626fb0a); set `ipv6-addr` explicitly. os-tayga already sets `wkpf-strict no`. Relevant because a CLAT always uses 192.0.0.x together with the ISP's prefix, very often the well-known one. (verified) |
| F7 | Upstream docs in the clone: refs/tayga/docs/clat/README.md, clat-route.conf, clat-route.sh | current main | Three reference CLAT layouts: proxy NDP (address from the on-link /64), NAT66 masquerade (ULA on the tun), routed prefix (/127 out of a delegated /64). | README line 5: the scripts are demonstrations, not best practice; they skip DAD and address generation. README line 11: 464XLAT is for outgoing connections. | `ip route add default dev clat mtu 1260` (clat-route.sh:17); `map 192.0.0.1 2001:db8:abcd::64` (clat-route.conf:8). All examples are single-host CLATs (one mapped IPv4). (verified) |

FreeBSD-specific tayga facts from the clone (verified):
- Non-`tunN` device names work for normal operation: tayga opens `/dev/tun` and renames with SIOCSIFNAME
  (refs/tayga/tun.c:461-472, 532-542); only `--mktun/--rmtun` need a `tun[0-9]+` name. The comment in
  docs/clat/clat-route.conf:1 ("For BSD systems, tun-devide must be named tun[0-9]") is stricter than the code.
- tayga reads the tun MTU once at startup (tun.c:546-556).
- Worker threads are compiled out on FreeBSD: `#define MAX_WORKERS 0` (refs/tayga/tayga.h:113-115);
  tayga.conf.example:171 marks `workers` as Linux only.
- `offlink-mtu` (default 1280) exists since 0.9.6 (tayga.conf.example:147-166).
- The Linux build configures addresses and routes itself through netlink (tun.c:382-422); the FreeBSD path does not.

### 1.7 Plain FreeBSD: ipfw nat64clat

| # | Source | Date | Notes |
|---|--------|------|-------|
| I1 | https://forums.freebsd.org/threads/nat64-464xlat.73741/ | 2020-01 | Two FreeBSD 12.1 VMs as CLAT and PLAT. CLAT side: `ipfw nat64clat NAT64 create clat_prefix 2001:db8:1234:1000::/96 plat_prefix 64:ff9b::/96 log allow_private`, `ipfw add allow log icmp6 from any to any icmp6types 135,136`, `ipfw add nat64clat NAT64 ip from any to any`; PLAT side needs a route for the clat_prefix and `sysctl net.inet.ip.fw.nat64_direct_output=1`. Custom kernel with IPFIREWALL_NAT64. Author says it eventually worked but never posts what changed. No pf involved. (verified) |
| I2 | https://forums.freebsd.org/threads/nat64-with-ipfw-issues.70366/ (developer olivier, 2019-06-04) | 2019 | Without direct output the translated packet re-enters the stack through netisr and is processed by the firewall a second time; a 12-STABLE bug broke that second pass, hence `nat64_direct_output=1`. (verified) |
| I3 | https://forum.netgate.com/topic/131460/setup-nat64-in-pfsense | 2018 to 2025 | pfSense users loading `ipfw_nat64.ko` next to pf: traffic must be allowed in both pf and ipfw; there is no hook to re-apply ipfw rules when pf reloads; module availability depends on the kernel build. (verified) |
| I4 | FreeBSD PR 292023 (https://bugs.freebsd.org/bugzilla/show_bug.cgi?id=292023) and PR 295794 (https://lists.freebsd.org/archives/freebsd-bugs/2026-June/034883.html) | 2025-12-29 and 2026-06-02 | Kernel panics in ipfw_nat64 when nat64clat and nat64lsn (or nat64stl and nat64lsn) are combined, reported on 16.0-CURRENT. 292023 is listed as closed/fixed; 295794 was "New" in June 2026. (PR 295794 header verified via the list archive; PR 292023 status only from a search snippet = likely) |
| I5 | A2 above | 2021 | The only OPNsense attempt; failed on the pf interaction. |

`nat64clat` is present in the ipfw(8) shipped in the OPNsense 26.7 source tree (refs/opnsense-src/sbin/ipfw/ipfw.8:149-161,
1020, 3851-3881). Whether the `ipfw_nat64` module is in the OPNsense kernel package was not established here.

### 1.8 pfSense

- Redmine #2358 "NAT64 support", opened 2012, resolved for Plus 25.07 / CE 2.8 (status and target from a search
  snippet = likely). Netgate describes it as NAT64 firewall rules + PREF64 in RA + DNS64 in the resolver
  (https://www.netgate.com/blog/netgate-releases-pfsense-plus-software-version-25.07, snippet = likely). The tayga
  maintainer states on the OPNsense forum that Netgate added `af-to` to FreeBSD pf and pfSense uses it (B5, verified).
- This is PLAT only. A typical third-party guide (https://muchamadfatihurrahman.my.id/posts/nat64-dns64-pfsense/,
  2025-05-06, verified) runs the CLAT on a Linux client with clatd.
- Netgate docs, NAT processing order (https://docs.netgate.com/pfsense/en/latest/nat/process-order.html, verified):
  NAT64 translation happens while processing the inbound interface rules, and NAT64-translated packets skip the
  outbound floating rule step on WAN. Redmine #16135 additionally says NAT64-translated packets cannot be translated
  again by NAT rules such as outbound NAT (search snippet only = likely).
- Redmine #16241 / forum topic 200017 (2026-01): NAT64 to RFC1918 destinations through the well-known prefix is now
  blocked by default, with an override knob under System / Advanced. (verified via forum page)
- No pfSense CLAT, no redmine request for one was found, forum tag "464xlat" is empty, tag "clat" has a
  single NAT64 thread. (verified for the tags; redmine search not possible = unverified)

### 1.9 OpenWrt field reports for the model the plugin intends to copy

| # | Source | Date | What broke | Workaround |
|---|--------|------|------------|------------|
| O1 | https://forum.openwrt.org/t/clat-464xlat-not-working-in-19-07-1/56496 | 2020 to 2023 | NAT64 prefix auto-detection (AAAA for ipv4only.arpa) failed because the upstream resolver returned only A records. | `option ip6prefix '64:ff9b::/96'` on the 464xlat interface. Always offer a manual prefix. (verified) |
| O2 | https://forum.openwrt.org/t/464xlat-bug-missing-ipv4/249579 | 2026-04-30 | On 25.12.2 the dynamic `464-<if>` device came up without 192.0.0.1/32; de-translated replies were dropped by the kernel. | `ip addr add 192.0.0.1/32 dev 464-lan6_4`. Unresolved upstream in the thread. (verified) |
| O3 | https://forum.openwrt.org/t/464xlat-installation-failing-on-openwrt-24-10-2/240820 | 2025 | Package regression between point releases (generated command lost quoting and arguments). | Upgrade to 24.10.3. (likely, search snippet) |

OpenWrt's script SNATs to 192.0.0.1 and flushes conntrack entries SNATed to 192.0.0.1 on teardown
(refs/openwrt/package/network/ipv6/464xlat/files/464xlat.sh:40, 65, 102-103). (verified)

### 1.10 Others

- MikroTik RouterOS 7 (https://forum.mikrotik.com/t/nat64-and-464xlat-on-ros-how-to/267046, 2025-12-11): tayga in a
  container as NAT64 only, CLAT on Apple clients; IPv4 ends up translated three times (NAT64, masquerade, CGN).
  Upstream says its CLAT container script is not finished (refs/tayga/docs/container/README.md:24,
  refs/tayga/docs/container/mikrotik.md:3). (verified)
- Debian bug #779105 (2015): request for a CLAT mode in tayga; answer was to use clatd. (verified)

## 2. Recurring pitfalls, with evidence

### 2.1 MTU / MSS
- Symptom is always the same: ping works, small pages work, large TLS transfers stall (F2, F5).
- Values seen in the field: IPv4 default route MTU 1260 = tayga's default 1280 minus 20 (F2, F7); MSS clamp 1220
  (F2) or 1440 (F5, for a 1500 path); gif tunnels 1460 with MSS 1420 (1.5); DS-Lite gif left at 1280 when created
  before WAN was ready (D1).
- draft-ietf-v6ops-claton-16 (2026-03-05) section 8 recommends an IPv4 MTU 28 bytes below the IPv6 MTU (20 for the
  header difference plus 8 for the fragment header) (https://datatracker.ietf.org/doc/html/draft-ietf-v6ops-claton, verified).
  With PPPoE at 1492 that is 1464.
- tayga fragments IPv4 to IPv6 above `offlink-mtu` (default 1280) unless DF is set (tayga.conf.example:147-166), and
  it reads the tun MTU only at startup (tun.c:546-556).
- OPNsense derives per-interface clamps from the assigned interface's MSS field: `max-mss (mss-40)` for inet and
  `(mss-60)` for inet6 (refs/opnsense-core/src/etc/inc/filter.inc:491-503). An assigned interface therefore gets MSS
  clamping from core without the plugin writing a rule.

### 2.2 Checksums
- No field report ties NIC checksum offload to tayga/tun breakage on FreeBSD; captures in F2 and F3 show valid sums.
- The real checksum failure is UDP with zero checksum (IPsec NAT-T, VoWiFi) being dropped by tayga's default mode;
  fixed with `udp-cksum-mode fwd` (B5).

### 2.3 pf scrub / reassembly on the tun
- A per-interface normalization rule on the tayga interface was mandatory in the OPNsense how-to until 2026-02 (B9).
  Now reassembly is global (`set reassemble yes`). On releases before that core change, fragments on a plugin tun
  were not reassembled unless the user added the rule.

### 2.4 reply-to / "force gateway"
- MAP-E on GIF needed "Disable force gateway" so the firewall's own IPv4 traffic takes the tunnel NAT (1.4).
- Automatic reply-to went missing once in the new rules GUI (D9).
- pf `af-to` and route-to/reply-to do not combine (A8).
- The nat64clat attempt died on pf state handling of traffic that was translated outside pf (A2).

### 2.5 Outbound NAT on the virtual interface
- NAT64 direction: users put the NAT rule on the tun instead of WAN (B1).
- Tunnel-WAN direction: automatic outbound NAT interfered and the user switched to Manual (1.4); the dslite plugin
  ships its own NAT in a pf anchor and warns that a manual rule doubles the translation (1.5); the OCN plugin asks
  for one manual rule per LAN (1.5).
- Port forwards: the `<interface> address` alias does not resolve for a plugin-registered interface (1.5).

### 2.6 Gateway monitoring
- DS-Lite peer 192.0.0.1 does not answer, so people disable monitoring (D8, OCN plugin) and thereby lose failover.
- The dslite plugin needs "Far Gateway", a unique monitor IP and a pinned host route for it; gateway reads offline for
  one to two minutes after boot (1.5).
- With tayga the tun peer (tayga's own `ipv4-addr`) does answer ping (F2), but that proves only that the daemon is
  alive, not that the PLAT is reachable.
- With PPPoE + DHCPv6 misconfiguration dpinger showed the IPv6 gateway online while nothing worked (D6): link-local
  monitoring is not an end-to-end signal.

### 2.7 DNS
- A firewall that resolves through DNS64 sends its own traffic through NAT64 (B6).
- NAT64 prefix discovery through ipv4only.arpa fails when the resolver in use does not synthesize (O1). The claton
  draft orders discovery as PREF64 first and RFC 7050 as fallback, and requires the ipv4only.arpa query to go to the
  resolvers learned on that interface (section 4 and 9.2, verified).
- PREF64 lifetime in OPNsense radvd follows three times MaxRtrAdvInterval; a user with a 5 s interval got 16 s and
  client CLATs dropped out (refs/gh/opnsense_core_10687.md lines 19-34, 53-55). Relevant if the box also advertises
  the ISP prefix to LAN clients.

### 2.8 Prefix or address change on reconnect
- Tunnel keeps the old outer source and silently black-holes IPv4 while IPv6 is fine (D2, D4).
- No event is raised when only RA/SLAAC changes (D3, D4).
- Community answers: newwanip hook filtered to inet6 plus a periodic job (1.5), a three second debounce and retry
  loop (1.5), watchdog scripts (D4). The claton draft section 7.1 says to tear down and recreate the CLAT instance on
  renumbering, optionally make-before-break.
- OpenWrt flushes NAT state for 192.0.0.1 on teardown (1.9).
- Event storms exist: 26.1-RC1 spawned hundreds of `rc.newwanipv6 pppoe0 force` processes on a PPPoE + DHCPv6 box
  until patch 9a80c6ddb29 (https://forum.opnsense.org/index.php?topic=50505.0, 2026-01-25/26, verified).

### 2.9 Boot ordering
- Device configured before WAN has a usable IPv6 address, then never reconfigured (D1, D2, D3).
- On PPPoE the SLAAC GUA could take more than ten minutes before 26.7.4 (D5).
- With "request prefix only" there is no WAN GUA at all; the source must come from the delegated prefix (D2, D3).
- os-tayga itself uses `sleep 1` between starting the daemon and configuring the tun (rc.d/opnsense-tayga:26).
- User-written syshook scripts with sleeps fight the framework and had to be removed after core improved (D3, D6).

### 2.10 Addressing and source selection
- Reusing an address that exists on another interface makes the tun configuration fail silently (B2).
- A GUA on the tun can be chosen as source for the firewall's own traffic (B3); counter evidence in B4.
- A CLAT address inside the on-link WAN /64 needs NDP proxying or NAT66; a routed (delegated) prefix does not (F2, F3, F5).
- tayga rejects sources that are not mapped (ICMPv6 code 5) and by default refuses the well-known prefix with
  non-global IPv4 unless `wkpf-strict no` (F3, F6).

### 2.11 HA / CARP
- No report of a CLAT, DS-Lite or MAP-E uplink on an OPNsense CARP pair was found.
- Related evidence only: os-tayga config sync complaint (B11) and both HA nodes losing IPv6 at a prefix change (D4).

### 2.12 Security side effects
- Translation gives a second path to IPv4 destinations that IPv4 rules do not cover (B7; pfSense #16241).
- The documented allow-all rule on the tayga interface group confuses users reading the live log (B8).

### 2.13 Plugin plumbing regressions
- configd action type (B10), input validation (B12), menu visible only after re-login and configd restart (1.5).

## 3. Tayga throughput evidence

| Source | Date | Platform | Result |
|--------|------|----------|--------|
| https://www1.slxh.eu/blog/2021/nat64-performance/ (verified) | 2021-03-31 | Linux (Debian Bullseye), iperf3 single TCP flow, best of three, no tuning | PC Engines APU (AMD GX-412, i211): routing 903 Mbit/s IPv4, tayga NAT64 199, NAT46 197. Jool on the same box 805. Ryzen 5 2600X (X550): routing 8478, tayga NAT64 2971, NAT46 2807; Jool 8193. Tayga reaches 21% of line rate on the APU and 31% on the Ryzen. |
| OPNsense forum topic 50096, reply 22 (verified) | 2026-02-21 | OPNsense 26.1.x, os-tayga 1.4, tayga 0.9.6, hardware not stated | User can now saturate a 2 Gbit/s line with NAT64 traffic on the same hardware, which was not possible before. Anecdotal, no method. |
| OPNsense forum topic 50096, apalrd (verified) | 2026-01-06 | - | Maintainer: single threaded and not very performant. |
| https://github.com/apalrd/tayga/issues/40 (verified) | 2025-05 to 2026-01, open | - | Maintainer: performance clearly below comparable projects; hot paths are checksum adjustment and the IPv6 map cache; most per-packet cost is in the kernel (context switches). Multi-queue tun workers are being integrated for Linux in dev-1.0; one flow still maps to one core. A contributor points out that multi-queue tun, io_uring, eBPF and segment offload do not exist on FreeBSD; maintainer confirms FreeBSD falls back to the single-packet path. |
| RIPE85 "open source NAT64" slides (search snippet only = unverified) | 2022 | Linux | Tayga described as core bound and topping out around 3 Gbit/s; Jool tested at 8.2 Gbit/s. |
| Lencse et al. papers (search snippets = unverified) | 2013 to 2020 | Linux/OpenBSD | Tayga about 120 kfps versus Jool about 230 kfps in one RFC 8219 style comparison (as re-quoted by the SLXH post). |
| ds-lite-opnsense README (verified) | 2026 | OPNsense, in-kernel gif, 10G line | About 2.29 Gbit/s per IPv4 flow. Upper reference for an in-kernel tunnel on OPNsense hardware, not a tayga number. |

Reading: on current low-power OPNsense boxes (N100/N305 class, DEC7xx) a tayga CLAT should carry several hundred
Mbit/s up to a low single-digit Gbit/s per flow, but nobody has published a FreeBSD/OPNsense measurement with method
and hardware. A CLAT path adds a NAT44 state lookup in pf plus two tun crossings per packet.

## 4. What users expect (UX)

- A WAN-side switch, not a recipe. noctarius' 2018 proposal was literally an "IPv4 configuration type" on WAN that
  behaves like "track interface" does for IPv6 (D7). M-Net users in 2026 say many would move to OPNsense if they did
  not have to build the tunnel by hand (D6, reply 12).
- Automatic parameter discovery with a manual override: AFTR via DHCPv6 option 64 for DS-Lite (D7, D6); for 464XLAT
  that means PREF64 from RA, then ipv4only.arpa, then a manual /96 (O1, claton draft).
- The result must look like a normal uplink: an interface that shows "up", a gateway with honest status, automatic
  outbound NAT, usable in port forwards, gateway groups and policy routing. Every deviation in the dslite plugin is
  listed by its author as a known problem (1.5).
- Survive reboot and PPPoE reconnect unattended. This is the top complaint in every DS-Lite thread (D1 to D4).
- No hand-edited `/tmp/rules.debug`, no syshook scripts with sleeps (1.4, D3, D6).
- Staff expectations: loosely coupled, no state files if the state can be read back from the system, predictable
  device names, hook into newwanip(v6) (D7); "stop fighting the framework" was the user's own conclusion in D6.
- A health/diagnostics page with concrete checks is appreciated (1.5).
- For the LAN side, the claton draft expects a CE router that does CLAT to also advertise PREF64 in RAs and offer a
  knob for DHCP option 108 (section 9.2); OPNsense users already ask about PREF64 lifetimes (2.7).
- Users who run tayga today expect VoWiFi/IPsec NAT-T to work (B5).

## 5. Existing things to study or avoid duplicating

| Item | Verdict |
|------|---------|
| OPNsense CLAT plugin or script | None exists. Nothing to duplicate. (verified by tracker and web search; absence proof is necessarily "likely") |
| os-tayga (official, NAT64 only) | Study for packaging and for the list of field failures in 1.2. Its group-only interface registration, `sleep 1`, static `route add` and manual NAT/pass rules are exactly what users trip over. Maurice (maurice-w) is the de facto domain owner and reviewer for anything tayga related in opnsense/plugins and opnsense/docs. |
| kawaii-not-kawaii/ds-lite-opnsense | Study: hook choice, ownership tracking of device and route, health checks, monitor host route. Avoid: own pf anchors for NAT and scrub, unassigned "offline" interface, manual gateway. |
| unchained-llc/os-ocnfixedip | Study: debounce and retry on newwanipv6, narrow scope. Avoid: plugin rewriting the system default route itself. |
| opnsense/core PR #2382 / #4335 (DS-Lite as WAN IPv4 type) | Study the review comments; this is what core maintainers objected to. |
| apalrd/tayga docs/clat + issues #83/#98 | The only FreeBSD CLAT recipes. Host CLAT only; router use needs NAT44 in front. |
| ipfw nat64clat | One failed OPNsense attempt, kernel panics fixed as late as 2026, lukewarm maintainer stance. |
| pf af-to (27.1) | The announced firewall-native path; no CLAT-specific discussion anywhere yet. |

## 6. Design implications (facts a designer must respect)

1. Treat "WAN has no usable IPv6 source yet" and "source changed" as normal states: (re)build on newwanip for inet6,
   debounce, and add a low-frequency reconcile, because SLAAC-only changes raise no event.
2. Do not use an address from the on-link WAN /64 for the CLAT unless NDP proxying is part of the plan; a delegated
   (routed) prefix avoids both NDP proxy and NAT66. With "request prefix only" the WAN may have no GUA at all.
3. Never reuse an address already on another interface for the tun, and keep GUAs off the tun unless source-address
   selection consequences are handled.
4. Make the device an assigned, addressed interface with a real gateway object; the unassigned or group-only variants
   are the documented source of "offline", missing alias, manual NAT and manual gateway complaints.
5. Do not load NAT or scrub rules through plugin-owned anchors or edit rules.debug: it collides with automatic
   outbound NAT (double translation) and with the stated constraint. Rely on core features that key off an assigned
   interface (automatic outbound NAT, interface MSS field, global reassembly).
6. Set the IPv4 MTU deliberately (IPv6 path MTU minus 28 per the draft; 1260 when tayga's default offlink-mtu of 1280
   is kept) and make sure tayga sees the tun MTU at start. Expose MSS through the interface, not through own rules.
7. Gateway monitor target must be a real IPv4 destination beyond the PLAT, with the probe pinned to the CLAT
   interface; pinging tayga's own address is only a liveness check.
8. Use `udp-cksum-mode fwd` and `wkpf-strict no` (or explicit `ipv6-addr`) as os-tayga does.
9. Offer PREF64, then RFC 7050, then manual prefix. Never depend on the firewall's own resolver doing DNS64.
10. configd actions that start/stop/restart must be `type:script`; add strict validation for address fields.
11. Budget for single-thread tayga performance on FreeBSD and say so in the UI/docs; keep the datapath swappable so
    the pf af-to path can replace it in 27.1.
12. Flush or kill pf states bound to the old CLAT source when the instance is rebuilt.
13. Minimum sensible OPNsense version for PPPoE users is 26.7.4 (SLAAC on PPPoE fix); the IPv4=None + PPPoE device
    model exists since 25.1.

## 7. Open questions

1. How did Maurice implement 464XLAT on his own OPNsense (A6)? Asking him would shortcut a lot.
2. No published tayga-on-FreeBSD throughput measurement with hardware and method. Needs a lab test on N100/DEC7xx.
3. Is `ipfw_nat64.ko` shipped in the OPNsense 26.7 kernel package, and does nat64clat coexist with pf states today?
   The only field test is from December 2021 on OPNsense 21.7 (A2), several base-system generations ago.
4. Does automatic outbound NAT pick up a plugin-provided, assigned tun interface that has a dynamic gateway, and does
   `<if> address` resolve for it? (Field reports say no for the plugin-registered gif; see opnsense-gateways-nat.md.)
5. Behaviour of an OPNsense CARP pair with a CLAT uplink: no field data at all.
6. Does pf `af-to` on FreeBSD 15.1 allow a second translation (NAT44) or outbound floating rules on translated
   packets? pfSense material says no; redmine #16135 could not be opened.
7. Could not read: pfSense redmine #2358/#16135 notes, FreeBSD PR 292023 details and fix commits, RIPE85 slides.
8. Does the target ISP hand out a delegated prefix on the IPv6CP-only PPPoE session, and does it send PREF64 or
   provide DNS64? This decides between routed-prefix and NDP-proxy addressing and the discovery default.
9. Why does tayga need a re-apply or reboot rather than a plain restart on OPNsense (B5)? Points at the rc script
   owning tun configuration and routes.
