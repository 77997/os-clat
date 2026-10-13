# Lab spike runbook: tayga CLAT by hand on stock OPNsense 26.7.6

Written 2026-10-11 for `DESIGN.md` section 15, items 1 to 4. It was written against draft v0.1 of the
design; items 1 to 4 are unchanged in v0.2, but the MTU expectations here predate the three-clamp rule
in DESIGN.md section 8 (they are identical for a 1492 uplink).

**This runbook is untested.** Nothing in it has been run on a box. Every command was checked against
source code or man pages (list in section 13); every "expected output" is a prediction from that
reading. Steps and expectations that could not be checked against a primary source carry the word
**UNVERIFIED**. Record what really happens next to each step; a deviation is a result, not a failure.

Goal: on a stock 26.7.6 box (no plugin, so no `_devices()` / `_interfaces()` / `_firewall()` hook) with an
IPv6-only PPPoE WAN, make LAN hosts reach IPv4 through the ISP's NAT64 using `tayga` on a tun device,
core's dynamic gateway, core's automatic outbound NAT, core's MSS clamp and one hand-made IPv6 pass rule.

| DESIGN section 15 item | Covered by |
|---|---|
| 1. Manual datapath, hand-made pass rule, TCP/UDP/ICMP from a LAN host | sections 5, 6 (V4 to V8) |
| 2. Assigned interface + router file gives gateway, default route, automatic NAT; `(dev:0)` resolves | section 6 (V1 to V3) |
| 3. Pass rule loads, no reply-to, CLAT address inside WAN /64 (antispoof), interface-bound states | section 6 (V3), section 8 |
| 4. MSS 1432, DF pings answered with "fragmentation needed" | section 6 (V9, V10), section 7 for the exact numbers |

---

## 1. Device name for the spike, and what it does to the MTU

**Use `clat0`, not `tun464`.**

- The Assignments device list is `get_interface_list()` (shown as "Hardware") plus names from plugin
  `_devices()` hooks. `get_interface_list()` splits the name at digits and drops it when a part equals a
  virtual pattern; `tun` is in that list (`interfaces.lib.inc:563-595, 636-640`). `tun464` is therefore
  hidden and only a `_devices()` hook could list it. `clat0` splits to `clat`, matches nothing, and is
  listed as Hardware as soon as it exists (`list_assign_options.php:44-54`). os-tayga's `nat64` works the
  same way.
- With a name that does not start with `tun`, tayga 0.9.6 opens the cloning node `/dev/tun`, gets a new
  `tunN` (kernel default MTU 1500, `if_tuntap.c:1058`), renames it with `SIOCSIFNAME` and reads the MTU
  with `SIOCGIFMTU` a few lines later in the same function (`tun.c:461-553` in the clone, same logic in
  0.9.6 `tayga.c`). There is no moment at which the MTU could be set first.

Consequences of `clat0`:

1. **tayga's internal MTU is always 1500**, whatever the WAN is. `ifconfig clat0 mtu 1492` afterwards
   changes only the kernel's `if_mtu`; tayga never re-reads it. This runbook leaves `clat0` at 1500.
2. TCP is not affected. The MSS clamp comes from the interface MSS field (1492 gives 1432).
3. The DF numbers of item 4 change. tayga answers DF packets above 1480 bytes itself with "MTU 1480".
   DF packets of 1473 to 1480 bytes are translated to 1493 to 1500 byte IPv6 packets, pf on `pppoe0`
   answers those with Packet Too Big 1492 (`pf.c:11098-11104`), and tayga converts that to
   "fragmentation needed, MTU 1472". It works, in two stages, and depends on the kernel's ICMPv6 error
   reaching tayga. The design's single-stage "1473 to 1492 gives MTU 1472" needs tayga to read 1492.
   Section 7 gives a variant for that.
4. DF-clear packets are fine: `offlink-mtu 1492` makes tayga fragment at min(1492, 1500).
5. A stale `clat0` blocks the next tayga start (rename fails with "File exists"). It must be destroyed
   before every restart, and a failed start leaves an orphan `tunN` behind.
6. `clat0` matches no `volatile` device pattern. **A reboot with `clat0` assigned stops at the console
   interface-assignment prompt** unless some interface has Lock set (`console.inc:48-76`). Tick Lock on
   the CLAT assignment and do not reboot during the spike. UNVERIFIED at runtime.

---

## 2. Prerequisites and safety

- OPNsense 26.7.6, no os-tayga plugin installed, console or LAN-side SSH access. Do not manage the box
  over a routed IPv4 path: the IPv4 default route will move to the CLAT.
- WAN: PPPoE device with **IPv4 Configuration Type None** and IPv6 DHCPv6 or SLAAC, IPv6 working.
- A PLAT (NAT64) reachable over IPv6, and its prefix. If the lab PLAT uses `64:ff9b::/96` and the lab
  "Internet" uses private, benchmark or documentation IPv4 ranges, tayga refuses them (`wkpf-strict`
  default). Use a network-specific prefix on the lab PLAT or add `wkpf-strict no` to the tayga config.
- A LAN host with IPv4 from the firewall (DHCPv4), default gateway = firewall LAN address.
- No other IPv4 gateway marked upstream or with priority below 254, and no static IPv4 gateway on an
  interface without an address. A management interface with its own IPv4 gateway will keep the default
  route; remove that gateway for the test.
- Outbound NAT mode automatic or hybrid; interface scrub not disabled.
- Take a configuration backup first (System > Configuration > Backups). Restoring it is the fallback
  clean-up.
- The root shell is csh. After choosing `8) Shell` type `sh`; all commands below are for `/bin/sh` as root.
- Optional: `script -a /root/clat-spike.log` to record the session.

---

## 3. Values to collect

```sh
WAN=pppoe0          # WAN device
LAN=igb1            # LAN device (adjust)

ifconfig $WAN | head -1                 # note "mtu", normally 1492
ndp -i $WAN                             # linkmtu=0 means no RA MTU; otherwise use the smaller value
ifconfig $WAN inet                      # expected: no "inet" line at all
ifconfig $WAN inet6                     # link-local, plus a global "autoconf" /64 and/or an IA_NA /128
/usr/local/sbin/ifctl -6p -i $WAN       # delegated prefix(es), e.g. 2001:db8:1200::/56 ; empty = none
/usr/local/sbin/ifctl -6n -i $WAN       # ISP resolvers learned on the WAN
ls /tmp/${WAN}_router 2>/dev/null       # expected: no such file (no IPv4 gateway on the WAN)
sysctl net.inet.ip.forwarding net.inet6.ip6.forwarding     # both 1
pluginctl -g nat.outbound.mode          # empty, "automatic" or "hybrid"
pluginctl -g system.scrub_interface_disable                # empty
configctl interface gateways status     # no IPv4 gateway with an address
netstat -rn4 | grep default             # expected: nothing
```

`pluginctl -g` was checked on core master only; `grep -A3 '<outbound>' /conf/config.xml` is the fallback.

**NAT64 prefix (`PREF64`).** Take it from the ISP. To cross-check with RFC 7050, ask an ISP resolver
directly (not Unbound on the box):

```sh
drill AAAA ipv4only.arpa @2001:db8:53::1      # resolver from "ifctl -6n"
```

Answers `...:c000:aa` and `...:c000:ab` at the end of a /96 give the prefix. A scoped link-local resolver
(`fe80::1%pppoe0`) may not be accepted by drill: UNVERIFIED.

Check that the PLAT works without any CLAT. If this fails, stop; the problem is not on this box.

```sh
ping -6 -c 3 64:ff9b::1.1.1.1          # replace prefix and target; expected: 3 replies
```

**The two IPv6 addresses.** They form a /127: the lower (even) one is the CLAT address that 192.0.0.1
maps to (`CLAT6`), the upper one is tayga's own (`SELF6`). Neither may be configured on any interface.

Case 1, a delegated prefix exists (preferred):

```sh
ifconfig | grep 'inet6 2001:db8:12'            # /64s of the PD already on interfaces (adjust the pattern)
# pick a /64 of the PD that is on no interface, e.g. prefix ID ff -> 2001:db8:1200:ff::/64
route -n get -inet6 2001:db8:1200:ff::464:0
```

Expected: the lookup ends at the discard route ifctl installed for the PD (`gateway: ::1`, flags contain
`BLACKHOLE`), not at a LAN device. If the PD is a single /64 that is on the LAN, use it anyway; the /127
route is more specific.

Case 2, no delegated prefix, WAN has a SLAAC address:

```sh
ifconfig $WAN inet6 | grep autoconf           # e.g. 2001:db8:aaaa:bbbb:xxxx:xxxx:xxxx:xxxx prefixlen 64
```

Use that /64. This depends on the BNG forwarding the whole /64 to the session.

Case 3, only an IA_NA /128 or only a link-local: not testable with this design.

In both usable cases:

```sh
CLAT6=2001:db8:1200:ff::464:0         # lower, last bit 0
SELF6=2001:db8:1200:ff::464:1         # upper
PREF64=64:ff9b::/96
MTU6=1492                             # WAN IPv6 MTU from above

ifconfig -a | grep -F -e "$CLAT6" -e "$SELF6"     # expected: no output
```

The variables are lost when the shell exits; write the values down.

---

## 4. Order of operations (why this order)

1. tayga must run first: `clat0` exists only while tayga has created it, and the GUI can only assign a
   device that exists.
2. All GUI work on the interface comes next. Every Apply on the interface runs `interface_reset()`,
   which deletes `/tmp/clat0_router`, and on 26.7.6 a record saved in the new Assignments dialog carries
   `ipaddr=none`, which makes core flush the tun's addresses on each apply (core#10996).
3. Addresses, route and router file are set after the last interface Apply.
4. `configctl interface newip clat0 force` is last: it needs an enabled record, an IPv4 address on the
   device and the router file, and it ends with a filter reload.

---

## 5. Procedure A (`clat0`)

### 5.1 Install tayga

```sh
pkg install -y tayga
pkg info tayga | grep -i version       # expected: 0.9.6
ls -l /usr/local/sbin/tayga
```

UNVERIFIED: that the box's configured repository offers `tayga` (the port is in opnsense/ports for 26.7).
The package installs no rc script and starts nothing.

### 5.2 Write the tayga configuration

Only directives that exist in 0.9.6 (`tun-device`, `ipv4-addr`, `ipv6-addr`, `prefix`, `map`,
`udp-cksum-mode`, `offlink-mtu`, `log`; also available but unused: `wkpf-strict`, `dynamic-pool`,
`data-dir`, `strict-frag-hdr`). `map-file`, `workers`, `tun-up`, `tun-ip`, `tun-route` do not exist in
0.9.6 and abort the start with `Unknown directive`.

```sh
cat > /usr/local/etc/tayga-clat.conf <<EOF
tun-device clat0
ipv4-addr 192.0.0.2
ipv6-addr ${SELF6}
prefix ${PREF64}
map 192.0.0.1 ${CLAT6}
udp-cksum-mode calc
offlink-mtu ${MTU6}
log drop reject icmp
EOF
cat /usr/local/etc/tayga-clat.conf      # check that the three variables were expanded
```

`ipv6-addr` must not lie inside `prefix` (tayga rejects that). `log` is optional and only adds
diagnostics; remove the line if tayga rejects it.

### 5.3 Start tayga

```sh
ifconfig clat0 2>/dev/null && echo "stale clat0: run 'ifconfig clat0 destroy' first"
/usr/local/sbin/tayga -c /usr/local/etc/tayga-clat.conf -p /var/run/tayga-clat.pid
pgrep -lf tayga
ifconfig clat0
opnsense-log | grep -i tayga | tail -5
```

Expected:

- `pgrep` shows one tayga process.
- `ifconfig clat0`: flags contain `POINTOPOINT` and `MULTICAST` but not `UP`, `mtu 1500`, no `inet` line,
  `groups: tun`, `nd6 options=...<...IFDISABLED...>`, last line `Opened by PID <pid>`.
- Log: `Using tun device clat0 with MTU 1500`. This line is the proof of section 1 point 1.
  UNVERIFIED: that tayga's syslog lines (ident `tayga`, facility daemon, level info) end up in the system
  log. If nothing shows, stop tayga, `ifconfig clat0 destroy`, and run it once in the foreground with
  `tayga -d -c /usr/local/etc/tayga-clat.conf` to read the messages, then Ctrl-C, destroy `clat0` again
  and start normally.

### 5.4 GUI: assign and configure the interface

1. **Interfaces > Assignments**, add an entry (the device list is cached for 60 seconds; if `clat0` is
   missing, wait and reload the page, or run `configctl interface list assign-opts` to look):
   - Device: `clat0` (listed under Hardware)
   - Description: `CLAT`
   - Enabled: ticked
   - Lock: ticked
   - MSS: `1492` (the WAN IPv6 MTU; not 1472)
   - MTU: empty
   - Block private networks, Block bogon networks: not ticked
   - IPv4 Configuration Type: None. IPv6 Configuration Type: None
   - Dynamic gateway policy: not ticked
   - Save, then Apply.

   Field names are from the 26.7 dialog definition; the exact click path of the page is UNVERIFIED.

2. Look at what was written:

   ```sh
   grep -B2 -A14 '<if>clat0</if>' /conf/config.xml
   ```

   The enclosing tag (for example `<opt1>`) is the interface key; it is called `opt1` below.
   On unpatched 26.7.6 expect `<ipaddr>none</ipaddr>` and `<ipaddrv6>none</ipaddrv6>` (core#10996).
   Record whether they are there. UNVERIFIED (taken from the issue and from reading the model).

3. If `none` is present: open **Interfaces > [CLAT]** (the legacy page, `/interfaces.php?if=opt1`), check
   that Enable is ticked, both configuration types show None and MSS shows 1492, press **Save**, then
   **Apply changes**. The legacy page rebuilds the record and writes no `ipaddr`/`ipaddrv6` key for type
   None. Its Apply also restarts the web GUI a few seconds later; reload the page.
   Run the `grep` again: expected `<enable>1</enable>`, `<mss>1492</mss>`, no `ipaddr` lines.
   UNVERIFIED (stable/26.7 `interfaces.php` was read, not run).

   From here on, do not open the CLAT entry in the Assignments dialog again until clean-up: a Save there
   writes `none` back, and the dialog validates the Device field against the list of existing devices,
   so it will refuse to save while `clat0` does not exist (tayga stopped).

   If `none` stays in the record the spike still works until the next Apply on this interface, but the
   gateway will be named `CLAT_NONE` instead of `CLAT_GW` (the name is built from the `ipaddr` value).

4. After the Apply:

   ```sh
   ifconfig clat0
   ```

   Expected: flags now contain `UP`, `description: CLAT (opt1)`. Core ran
   `ifconfig clat0 inet6 -accept_rtadv description ... up`. It does not clear `IFDISABLED`.
   The apply also tries hardware offload settings on the device; error lines about that in the system
   log would be harmless. UNVERIFIED.

### 5.5 GUI: the one IPv6 pass rule

**Firewall > Rules**, add a rule (labels from the master form; 26.7.6 wording may differ slightly, UNVERIFIED):

- Interface: `CLAT` (only this one)
- Quick: ticked
- Action: Pass
- Direction: In
- Version: **IPv6** (not IPv4+IPv6; an IPv4 rule on this interface would get `reply-to (clat0 192.0.0.2)`)
- Protocol: any
- Source: any. Destination: any
- Log: ticked (useful during the spike)
- Description: `CLAT: translated IPv6 from tayga`
- Save, then Apply.

### 5.6 Kernel side: addresses, IPv6 enable, route

```sh
ifconfig clat0 inet 192.0.0.1/32 192.0.0.2 up
ifconfig clat0 inet6 -ifdisabled
route -6 add ${CLAT6}/127 -interface clat0
```

- Line 1: local 192.0.0.1, peer 192.0.0.2 (tayga). The `/32` is deliberate: without a mask the kernel
  applies the classful default and the interface gets `netmask 0xffffff00`.
- Line 2: a new tun has IPv6 disabled and `ip6_input` drops everything tayga writes until this is done.
- Line 3: one route for both addresses. Never route `PREF64` into `clat0`.

Check:

```sh
ifconfig clat0
route -n get -inet6 ${CLAT6}
route -n get -inet6 ${SELF6}
route -n get -inet6 64:ff9b::1.1.1.1         # use your PREF64
ping -c 2 192.0.0.2
ping -6 -c 2 ${SELF6}
```

Expected:

- `inet 192.0.0.1 --> 192.0.0.2 netmask 0xffffffff`, an `inet6 fe80::...%clat0` line, and
  `nd6 options=...` without `IFDISABLED`.
- The first two lookups: `interface: clat0`, flags `<UP,DONE,STATIC>`, mask ending in `fffe`.
- The third lookup: `interface: pppoe0` (must not be `clat0`).
- Both pings answered. tayga answers echo requests to its own two addresses itself, so this proves the
  tun, both address families and tayga are alive. It says nothing about the PLAT.

### 5.7 Router file, then tell core

```sh
/usr/local/sbin/ifctl -i clat0 -4rd -a 192.0.0.2
cat /tmp/clat0_router                        # expected: 192.0.0.2
configctl interface newip clat0 force        # expected output: OK
opnsense-log | grep -E 'IP renewal|ROUTING|Failed to detect' | tail -8
```

Expected log lines (texts from core master, UNVERIFIED for 26.7.6):

```
IP renewal starting (new: 192.0.0.1, old: , interface: opt1, device: clat0, force: yes)
ROUTING: treating '192.0.0.2' as far gateway for '192.0.0.1/32'
ROUTING: configuring inet default gateway on opt1
ROUTING: setting inet default route to 192.0.0.2
```

`Failed to detect IP for interface opt1` means `clat0` has no IPv4 address (flushed, or step 5.6 skipped).
`Interface 'opt1' (clat0) is disabled or empty` means the record is not enabled.

---

## 6. Verification

Write the observed result next to each check.

### V1 Gateway list (item 2)

```sh
configctl interface gateways status
```

Expected: an entry with `"name":"CLAT_GW"`, `"address":"192.0.0.2"`, `"status":"none"`,
`"status_translated":"Online"`, monitor `~`. Output format UNVERIFIED for 26.7.6.
GUI: System > Gateways > Configuration shows `CLAT_GW`, interface CLAT, IPv4, priority 254, gateway
192.0.0.2, monitoring disabled, marked as the active default.
A name of `CLAT_NONE` means the record contains `ipaddr=none` (step 5.4.3).

### V2 Routing table (item 2)

```sh
netstat -rn4
netstat -rn6 | grep clat0
```

Expected IPv4 (other lines omitted):

```
Destination        Gateway            Flags     Netif Expire
default            192.0.0.2          UGS       clat0
192.0.0.1          link#N             UHS         lo0
192.0.0.2          link#N             UH        clat0
```

Expected IPv6: `<CLAT6>/127  link#N  US  clat0` and `fe80::%clat0/64  link#N  U  clat0`.
`netstat -rn6 | grep default` must still show the default via `pppoe0`.

### V3 pf rules (items 2 and 3)

```sh
pfctl -sn | grep clat0
pfctl -vsn | grep 'clat0'
pfctl -sr | grep clat0
grep clat0 /tmp/rules.debug
```

Expected NAT rules, one pair per interface that has IPv4 and no gateway, plus 127.0.0.0/8:

```
nat on clat0 inet from (igb1:network) to any port = 500 -> (clat0:0) static-port
nat on clat0 inet from (igb1:network) to any -> (clat0:0) port 1024:65535
```

(pfctl may print `isakmp` for 500.) With `-v` the target reads **`(clat0:0:1)`**: one address resolved,
which is 192.0.0.1. `(clat0:0:*)` means it resolves to nothing (address missing or interface down).
There must be no `nat on pppoe0 inet` rule.

Expected filter and scrub rules that name `clat0`:

```
scrub on clat0 inet all max-mss 1452 fragment reassemble
scrub on clat0 inet6 all max-mss 1432 fragment reassemble
pass in log quick on clat0 inet6 all flags S/SA keep state label "<uuid of your rule>"
```

- The pass rule must not contain `reply-to`.
- Also present because this is an ordinary `optN` (the design's plugin-registered interface would not
  have them): an antispoof line such as `block drop in log on ! clat0 inet from 192.0.0.1 to any` and one
  `pass out ... route-to (clat0 192.0.0.2) inet from (clat0) to ! (clat0:network) ...` line.
  Exact text UNVERIFIED.
- If the CLAT address is inside the WAN /64 or a LAN /64 there is also
  `block drop in log on ! <that device> inet6 from <that /64> to any`. It is not `quick`, so the pass rule
  wins.

### V4 Firewall-originated IPv4 (item 1)

```sh
ping -c 3 1.1.1.1
drill @1.1.1.1 example.com A | grep -A2 'ANSWER SECTION'
```

Expected: replies. The source is 192.0.0.1 without NAT.

### V5 Packet path on the tun and on the WAN (item 1)

In two more SSH sessions:

```sh
tcpdump -ni clat0 'icmp or icmp6'
tcpdump -ni pppoe0 "ip6 and host ${CLAT6}"
```

From the LAN host: `ping -c 2 1.1.1.1` (Windows: `ping -4 -n 2 1.1.1.1`).

Expected on `clat0`, four lines per echo (addresses are examples; the echo id is rewritten by NAT):

```
IP 192.0.0.1 > 1.1.1.1: ICMP echo request, id 40211, seq 1, length 64
IP6 2001:db8:1200:ff::464:0 > 64:ff9b::101:101: ICMP6, echo request, id 40211, seq 1, length 64
IP6 64:ff9b::101:101 > 2001:db8:1200:ff::464:0: ICMP6, echo reply, id 40211, seq 1, length 64
IP 1.1.1.1 > 192.0.0.1: ICMP echo reply, id 40211, seq 1, length 64
```

Expected on `pppoe0`: lines 2 and 3 only. The LAN host sees normal replies.
MLD and neighbour-discovery packets from `fe80::` also appear on `clat0`; tayga drops them.

Which lines are missing tells where it breaks; see section 10.

### V6 NAT state (item 2)

```sh
pfctl -ss | grep -F '192.0.0.1'
```

Expected while the ping runs: an IPv4 state that shows the LAN host in brackets, for example
`all icmp 192.0.0.1:40211 (192.168.1.10:1) -> 1.1.1.1:8 0:0`, and
`pfctl -ss | grep -F "$CLAT6"` shows two IPv6 states (in on `clat0`, out on `pppoe0`).

### V7 TCP from the LAN host (item 1)

```
curl -4 -sS -o /dev/null -w '%{http_code} %{size_download} %{speed_download}\n' http://<an IPv4-only URL of a few MB>
curl -4 -sS -o /dev/null -w '%{http_code}\n' https://1.1.1.1/
```

Expected: `200` and a complete download. A transfer that connects and then stalls points at MSS (V9).

### V8 UDP from the LAN host (item 1)

`dig +notcp @1.1.1.1 example.com A` (Linux/macOS), `nslookup example.com 1.1.1.1` (Windows).
Expected: an answer. `traceroute -n 1.1.1.1` shows the firewall, then several hops as `192.0.0.2`
(tayga puts its own address on ICMPv6 errors from IPv6-only routers), then IPv4 hops behind the PLAT.

### V9 TCP MSS (item 4)

Three captures on the firewall while the LAN host opens one new TCP connection to an IPv4 address
(`curl -4 http://<addr>/`):

```sh
tcpdump -ni $LAN  -c 2 'tcp[tcpflags] & tcp-syn != 0 and host <addr>'
tcpdump -ni clat0 -c 4 '(ip and tcp[tcpflags] & tcp-syn != 0) or (ip6 and ip6[6] == 6 and ip6[53] & 2 != 0)'
tcpdump -ni pppoe0 -c 2 'ip6 and ip6[6] == 6 and ip6[53] & 2 != 0'
```

`ip6[53]` is the TCP flags byte when there is no extension header. `tcp[tcpflags]` on IPv6 packets may
be rejected by the base system's libpcap, hence this form (UNVERIFIED).

Expected `mss` option values with MSS field 1492 and no MSS set on LAN or WAN (all UNVERIFIED, derived
from the rule generator and pf code):

| Capture point | SYN (LAN to Internet) | SYN-ACK (Internet to LAN) |
|---|---|---|
| LAN device | the host's own value, typically 1460 (captured before pf) | 1432 or lower |
| `clat0`, IPv4 packet | 1452 (clamped by the inet rule) | 1432 or lower |
| `clat0`, IPv6 packet | 1452 (as written by tayga, before pf) | 1432 or lower (clamped by the inet6 rule) |
| `pppoe0`, IPv6 packet | **1432** | whatever the PLAT sent |

Note for the design: the SYN-ACK captured on `pppoe0` is seen before pf, so it does **not** show 1432.
The clamped SYN-ACK is visible on `clat0` (IPv6, towards tayga) and on the LAN.

### V10 DF pings (item 4)

From the LAN host. Payload = IPv4 total length minus 28.

| OS | Command for a total length of 1472 |
|---|---|
| Linux | `ping -4 -M do -c 2 -s 1444 1.1.1.1` |
| FreeBSD, macOS | `ping -D -c 2 -s 1444 1.1.1.1` |
| Windows | `ping -4 -f -n 2 -l 1444 1.1.1.1` |

On the firewall, watch the errors: `tcpdump -ni clat0 'icmp[icmptype] == 3 or (icmp6 and ip6[40] == 2)'`.

Expected with Procedure A (tayga read MTU 1500, WAN 1492):

| IPv4 total length | Payload (`-s` / `-l`) | Expected |
|---|---|---|
| up to 1472 | up to 1444 | echo reply (if the target answers large pings) |
| 1473 to 1480 | 1445 to 1452 | `clat0` shows the IPv6 packet going in, an ICMPv6 Packet Too Big (MTU 1492) from a firewall address coming back out, then ICMPv4 "need to frag (mtu 1472)" from 192.0.0.2. Host: `From 192.0.0.2 ... Frag needed and DF set (mtu = 1472)`. UNVERIFIED |
| 1481 to 1500 | 1453 to 1472 | tayga answers directly: "need to frag (mtu 1480)" from 192.0.0.2. This differs from the design's 1472 because of the custom device name |

The design's own expectation (1473 to 1492 all answered with MTU 1472) is checked in section 7.
Linux caches the learned MTU; `ip route flush cache` between runs. Whether every host OS accepts an
ICMP error sourced from 192.0.0.2 is UNVERIFIED; note the OS and the result.

From the firewall itself: `ping -D -c 1 -s 1453 1.1.1.1` should print
`frag needed and DF set (MTU 1480)` from 192.0.0.2.

---

## 7. Variant B: let tayga read MTU 1492 (exact numbers for item 4)

Idea: use a persistent `tun464` so the MTU can be set before tayga starts, as the design does, and
rename the interface to `clat0` after tayga has opened it so the existing assignment binds to it.
`if_rename()` has no restriction for an open or UP interface and tun creates a `/dev/clat0` alias
(`if.c:3142-3201`, `if_tuntap.c:1078-1126`). **UNVERIFIED: renaming a tun that tayga holds open, and
tayga working afterwards.** If it fails, record that and keep the Procedure A results.

```sh
# stop Procedure A's instance
/usr/local/sbin/ifctl -i clat0 -4rd
kill "$(cat /var/run/tayga-clat.pid)"; sleep 1
route -q -6 delete ${CLAT6}/127 2>/dev/null
ifconfig clat0 destroy

# same config, but the device is tun464
sed 's/^tun-device .*/tun-device tun464/' /usr/local/etc/tayga-clat.conf > /usr/local/etc/tayga-clat-b.conf

ifconfig tun464 create
ifconfig tun464 mtu ${MTU6}
/usr/local/sbin/tayga -c /usr/local/etc/tayga-clat-b.conf -p /var/run/tayga-clat.pid
opnsense-log | grep -i tayga | tail -3        # expected: Using tun device tun464 with MTU 1492
ifconfig tun464 name clat0
ifconfig clat0                                # mtu 1492, Opened by PID <pid>
```

Then repeat 5.6 and 5.7 unchanged (no GUI step is needed; the record still says `clat0`), and repeat V1
to V9. For V10 the expectation is now the design's:

| IPv4 total length | Payload | Expected |
|---|---|---|
| up to 1472 | up to 1444 | echo reply |
| 1473 to 1492 | 1445 to 1464 | "need to frag (mtu 1472)" from 192.0.0.2, sent by tayga, no ICMPv6 involved |
| 1493 to 1500 | 1465 to 1472 | "need to frag (mtu 1492)" from the firewall's LAN address, sent by pf before NAT; the retry then gets 1472 from tayga |

Restarting tayga in this variant: rename back first (`ifconfig clat0 name tun464`), because tayga looks
the interface up by the configured name; then start, rename again, and redo 5.6 and 5.7.

---

## 8. Extra checks for item 3

Run V5 and V7 again in each of these states and note pass or fail.

1. **CLAT address inside the WAN /64** (only if the WAN has a SLAAC /64): stop tayga
   (section 9, "after a tayga restart"), set `CLAT6`/`SELF6` to a pair inside the WAN /64, rewrite the
   config, start again. `pfctl -sr | grep 'on ! pppoe0 inet6'` shows the antispoof block for that /64;
   traffic must still pass, and Firewall > Log Files > Live View must show no block on CLAT.
   Leave the capture running for several minutes: if replies stop arriving on `pppoe0` after a while,
   the BNG does neighbour resolution for the address (that is item 5 of the design, record it).
2. **Interface-bound states**: Firewall > Settings > Advanced, enable binding states to the interface
   (config key `system.state-policy`; label UNVERIFIED), Save, then check
   `grep state-policy /tmp/rules.debug` shows `set state-policy if-bound`. Start new connections and
   repeat V5 and V7. Switch it back afterwards.
3. **No reply-to**: already covered in V3.

---

## 9. Re-applying after a restart or a GUI Apply

Runtime state is lost in three situations:

| Event | What is lost |
|---|---|
| tayga exits (kill, crash) | kernel downs `clat0` and removes its addresses and the IPv4 default route; `/tmp/clat0_router` stays |
| Apply on the CLAT interface (either page) | `/tmp/clat0_router`; with `ipaddr=none` also 192.0.0.1 |
| `ifconfig clat0 destroy` | everything on the device |

After a GUI Apply, or as the last part after a tayga restart:

```sh
ifconfig clat0 inet 192.0.0.1/32 192.0.0.2 up
ifconfig clat0 inet6 -ifdisabled
route -q -6 delete ${CLAT6}/127 2>/dev/null
route -6 add ${CLAT6}/127 -interface clat0
/usr/local/sbin/ifctl -i clat0 -4rd -a 192.0.0.2
configctl interface newip clat0 force
```

After a tayga restart (Procedure A), before the block above:

```sh
/usr/local/sbin/ifctl -i clat0 -4rd                 # remove the router file while the tun is down
kill "$(cat /var/run/tayga-clat.pid)" 2>/dev/null; sleep 1
netstat -rn6 | grep clat0                           # note whether the /127 route survived the close
ifconfig clat0 destroy
/usr/local/sbin/tayga -c /usr/local/etc/tayga-clat.conf -p /var/run/tayga-clat.pid
```

Whether the `-interface` IPv6 route survives a tayga exit is UNVERIFIED; the `netstat` line records it
(the supervisor needs to know).

---

## 10. Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| tayga exits: `Unable to rename interface tun0 to clat0, aborting: File exists` | stale `clat0` from an earlier run | `ifconfig clat0 destroy`, also destroy the orphan `tunN` (`ifconfig -l`), start again |
| tayga exits: `Unknown directive ...` | directive from newer documentation | keep to the list in 5.2 |
| tayga exits: `Unable to open /dev/tun` | not root, or cloning off | `sysctl net.link.tun.devfs_cloning` must be 1 |
| tayga exits: `ipv6-addr cannot reside within configured prefix` | `SELF6` taken from the NAT64 prefix | choose both addresses from the PD or WAN /64 |
| `clat0` not offered in Assignments | 60 s cache of the device list, or tayga not running | `configctl interface list assign-opts \| grep clat0`; `ifconfig clat0` |
| Assignments dialog refuses to save the CLAT entry | device does not exist at that moment (tayga stopped, or between destroy and restart) | `ifconfig clat0`; start tayga first |
| Gateway named `CLAT_NONE` | record has `ipaddr=none` (26.7.6 Assignments dialog) | step 5.4.3 |
| No `CLAT_GW` at all | router file missing (never written, or wiped by an Apply), or interface not enabled | `cat /tmp/clat0_router`; `grep -A6 '<if>clat0' /conf/config.xml` |
| `newip` logs `Failed to detect IP for interface` | no IPv4 on `clat0` (tayga restarted, or flushed by an Apply with `ipaddr=none`) | `ifconfig clat0`; redo section 9 |
| Log: `refusing to set inet gateway on addressless` | same as above, seen from the routing code | same |
| `CLAT_GW` exists, default route does not point to it | another IPv4 gateway is upstream or has a lower priority number; or a static gateway on an address-less interface sorts first | `configctl interface gateways status`; System > Gateways > Configuration |
| No `nat on clat0` in `pfctl -sn` | outbound NAT mode manual or disabled; or no gateway (see above); or filter not reloaded | Firewall > NAT > Source NAT, Mode; `configctl filter reload`; `cat /tmp/rules.debug.error` |
| `pfctl -vsn` shows `(clat0:0:*)` | no address on `clat0`, or interface down | `ifconfig clat0` |
| V5: IPv4 request on `clat0`, no IPv6 line follows | tayga refused it: source not 192.0.0.1 and well-known prefix with strict mode (NAT missing), destination private with the well-known prefix, tayga dead | `pgrep tayga`; `opnsense-log \| grep tayga`; source address in the capture; `wkpf-strict` note in section 2 |
| V5: IPv6 request appears on `clat0` but never on `pppoe0` | IPv6 still disabled on the tun; or pass rule missing or wrong family or wrong interface; or no IPv6 default route | `ifconfig clat0 \| grep nd6`; Live View filtered on CLAT / block (label "Default deny / state violation rule"); `pfctl -sr \| grep 'clat0 inet6'`; `netstat -rn6 \| grep default` |
| V5: request leaves `pppoe0`, no reply arrives | wrong NAT64 prefix or PLAT down; BNG does not route the CLAT address back (WAN /64 placement); BNG source filter | `ping -6 <PREF64>::1.1.1.1` from the firewall; try a PD-based address |
| V5: reply arrives on `pppoe0`, not on `clat0` | /127 route missing (traffic goes to the PD discard route or back to the BNG), or the address is configured locally | `route -n get -inet6 $CLAT6`; `ifconfig -a \| grep -F "$CLAT6"` |
| V5: IPv4 reply appears on `clat0`, host gets nothing | NAT state gone; antispoof or a user rule on LAN-out | `pfctl -ss \| grep 192.0.0.1`; Live View |
| Ping and small pages work, large downloads stall | no MSS clamp: MSS field empty, interface scrub disabled, or only one of the two scrub lines | `pfctl -sr \| grep max-mss`; Firewall > Settings > Normalization |
| Everything worked, stopped after pressing Apply on an interface page | router file wiped, addresses flushed | section 9 |
| Everything worked, stopped after some minutes with a WAN-/64 address | BNG neighbour-cache timeout for the CLAT address | capture on `pppoe0`; use a PD address |
| Firewall-originated IPv4 works, LAN hosts do not | NAT rule missing for that LAN (interface has a gateway set, or no IPv4), or LAN rules block | `pfctl -sn`; LAN rules |
| DF ping gets no error at all | host ignores errors from 192.0.0.2, or state already expired | capture on the LAN device for `icmp[icmptype] == 3` |
| Traffic odd only for packets leaving `clat0` from 192.0.0.1 | the `route-to` force-gateway rule that every `optN` with a gateway gets | test once with Firewall > Settings > Advanced, "Disable force gateway", and record the difference |
| Box stops at the console asking to assign interfaces after a reboot | `clat0` assigned, device absent at boot, no Lock | answer the prompt keeping WAN/LAN; then clean up (section 11) |

---

## 11. Clean-up

GUI first, **while `clat0` still exists** (the Assignments dialog validates the device, see 5.4):

1. Firewall > Rules: delete the CLAT rule, Apply.
2. Interfaces > Assignments: edit CLAT, untick Lock, Save, Apply; then delete the entry and Apply.
   (Deleting also removes rules that reference only this interface. A locked entry cannot be deleted.)
   If the dialog refuses to save because the device is already gone, start tayga once more so that
   `clat0` exists, or restore the backup. UNVERIFIED.
3. Undo any setting changed in section 8.

Then the runtime state:

```sh
/usr/local/sbin/ifctl -i clat0 -4rd                    # remove /tmp/clat0_router
kill "$(cat /var/run/tayga-clat.pid)"; sleep 1          # tayga exits on SIGTERM
route -q -6 delete ${CLAT6}/127 2>/dev/null
ifconfig clat0 destroy
ifconfig tun464 destroy 2>/dev/null                    # only if Variant B left it under this name
ifconfig -l                                            # no clat0, no orphan tunN
```

Then:

```sh
configctl interface routes configure                   # re-evaluates routing and reloads the filter
configctl filter reload
rm -f /usr/local/etc/tayga-clat.conf /usr/local/etc/tayga-clat-b.conf /var/run/tayga-clat.pid \
      /tmp/clat0_oldip /tmp/clat0_oldgw
pkg delete -y tayga                                    # optional
```

Do not use `configctl interface newip clat0 force` here: it returns early once the device has no address.

Verify the box is back to its start state:

```sh
netstat -rn4 | grep default                  # nothing
pfctl -sn | grep clat0                       # nothing
pfctl -sr | grep clat0                       # nothing
configctl interface gateways status          # no CLAT_GW
grep -c clat0 /conf/config.xml               # 0
```

Only now is a reboot safe. If anything is left, restore the backup from section 2.

---

## 12. What to report back to the design

Fill in from the results above.

1. Gateway name seen (`CLAT_GW` or `CLAT_NONE`) and whether 26.7.6 wrote `ipaddr=none`.
2. Whether `(clat0:0)` resolved (`:1` in `pfctl -vsn`) and NAT states showed 192.0.0.1.
3. The exact `pfctl -sr` lines for `clat0`, including the antispoof and force-gateway lines.
4. The four MSS values of V9, and where the SYN-ACK showed the clamp.
5. The V10 table for Procedure A and, if it worked, Variant B.
6. Whether renaming an open tun works (Variant B).
7. Whether the `-interface` IPv6 route survives a tayga exit (section 9).
8. Whether tayga's log lines reach the system log, and which lines `newip` logged.
9. For a WAN-/64 address: how long the return path kept working.

Points about DESIGN.md section 8 found while writing this runbook (code reading only):

- Bring-up steps 1 to 7 are syntactically correct for 0.9.6, FreeBSD 15 and 26.7 core.
- Step 4 as written (`ifconfig tun464 inet 192.0.0.1 192.0.0.2 up`, no mask) gives netmask /24, not /32.
  It works, but `(tun464:network)` and core's "primary network" become 192.0.0.0/24. Use `192.0.0.1/32`.
- Teardown says "ask core to re-evaluate routing and the filter" without naming the command. The
  bring-up command cannot be reused: `rc.newwanip` returns before routing and filter when the device has
  no IPv4 address or the record is disabled. `configctl interface routes configure` does both.
- "Change of prefix, CLAT address or MTU: full restart of steps 1 to 7" does not delete the old /127
  route. Step 5 will fail with "route already in table" if the same route survived, and a route for an
  old address stays behind if it did. A delete before the add is needed in both cases.
- Section 15 item 4 expects the SYN-ACK to show 1432 "on the PPPoE side"; a capture there is taken
  before pf. See V9.
- Section 7.3 names the gateway `CLAT_GW`; with `ipaddr=none` in the record it is `CLAT_NONE`.

---

## 13. What was checked, and against what

Checked in the local clones (`refs/`):

| Item | Source |
|---|---|
| `tun464` hidden, `clat0` listed as Hardware; 60 s cache | `opnsense-core/src/etc/inc/interfaces.lib.inc:563-595, 636-640`; `.../scripts/interfaces/list_assign_options.php:44-76`; `.../actions.d/actions_interface.conf:81-86` |
| tayga clone, rename, MTU read order; `--mktun` only for `tun*` names | `tayga/tun.c:454-558` (master; 0.9.6 `tayga.c`, read as a fetched excerpt, has the same sequence) |
| tun default MTU, link up on open, down and purge on close, rename alias, MTU ioctl | `opnsense-src/sys/net/if_tuntap.c:1058, 1078-1126, 1204, 1276-1291, 1466-1468, 1538-1547` |
| Rename has no open/UP restriction | `opnsense-src/sys/net/if.c:3142-3201` |
| `ifctl -i <dev> -4rd -a <gw>`, `-4rd` alone removes the file | `opnsense-core/src/opnsense/scripts/interfaces/ifctl.sh:81-136, 259-283` |
| `configctl interface newip <dev> force`, `routes configure`, `gateways status`, `list assign-opts` | `.../actions.d/actions_interface.conf:26-30, 81-86, 166-170, 193-196` |
| `newip` takes a device name, needs enabled record and IPv4, then routing and filter | `opnsense-core/src/etc/rc.newwanip:39-69, 123-125` |
| `routes configure` runs routing and a filter reload | `opnsense-core/src/etc/rc.routing_configure:73-79` |
| Gateway name from `descr` and `ipaddr`, priority 254, router file | `.../Routing/Gateways.php:283-306, 386-441` |
| Far-gateway handling, default route add, log texts | `opnsense-core/src/etc/inc/system.inc:559-655, 682-722` |
| Automatic NAT condition and rule text | `.../etc/inc/filter.lib.inc:176-195`; `filter.inc:208-226`; `.../Firewall/SNatRule.php:73-80, 134-138` |
| `(dev:0:N)` in verbose pfctl output; p2p needs `IFA_ROUTE` | `opnsense-src/sbin/pfctl/pf_print_state.c:59-75`; `sys/netpfil/pf/pf_if.c:739-742` |
| Scrub rule print format | `opnsense-src/sbin/pfctl/pfctl_parser.c:1174-1190` |
| pf sends frag-needed / Packet Too Big for forwarded oversize packets | `opnsense-src/sys/netpfil/pf/pf.c:11083-11104` |
| Antispoof and force-gateway rules skip only `internal_dynamic` | `filter.inc:575-578`; `filter.lib.inc:585-618` |
| Boot mismatch prompt and Lock | `opnsense-core/src/etc/inc/console.inc:48-76`; `rc.bootup:73-75` |
| `pluginctl -g`, `opnsense-log` | `opnsense-core/src/sbin/pluginctl:156-241`; `src/sbin/opnsense-log` |
| Rule dialog field names (master) | `.../Firewall/forms/dialogFilterRule.xml` |

Checked in fetched upstream files (content-level, no line numbers):

| Item | URL |
|---|---|
| 0.9.6 directive table, `log` keywords, `offlink-mtu` limits, comments, "Unknown directive", ipv6-addr vs prefix | `raw.githubusercontent.com/apalrd/tayga/0.9.6/conffile.c`, `.../tayga.conf.5` |
| 0.9.6 options `-c -d -n -p -u -g -r --mktun --rmtun`; all signals exit | `.../0.9.6/tayga.c` |
| 0.9.6 MTU logic, PTB conversion, own-address fallback, echo to own addresses | `.../0.9.6/nat64.c` |
| stable/26.7 `interface_configure()`: `-accept_rtadv description ... up`, case `none` leaves `ifdisabled`, flush on non-empty `ipaddr` | `raw.githubusercontent.com/opnsense/core/stable/26.7/src/etc/inc/interfaces.inc` |
| stable/26.7 legacy interface page: type None writes no `ipaddr`, MSS field, apply sequence | `.../stable/26.7/src/www/interfaces.php` |
| stable/26.7 `rc.newwanip`, scrub lines, antispoof, automatic NAT, `state-policy` | `.../stable/26.7/src/etc/rc.newwanip`, `.../src/etc/inc/filter.inc` |
| stable/26.7 gateway naming | `.../stable/26.7/src/opnsense/mvc/app/models/OPNsense/Routing/Gateways.php` |
| stable/26.7 Assignments dialog fields; menu paths; Source NAT mode dialog | `.../Interfaces/forms/dialogAssignment.xml`, `.../Firewall/Menu/Menu.xml`, `.../Core/Menu/Menu.xml`, `.../Firewall/forms/dialogSNatMode.xml` |
| `ifconfig` address/dest/CIDR, `mtu`, `name`, `create`, `destroy`, `inet6 -ifdisabled` | `raw.githubusercontent.com/opnsense/src/stable/26.7/sbin/ifconfig/ifconfig.8` |
| `route` flags `-4 -6 -n -q`, `add/delete/get`, `net/bits`, `-interface` | `.../stable/26.7/sbin/route/route.8`; usage precedent `system.inc:614` |
| `ping -D -s -c -S -6`, `ping6` name | `.../stable/26.7/sbin/ping/ping.8` |
| Classful default mask on p2p, host route to the peer, `IFA_ROUTE` | `.../stable/26.7/sys/netinet/in.c` |

Not checked against a source (standard usage from general knowledge): `tcpdump` filter expressions,
`netstat -rn4/-rn6` output layout, `drill`, `ndp -i`, `pgrep`, `sed`, `script`, `pkg`, and the LAN-host
commands for Linux and Windows.

---

## 14. All UNVERIFIED points in one list

1. `pkg install tayga` succeeds from the box's repository (5.1).
2. tayga's log lines reach the system log; `opnsense-log | grep tayga` shows the MTU line (5.3).
3. Click path and behaviour of the 26.7.6 Assignments page; that it writes `ipaddr=none` (5.4.1, 5.4.2).
4. A legacy-page Save removes `ipaddr=none` and keeps MSS and Enable (5.4.3).
5. Side effects of the apply on a tun (hardware offload settings) (5.4.4).
6. Rule dialog labels on 26.7.6 (5.5).
7. Log texts of `newip` on 26.7.6 (5.7).
8. Output format of `configctl interface gateways status` and of `pluginctl -g` on 26.7.6 (section 3, V1).
9. Exact text of core's antispoof and force-gateway rules for `clat0`, and that the force-gateway
   `route-to` rule is harmless on the tun (V3, section 10).
10. All MSS values in V9, and the `ip6[53]` capture filter.
11. The two-stage path for DF packets of 1473 to 1480 bytes in Procedure A, including the source
    address of the resulting ICMPv4 error (V10).
12. Host operating systems acting on an ICMP error from 192.0.0.2 (V10).
13. Variant B as a whole: renaming a tun that tayga holds open (section 7).
14. Label and location of the "bind states to interface" setting (section 8).
15. Whether the `-interface` IPv6 route survives a tayga exit (section 9).
16. Boot behaviour with `clat0` assigned, and that Lock prevents the console prompt (section 1, 10).
17. `drill` with a scoped link-local resolver (section 3).
