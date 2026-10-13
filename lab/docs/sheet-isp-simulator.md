# Sheet: isp-simulator — the Debian 13 VM "clat-world"

Research sheet, written 2026-10-12. **Nothing in this sheet has been run.** No VM exists yet, no image was downloaded, no Hyper-V command was issued. Every file and command below comes from reading man pages, package sources and documentation.

Marking used:

- **[SRC]** read in a primary source (the source is named at the statement or in section 13).
- **UNCONFIRMED** not found in a primary source, or it depends on behaviour that only a run can show. Section 11 lists what the first run has to confirm, with the command for each.

Placeholders of the form `@@NAME@@` are filled in by whatever builds the seed image (section 10.3). Test credentials are not written in this sheet.

---

## 0. Findings that change the plan

1. **The image must be `debian-13-generic-amd64.qcow2` (415M), not `genericcloud`.** The cloud kernel has `# CONFIG_PPP is not set`, so no PPPoE server can run on genericcloud. The generic image uses `linux-image-amd64`, which has `CONFIG_PPP=m`, `CONFIG_PPPOE=m`, `CONFIG_TUN=m` and all Hyper-V drivers. `nocloud` has no cloud-init. [SRC: Debian kernel `debian/config/config.cloud` lines 896-898, `debian/config/config` lines 3838-3849, `kernelarch-x86/config` lines 684, 1346, 1706; debian-cloud-images `config_space/13/package_config/AMD64`]
2. **The simulated BNG cannot grant a PPP MTU above 1500.** Both rp-pppoe 4.0 (`ETH_JUMBO_LEN = ETH_DATA_LEN+8`) and pppd 2.5.2's `pppoe.so` (`ETH_JUMBO_LEN 1508`, `MAX_PPPOE_MTU` = 1500) cap it. A request above 1500 is answered with 1500, which is not an exact echo. DESIGN 8.3 row "WAN MTU 1508" can be exercised exactly; rows 1518 and 1528 can only be exercised against a BNG that does not echo the value. accel-ppp is not packaged in Debian 13. (Section 8.)
3. **Debian 13 ships tayga 0.9.2** (`0.9.2-10+deb13u1`), not 0.9.6. It has no `wkpf-strict` and no `offlink-mtu` directive, always refuses private IPv4 with the well-known prefix, and fragments DF-clear IPv4 packets to 1280-byte IPv6 packets. That is good enough for a simulated PLAT, with two visible effects (section 5.5).
4. **Kea is the DHCPv6-PD server, started per PPP session.** A risk was found by reading Debian's AppArmor profile for `kea-dhcp6`: it has no `capability net_bind_service` line (the `kea-dhcp4` profile has one). A local override is written before the package is installed; whether it is needed is UNCONFIRMED. (Section 4.)
5. **NIC names are bound by MAC address, not by order.** cloud-init renames by MAC only (`set-name` needs `match.macaddress`), and the order of Hyper-V synthetic NICs in a guest is not guaranteed. This sheet uses the static MACs that `sheet-hyperv-mechanics.md` section 2.5 already defines (section 1.1).
6. **The lab has no IPv6 Internet.** The Default Switch gives IPv4 NAT only. All IPv6 ends on clat-world; the only way out is the NAT64.

Two points where `sheet-hyperv-mechanics.md` (read on 2026-10-12) has to follow this sheet:

- Its conversion command names `debian-13-genericcloud-amd64.qcow2`. It must be `debian-13-generic-amd64.qcow2` (finding 1).
- Its open question whether the kernel can read the seed DVD: the generic image's kernel has `CONFIG_BLK_DEV_SR=m`, `CONFIG_ISO9660_FS=m`, `CONFIG_JOLIET=y` and `CONFIG_VFAT_FS=m` [SRC: `debian/config/config` lines 4775, 5967, 6011-6012], so an ISO on the SCSI DVD drive and a FAT disk are both readable. That the modules load in time for cloud-init's local stage is for the first run to show.

---

## 1. Overview

### 1.1 NICs, names, MAC contract

This sheet numbers the NICs eth0 to eth3 (nat, wan, lan, mgmt); the kernel's own names need not match, see item 5. Inside the guest they get role names, bound by MAC:

| Listed as | Hyper-V switch | Adapter name and static MAC in `sheet-hyperv-mechanics.md` 2.5 | Guest name | Use |
|---|---|---|---|---|
| eth0 | Default Switch | `nat`, `02:c1:a7:00:01:01` | `up0` | DHCPv4, Internet, ssh from the host |
| eth1 | clat-wan (private) | `wan`, `02:c1:a7:00:01:03` | `wan0` | PPPoE server, no IP address |
| eth2 | clat-lan (private) | `lan`, `02:c1:a7:00:01:04` | `lan0` | moved into network namespace `client` |
| eth3 | clat-mgmt (private) | `mgmt`, `02:c1:a7:00:01:02` | `mgmt0` | 10.99.0.1/24, jump host path to 10.99.0.2 |

- The MACs are the ones the Hyper-V sheet already proposes (`-StaticMacAddress '02C1A7000101'` and so on). That sheet adds the adapters in the order nat, mgmt, wan, lan, which is not the eth0 to eth3 order above. It does not matter here: every name in this sheet is bound to a MAC, never to a position.
- These are locally administered unicast addresses. That Hyper-V accepts them as static MACs is UNCONFIRMED (same remark in the Hyper-V sheet); if the fallback `00155Dxxxxxx` is used, `network-config` (10.2) must be changed with it.
- Without static MACs, `network-config` cannot rename; it would have to use the kernel names eth0 to eth3 and trust the order (UNCONFIRMED that the order is stable).
- Hyper-V port settings needed on clat-world's adapters: all defaults (MAC address spoofing off, DHCP guard off, router guard off). The crafted RA of section 7.4 uses the adapter's real MAC, so spoofing stays off. Router guard must stay off on the `clat-lan` adapter or that RA is dropped by the switch.

### 1.2 Addressing plan

| Item | Value | Note |
|---|---|---|
| `up0` | DHCP from the Default Switch | subnet and gateway change when the host reboots (community reports, UNCONFIRMED) |
| `mgmt0` | 10.99.0.1/24 | OPNsense is 10.99.0.2 |
| PPP link, server side | link-local `fe80::1` | `ipv6 ::1,` in the pppd options |
| WAN /64 announced in the RA | `2001:db8:a::/64` | autonomous flag on or off |
| Delegated prefix | `2001:db8:5600::/56` | renumbering example: `2001:db8:5700::/56` |
| DNS resolver (RDNSS) | `2001:db8:64::53` | on dummy interface `isp0`; also listens on 10.99.0.1 |
| NAT64 prefix | `64:ff9b::/96` | tayga on tun `nat64` |
| tayga's own addresses | `192.168.255.1`, `2001:db8:64::64` | |
| NAT64 IPv4 pool | `192.168.255.0/24` | masqueraded out of `up0` |
| IPv4 test target | `192.88.99.1` = `64:ff9b::c058:6301` | on `isp0`; see 5.3 |
| IPCP addresses (only with `ispctl ipv4 on`) | `100.64.0.1` (BNG) and `100.64.0.2` and up | |
| LAN client | DHCPv4 from OPNsense (192.168.1.0/24 by default) | namespace `client` |

2001:db8::/32 is the documentation prefix. It never leaves clat-world. OPNsense's "Block bogon networks" on the WAN applies to new inbound connections only; replies match states. The first run should still note whether that default setting has any effect.

### 1.3 Packages (Debian 13 "trixie", amd64)

Versions from `qa.debian.org/madison.php` on 2026-10-12 [SRC]:

| Package | Version | Role |
|---|---|---|
| `ppp` | 2.5.2-1+1 | pppd, `pppoe.so` plugin |
| `pppoe` | 4.0-1 | rp-pppoe; contains `/usr/sbin/pppoe-server` [SRC: package file list] |
| `radvd` | 1:2.20-1+b1 | Router Advertisements with `nat64prefix`; also contains `radvdump` |
| `kea-dhcp6-server` | 2.6.3-1+deb13u1 | DHCPv6 prefix delegation |
| `tayga` | 0.9.2-10+deb13u1 | NAT64 |
| `nftables` | 1.1.3-1 | masquerade, forward policy |
| `unbound` | 1.22.0-2+deb13u3 (1.26.1 in trixie-security) | DNS64 resolver |
| `python3-scapy` | 2.6.1+dfsg-1 | crafted RA with PREF64 |
| `udhcpc` | 1:1.37.0-6 | DHCPv4 client in the namespace (busybox) |
| `iperf3` 3.18, `tcpdump` 4.99.5, `curl`, `iputils-ping`, `iputils-tracepath`, `bind9-dnsutils`, `mtr-tiny`, `conntrack`, `ethtool` | | test tools |
| `hyperv-daemons` | 6.12.x | KVP daemon, so the host can read the guest's IP addresses |

Not in Debian 13: `accel-ppp`, `odhcpd` (no rows in madison / sources.debian.org). In Debian 13 but not used: `jool-dkms` 4.1.13 (builds a kernel module with DKMS, so it is excluded), `dnsmasq` 2.91, `wide-dhcpv6-server` 20080615-24, `dibbler-server` 1.0.1-2, `isc-dhcp-server` 4.4.3-P1-8.

Already in the generic cloud image [SRC: debian-cloud-images `config_space/13/package_config`]: cloud-init, netplan.io, systemd-resolved, openssh-server, apparmor, iptables, unattended-upgrades, python3 (cloud-init needs it).

### 1.4 Services on clat-world

| Unit | From | Started |
|---|---|---|
| `isp-base.service` | this lab | boot; runs `ispctl init` (dummy interface, routes, pppd options) |
| `isp-pppoe.service` | this lab | boot; `pppoe-server` on `wan0` |
| `isp-nat64.service` | this lab | boot; tayga (the packaged `tayga.service` is disabled, it does not set up the tun) |
| `isp-www.service`, `isp-iperf3.service` | this lab | boot; test target on 192.88.99.1 |
| `isp-client.service` | this lab | boot; namespace `client` and its DHCP client |
| `nftables.service`, `unbound.service` | Debian | boot |
| `radvd.service`, `kea-dhcp6-server.service` | Debian | **only from the PPP hooks**, with a config generated for the session's interface |

---

## 2. PPPoE server with IPv6CP only (item 1)

### 2.1 What the sources say

- Debian's `pppoe` package builds rp-pppoe 4.0 with `PPPD=/usr/sbin/pppd ./configure`; the default plugin path compiled in is `/etc/ppp/plugins/rp-pppoe.so`, which does not exist on Debian. `-g` gives the plugin: man page, "the full path to the pppoe.so or rp-pppoe.so plugin to use with kernel-mode PPPoE". pppd looks for a plugin name without a slash in `/usr/lib/pppd/<version>/`. So: `-k -g pppoe.so`. [SRC: `debian/rules`, `src/Makefile.in` lines 44-45, `man/pppoe-server.8`, `pppd.8` "plugin"]
- In kernel mode `pppoe-server` runs: `pppd plugin <path> nic-<if> rp_pppoe_sess <id>:<mac> rp_pppoe_service <name> file <optfile> <local>:<remote> nodetach noaccomp nopcomp default-asyncmap remotenumber <mac> mru N mtu N`. [SRC: `pppoe-server.c` 4.0 lines 1926-2020]. pppd 2.5.2's `pppoe.so` still accepts `rp_pppoe_sess` and `rp_pppoe_service` as "Legacy alias" options and strips the `nic-` prefix. [SRC: `pppd/plugins/pppoe/plugin.c` lines 79-88, 363]
- The option file defaults to `/etc/ppp/pppoe-server-options` and "must exist". Debian's package removes the shipped one, so the lab writes it. [SRC: man page; `debian/rules` `rm -rf debian/pppoe/etc/ppp`]
- `noip`: "Disable IPCP negotiation and IP communication". It clears `ipcp_protent.enabled_flag`. A packet for a protocol that is not enabled is answered with `lcp_sprotrej()`, an LCP Protocol-Reject; with `debug`, pppd logs "Unsupported protocol '…' (0x8021) received". That is the clean refusal of a client that proposes IPCP. [SRC: `pppd.8`; `ipcp.c` line 143; `main.c` lines 1201-1215]
- `+ipv6`: "Enable the IPv6CP and IPv6 protocols". `ipv6 <local>,<remote>`: "Either one may be omitted". With only the local identifier given, pppd sets `accept_remote`, so the client keeps the identifier it proposes. [SRC: `pppd.8`; `ipv6cp.c` lines 363-399, 547-548]
- Debian's `/etc/ppp/options` already contains `auth`, `lcp-echo-interval 30`, `lcp-echo-failure 4`. `/etc/ppp/ipv6-up` runs `run-parts /etc/ppp/ipv6-up.d` with the six arguments `interface tty speed local-LL remote-LL ipparam`. run-parts skips names containing a dot, hence `50-isp`. [SRC: Debian ppp `debian/extra/options`, `debian/extra/ipv6-up`; `pppd.8` scripts section]
- A PPPoE client that sends an empty Service-Name is served without `-S`. [SRC: man page, `-S`]

### 2.2 Files

`/etc/systemd/system/isp-pppoe.service`

```ini
[Unit]
Description=Lab BNG: PPPoE server on wan0 (IPv6CP only by default)
Requires=isp-base.service
After=isp-base.service

[Service]
Type=simple
ExecStartPre=/usr/sbin/modprobe -a pppoe
ExecStart=/usr/sbin/pppoe-server -F -I wan0 -C clat-bng -k -g pppoe.so -L 100.64.0.1 -R 100.64.0.2 -N 8 -O /etc/ppp/pppoe-server-options
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
```

- `-F` foreground; `-k` kernel mode; `-N 8` so a new session can come up while a dead one is still waiting for its LCP echo time-out. The hooks follow the newest session (section 9).
- Stopping the unit kills the pppd children too (systemd's default control-group kill), which ends all sessions.
- Fallback if kernel mode fails on the first run: remove `-k -g pppoe.so`. pppd is then started with `pty "/usr/sbin/pppoe -n -I wan0 -e <sess>:<mac> -S ''"` and all frames pass through a user-space process (slow, but functional).

`/etc/ppp/pppoe-server-options` (written by `ispctl`, shown for `ipv4 off`)

```
# written by ispctl; do not edit
name clat-bng
auth
require-chap
+ipv6
ipv6 ::1,
noip
lcp-echo-interval 5
lcp-echo-failure 3
nodefaultroute
ipparam clat-lab
debug
logfile /var/log/isp/pppd.log
```

With `ispctl ipv4 on` the line `noip` is left out. pppd then negotiates IPCP with the addresses that `pppoe-server` puts on its command line (`100.64.0.1:100.64.0.2`). The nftables rules of section 5.2 already masquerade 100.64.0.0/24 out of `up0`, so native IPv4 works at once.

`/etc/ppp/chap-secrets` and `/etc/ppp/pap-secrets` (mode 0600, written after the packages are installed)

```
# client        server  secret                  IP addresses
@@PPPOE_USER@@  *       "@@PPPOE_PASS@@"        *
```

`/etc/ppp/ipv6-up.d/50-isp` (mode 0755)

```sh
#!/bin/sh
# $1 interface, $4 local link-local, $5 remote link-local
exec /usr/local/sbin/ispctl _up "$1" "$5"
```

`/etc/ppp/ipv6-down.d/50-isp` (mode 0755)

```sh
#!/bin/sh
exec /usr/local/sbin/ispctl _down "$1"
```

`/etc/ppp/ip-up.d/50-isp` (mode 0755; only runs when IPCP came up, so its log line is the evidence for the native-IPv4 test)

```sh
#!/bin/sh
logger -t ispctl "IPv4 up on $1: local $4 remote $5"
```

### 2.3 Operations

| Action | Command | Effect |
|---|---|---|
| Graceful reset from the BNG side | `pkill -TERM -x pppd` | pppd closes LCP (Terminate-Request); when pppd exits, pppoe-server sends PADT |
| Silent loss | `ip link set wan0 down; pkill -KILL -x pppd; sleep 2; ip link set wan0 up` | no Terminate-Request and no PADT reach the client (UNCONFIRMED: that pppoe-server survives the failed send; the unit restarts it if not) |
| Allow IPCP | `ispctl ipv4 on; ispctl session reset` | next session offers IPv4 |

Native IPv4 appears only if OPNsense also proposes IPCP, which needs WAN "IPv4 Configuration Type" PPPoE. With type None, mpd5 does not negotiate IPCP (to be seen in `/var/log/isp/pppd.log`). The second native-IPv4 case of DESIGN section 15 item 10 (a static gateway) needs no IPCP at all: give OPNsense's management interface the gateway 10.99.0.1 and run `ispctl provision on`.

---

## 3. Router Advertisements from radvd, per session (item 2)

### 3.1 What the sources say (radvd 2.20)

- `nat64prefix` arrived in 2.20_rc1 (2023-11-16: "NAT64/pref64 support (RFC6052, RFC8781)"); 2.20 was released 2024-12-31. Debian 12 has 2.19 (no support); Debian 13 has 1:2.20-1. [SRC: radvd `CHANGES`; madison]
- Syntax: `nat64prefix prefix/length { AdvValidLifetime seconds; };`. Length must be 32, 40, 48, 56, 64 or 96. `AdvValidLifetime`: maximum 65528, rounded up to a multiple of 8, default "the lesser value of 3 * MaxRtrAdvInterval, or 65528". [SRC: `radvd.conf.5`; `gram.y` lines 493-577]
- **Lifetime 0 is accepted** (the grammar only checks the maximum) and is encoded as scaled lifetime 0: `htons(((curr_validlft + 7) & 0xFFF8) | plc)`. That is the withdrawal of RFC 8781. [SRC: `gram.y` lines 565-576; `send.c` lines 292-354]
- The option is put into every RA, solicited or not (`build_ra_options`). It is **not** zeroed in the final RA that radvd sends when it stops; only the router lifetime is. So stopping radvd does not withdraw the prefix. [SRC: `send.c` lines 846-848; `radvd.c` `stop_advert_foo`]
- Solicited RAs: with `AdvRASolicitedUnicast on` (default) and a solicitation from a specified source address, radvd answers at once with a unicast RA to the solicitor, without rate limit. Otherwise it answers by multicast, at most one per `MinDelayBetweenRAs` (3 s). [SRC: `process.c` lines 151, 189-200]
- `UnicastOnly on`: "This will prevent unsolicited advertisements from being sent, and will cause solicited advertisements to be unicast to the soliciting node." This gives a "solicited only" mode for testing the supervisor's Router Solicitation burst. [SRC: `radvd.conf.5`; `radvd.c` lines 729-745]
- SIGHUP re-reads the config and calls `kickoff_adverts()`, which sends one RA immediately (unless `UnicastOnly`). No zero-lifetime RA is sent on reload. A stop or restart does send a final RA with router lifetime 0 (`RemoveAdvOnExit`, default on), which removes the client's default route for a moment. So runtime changes use **reload**, never restart. [SRC: `radvd.c` lines 729-821; `radvd.conf.5`]
- PPP interfaces: `check_device()` forces `UnicastOnly` only when the interface has neither `IFF_MULTICAST` nor `IFF_POINTOPOINT`; a ppp interface passes. For a non-Ethernet type radvd sets no source link-layer option and does not limit `AdvLinkMTU` from above. [SRC: `device-common.c`; `device-linux.c` lines 122-128; `interface.c` lines 223-226]
- Debian's unit: `ConditionPathExists=/etc/radvd.conf`, `ExecReload` = config test, then `kill -HUP`. [SRC: `radvd.service.in` in the Debian source]
- radvd also tries to write `AdvLinkMTU` to `/proc/sys/net/ipv6/conf/<if>/mtu` on the server. Under Debian's unit (capability set without CAP_NET_ADMIN) this probably fails and is ignored. It does not matter: the ppp interface already has the negotiated MTU. UNCONFIRMED, harmless.

### 3.2 Generated `/etc/radvd.conf`

Written by `ispctl` for the session's interface. With the defaults of section 9.1 and a session on `ppp0` at MTU 1492:

```
interface ppp0 {
    AdvSendAdvert on;
    IgnoreIfMissing on;
    MaxRtrAdvInterval 600;
    AdvDefaultLifetime 1800;
    AdvManagedFlag off;
    AdvOtherConfigFlag on;
    AdvLinkMTU 1492;
    prefix 2001:db8:a::/64 {
        AdvOnLink on;
        AdvAutonomous on;
        AdvValidLifetime 7200;
        AdvPreferredLifetime 3600;
    };
    RDNSS 2001:db8:64::53 {
        AdvRDNSSLifetime 1800;
    };
    nat64prefix 64:ff9b::/96 { AdvValidLifetime 1800; };
};
```

| Setting | Variable | Values |
|---|---|---|
| SLAAC address on the WAN | `SLAAC` | `on` / `off` → `AdvAutonomous` |
| PREF64 | `PREF64` | `on` (option with `PREF64_LIFETIME`), `off` (no option), `withdraw` (option with lifetime 0) |
| PREF64 prefix and lifetime | `PREF64_PREFIX`, `PREF64_LIFETIME` | any RFC 6052 length; 0 to 65528 |
| RA MTU option | `RA_MTU` | `auto` (the ppp interface's MTU), `off` (no option), or a number ≥ 1280 |
| RA interval | `RA_INTERVAL` | 10 to 1800 s. Default 600, so that an RA-only line really depends on the solicited RA |
| Unsolicited RAs | `RA_UNSOLICITED` | `on`; `off` adds `UnicastOnly on;` |
| M and O flags | `RA_M`, `RA_O` | what the ISP's BNG sends is not known; default M off, O on |

Runtime change: `ispctl` rewrites the file and runs `systemctl reload-or-restart radvd` (reload when it runs, start when it does not). A reload pushes one unsolicited RA at once. For "the lifetime runs out without a refresh": `ispctl pref64 on 64:ff9b::/96 64`, wait for one RA, then `ispctl pref64 off`; RAs continue without the option and the learned entry expires after 64 s.

`ispctl pref64 on <other prefix>` only changes the announcement. tayga keeps translating 64:ff9b::/96, so traffic to the other prefix fails. That is enough for the "a different prefix from the same source is ignored while the current one is valid" case.

Not implemented: RDNSS with a link-local resolver address (DESIGN section 16 asks which kind the real BNG announces).

---

## 4. DHCPv6 prefix delegation on the ppp interface (item 3)

### 4.1 Evaluation

| Server | In Debian 13 | Delegates prefixes | On a ppp interface | Verdict |
|---|---|---|---|---|
| **Kea** `kea-dhcp6-server` 2.6.3 | yes | yes, `pd-pools`; "If both the delegated and prefix lengths are equal, the server will be able to delegate only one prefix" | Interfaces come from netlink with no device-type filter; a socket is opened on every configured interface that is up and running, bound to its link-local address, plus the ff02::1:2 group. A subnet is tied to a link-local-only interface with `"interface"`. The interface must exist when the config is loaded. No route installation. [SRC: `iface_mgr_linux.cc` `detectIfaces`, `iface_mgr.cc` `openSockets6`, ARM `dhcp6-srv.rst`] | **chosen** |
| WIDE `dhcp6s` (`wide-dhcpv6-server`) | yes | only per client: `host x { duid …; prefix …/56 pltime vltime; };` pools exist for addresses only | runs on one named interface | fallback; needs OPNsense's DUID in advance |
| dnsmasq 2.91 | yes | **no.** The man page only describes allocating addresses "from subnets which are dynamically delegated via DHCPv6 prefix delegation" and relaying | – | rejected |
| odhcpd | **not packaged** | yes | – | rejected |
| dibbler-server 1.0.1 | yes | yes (`pd-class { pd-pool …; pd-length 56 }`) | not verified; upstream inactive (UNCONFIRMED) | not chosen |
| ISC dhcpd 4.4.3-P1 | yes | yes | needs a `subnet6` that matches a global address on the link; end of life upstream | rejected |
| accel-ppp (would do PPPoE, RA and PD in one daemon) | **not packaged** | – | – | not available |

Why Kea needs no DUID and no route hook here: the pool holds exactly one prefix and there is exactly one customer, so whoever asks gets that prefix, and `ispctl` installs the route itself.

### 4.2 Generated `/etc/kea/kea-dhcp6.conf`

Written by `ispctl` when a session comes up (mode 0644; the daemon runs as `_kea`):

```json
{
"Dhcp6": {
    "interfaces-config": { "interfaces": [ "ppp0" ] },
    "lease-database": { "type": "memfile", "persist": false },
    "renew-timer": 1800,
    "rebind-timer": 2880,
    "preferred-lifetime": 3600,
    "valid-lifetime": 7200,
    "subnet6": [ {
        "id": 1,
        "subnet": "2001:db8:a::/64",
        "interface": "ppp0",
        "pd-pools": [ { "prefix": "2001:db8:5600::", "prefix-len": 56, "delegated-len": 56 } ]
    } ],
    "loggers": [ { "name": "kea-dhcp6", "severity": "INFO",
                   "output-options": [ { "output": "stdout" } ] } ]
}
}
```

- `"persist": false`: no lease file. Every restart of Kea starts with no leases, which makes the outcome of a session deterministic.
- `output-options` is the key name since Kea 2.5.2; `output_options` is deprecated since 2.6.2. [SRC: ARM `logging.rst`]
- Any length from /48 to /64 works the same way (`prefix-len` = `delegated-len`), which covers DESIGN's "a single /64 must work too".
- No address pool: an IA_NA request gets status NoAddrsAvail inside the IA, and the IA_PD is still served. [SRC: ARM, "Place NoAddrsAvail and NoPrefixAvail status codes in the IA_NA and IA_PD options in the ADVERTISE message"]. How OPNsense's dhcp6c reacts when it also asks for an address is for the first run to show.
- Debian's unit: `User=_kea`, `AmbientCapabilities=CAP_NET_BIND_SERVICE`, `ExecStart=/usr/sbin/kea-dhcp6 -c /etc/kea/kea-dhcp6.conf`. [SRC: Debian `kea-dhcp6-server.service`]

`/etc/apparmor.d/local/usr.sbin.kea-dhcp6` (written **before** the package is installed; the profile ends with `#include <local/usr.sbin.kea-dhcp6>`)

```
# lab: Debian's kea-dhcp6 profile has no capability rule; port 547 needs this one
capability net_bind_service,
```

### 4.3 Route, renumbering, session reset

- Route towards the session: `ip -6 route replace 2001:db8:5600::/56 dev ppp0` and the same for the WAN /64. On a point-to-point interface no next hop is needed. The routes disappear with the interface.
- `ispctl pd <prefix/len>`: delete the old route, store the new prefix, rewrite the Kea config, restart Kea, add the new route. The client still holds the old prefix. Two ways on from there:
  1. `ispctl session reset`: the new session solicits and gets the new prefix. This is the deterministic renumbering test.
  2. Wait for the client's Renew. Kea's `extendIA_PD` calls `renewLeases6()`, which can allocate a new lease, and has the comment "For the leases that we just retired, send the prefixes with 0 lifetimes" [SRC: `dhcp6_srv.cc`]. The exact reply to a Renew from a client Kea has never seen was not read to the end: UNCONFIRMED.
- Lifetimes are variables (`PD_T1`, `PD_T2`, `PD_PREFERRED`, `PD_VALID`). The defaults are long on purpose; short ones make dhcp6c renew every few minutes and may trigger core events that a real line does not produce.

### 4.4 Fallback: WIDE dhcp6s

Only if Kea does not work on the ppp interface. `/etc/wide-dhcpv6/dhcp6s.conf`:

```
host opnsense {
    duid @@OPNSENSE_DUID@@;
    prefix 2001:db8:5600::/56 3600 7200;
};
```

Start: `dhcp6s -c /etc/wide-dhcpv6/dhcp6s.conf ppp0` (invocation not checked against dhcp6s(8), UNCONFIRMED). The DUID has to be fixed in OPNsense (Interfaces > Settings) or read from the first Solicit. [SRC: `dhcp6s.conf.5` host statement]

---

## 5. NAT64 and the IPv4 test target (item 4)

### 5.1 tayga on clat-world (0.9.2)

Directives that exist in Debian's 0.9.2: `ipv4-addr`, `ipv6-addr`, `prefix`, `tun-device`, `map`, `dynamic-pool`, `data-dir`, `strict-frag-hdr`. Nothing else. [SRC: Debian tayga `conffile.c` lines 367-374]

`/etc/isp/tayga-nat64.conf`

```
tun-device nat64
ipv4-addr 192.168.255.1
ipv6-addr 2001:db8:64::64
prefix 64:ff9b::/96
dynamic-pool 192.168.255.0/24
data-dir /var/lib/isp/tayga
```

`ipv6-addr` must be given: with the well-known prefix and a private `ipv4-addr`, tayga cannot derive it. Every IPv6 source that is not inside the NAT64 prefix (the CLAT address, OPNsense's own addresses) gets an IPv4 address from the pool for "two hours and four minutes after the last packet". [SRC: `tayga.conf.5`]

`/etc/systemd/system/isp-nat64.service`

```ini
[Unit]
Description=Lab PLAT: tayga NAT64 for 64:ff9b::/96
Requires=isp-base.service
After=isp-base.service

[Service]
Type=simple
ExecStartPre=/usr/sbin/tayga --mktun --config /etc/isp/tayga-nat64.conf
ExecStartPre=/usr/local/sbin/ispctl _nat64_net
ExecStart=/usr/sbin/tayga --nodetach --config /etc/isp/tayga-nat64.conf
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

`ispctl _nat64_net` runs:

```sh
ip link set nat64 mtu 1600 up
ip -6 addr replace 2001:db8:64::1/128 dev nat64     # global source for the kernel's ICMPv6 errors
ip route replace 192.168.255.0/24 dev nat64 mtu 1500
ip -6 route replace 64:ff9b::/96 dev nat64
ip -6 route replace 2001:db8:64::64/128 dev nat64
```

- tayga reads the tun MTU once at start and uses it as its IPv6 limit [SRC: `tayga.c` lines 152-162]. 1600 lets a 1500-byte IPv4 packet (1520 bytes as IPv6) through in both directions, so the simulated PLAT is never the bottleneck; the PPP link is.
- `mtu 1500` on the pool route keeps the local test target behaving like an Internet host (MSS 1460, packets up to 1500 bytes).
- Debian's own `tayga.service` runs `tayga -d --config /etc/tayga.conf` with no tun or route setup [SRC: patch 0009]. It is disabled.

### 5.2 nftables

`/etc/nftables.conf` (loaded by Debian's `nftables.service`)

```
#!/usr/sbin/nft -f
flush ruleset

table inet isp {
    # empty = provisioning NAT off. "ispctl provision on" adds 10.99.0.0/24.
    set provision4 {
        type ipv4_addr
        flags interval
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ip daddr 192.88.99.0/24 drop
        ct state established,related accept
        iifname "ppp*" oifname "nat64" accept
        iifname "nat64" oifname "ppp*" accept
        iifname "nat64" oifname "up0" accept
        iifname "ppp*" oifname "up0" ip saddr 100.64.0.0/24 accept
        iifname "mgmt0" oifname "up0" ip saddr @provision4 accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
        oifname "up0" ip daddr 192.88.99.0/24 drop
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "up0" ip saddr { 192.168.255.0/24, 100.64.0.0/24 } masquerade
        oifname "up0" ip saddr @provision4 masquerade
    }
}
```

tayga is stateless and maps one IPv6 address to one pool address; the masquerade rule supplies the stateful part. `flush ruleset` empties the set, so provisioning NAT is off after every boot or reload. The syntax has to be checked on the first run with `nft -c -f /etc/nftables.conf`.

### 5.3 The CLAT's `wkpf-strict` and the choice of test target

Read in tayga 0.9.6 `addrmap.c` (a working copy, not in this repository, is byte-identical to `https://raw.githubusercontent.com/apalrd/tayga/0.9.6/addrmap.c`, sha256 `c732a05f…f4e93d`; the newer clone in `refs/tayga` has the same list).

With `wkpf-strict` on (the default, `conffile.c` line 538) **and** the prefix exactly `64:ff9b::/96`, `is_private_ip4_addr()` (lines 105-140) makes `append_to_prefix()` (lines 465-473) and `map_ip6_to_ip4()` (lines 673-678) return `ERROR_REJECT` for:

| Refused range | Comment in the source |
|---|---|
| 10.0.0.0/8 | RFC1918 |
| 100.64.0.0/10 | RFC6598 |
| 172.16.0.0/12 | RFC1918 |
| 192.0.2.0/24 | RFC5737 |
| 192.168.0.0/16 | RFC1918 |
| 198.18.0.0/15 | RFC2544 |
| 198.51.100.0/24 | RFC5737 |
| 203.0.113.0/24 | RFC5737 |

For an IPv4 packet from the LAN to such a destination the CLAT answers with ICMPv4 type 3 code 1 (host unreachable) from its own address. [SRC: `nat64.c` lines 361-367]

Independent of `wkpf-strict`, `validate_ip4_addr()` (lines 38-62) makes these untranslatable (dropped silently): 0.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255. 240.0.0.0/4 is accepted by tayga ("Class E considered valid now"), but it is not a sensible target because routers may refuse it.

Debian's 0.9.2 on the PLAT side has the same list without 100.64.0.0/10, and always applies it. [SRC: Debian tayga `addrmap.c`, patch 0012]

Consequences:

- Every documentation and benchmark range is refused, and so is the Default Switch subnet (172.16/12, UNCONFIRMED range), 10.99.0.0/24 and the tayga pool. None of them can be the test target.
- **Test target: `192.88.99.1`.** 192.88.99.0/24 is the deprecated 6to4 relay anycast prefix (RFC 7526). It is in none of the lists above, and Linux and FreeBSD treat it as ordinary unicast. Inside the lab the address exists only on clat-world's dummy interface. Three things keep it there if something is misconfigured: a blackhole route for the /24, the two nftables drop rules, and the fact that the prefix is hardly routed on the Internet any more.
- Useful negative test: `ispctl client ping -c2 10.99.0.1` must return "Destination Host Unreachable" from the CLAT.

### 5.4 The test target

Set up by `ispctl init`:

```sh
ip link add isp0 type dummy
ip link set isp0 up
ip addr replace 192.88.99.1/32 dev isp0
ip -6 addr replace 2001:db8:64::53/128 dev isp0
ip route replace blackhole 192.88.99.0/24
```

ICMP echo of any size is answered by the kernel. HTTP and iperf3:

`/etc/systemd/system/isp-www.service`

```ini
[Unit]
Description=Lab IPv4 test target: HTTP on 192.88.99.1
Requires=isp-base.service
After=isp-base.service

[Service]
ExecStart=/usr/bin/python3 -m http.server 80 --bind 192.88.99.1 --directory /srv/isp-www
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/isp-iperf3.service`: the same with `ExecStart=/usr/bin/iperf3 -s -B 192.88.99.1`.

`/srv/isp-www/` gets `index.html` and a 100 MB file `100M.bin` from `ispctl init`.

The target is IPv4-only on purpose. With `ispctl ipv4 on` the same address is reachable natively over the PPP link, which gives a native baseline for comparisons.

### 5.5 What the simulated PLAT does differently from a real one

1. **Large DF-clear IPv4 packets come back as IPv6 fragments.** 0.9.2 has a fixed off-link MTU of 1280 and fragments any DF-clear IPv4 packet whose IPv6 form would exceed it [SRC: Debian tayga `conffile.c` line 406, `nat64.c` lines 217-254]. Linux sends ICMP echo replies with DF clear (from kernel knowledge, UNCONFIRMED). So the reply to a ping of more than about 1260 bytes arrives at the CLAT as two IPv6 fragments. The DF probe of DESIGN section 10 therefore also exercises the CLAT's fragment translation and pf's reassembly. Cross-check the forward path MTU with `tracepath`, with a UDP DF probe (`iperf3 -u -l`), and with TCP.
2. **DF-set packets pass unfragmented up to the tun MTU.** If the PPP link is smaller, the Linux kernel sends ICMPv6 Packet Too Big, which tayga turns into ICMPv4 "fragmentation needed" for the IPv4 sender. That is normal PLAT behaviour.

Neither says anything about the NAT64 of the real network (DESIGN section 16, item 3).

### 5.6 Towards the real Internet

Path: LAN client → OPNsense NAT44 → CLAT → IPv6 over PPPoE → tayga → masquerade to `up0`'s address → Default Switch NAT on the Windows host → the host's network.

| Traffic | Expectation | Status |
|---|---|---|
| TCP, UDP outbound | works | UNCONFIRMED until run |
| ICMP echo outbound | works | UNCONFIRMED |
| ICMP errors coming back (path MTU, traceroute hops) | may be lost in the Default Switch NAT | UNCONFIRMED; this is why MTU tests use the local target |
| Anything initiated from outside | does not work | by design |
| IPv6 to the Internet | does not exist | the Default Switch offers no IPv6 |
| Destinations in the refused ranges of 5.3, including the Windows host's Default Switch address | refused | by design of tayga |

MTU of the Internet path is 1500 at best (Default Switch). A VPN on the Windows host can change all of this.

---

## 6. DNS64 with unbound (item 5)

### 6.1 What the sources say (unbound 1.22)

- "The dns64 module must be configured in the module-config: "dns64 validator iterator" directive". `dns64-prefix` defaults to 64:ff9b::/96. [SRC: `unbound.conf.5` lines 2477-2495]
- unbound has no special handling of `ipv4only.arpa`: the name does not occur in `services/localzone.c` or `dns64/dns64.c`, and the default local zones do not include it. The AAAA answer is therefore synthesised by the dns64 module from the A records (192.0.0.170, 192.0.0.171) that normal recursion returns. **This needs working DNS towards the Internet from clat-world.** Expected answer: `64:ff9b::c000:aa` and `64:ff9b::c000:ab`. UNCONFIRMED until run.
- `ip-freebind: yes` "Allows you to bind to IP addresses that are nonlocal or do not exist", so unbound does not depend on start order. `prefer-ip4: yes` because clat-world has no IPv6 route to the Internet. [SRC: `unbound.conf.5` lines 380-385, 470-475]
- Debian's `/etc/unbound/unbound.conf` is `include-toplevel: "/etc/unbound/unbound.conf.d/*.conf"`. systemd-resolved (in the image) listens on 127.0.0.53 and 127.0.0.54 only, so there is no port clash.

### 6.2 Files

`/etc/unbound/unbound.conf.d/isp.conf`

```
server:
    interface: 2001:db8:64::53
    interface: 10.99.0.1
    ip-freebind: yes
    access-control: 0.0.0.0/0 allow
    access-control: ::/0 allow
    prefer-ip4: yes
    dns64-prefix: 64:ff9b::/96
```

`/etc/unbound/unbound.conf.d/isp-dns64.conf` (written by `ispctl dns64 on|off`)

```
server:
    module-config: "dns64 validator iterator"
```

For `off` the value is `"validator iterator"`. `ispctl` then runs `systemctl restart unbound`. The RDNSS address stays the same in both states, so `pref64 off` plus `dns64 off` is the "neither" line of DESIGN section 1.

Check: `dig @2001:db8:64::53 ipv4only.arpa AAAA +short` (on: two addresses; off: empty). `unbound-checkconf` validates the files.

Optional knobs, not in the default setup:

- `dns64-synthall: yes` makes every name resolve into 64:ff9b::/96, so that OPNsense reaches the whole IPv4 Internet over IPv6 even without the CLAT. A real DNS64 does not do that.
- If recursion to the root servers is blocked from the host's network: `forward-zone: name: "." forward-addr: <the DNS server that up0 got by DHCP>`. The address changes with the Default Switch subnet.
- A local `auth-zone` for `ipv4only.arpa` (`for-downstream: no`, `for-upstream: yes`, plus `domain-insecure`) would remove the dependency on Internet DNS. UNCONFIRMED that the dns64 module then synthesises.

---

## 7. The IPv4-only LAN client (item 6)

### 7.1 Namespace and DHCP

`ispctl _client_setup` (run by the unit before the DHCP client):

```sh
ip netns list | grep -qw client || ip netns add client
mkdir -p /etc/netns/client
[ -e /etc/netns/client/resolv.conf ] || : > /etc/netns/client/resolv.conf
ip netns exec client sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
if [ -d /sys/class/net/lan0 ]; then ip link set lan0 netns client; fi
ip -n client link set lo up
ip -n client link set lan0 up
```

IPv6 is disabled in the namespace before `lan0` enters it, so the client is strictly IPv4-only. `ip netns exec` bind-mounts `/etc/netns/client/resolv.conf` over `/etc/resolv.conf` for the commands it runs (ip-netns(8), not checked against a source; that it works across Debian's resolv.conf symlink is UNCONFIRMED).

`/etc/systemd/system/isp-client.service`

```ini
[Unit]
Description=Lab LAN client: namespace "client" with a DHCPv4 client on lan0
After=systemd-networkd.service cloud-init-local.service isp-base.service

[Service]
Type=simple
ExecStartPre=/usr/local/sbin/ispctl _client_setup
ExecStart=/usr/sbin/ip netns exec client busybox udhcpc -f -i lan0 -O mtu -x hostname:clat-client -s /usr/local/lib/isp/udhcpc-script
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`/usr/local/lib/isp/udhcpc-script` (mode 0755)

```sh
#!/bin/sh
# busybox udhcpc event script for the lab client namespace
case "$1" in
    deconfig)
        ip addr flush dev "$interface"
        ip link set "$interface" up
        ;;
    bound|renew)
        ip addr replace "$ip/${mask:-24}" dev "$interface"
        ip route replace default via "${router%% *}" dev "$interface"
        : > /etc/resolv.conf
        for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
        ;;
esac
exit 0
```

udhcpc keeps retrying while OPNsense is down. The variable names (`interface`, `ip`, `mask`, `router`, `dns`) are busybox's (not checked against a source, UNCONFIRMED).

### 7.2 Running commands in the client

`ispctl client <command…>` is `ip netns exec client <command…>`. From the Windows host: `ssh root@clat-world.mshome.net ispctl client ping -c3 192.88.99.1`.

### 7.3 Test commands

At the default PPP MTU 1492 the CLAT presents an IPv4 MTU of 1472 and an MSS of 1432 (DESIGN 8.1).

| Purpose | Command | Expected |
|---|---|---|
| Reachability | `ispctl client ping -c3 192.88.99.1` | replies |
| Largest DF size | `ispctl client ping -c2 -M do -s 1444 192.88.99.1` | replies (1444+28 = 1472) |
| One byte more | `ispctl client ping -c2 -M do -s 1445 192.88.99.1` | "Frag needed and DF set (mtu = 1472)" |
| A 1500-byte packet | `ispctl client ping -c2 -M do -s 1472 192.88.99.1` | frag needed while the uplink is below 1520 |
| Path MTU | `ispctl client tracepath -4 -n 192.88.99.1` | pmtu 1472 |
| HTTP | `ispctl client curl -sS -o /dev/null -w '%{http_code} %{size_download} %{speed_download}\n' http://192.88.99.1/100M.bin` | 200, 104857600 |
| TCP throughput | `ispctl client iperf3 -c 192.88.99.1 -t 10` and with `-R` | |
| UDP with DF at a given size | `ispctl client iperf3 -c 192.88.99.1 -u -b 20M -l 1444` | |
| MSS seen by the client | `ispctl client tcpdump -ni lan0 -c2 'tcp[tcpflags] & tcp-syn != 0 and host 192.88.99.1'` | SYN `mss 1460`; SYN-ACK `mss 1432` |
| MSS on the ISP side | `tcpdump -ni ppp0 -c2 'ip6[6] == 6 and ip6[53] & 0x02 != 0'` | SYN arrives with `mss 1432` |
| Internet | `ispctl client curl -4 -sS -o /dev/null -w '%{http_code}\n' https://example.com` | 200 |
| `wkpf-strict` | `ispctl client ping -c2 10.99.0.1` | host unreachable from the CLAT |
| RAs as sent by the BNG | `tcpdump -ni ppp0 -vv 'icmp6 and ip6[40] == 134'` | option 38 is printed undecoded: tcpdump 4.99.5 has no PREF64 decoder [SRC: `print-icmp6.c`] |

`radvdump` (in the `radvd` package) decodes PREF64 [SRC: `radvdump.c` line 468], but radvd turns multicast loopback off, so radvdump on clat-world does not see clat-world's own RAs.

### 7.4 Crafted Router Advertisement with PREF64 on the LAN

scapy 2.6.1 has the class: `ICMPv6NDOptPREF64(type=38, len=2, scaledlifetime (13 bits), plc (3 bits), prefix)`; the prefix field writes the first 12 bytes. [SRC: scapy `layers/inet6.py` lines 2165-2184]

`/usr/local/lib/isp/send-ra-pref64.py` (mode 0755)

```python
#!/usr/bin/env python3
"""Send Router Advertisements with a PREF64 option (RFC 8781) from the LAN client. Negative test only."""
import argparse
import ipaddress

from scapy.all import Ether, IPv6, ICMPv6ND_RA, ICMPv6NDOptPREF64, get_if_hwaddr, sendp

PLC = {96: 0, 64: 1, 56: 2, 48: 3, 40: 4, 32: 5}

ap = argparse.ArgumentParser()
ap.add_argument("--iface", default="lan0")
ap.add_argument("--prefix", default="2001:db8:bad:64::/96")
ap.add_argument("--lifetime", type=int, default=1800)
ap.add_argument("--src", default="fe80::bad:64")
ap.add_argument("--count", type=int, default=3)
args = ap.parse_args()

net = ipaddress.IPv6Network(args.prefix)
ra = (Ether(src=get_if_hwaddr(args.iface), dst="33:33:00:00:00:01")
      / IPv6(src=args.src, dst="ff02::1", hlim=255)
      / ICMPv6ND_RA(chlim=64, routerlifetime=0)
      / ICMPv6NDOptPREF64(scaledlifetime=(args.lifetime + 7) // 8, plc=PLC[net.prefixlen],
                          prefix=str(net.network_address)))
sendp(ra, iface=args.iface, count=args.count, inter=1.0)
```

Run: `ispctl client python3 /usr/local/lib/isp/send-ra-pref64.py`. The frame is sent at layer 2, so it does not need IPv6 in the namespace. The Ethernet source is the adapter's real MAC, because Hyper-V drops frames with another source MAC unless MAC spoofing is enabled. Router lifetime is 0, so nothing takes the sender as a router. Expected: the NAT64 prefix shown on the plugin's status page does not change. Confirm first that the frame arrives: `tcpdump -ni <LAN device> 'icmp6 and ip6[40] == 134'` on OPNsense.

---

## 8. MTU scenarios (item 7)

### 8.1 RFC 4638 in rp-pppoe 4.0 and pppd 2.5.2

- `pppoe-server` reads the PPP-Max-Payload tag from PADI and PADR; a value of 1492 or less is ignored. [SRC: `pppoe-server.c` lines 443-449, 488-494]
- In PADO and PADS it "shrinks" the value to `interface MTU - 8` and to `ETH_JUMBO_LEN - 8`, and only if the result is still above 1492 does it send the tag back and start pppd with `mru N mtu N`. Otherwise pppd gets `mru 1492 mtu 1492`. [SRC: lines 714-732, 1042-1062, 2004-2018]
- `ETH_JUMBO_LEN` is `ETH_DATA_LEN+8` = 1508, so the largest value ever echoed is **1500**. [SRC: rp-pppoe `pppoe.h` lines 108-133]
- pppd's `pppoe.so` clamps MRU and MTU to `MAX_PPPOE_MTU` = 1500 and to `interface MTU - 8`. [SRC: ppp `plugins/pppoe/pppoe.h` lines 169-192, `plugin.c` lines 177-180, 456-459]
- The interface MTU is read when `pppoe-server` opens the interface, so the server must be restarted after `wan0`'s MTU changes. [SRC: line 1601]
- No command-line option is involved: support is always on and is controlled by `wan0`'s MTU alone.

`ispctl mtu <n>` (n from 1492 to 1500) sets `wan0` to MTU n+8 and restarts the server:

| `ispctl mtu` | `wan0` MTU | Client asks 1500 (WAN MTU field 1508) | Client asks 1510 (field 1518) | Client asks 1520 (field 1528) |
|---|---|---|---|---|
| 1492 (default) | 1500 | no tag in PADO/PADS; session at 1492. A BNG without RFC 4638 | no tag | no tag |
| 1500 | 1508 | **tag 1500 echoed exactly**; pppd runs with mru/mtu 1500 | tag 1500, not what was asked | by DESIGN 8.3 defect A, mpd5 sends no tag at all |

What this covers of DESIGN section 8.3:

- Row "empty" and row "1508": fully, including the negative variant "the BNG does not echo" (`ispctl mtu 1492` with field 1508), which shows defect C.
- Rows "1509 to 1518" and "above 1518": only against a BNG that does not echo the requested value. Whether mpd5 holds a negotiated 1501 to 1510 and loses it at reconnect (defect B) **cannot be tested with this simulator**, and neither can the post-fix cases 1528 and 1536. That needs a BNG that grants more than 1500: accel-ppp built from source, or mpd5 as a server on a FreeBSD VM. Both are outside this lab's scope; it stays a gap.
- Oversized frames that OPNsense sends in those rows are best captured on the OPNsense side (`tcpdump -i <WAN parent>`), because `wan0` at MTU 1508 may never see them.

RA MTU option: `RA_MTU=auto` announces the session's negotiated MTU, which is what DESIGN 8.3 requires ("must equal the negotiated value or be absent"). `ispctl ramtu off` removes it; `ispctl ramtu 1280` gives a deliberately lower value.

### 8.2 Jumbo frames on Hyper-V synthetic NICs

- Linux `hv_netvsc`: `max_mtu = NETVSC_MTU - ETH_HLEN` (65521) when the NVSP version is 2 or higher. After the device is set up again it asks the host for `RNDIS_OID_GEN_MAXIMUM_FRAME_SIZE` and lowers the MTU if the host reports less. `ip link set wan0 mtu 1508` is all that is needed in the guest. [SRC: Linux 6.12 `netvsc_drv.c` lines 2617-2621, `hyperv_net.h` line 851, `rndis_filter.c` lines 1509-1514]
- FreeBSD `hn(4)`: `SIOCSIFMTU` up to `HN_MTU_MAX` (65535 - 6). The driver detaches and re-attaches its synthetic parts with the new MTU, asks the host, and logs "fixup mtu" if the host grants less. [SRC: opnsense/src stable/26.7 `if_hn.c` lines 3737-3813, `if_hnvar.h` line 37]
- Microsoft lists "Jumbo frames" as supported for FreeBSD guests with the note "9126 is the maximum supported MTU size" (table covers FreeBSD 11 to 13.5) and for Debian guests (table covers 10 to 12). FreeBSD 15 and Debian 13 are not in those tables. [SRC: Microsoft Learn, supported FreeBSD / Debian virtual machines on Hyper-V]
- **UNCONFIRMED: that a private virtual switch carries frames above 1514 bytes between two guests with no host-side setting.** Check before any jumbo test: with a session at PPP MTU 1500, `ping -6 -c2 -M do -s 1452 <OPNsense link-local>%ppp0` on clat-world (a 1500-byte IPv6 packet, 1522 bytes on the wire) must be answered, while `-s 1453` must fail locally.
- Changing the MTU re-initialises the vNIC on both guests and drops the link for a moment.

---

## 9. `ispctl` (item 8)

### 9.1 Settings file `/etc/isp/isp.env`

Plain `KEY=value`, no spaces, no quotes. `ispctl` sources it and rewrites single lines.

```
WAN_PREFIX=2001:db8:a::/64
SLAAC=on
PD_PREFIX=2001:db8:5600::/56
PD_T1=1800
PD_T2=2880
PD_PREFERRED=3600
PD_VALID=7200
DNS_ADDR=2001:db8:64::53
DNS64=on
PREF64=on
PREF64_PREFIX=64:ff9b::/96
PREF64_LIFETIME=1800
RA_INTERVAL=600
RA_UNSOLICITED=on
RA_M=off
RA_O=on
RA_MTU=auto
BNG_MTU=1492
IPV4=off
```

### 9.2 Subcommands

| Command | What it does |
|---|---|
| `pref64 on [prefix/len] [lifetime]` | announce the option; optional new prefix and lifetime; reload radvd |
| `pref64 off` | RAs without the option |
| `pref64 withdraw` | option with lifetime 0 |
| `dns64 on\|off` | switch the dns64 module; restart unbound |
| `slaac on\|off` | autonomous flag of the WAN /64; reload radvd |
| `pd <prefix/len>` | new delegated prefix (/48 to /64): route, Kea config, Kea restart |
| `session reset` | SIGTERM to pppd: LCP terminate and PADT |
| `session drop` | silent loss (extra) |
| `ipv4 on\|off` | pppd options with or without `noip`; effective at the next session |
| `mtu <1492..1500>` | `wan0` MTU = n+8, restart the PPPoE server (ends the session) |
| `ramtu auto\|off\|<n>` | MTU option in the RA (extra) |
| `provision on\|off` | IPv4 NAT for 10.99.0.0/24 out of `up0` |
| `set KEY VALUE`, `apply` | change any setting, then regenerate RA and PD config (extra) |
| `client <command…>` | run a command in the client namespace (extra) |
| `status` | settings, session, services, routes, RA config, DNS64 check, client address |

State: `/run/isp/session` holds `IFACE` and `PEER_LL` of the newest session. A change made with no session up is stored and used at the next session.

### 9.3 The script `/usr/local/sbin/ispctl` (mode 0755)

```sh
#!/bin/sh
# ispctl - control the simulated ISP on clat-world. Lab use only.
set -eu
ENV=/etc/isp/isp.env
SESS=/run/isp/session
PPPOPT=/etc/ppp/pppoe-server-options
WAN=wan0
. "$ENV"

say() { echo "ispctl: $*"; logger -t ispctl -- "$*" 2>/dev/null || true; }
die() { echo "ispctl: $*" >&2; exit 2; }
usage() {
    die "usage: pref64 on [prefix/len] [lifetime]|off|withdraw | dns64 on|off | slaac on|off | pd <prefix/len> | session reset|drop | ipv4 on|off | mtu <1492..1500> | ramtu auto|off|<n> | provision on|off | set KEY VALUE | apply | client <cmd...> | status"
}
need_onoff() { case "${1:-}" in on|off) ;; *) die "expected on or off" ;; esac; }

setvar() {      # setvar KEY VALUE: store in the settings file and in this shell
    if grep -q "^$1=" "$ENV"; then sed -i "s|^$1=.*|$1=$2|" "$ENV"; else echo "$1=$2" >> "$ENV"; fi
    eval "$1=\$2"
}

have_session() {
    IFACE=""; PEER_LL=""
    if [ -r "$SESS" ]; then . "$SESS"; fi
    [ -n "$IFACE" ] && [ -d "/sys/class/net/$IFACE" ]
}

write_ppp_options() {
    {
        echo "# written by ispctl; do not edit"
        echo "name clat-bng"
        echo "auth"
        echo "require-chap"
        echo "+ipv6"
        echo "ipv6 ::1,"
        if [ "$IPV4" != on ]; then echo "noip"; fi
        echo "lcp-echo-interval 5"
        echo "lcp-echo-failure 3"
        echo "nodefaultroute"
        echo "ipparam clat-lab"
        echo "debug"
        echo "logfile /var/log/isp/pppd.log"
    } > "$PPPOPT"
}

render_radvd() {
    mtu=$RA_MTU
    if [ "$mtu" = auto ]; then mtu=$(cat "/sys/class/net/$IFACE/mtu"); fi
    {
        echo "interface $IFACE {"
        echo "    AdvSendAdvert on;"
        echo "    IgnoreIfMissing on;"
        echo "    MaxRtrAdvInterval $RA_INTERVAL;"
        echo "    AdvDefaultLifetime $((RA_INTERVAL * 3));"
        echo "    AdvManagedFlag $RA_M;"
        echo "    AdvOtherConfigFlag $RA_O;"
        if [ "$RA_UNSOLICITED" = off ]; then echo "    UnicastOnly on;"; fi
        if [ "$mtu" != off ]; then echo "    AdvLinkMTU $mtu;"; fi
        echo "    prefix $WAN_PREFIX {"
        echo "        AdvOnLink on;"
        echo "        AdvAutonomous $SLAAC;"
        echo "        AdvValidLifetime 7200;"
        echo "        AdvPreferredLifetime 3600;"
        echo "    };"
        echo "    RDNSS $DNS_ADDR {"
        echo "        AdvRDNSSLifetime $((RA_INTERVAL * 3));"
        echo "    };"
        case "$PREF64" in
            on)       echo "    nat64prefix $PREF64_PREFIX { AdvValidLifetime $PREF64_LIFETIME; };" ;;
            withdraw) echo "    nat64prefix $PREF64_PREFIX { AdvValidLifetime 0; };" ;;
        esac
        echo "};"
    } > /etc/radvd.conf
}

render_kea() {
    p=${PD_PREFIX%/*}; l=${PD_PREFIX#*/}
    cat > /etc/kea/kea-dhcp6.conf <<EOF
{
"Dhcp6": {
    "interfaces-config": { "interfaces": [ "$IFACE" ] },
    "lease-database": { "type": "memfile", "persist": false },
    "renew-timer": $PD_T1,
    "rebind-timer": $PD_T2,
    "preferred-lifetime": $PD_PREFERRED,
    "valid-lifetime": $PD_VALID,
    "subnet6": [ {
        "id": 1,
        "subnet": "$WAN_PREFIX",
        "interface": "$IFACE",
        "pd-pools": [ { "prefix": "$p", "prefix-len": $l, "delegated-len": $l } ]
    } ],
    "loggers": [ { "name": "kea-dhcp6", "severity": "INFO",
                   "output-options": [ { "output": "stdout" } ] } ]
}
}
EOF
    chmod 644 /etc/kea/kea-dhcp6.conf
}

apply_ra() {
    if ! have_session; then say "no PPP session: stored, used at the next session"; return 0; fi
    render_radvd
    systemctl reload-or-restart radvd
}

apply_pd() {
    if ! have_session; then say "no PPP session: stored, used at the next session"; return 0; fi
    render_kea
    systemctl restart kea-dhcp6-server
    ip -6 route replace "$WAN_PREFIX" dev "$IFACE"
    ip -6 route replace "$PD_PREFIX" dev "$IFACE"
}

cmd=${1:-}
case "$cmd" in
pref64)
    case "${2:-}" in
        on)
            setvar PREF64 on
            if [ -n "${3:-}" ]; then setvar PREF64_PREFIX "$3"; fi
            if [ -n "${4:-}" ]; then setvar PREF64_LIFETIME "$4"; fi
            ;;
        off|withdraw) setvar PREF64 "$2" ;;
        *) usage ;;
    esac
    apply_ra
    ;;
dns64)
    need_onoff "${2:-}"; setvar DNS64 "$2"
    if [ "$2" = on ]; then m="dns64 validator iterator"; else m="validator iterator"; fi
    printf 'server:\n    module-config: "%s"\n' "$m" > /etc/unbound/unbound.conf.d/isp-dns64.conf
    systemctl restart unbound
    ;;
slaac)
    need_onoff "${2:-}"; setvar SLAAC "$2"; apply_ra
    ;;
pd)
    [ -n "${2:-}" ] || usage
    new=$(python3 -c 'import ipaddress,sys; n=ipaddress.IPv6Network(sys.argv[1]); assert 48 <= n.prefixlen <= 64; print(n)' "$2") \
        || die "not an IPv6 prefix between /48 and /64: $2"
    if have_session; then ip -6 route del "$PD_PREFIX" dev "$IFACE" 2>/dev/null || true; fi
    setvar PD_PREFIX "$new"
    apply_pd
    ;;
session)
    case "${2:-}" in
        reset) pkill -TERM -x pppd || true ;;
        drop)  ip link set "$WAN" down; pkill -KILL -x pppd || true; sleep 2; ip link set "$WAN" up ;;
        *) usage ;;
    esac
    ;;
ipv4)
    need_onoff "${2:-}"; setvar IPV4 "$2"; write_ppp_options
    say "effective at the next session: ispctl session reset"
    ;;
mtu)
    n=${2:-}
    case "$n" in ''|*[!0-9]*) usage ;; esac
    if [ "$n" -lt 1492 ] || [ "$n" -gt 1500 ]; then die "PPP MTU must be 1492..1500 (limit of rp-pppoe 4.0 and pppd 2.5.2)"; fi
    setvar BNG_MTU "$n"
    ip link set "$WAN" mtu $((n + 8))
    systemctl restart isp-pppoe
    ;;
ramtu)
    [ -n "${2:-}" ] || usage
    setvar RA_MTU "$2"; apply_ra
    ;;
provision)
    need_onoff "${2:-}"
    nft flush set inet isp provision4
    if [ "$2" = on ]; then nft add element inet isp provision4 '{ 10.99.0.0/24 }'; fi
    ;;
set)
    [ -n "${3:-}" ] || usage
    setvar "$2" "$3"; say "stored $2; run: ispctl apply"
    ;;
apply)
    apply_ra; apply_pd
    ;;
client)
    shift
    exec ip netns exec client "$@"
    ;;
status)
    echo "== settings"; cat "$ENV"
    echo "== session"
    if have_session; then echo "$IFACE peer $PEER_LL mtu $(cat "/sys/class/net/$IFACE/mtu")"; else echo "none"; fi
    echo "== pppd"; pgrep -a -x pppd || echo "none"
    echo "== services"
    for u in isp-pppoe isp-nat64 radvd kea-dhcp6-server unbound nftables isp-www isp-iperf3 isp-client; do
        printf '%-20s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)"
    done
    echo "== links"; ip -br link
    echo "== addresses"; ip -br addr
    echo "== ipv6 routes"; ip -6 route show | grep -v '^fe80' || true
    echo "== provisioning NAT"; nft list set inet isp provision4 | grep elements || echo "off"
    echo "== radvd.conf"; cat /etc/radvd.conf 2>/dev/null || echo "none"
    echo "== dns64 (ipv4only.arpa AAAA)"; dig +short +time=2 +tries=1 @"$DNS_ADDR" ipv4only.arpa AAAA || true
    echo "== client"; ip -n client -br addr 2>/dev/null || echo "no namespace"
    ;;
init)           # boot: isp-base.service
    mkdir -p /run/isp /var/log/isp /var/lib/isp/tayga /srv/isp-www
    rm -f "$SESS" /etc/radvd.conf
    modprobe -a dummy tun pppoe
    ip link show isp0 >/dev/null 2>&1 || ip link add isp0 type dummy
    ip link set isp0 up
    ip addr replace 192.88.99.1/32 dev isp0
    ip -6 addr replace "$DNS_ADDR/128" dev isp0
    ip route replace blackhole 192.88.99.0/24
    sysctl -qw "net.ipv6.conf.$WAN.disable_ipv6=1"
    ip link set "$WAN" mtu $((BNG_MTU + 8)) up
    write_ppp_options
    [ -s /srv/isp-www/index.html ] || echo "clat lab IPv4 test target 192.88.99.1" > /srv/isp-www/index.html
    [ -e /srv/isp-www/100M.bin ] || head -c 104857600 /dev/zero > /srv/isp-www/100M.bin
    ;;
_nat64_net)     # isp-nat64.service, after tayga --mktun
    ip link set nat64 mtu 1600 up
    ip -6 addr replace 2001:db8:64::1/128 dev nat64
    ip route replace 192.168.255.0/24 dev nat64 mtu 1500
    ip -6 route replace 64:ff9b::/96 dev nat64
    ip -6 route replace 2001:db8:64::64/128 dev nat64
    ;;
_client_setup)  # isp-client.service
    ip netns list | grep -qw client || ip netns add client
    mkdir -p /etc/netns/client
    [ -e /etc/netns/client/resolv.conf ] || : > /etc/netns/client/resolv.conf
    ip netns exec client sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
    if [ -d /sys/class/net/lan0 ]; then ip link set lan0 netns client; fi
    ip -n client link set lo up
    ip -n client link set lan0 up
    ;;
_up)            # /etc/ppp/ipv6-up.d/50-isp: $2 interface, $3 peer link-local
    mkdir -p /run/isp
    printf 'IFACE=%s\nPEER_LL=%s\n' "$2" "$3" > "$SESS"
    say "session up on $2, peer $3, mtu $(cat "/sys/class/net/$2/mtu")"
    apply_ra; apply_pd
    ;;
_down)          # /etc/ppp/ipv6-down.d/50-isp: $2 interface
    if [ -r "$SESS" ] && grep -q "^IFACE=$2\$" "$SESS"; then
        rm -f "$SESS"
        systemctl stop kea-dhcp6-server radvd || true
    fi
    say "session down on $2"
    ;;
*)
    usage
    ;;
esac
```

`/etc/systemd/system/isp-base.service`

```ini
[Unit]
Description=Lab ISP base setup (dummy interface, routes, pppd options)
After=systemd-networkd.service cloud-init-local.service
Wants=systemd-networkd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ispctl init

[Install]
WantedBy=multi-user.target
```

The script is plain POSIX sh and has not been run; it needs `sh -n` and a walk through every subcommand on the first run.

---

## 10. Unattended provisioning with cloud-init on Hyper-V (item 9)

### 10.1 Image variant

| Variant | cloud-init | Kernel | Usable |
|---|---|---|---|
| `debian-13-generic-amd64.qcow2` (415M) | yes | `linux-image-amd64`: PPP, PPPoE, tun, Hyper-V drivers as modules | **yes** |
| `debian-13-genericcloud-amd64.qcow2` (326M) | yes | `linux-image-cloud-amd64`: Hyper-V drivers yes, **`CONFIG_PPP` not set** | no |
| `debian-13-nocloud-amd64.qcow2` (388M) | "Does not run cloud-init and boots directly to a root prompt" | | no |

[SRC: `cloud.debian.org/images/cloud/` descriptions; kernel configs as in section 0]

Hyper-V Generation 2: the image has `grub-cloud-amd64` and an EFI system partition, and the kernel command line uses `root=PARTUUID=`. That it boots as a Generation 2 guest is expected but UNCONFIRMED. Secure Boot should be switched off for this VM (`Set-VMFirmware -EnableSecureBoot Off`, the form Microsoft documents for Debian guests); whether the "Microsoft UEFI Certificate Authority" template also works is UNCONFIRMED. No initramfs module restriction is configured in the image build, so the Hyper-V storage driver should be in the initramfs (UNCONFIRMED).

Requirements for the Hyper-V sheet: Generation 2, Secure Boot off, 2 virtual processors, 2 GB static memory, VHDX converted from the qcow2 and grown to at least 8 GB (the image grows its root file system at first boot), a DVD drive with the seed ISO, the four adapters of section 1.1 with static MACs.

### 10.2 NoCloud seed

[SRC: cloud-init documentation, NoCloud datasource]: a "vfat or iso9660 filesystem" whose volume "must be labelled CIDATA", with `user-data` and `meta-data` in its root directory; `network-config` is optional; `meta-data` must contain an `instance-id`, and a changed `instance-id` makes cloud-init treat the next boot as a first boot.

Build in a throwaway container (run later, one container at a time):

```sh
# from Git Bash anywhere inside the checkout
MSYS_NO_PATHCONV=1 wslc.exe run --rm -v "$(cygpath -w "$(git rev-parse --show-toplevel)/lab/.work"):/work" alpine:3.22 sh -c \
  'apk add --no-cache xorriso >/dev/null && cd /work/seed/clat-world && \
   xorriso -as mkisofs -o /work/disks/clat-world-seed.iso -V CIDATA -J -r user-data meta-data network-config' 2>&1 | tr -d '\0'
```

(The documented command is `genisoimage -output seed.iso -volid cidata -joliet -rock user-data meta-data`; `xorriso -as mkisofs` takes the same options in short form.)

`meta-data`

```yaml
instance-id: clat-world-@@BUILD_ID@@
local-hostname: clat-world
```

`network-config` (version 2; on a system with netplan, cloud-init passes it through unchanged, and it renames by MAC before netplan runs [SRC: cloud-init network config v2; netplan YAML reference])

```yaml
version: 2
ethernets:
  up0:
    match: {macaddress: "02:c1:a7:00:01:01"}
    set-name: up0
    dhcp4: true
    dhcp4-overrides: {send-hostname: true, hostname: clat-world}
    dhcp6: false
    accept-ra: false
    link-local: []
  wan0:
    match: {macaddress: "02:c1:a7:00:01:03"}
    set-name: wan0
    dhcp4: false
    dhcp6: false
    accept-ra: false
    link-local: []
    optional: true
  lan0:
    match: {macaddress: "02:c1:a7:00:01:04"}
    set-name: lan0
    dhcp4: false
    dhcp6: false
    accept-ra: false
    link-local: []
    optional: true
  mgmt0:
    match: {macaddress: "02:c1:a7:00:01:02"}
    set-name: mgmt0
    addresses: [10.99.0.1/24]
    dhcp4: false
    dhcp6: false
    accept-ra: false
    link-local: []
    optional: true
```

- MAC letters must be lowercase; `set-name` needs `match.macaddress`. [SRC: cloud-init]
- `optional: true` keeps boot from waiting for the three lab links. `link-local: []` disables link-local addressing. [SRC: netplan]
- `dhcp4-overrides.hostname` sends the name in the DHCP request whatever the system hostname is at that moment. cloud-init also sets the hostname "in the init-local stage before networking is configured". [SRC: netplan; cloud-init set_hostname]

### 10.3 `user-data`

Skeleton; the `write_files` entries carry the file contents given in the sections named in the manifest below.

```yaml
#cloud-config
hostname: clat-world
manage_etc_hosts: true
disable_root: false
ssh_pwauth: false
ssh_authorized_keys:
  - "@@LAB_SSH_PUBKEY@@"
users:
  - default
  - name: root
    ssh_authorized_keys:
      - "@@LAB_SSH_PUBKEY@@"
chpasswd:
  expire: false
  users:
    - {name: root, password: "@@CONSOLE_PASS@@", type: text}

bootcmd:
  # no service is started by package installation; removed again in runcmd
  - [cloud-init-per, instance, isp-policy, sh, -c, "printf '#!/bin/sh\\nexit 101\\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d"]
  # the image has unattended-upgrades; keep apt quiet while the lab runs
  - [cloud-init-per, instance, isp-noapt, systemctl, mask, --now, apt-daily.timer, apt-daily-upgrade.timer]

package_update: true
package_upgrade: false
packages:
  - ppp
  - pppoe
  - radvd
  - kea-dhcp6-server
  - tayga
  - unbound
  - nftables
  - python3-scapy
  - udhcpc
  - iperf3
  - tcpdump
  - curl
  - iputils-ping
  - iputils-tracepath
  - bind9-dnsutils
  - mtr-tiny
  - conntrack
  - ethtool
  - hyperv-daemons

write_files:
  - path: /etc/sysctl.d/90-isp.conf
    content: |
      net.ipv4.ip_forward = 1
      net.ipv6.conf.all.forwarding = 1
  - path: /etc/modules-load.d/isp.conf
    content: |
      pppoe
      tun
      dummy
  - path: /etc/apparmor.d/local/usr.sbin.kea-dhcp6
    content: |
      capability net_bind_service,
  # ... one entry per row of the manifest below ...

runcmd:
  - rm -f /usr/sbin/policy-rc.d
  - systemctl daemon-reload
  - sysctl --system
  - for u in tayga radvd kea-dhcp6-server iperf3; do systemctl disable --now "$u.service" || true; done
  - apparmor_parser -r /etc/apparmor.d/usr.sbin.kea-dhcp6 || true
  - systemctl enable --now nftables.service isp-base.service
  - /usr/local/sbin/ispctl dns64 on
  - systemctl enable unbound.service
  - systemctl enable --now isp-nat64.service isp-pppoe.service isp-www.service isp-iperf3.service isp-client.service
  - touch /var/lib/isp/provisioned
```

Manifest of the remaining `write_files` entries:

| Path | Mode | `defer: true` | Content |
|---|---|---|---|
| `/etc/isp/isp.env` | 0644 | no | 9.1 |
| `/usr/local/sbin/ispctl` | 0755 | no | 9.3 |
| `/usr/local/lib/isp/udhcpc-script` | 0755 | no | 7.1 |
| `/usr/local/lib/isp/send-ra-pref64.py` | 0755 | no | 7.4 |
| `/etc/isp/tayga-nat64.conf` | 0644 | no | 5.1 |
| `/etc/systemd/system/isp-base.service` | 0644 | no | 9.3 |
| `/etc/systemd/system/isp-pppoe.service` | 0644 | no | 2.2 |
| `/etc/systemd/system/isp-nat64.service` | 0644 | no | 5.1 |
| `/etc/systemd/system/isp-www.service`, `isp-iperf3.service` | 0644 | no | 5.4 |
| `/etc/systemd/system/isp-client.service` | 0644 | no | 7.1 |
| `/etc/ppp/ipv6-up.d/50-isp`, `/etc/ppp/ipv6-down.d/50-isp`, `/etc/ppp/ip-up.d/50-isp` | 0755 | yes | 2.2 |
| `/etc/ppp/chap-secrets`, `/etc/ppp/pap-secrets` | 0600 | yes | 2.2 |
| `/etc/nftables.conf` | 0755 | yes | 5.2 |
| `/etc/unbound/unbound.conf.d/isp.conf` | 0644 | yes | 6.2 |

- `defer: true`: "Defer writing the file until 'final' stage, after users were created, and packages were installed" [SRC: cloud-init write_files]. It is used for every file under a path that a package owns, so no package installation meets a file it did not expect. `/etc/radvd.conf`, `/etc/kea/kea-dhcp6.conf` and `/etc/ppp/pppoe-server-options` are not in user-data at all; `ispctl` generates them.
- Secrets: `@@PPPOE_USER@@`, `@@PPPOE_PASS@@` and `@@CONSOLE_PASS@@` are generated once by the seed builder (for example `openssl rand -hex 8` in the alpine container) and kept in `lab/.work/disks/build/secrets.env`, where the OPNsense configuration reads the same PPPoE values. The ssh key pair is made on the host with Windows' own `ssh-keygen` (`-t ed25519 -N ""`), into `lab/.work/disks/build/`; nothing is installed for that.
- The console password is only for the Hyper-V console when ssh does not work. ssh stays key-only.
- Login as `debian` (the image's default user, passwordless sudo) with the same key is the fallback if root login is not set up as expected. Where top-level `ssh_authorized_keys` end up for root is UNCONFIRMED, hence the explicit `users` entry.
- Done marker: `/var/lib/isp/provisioned`; or `cloud-init status --wait`.

### 10.4 Reaching the VM

- Name: the Default Switch registers DHCP client names under `mshome.net`, so `ssh root@clat-world.mshome.net`. Community reports say the host keeps these names in `hosts.ics` and that name resolution broke for some users on Windows 11 24H2. UNCONFIRMED.
- Fallback without any Hyper-V right: `arp -a | findstr /i 02-c1-a7-00-01-01` on the host shows the VM's current address, because the MAC is static.
- Fallback with Hyper-V rights: `(Get-VMNetworkAdapter -VMName clat-world).IPAddresses` (needs `hyperv-daemons` in the guest).
- OPNsense: `ssh -J root@clat-world.mshome.net root@10.99.0.2`.

### 10.5 Provisioning switch for OPNsense

- `ispctl provision on`: 10.99.0.0/24 is masqueraded out of `up0` and forwarded. OPNsense then needs a temporary route (`route add default 10.99.0.1`, not saved in its configuration) and can use 10.99.0.1 as DNS server.
- `ispctl provision off`: the set is emptied. It is also empty after every boot of clat-world.
- The condition "no native IPv4 gateway during tests" is decided on OPNsense (no gateway on the management interface). The switch on clat-world is the second safeguard.

---

## 11. What the first run has to confirm

In this order; each line is one observation.

| # | Check | Command or place | Pass |
|---|---|---|---|
| 1 | The generic image boots as Generation 2 and cloud-init finds the seed | VM console; `cloud-init status --long` | status done, datasource NoCloud |
| 2 | Names follow the MACs | `ip -br link` | `up0 wan0 lan0 mgmt0` with the MACs of 1.1 |
| 3 | Name or ARP lookup from the host | `ssh root@clat-world.mshome.net true` | login works |
| 4 | Packages installed, nothing failed | `systemctl --failed`; `/var/log/cloud-init-output.log` | no failed unit |
| 5 | Script and rule syntax | `sh -n /usr/local/sbin/ispctl`; `nft -c -f /etc/nftables.conf`; `unbound-checkconf` | no error |
| 6 | DNS64 | `dig @2001:db8:64::53 ipv4only.arpa AAAA +short` | `64:ff9b::c000:aa`, `64:ff9b::c000:ab` |
| 7 | NAT64 to the local target, from clat-world itself | `ping -6 -c2 64:ff9b::c058:6301` | replies |
| 8 | PPPoE in kernel mode | after OPNsense dials: `journalctl -u isp-pppoe`; `/var/log/isp/pppd.log` | "Session … created", IPV6CP up, `ppp0` exists |
| 9 | An IPCP proposal is rejected | set OPNsense WAN IPv4 to PPPoE; `pppd.log` | "Unsupported protocol … (0x8021)", session stays up on IPv6CP |
| 10 | radvd on ppp | `systemctl status radvd`; `tcpdump -ni ppp0 -vv 'icmp6 and ip6[40] == 134'` | RA with prefix, RDNSS, MTU, option 38 |
| 11 | Solicited RA is unicast and carries option 38 | same capture while OPNsense's WAN reconnects | RA to OPNsense's link-local address |
| 12 | Kea binds on ppp under AppArmor | `ss -ulnp \| grep 547`; `journalctl -u kea-dhcp6-server`; `journalctl -k \| grep -i apparmor` | socket on `fe80::1%ppp0`, no DENIED line |
| 13 | Prefix delegation | Kea log; `/tmp/pppoe0_prefixv6` on OPNsense | 2001:db8:5600::/56 |
| 14 | Client namespace | `ispctl client ip -br addr`; `ispctl client cat /etc/resolv.conf` | 192.168.1.x on `lan0`, OPNsense as name server |
| 15 | End to end through the CLAT | section 7.3 | as listed |
| 16 | Internet through the Default Switch | 7.3 "Internet"; `ispctl client ping -c3 1.1.1.1`; `ispctl client mtr -4 -n -r -c3 1.1.1.1` | records what works, including ICMP errors |
| 17 | PREF64 off, withdraw, other prefix; SLAAC off; DNS64 off | `ispctl …`, capture as in 10 | RA content follows |
| 18 | Renumbering | `ispctl pd 2001:db8:5700::/56; ispctl session reset` | new prefix on OPNsense |
| 19 | Jumbo frames on the private switch | section 8.2 check | 1500-byte IPv6 packet passes at `ispctl mtu 1500` |
| 20 | PPP-Max-Payload echo | `tcpdump -ni wan0 -vv -e 'ether proto 0x8863'` during a dial with WAN MTU 1508 | tag in PADI/PADR and the same value in PADO/PADS |
| 21 | Crafted RA reaches OPNsense's LAN | section 7.4 | frame seen on the LAN device |
| 22 | Reboot of clat-world | reboot, then `ispctl status` | everything back, provisioning NAT off |

---

## 12. UNCONFIRMED items and gaps, in one place

Could break the lab:

1. Debian generic image on Hyper-V Generation 2 (boot, initramfs drivers, Secure Boot setting).
2. `pppoe-server -k -g pppoe.so` with pppd 2.5.2 (the pieces fit by source reading; never run together here). Fallback: user mode.
3. Kea on a ppp interface, and its AppArmor profile without `capability net_bind_service`. Fallback: WIDE dhcp6s (4.4).
4. Jumbo frames across a Hyper-V private switch.
5. `clat-world.mshome.net` on Windows 11 (a name-resolution problem is reported for 24H2, 10.4). Fallback: ARP lookup by MAC.
6. Hyper-V accepting the locally administered static MACs. Fallback: unused `00155Dxxxxxx` addresses, changed in `network-config` too.
7. DNS recursion from clat-world through the Default Switch (needed for the `ipv4only.arpa` synthesis).

Affect what a result means:

8. The PLAT is tayga 0.9.2: DF-clear packets above 1280 bytes return as IPv6 fragments (5.5). It says nothing about the ISP's NAT64.
9. PPP MTU is capped at 1500 on the simulator (8.1). DESIGN 8.3 rows above 1508 are only testable against a non-echoing BNG.
10. What comes back through the Default Switch NAT for ICMP errors (5.6).
11. Kea's reply to a Renew for a prefix it no longer has (4.3).
12. How OPNsense's dhcp6c handles NoAddrsAvail for IA_NA when only a prefix is offered.
13. What the real BNG sends for M/O flags, RA interval, RDNSS address type and IPCP refusal is not known; the simulator's values are assumptions.

Small:

14. busybox udhcpc variable names; `ip netns exec` over the resolv.conf symlink; DF bit of Linux echo replies; radvd writing the interface MTU under Debian's unit; `dhcp6s` command line; where cloud-init puts top-level ssh keys for root; whether pppoe-server survives `session drop`; tcpdump's AppArmor profile on Debian (write captures as `*.pcap` under `/var/log/isp/` or `/root`).

Not done for this sheet: no download, no container, no Hyper-V command. Fourteen small text files (man pages and source files of radvd 2.20 and ppp 2.5.2) were fetched from GitHub for reading and kept in a working copy (not in this repository); they are reference text only and nothing from them was executed.

---

## 13. Sources

Package versions and contents
- `https://qa.debian.org/madison.php` (trixie, trixie-security), queried 2026-10-12
- `https://packages.debian.org/trixie/amd64/pppoe/filelist`, `…/tayga/filelist`

rp-pppoe 4.0 (Debian source `rp-pppoe` 4.0-1): `https://sources.debian.org/src/rp-pppoe/4.0-1/`
- `src/pppoe-server.c` (lines 443-449, 488-494, 714-732, 1042-1062, 1130-1185, 1601, 1900-2020), `src/pppoe.h` (108-133), `src/Makefile.in` (40-52), `man/pppoe-server.8`, `debian/rules`

ppp 2.5.2: `https://github.com/ppp-project/ppp/tree/v2.5.2`
- `pppd/pppd.8`, `pppd/main.c` (1201-1215), `pppd/ipcp.c` (143-146), `pppd/ipv6cp.c` (236-266, 356-402, 545-548), `pppd/plugins/pppoe/plugin.c` (77-101, 160-226, 363, 456-463), `pppd/plugins/pppoe/pppoe.h` (169-192)
- Debian packaging: `https://sources.debian.org/src/ppp/2.5.2-1+1/debian/extra/` (`options`, `ipv6-up`, `ip-up`)

radvd 2.20: `https://github.com/radvd-project/radvd/tree/v2.20`
- `radvd.conf.5.man`, `CHANGES`, `gram.y` (493-577), `send.c` (292-354, 846-848), `process.c` (151, 189-200), `radvd.c` (716-821), `device-common.c` (`check_device`), `device-linux.c` (44-128), `interface.c` (223-226), `radvdump.c` (468)
- Debian: `https://sources.debian.org/src/radvd/1:2.20-1/` (`radvd.service.in`)

Kea 2.6.3: `https://github.com/isc-projects/kea/tree/Kea-2.6.3`
- `doc/sphinx/arm/dhcp6-srv.rst` (interfaces, "Subnet and Prefix Delegation Pools", subnet selection with `interface`, status codes), `doc/sphinx/arm/logging.rst`, `src/lib/dhcp/iface_mgr.cc` (`openSockets6`), `src/lib/dhcp/iface_mgr_linux.cc` (`detectIfaces`), `src/bin/dhcp6/dhcp6_srv.cc` (`extendIA_PD`)
- Debian: `https://sources.debian.org/src/isc-kea/2.6.3-1+deb13u1/debian/` (`kea-dhcp6-server.service`, `usr.sbin.kea-dhcp6`, `usr.sbin.kea-dhcp4`)

Other DHCPv6 servers
- `https://sources.debian.org/src/wide-dhcpv6/20080615-24/dhcp6s.conf.5`
- `https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html`
- `https://sources.debian.org/src/dibbler/1.0.1-2/doc/examples/server-prefix-delegation.conf`

tayga
- 0.9.6: `https://raw.githubusercontent.com/apalrd/tayga/0.9.6/addrmap.c`; local copies of `addrmap.c`, `conffile.c` and `nat64.c` (a working copy, not in this repository); `refs/tayga/addrmap.c`
- Debian 0.9.2: `https://sources.debian.org/src/tayga/0.9.2-10+deb13u1/` (`addrmap.c`, `conffile.c`, `nat64.c`, `tayga.c`, `tayga.conf.5`, `debian/patches/0009-…`, `0012-…`, `debian/init`, `debian/default`)

unbound 1.22.0
- `https://github.com/NLnetLabs/unbound/blob/release-1.22.0/doc/unbound.conf.5.in`; `services/localzone.c` and `dns64/dns64.c` (no `ipv4only`)
- Debian: `https://sources.debian.org/src/unbound/1.22.0-2+deb13u3/debian/` (`unbound.conf`, `unbound.service`, `apparmor-profile`)

Tools
- scapy 2.6.1 `scapy/layers/inet6.py` (2165-2184); tcpdump 4.99.5 `print-icmp6.c`

Debian cloud image and kernel
- `https://cloud.debian.org/images/cloud/`
- `https://salsa.debian.org/cloud-team/debian-cloud-images` `config_space/13/package_config/{AMD64,CLOUD,GENERIC,SYSTEM_BOOT}`, `config_space/13/files/…`
- `https://salsa.debian.org/kernel-team/linux` branch `debian/6.12/trixie`: `debian/config/config.cloud`, `debian/config/config`, `debian/config/kernelarch-x86/config`

cloud-init and netplan
- `https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html`, `…/reference/network-config-format-v2.html`, `…/reference/modules.html`
- `https://netplan.readthedocs.io/en/stable/netplan-yaml/`

Hyper-V
- `https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/supported-freebsd-virtual-machines-on-hyper-v`, `…/supported-debian-virtual-machines-on-hyper-v`, `…/plan/plan-hyper-v-networking-in-windows-server`
- Linux 6.12 `drivers/net/hyperv/{netvsc_drv.c,hyperv_net.h,rndis_filter.c}`; opnsense/src stable/26.7 `sys/dev/hyperv/netvsc/{if_hn.c,if_hnvar.h}`
- Default Switch behaviour (random subnet, `hosts.ics`, 24H2 name-resolution report): community pages only, not a primary source

Project
- `DESIGN.md` sections 1, 5, 8, 10, 15, 16; `net/clat/src/opnsense/scripts/clat/lib/discovery.py` (`accept_ra`, `parse_ra_pref64`)
