# PLAN: Hyper-V lab for os-clat

> **Reference copy, added at integration.** This is the plan the lab was written from; the scripts cite it as "PLAN.md" or "PLAN" (for example "PLAN section 7 row 14"). The three sheets it names are copied next to it, unchanged. Neither is kept up to date. **Where this text differs from `../README.md` or from the scripts, the README and the scripts apply.** Differences known at integration:
>
> 1. The status line below is out of date: the downloads are done and verified, `build.sh` has built the three `base-*` files (Path A: the configuration is seeded into the image), and all scripts exist. At integration: no Hyper-V command had run, no VM existed, nothing was tested.
> 2. Section 3.1 and 3.3, `lab.sh`: it has no `soft-reset` and no `opn-cfg` verb. Both exist once, inside `run-tests.sh`, which does not source `lab.sh` (it calls only `lab.sh addr`). `lab.sh` has three verbs the plan does not list: `rights`, `hv` and `addr --wait`. `lab.sh world` also copies `web-restore.sh` and the rendered configuration to clat-world (for Path B). In the ssh_config written by `lab.sh addr` only clat-world's host key is pinned; clat-opn's is not (it changes with every rebuild and the box is reached only through clat-world).
> 3. Section 2 decision 4, M1 and section 7 row 5: the real 26.7 nano image holds four files with the factory mark (the nano configuration, `config.xml.sample`, two unit-test fixtures of core), not two. `opnsense/seed_config.py` therefore requires exactly one target (factory mark, serial console first, sector aligned, devices `mismatch0` and `mismatch1`) and reports the others. It is no longer the version printed in the OPNsense sheet.
> 4. M0: `whoami /groups | findstr ...` has to be typed in cmd or PowerShell. Git Bash has a `whoami` of its own; there, use `bash lab.sh rights`.
> 5. Section 10 step 2: `remove-lab.ps1` deletes `lab-state.json`, so the check for leftover files under `C:\ProgramData\Microsoft\Windows\Hyper-V` is printed by `remove-lab.ps1` itself (its log), not by a later `status-lab.ps1`.
> 6. Section 3.2: the two base images take 3.7 GB, not about 3. The folder also holds `disks/build/built.txt` (what each base file was built from) and `results/lab.log`, `results/build-*.log`, `results/provision-*.log`.
> 7. Section 8: where the test runner deviates from a criterion (T02(5), T10, T13, T16(b2), T21, T24), `run-tests.sh` says so in its output; the README lists them.

Written 2026-10-12; revised the same day after review (12 issues, all applied; section 13 says where). Inputs: `sheet-opnsense-on-hyperv.md`, `sheet-isp-simulator.md`, `sheet-hyperv-mechanics.md` (same folder as this file), `DESIGN.md` sections 5, 8, 9, 10, 11, 15, `README.md` (both at the top of the repository), and the plugin source under `net/clat`.

**Status: a plan. No Hyper-V command has run, no image has been downloaded, no VM exists, nothing here is tested.** Every script named below still has to be written from the sheets, with the changes of sections 2.1 and 2.2. Section 7 lists what the first run has to confirm, with a primary route and a fallback for each open point.

Words used: **UNCONFIRMED** = no primary source or it needs a run. "Measured" = a read-only check on the lab host on 2026-10-12 (section 12). `W:` = command on clat-world, `O:` = on clat-opn, `C:` = in the IPv4-only client namespace on clat-world, `st.x` = field `x` of the JSON printed by `configctl clat details` on clat-opn, `status.json` = `/var/run/clat/status.json`, the file the supervisor writes.

---

## 1. Topology

```
 Windows host with Hyper-V (Git Bash: build.sh, lab.sh, run-tests.sh; PowerShell: hyperv\*.ps1)
   |  vEthernet (Default Switch) <ICS address>/20; the subnet can change at host boot
   |  ICS gives DHCP, DNS (<name>.mshome.net) and IPv4 NAT to the Internet. No IPv6.
   |
 [Default Switch] ---- nat  02:C1:A7:00:01:01  up0    DHCP, hostname clat-world ---------+
   (exists, never changed)                                                               |
 [clat-mgmt] --+------ mgmt 02:C1:A7:00:01:02  mgmt0  10.99.0.1/24                       |  VM "clat-world"
   private     |                                                                         |  Debian 13 generic image
 [clat-wan] ---|--+--- wan  02:C1:A7:00:01:03  wan0   no address, PPPoE server           |  Generation 2, Secure Boot off
   private     |  |                                   MTU 1500 (1508 with ispctl mtu 1500)  2 vCPU, 2048 MB, 8 GB
 [clat-lan] ---|--|-+- lan  02:C1:A7:00:01:04  lan0   inside netns "client", DHCPv4 -----+
   private     |  | |                                 from OPNsense (192.168.1.100-199), IPv6 disabled
               |  | |
               |  | +- lan  02:C1:A7:00:02:01  hn0    LAN   192.168.1.1/24, 2001:db8:5600::/64 (track6 id 0) --+
               |  +--- wan  02:C1:A7:00:02:02  hn1    parent of pppoe0 = WAN (IPv4 None, DHCPv6, PD /56)      |  VM "clat-opn"
               +------ mgmt 02:C1:A7:00:02:03  hn2    MGMT  10.99.0.2/24, no gateway -------------------------+  OPNsense 26.7 nano image
                                                                                                                 Generation 1, IDE disk
                                             tun464  CLAT  192.0.0.1 -> 192.0.0.2 (plugin, when active)          2 vCPU, 4096 MB, 16 GB
```

Inside clat-world (the simulated ISP):

| Item | Value |
|---|---|
| PPP link | always `ppp0`: the PPPoE server has one session slot (`-N 1`). BNG link-local `fe80::1`; PPP MTU 1492 (1500 with `ispctl mtu 1500`) |
| WAN /64 in the RA | `2001:db8:a::/64`, autonomous flag on or off (`ispctl slaac`) |
| Delegated prefix | `2001:db8:5600::/56` (renumbering: `2001:db8:5700::/56`), Kea, one-prefix pool |
| Resolver (RDNSS), DNS64 | `2001:db8:64::53` on dummy `isp0`; also listens on 10.99.0.1. `ipv4only.arpa` is answered from local data with TTL 60, so prefix discovery by DNS needs no Internet |
| NAT64 | tayga 0.9.2 on tun `nat64`, prefix `64:ff9b::/96`, pool `192.168.255.0/24`, masqueraded out of `up0` |
| IPv4 test target | `192.88.99.1` on `isp0` = `64:ff9b::c058:6301`; HTTP :80 (100 MB file), iperf3 :5201, ICMP |
| Negative-test destination | `10.255.255.1`: private, on no connected network of OPNsense, exists nowhere. The CLAT must refuse it |
| IPCP addresses (only with `ispctl ipv4 on`) | `100.64.0.1` (BNG), `100.64.0.2` (client; fixed, because there is one slot) |
| Provisioning NAT (off by default) | `ispctl provision on`: 10.99.0.0/24 masqueraded out of `up0` |
| Offloads | TSO, GSO, GRO and TX checksum off on `wan0` and `lan0`; software RSC off on the three lab switches (decision 28) |

Expected on clat-opn once the CLAT is active at PPP MTU 1492: CLAT IPv6 pair = a /127 in `2001:db8:56ff::/64` (highest /64 of the /56), `tun464` MTU 1492, IPv4 MTU presented 1472, TCP MSS 1432 (DESIGN 8.1).

Paths: host -> clat-world by ssh on the Default Switch; host -> clat-opn by ssh through clat-world (`ProxyJump`); clat-world -> clat-opn directly on 10.99.0.0/24 (ssh and web API). No lab switch has a host adapter.

**What bypasses the CLAT.** 192.168.1.0/24 (LAN) and 10.99.0.0/24 (MGMT) are connected networks of OPNsense. A packet from the LAN client to an address in either never enters `tun464`: it stays on the LAN or leaves by `hn2`. No test may use such an address as a CLAT destination. clat-world drops what reaches `mgmt0` with a source outside 10.99.0.0/24, so a LAN packet that took that way is never answered out of `up0`. The README has to say this.

---

## 2. Decisions

| # | Topic | Decision | Reason |
|---|---|---|---|
| 1 | OPNsense image | `OPNsense-26.7-nano-amd64.img.bz2` | the only image that is an installed system; the others are live installers that need someone at a console |
| 2 | clat-opn generation | **Generation 1**, disk on IDE 0:0 | the nano image has a BSD disklabel and BIOS boot code only; Generation 2 (UEFI) cannot boot it |
| 3 | clat-opn size | 2 vCPU, 4096 MB static, VHDX enlarged to 16 GB **before** the first boot | OPNsense minimum is 3 GB RAM; FreeBSD has no dynamic memory; the image grows its file system only at first boot |
| 4 | Unattended OPNsense bring-up | **Path A**: `seed_config.py` overwrites the factory `/usr/local/etc/config.xml` inside the raw image (same byte length) before conversion. Fallback **Path B**: boot factory defaults, restore `config.xml` through the web GUI from the client namespace. Then Path C (serial + importer, elevated), Path D (console by hand) | a second disk with `conf/config.xml` is not unattended (the importer needs a key press and a typed device name). The build decides: the script's dry run must find exactly two factory configs, one of them the nano one |
| 5 | Adapter order on clat-opn | added in the order **lan, wan, mgmt** -> expected `hn0`, `hn1`, `hn2`; static MACs `02C1A70002` + `01`/`02`/`03` (last byte = `hn` unit + 1) | the factory assignment (first = LAN, second = WAN) then also fits, which Path B needs. The mechanics sheet's order (mgmt, wan, lan) and its MAC numbering are replaced |
| 6 | Debian image | `debian-13-generic-amd64.qcow2` | the genericcloud kernel has `CONFIG_PPP` unset: no PPPoE server. nocloud has no cloud-init |
| 7 | clat-world generation | Generation 2, Secure Boot off, 2 vCPU, 2048 MB, 8 GB, seed ISO (label `CIDATA`) on a SCSI DVD drive | image has an EFI partition; Secure Boot off is the one setting with confirmed syntax |
| 8 | clat-world provisioning | cloud-init does the minimum (host name, NIC names by MAC, root key). Everything else is pushed over ssh and installed by one idempotent `install.sh` | cloud-init runs once per disk; the ISP files are unexecuted text and will need corrections. A push can be repeated in seconds; a seed cannot. Deviation from the ISP sheet section 10.3, which put everything into user-data |
| 9 | PPPoE server | rp-pppoe 4.0 `pppoe-server -k -g pppoe.so -N 1`, pppd 2.5.2 with `noip`, `+ipv6`, `ipv6 ::1,` | IPv6CP only; an IPCP proposal is answered by LCP Protocol-Reject. One session slot: there is one subscriber, and the session is then always `ppp0` with IPCP address 100.64.0.2, so no command and no criterion depends on which slot a redial got. Cost: a redial that arrives while the old pppd is still closing is refused once and has to be repeated by mpd5 (section 7 row 23). Fallback for the server itself: user-mode PPPoE (drop `-k -g pppoe.so`) |
| 10 | Router Advertisements | radvd 2.20, config generated per PPP session, changed by reload | has `nat64prefix`; lifetime 0 = withdrawal; a restart would send a zero-lifetime RA |
| 11 | DHCPv6-PD server | **Kea 2.6.3**, `pd-pools` with prefix length = delegated length, config regenerated per session, memfile without persistence. Kea is restarted at session start and when its rendered config changed, not on every `ispctl apply` | the only packaged server that delegates without knowing the client's DUID. A needless restart would make Kea forget the lease OPNsense still holds. Fallback: WIDE `dhcp6s` with OPNsense's DUID |
| 12 | NAT64 (PLAT) | Debian's **tayga 0.9.2** on tun `nat64` plus nftables masquerade | packaged, no kernel module (Jool needs DKMS). It is not the ISP's NAT64: results about fragments and ICMP do not transfer |
| 13 | DNS64 | unbound 1.22. `ipv4only.arpa` is a local zone on clat-world: `ispctl dns64 on` serves A 192.0.0.170/171 and AAAA `64:ff9b::c000:aa`/`ab`, `off` serves the A records only, all with TTL 60. The `dns64` module is switched too, for all other names | prefix discovery by DNS then depends neither on recursion through the host's network nor on DNSSEC, and the TTL is set by the lab: the "refresh returns no prefix" path of DESIGN 5.2 becomes testable. That local data wins over the dns64 module is UNCONFIRMED (section 7 row 21) |
| 14 | IPv4 test target | **192.88.99.1** on a dummy interface of clat-world | the CLAT's tayga 0.9.6 refuses RFC 1918, 100.64/10, the documentation and benchmark ranges with the well-known prefix (`wkpf-strict`); 192.88.99.0/24 is in none of its lists and is kept inside the VM by a blackhole route and two nftables drops |
| 15 | LAN client | network namespace `client` on clat-world with the `lan` NIC moved into it, IPv6 disabled, busybox `udhcpc` | a strictly IPv4-only host without a third VM; no MAC spoofing needed because the real NIC is moved |
| 16 | Temporary IPv4 for OPNsense | runtime route `route add -inet default 10.99.0.1` plus `ispctl provision on`; never a gateway in `config.xml` | core never removes a default route when no gateway is configured, so a config gateway would need the manual delete anyway; a reboot clears the runtime route |
| 17 | Order: provisioning before the plugin | update, kernel hold and tayga are done first, the route is removed, the box is rebooted and checkpointed; **then** the plugin is installed | a runtime default route is invisible to the plugin's native-IPv4 test (it reads core's gateway list), so plugin and provisioning route must never coexist. This also installs the plugin the way a customer does: on a box without IPv4 |
| 18 | OPNsense version | packages and base current 26.7.x; **kernel 26.7.4, locked**, tunable `hw.vmbus.tlb_hcall=0` seeded | the 26.7.6 kernel crashes unbound, syslog-ng and python on Hyper-V (forum topic 53114). If a kernel newer than 26.7.6 is on the mirror when the lab is built: section 7, row 14 |
| 19 | Plugin installation | no package: tar of `net/clat/src` over ssh into `/usr/local`, explicit modes, then the lines of the generated `+POST_INSTALL` | building the package needs a clone of opnsense/plugins, which this plan does not download |
| 20 | How the host reaches the VMs | Git Bash `ssh` with one lab key and a lab-only config and known_hosts file. clat-world: `clat-world.mshome.net`, else the neighbour table by static MAC, else Hyper-V KVP; the first candidate that accepts the lab key and answers `hostname` = `clat-world` is used. clat-opn: `ProxyJump` to 10.99.0.2 | measured: Git Bash's ssh loads a key from a folder with a wide ACL, Windows' `ssh.exe` refuses it. A stale `mshome.net` name cannot mislead, because only a VM the lab provisioned accepts the key |
| 21 | Where tests execute | test bodies run **on clat-world** (it is the ISP, the client and has direct ssh and API access to 10.99.0.2); the host only starts them, resets VMs and collects results | avoids quoting through MSYS -> ssh -> ssh -> csh, and avoids two ssh hops per measurement |
| 22 | Reset between tests | one off-state checkpoint per VM, `clat-base` (updated OPNsense with tayga, no plugin, no IPv4 route). Every run restores it and installs the current plugin tree. Between tests of one group a soft reset that also restarts the plugin's service | each run tests the current source on a clean box, and the install is itself a test. The supervisor keeps a failure count, a back-off, a DNS query schedule and a restart counter in memory; only a restart of the service makes a test independent of the one before |
| 23 | Rights | preferred: the account that runs the lab joins "Hyper-V Administrators" (section 11). Otherwise the `hyperv\*.ps1` command lines of the table in section 11 are run elevated | without the group every start, stop and restore needs an elevated console |
| 24 | VM configuration folder | `lab\.work\disks\<vm>.vm\` (New-VM `-Path`) | keeps the VMs' files inside the lab's three folders; the `clat-*` removal rule covers them |
| 25 | Serial console | COM1 of both VMs is mapped to a named pipe, but the lab does not depend on it | opening the pipe needs an elevated process; it is the fallback for diagnosing a failed first boot of clat-opn (first boot prints on COM1 only) |
| 26 | Negative-test destination | `10.255.255.1` | it must follow OPNsense's default route into `tun464` so that tayga sees it and answers ICMP type 3 code 1 (tayga `nat64.c` 379-383, `addrmap.c` 97-132). 10.99.0.1, used before, is on a connected network of OPNsense and never reaches tayga |
| 27 | Evidence that tayga was, or was not, restarted | the tayga **pid** and `tayga.started` from the sampler, with `st.tayga.uptime` at the end. `tayga.restarts` is used as a crash counter only | `restarts` is incremented only in `tayga_exit()` (supervisor.py 739-750), that is for exits the supervisor did not ask for. A restart for a changed plan goes through `renumber()` (763-770) and leaves it unchanged |
| 28 | Offloads | guest: `ethtool -K <if> tso off gso off gro off tx off` on `wan0` and `lan0`. Host: `Set-VMSwitch -EnableSoftwareRsc $false` on the three lab switches only, if the parameter exists (measured: it does) | a router under test must see the frames the client sent. That software RSC on a virtual switch (on by default since Windows 10 1809) hands oversized coalesced TCP frames to FreeBSD router VMs is not checked against a source (UNCONFIRMED); the setting touches only switches the lab created, and M10 checks the result |
| 29 | Output of the Hyper-V scripts | every `hyperv\*.ps1` writes what it prints to `.work\results\hyperv-<UTC>-<script>.log`; `create-lab.ps1` and `reset-lab.ps1` end with the status listing | in elevated mode the unelevated shell cannot call Hyper-V, but it can read these files, and with them the check lines of M2 and M7 |

### 2.1 Where the sheets disagreed and what applies

1. Generation of clat-opn: 1 (not 2). No second disk. `Set-VMFirmware` is called for clat-world only.
2. `Base` for clat-world is converted from `debian-13-generic-amd64.qcow2` (the mechanics sheet's command names genericcloud).
3. clat-opn adapters: order lan, wan, mgmt; MACs `02C1A7000201/02/03`. clat-world keeps the MACs of the ISP sheet section 1.1.
4. "Read `ifconfig` at first boot, then write the assignments" is not possible with Path A. The assignment is seeded as `hn0`/`hn1`/`hn2`; M4 checks it; the remedy for another order is to reconnect adapters to switches, not to rebuild.
5. VM folders live under `disks\`, not under a fourth folder `vm\`.
6. The seed ISO is named `base-world-seed.iso` so that `remove-lab.ps1` keeps it and `create-lab.ps1` alone can rebuild the lab.
7. Disk size for clat-opn is 16 GB (the mechanics draft has 8).
8. The stop action is `ShutDown`; a "Nothing" value does not exist.

### 2.2 Changes to the sheets after review

The scripts are written from the sheets with these changes. None of them has run.

ISP sheet (`sheet-isp-simulator.md`):

1. **2.2, `isp-pppoe.service`:** `-N 1` instead of `-N 8`.
2. **5.2, `nftables.conf`:** a new chain, and one more rule at the end of `chain forward`:

   ```
   chain input {
       type filter hook input priority filter; policy accept;
       iifname "mgmt0" ip saddr != 10.99.0.0/24 counter drop
   }
   # last rule of chain forward: other IPv6 from the subscriber gets an error, not silence
   iifname "ppp*" meta nfproto ipv6 counter reject with icmpv6 type no-route
   ```

   Without the reject, OPNsense's recursive Unbound waits for time-outs on every IPv6 query to the Internet.
3. **5.3 and 7.3:** the `wkpf-strict` test is `ispctl client ping -c2 -W2 10.255.255.1`, not `ping 10.99.0.1`.
4. **6.2, `isp-dns64.conf`,** written by `ispctl dns64 on`:

   ```
   server:
       module-config: "dns64 validator iterator"
       local-zone: "ipv4only.arpa." static
       local-data: "ipv4only.arpa. 60 IN SOA localhost. nobody.invalid. 1 3600 1200 604800 60"
       local-data: "ipv4only.arpa. 60 IN A 192.0.0.170"
       local-data: "ipv4only.arpa. 60 IN A 192.0.0.171"
       local-data: "ipv4only.arpa. 60 IN AAAA 64:ff9b::c000:aa"
       local-data: "ipv4only.arpa. 60 IN AAAA 64:ff9b::c000:ab"
   ```

   `ispctl dns64 off` writes `module-config: "validator iterator"` and the same zone without the two AAAA lines. The SOA line is an addition of this plan: it gives the "no AAAA" answer a TTL of 60 s, which is what the plugin (sysif.py 392-395) and OPNsense's Unbound use for it. The sheet's sentence "this needs working DNS towards the Internet" no longer applies to `ipv4only.arpa`. If the fallback of section 7 row 12 (forwarding to the ICS DNS proxy) is ever used, `module-config` becomes `"dns64 iterator"`: a proxy without DNSSEC makes the validator answer SERVFAIL.
5. **7.4, `send-ra-pref64.py`:** unchanged, but T10 always passes `--src` (the BNG's link-local address). The script's default source `fe80::bad:64` is used in one separate case only.
6. **9.3, `ispctl`:**
   - new verb `iface`: prints `IFACE` from `/run/isp/session`, nothing when there is no session;
   - new verb `defaults`: copies `isp.env.default` over `isp.env`, sets `wan0` back to MTU 1500, rewrites the pppd options and the unbound DNS64 file, restarts `isp-pppoe` and unbound;
   - `apply_pd` renders the Kea file to a temporary name and restarts Kea only when it differs from the file in use or Kea is not running; `_up` always restarts Kea (new interface instance);
   - `_up` and `_down` run their whole body under `flock /run/isp/lock`. No other verb takes the lock (a verb that restarts `isp-pppoe` while holding it would wait for `_down`, which would wait for the lock);
   - `init` runs `ethtool -K wan0 tso off gso off gro off tx off || true` and logs `ethtool -k wan0`; `_client_setup` does the same for `lan0` inside the namespace.

Hyper-V mechanics sheet (`sheet-hyperv-mechanics.md`):

7. **7.1, `lab-common.ps1`:** `Start-LabLog <script>` and `Stop-LabLog`: `Start-Transcript` to `.work\results\hyperv-<UTC yyyyMMddTHHmmssZ>-<script>.log`; a nested call (status from inside create) does nothing. Every script calls them.
8. **7.2, `create-lab.ps1`:** after the switches exist, for each of the three lab switches: `if ((Get-Command Set-VMSwitch).Parameters.ContainsKey('EnableSoftwareRsc')) { Set-VMSwitch -Name <s> -EnableSoftwareRsc $false }`, then print `rsc <s>: SoftwareRscEnabled=<value>`. The Default Switch is never passed to `Set-VMSwitch`. The script ends by running the status listing.
9. **7.3, `remove-lab.ps1`:** before `Remove-VM`, for every kept file (`base-*` in `disks\`): `icacls <file> /remove "NT VIRTUAL MACHINE\<VM id>"`. After the VMs are gone it deletes `results\lab-state.json`.
10. **7.4, `status-lab.ps1`:** also prints `SoftwareRscEnabled` of the lab switches, the ACL of the kept `base-*` files, and, for the VM ids in `lab-state.json`, whether a file named after them exists under `C:\ProgramData\Microsoft\Windows\Hyper-V` (a directory listing; "not readable" is printed if it is refused).

---

## 3. Files to create

### 3.1 `lab/` (text, LF; `*.ps1` ASCII only)

| File | Runs on | Content and source |
|---|---|---|
| `README.md` | - | how to run M0 to M10 and the tests, the elevated steps (the table of section 11, word for word), clean-up. Must say that nothing is tested until `results/first-run.txt` exists, must repeat section 7, and must state that destinations in 192.168.1.0/24 and 10.99.0.0/24 bypass the CLAT (section 1) |
| `.gitignore` | - | one line `.work/` (the folder holds keys and secrets) |
| `build.sh` | host, Git Bash | M1: downloads, checks, keys and secrets, rendering, seeding, conversion (section 6, M1). Refuses to rebuild a `base-*` file or the seed ISO while `results/lab-state.json` lists a VM, unless `--force`: a running clat-world holds the ISO open |
| `lab.sh` | host, Git Bash | the driver and the helper functions `run-tests.sh` sources. Verbs in 3.3 |
| `run-tests.sh` | host and clat-world | the one test runner. Outer part (host): resets, plugin push, starts the inner part, collects results. Inner part (`--inside`, on clat-world): the sampler and the test bodies of section 8. One file; the outer part copies itself to clat-world. `--reset hyperv\|guest\|manual` chooses how an H reset is done (section 10); the default is `hyperv` with Hyper-V rights and `guest` without |
| `hyperv/lab-common.ps1` | host | mechanics sheet 7.1 with the changes of 2.1 (VM table: generation, sizes, adapter order, MACs, `Dvd`, no `ExtraDisk`; `VmDir` = `disks`) and of 2.2 item 7 |
| `hyperv/create-lab.ps1` | host | mechanics sheet 7.2 with 2.2 item 8. Switches `-SwitchesOnly`, `-NoStart`. Resize to 16 GB / 8 GB before the first start. Generation 1: no `Set-VMFirmware`, DVD left empty |
| `hyperv/remove-lab.ps1` | host | mechanics sheet 7.3 with 2.2 item 9; directories `clat-*` are looked for in `disks\` |
| `hyperv/status-lab.ps1` | host | mechanics sheet 7.4 with 2.2 item 10, plus free space on the checkout's volume |
| `hyperv/reset-lab.ps1` | host | new, small: `-Action Save\|Restore\|Start\|Stop [-Name clat-base] [-VM <name>]` (`-VM` limits Start and Stop to one VM), built from mechanics sheet 2.9 and 2.10. Save = guest shutdown of both, `Checkpoint-VM` both, start clat-world then clat-opn. Restore = turn off both, `Restore-VMSnapshot` both, start both. Ends with the status listing. A separate file because in "elevated" mode exactly this has to be run in an elevated console |
| `world/user-data.tmpl` | cloud-init | minimal: `hostname`, `disable_root: false`, `ssh_pwauth: false`, root's authorized key (both the top-level list and an explicit `users:` entry), console password. No packages, no `write_files`. The two-line `meta-data` (`instance-id`, `local-hostname`) is written by `build.sh` |
| `world/network-config` | cloud-init | ISP sheet 10.2 unchanged (names `up0`, `wan0`, `lan0`, `mgmt0` bound to the MACs of section 1) |
| `world/install.sh` | clat-world, root | idempotent. (1) `policy-rc.d` exit 101, mask the apt timers; (2) copy `etc/apparmor.d/local/usr.sbin.kea-dhcp6` first; (3) `apt-get update`, install the package list of ISP sheet 1.3 plus `jq`, `iputils-arping`, `netcat-openbsd`; (4) copy the staged `rootfs/` tree to `/` with the modes of ISP sheet 10.3; (5) write `chap-secrets`/`pap-secrets` from `/root/lab.env`; (6) the `runcmd` lines of ISP sheet 10.3; (7) `touch /var/lib/isp/provisioned` |
| `world/rootfs/...` | clat-world | the files of the ISP sheet with the changes of 2.2 items 1 to 6, one file each, at their target paths: `etc/isp/isp.env` (9.1) and a copy `etc/isp/isp.env.default`; `etc/isp/tayga-nat64.conf` (5.1); `etc/nftables.conf` (5.2); `etc/unbound/unbound.conf.d/isp.conf` (6.2); `etc/apparmor.d/local/usr.sbin.kea-dhcp6` (4.2); `etc/sysctl.d/90-isp.conf`, `etc/modules-load.d/isp.conf` (10.3); `etc/ppp/ipv6-up.d/50-isp`, `etc/ppp/ipv6-down.d/50-isp`, `etc/ppp/ip-up.d/50-isp` (2.2); `etc/systemd/system/isp-{base,pppoe,nat64,www,iperf3,client}.service` (2.2, 5.1, 5.4, 7.1, 9.3); `usr/local/sbin/ispctl` (9.3); `usr/local/lib/isp/udhcpc-script` (7.1); `usr/local/lib/isp/send-ra-pref64.py` (7.4) |
| `opnsense/config.xml.template` | build | copy of the template printed in the OPNsense sheet (6.1) |
| `opnsense/seed_config.py` | build container | copy of the helper printed in the OPNsense sheet (5.2) |
| `opnsense/provision.sh` | clat-opn, `/bin/sh` | M6: package upgrade, tayga, base, kernel hold and lock (OPNsense sheet 7.2, 7.3). Ends with a line `PROVISION DONE rc=<n>` |
| `opnsense/install-plugin.sh` | clat-world | `install` and `remove`: OPNsense sheet 8.2 and 8.3, reading `/root/os-clat.tar` and `/root/os-clat.files` and talking to 10.99.0.2 |
| `opnsense/web-restore.sh` | clat-world, client namespace | Path B only: OPNsense sheet 5.4 |

### 3.2 `lab/.work/` (generated; never edited by hand)

```
cache/    OPNsense-26.7-nano-amd64.img.bz2, OPNsense-26.7-checksums-amd64.sha256,
          debian-13-generic-amd64.qcow2, SHA512SUMS
disks/    build/                    small generated inputs, kept when the VMs are removed:
            secrets.env             PPPoE user and password, console password, API key and secret
            lab_ed25519, .pub       the one lab ssh key pair
            clat-opn-config.xml     rendered OPNsense configuration
            seed/                   rendered user-data, meta-data, network-config
            ssh_config              written by "lab.sh addr"
            os-clat.tar, .files     the plugin tree as last pushed
          clat-opn.raw              3 GiB, exists only while build.sh runs
          base-opnsense-26.7.vhdx   seeded base image (kept)
          base-debian-13.vhdx       (kept)
          base-world-seed.iso       CIDATA seed (kept)
          clat-world.vhdx, clat-opn.vhdx          written by Convert-VHD, resized
          clat-*.avhdx                            checkpoint files, written by Hyper-V
          clat-world.vm\, clat-opn.vm\            VM configuration and checkpoint metadata
          clat-known_hosts                        lab-only known_hosts
results/  assets.txt                hashes, sizes, image build id, seed_config.py output
          lab-state.json            VM ids and MACs (deleted by remove-lab.ps1)
          hyperv-<UTC>-<script>.log what each hyperv\*.ps1 run printed
          first-run.txt             the answers to section 7
          <UTC timestamp>/          one folder per test run: env.txt, summary.tsv, Txx/*.log, *.pcap
```

Disk budget on the checkout's volume: cache 0.9 GB, bases about 3 GB, VM disks about 6 to 7 GB after the update, checkpoints a few GB, plus 3 GB for the raw file during the build. Estimate 13 GB steady, 17 GB peak (UNCONFIRMED until built). `build.sh` refuses to start with less than 20 GB free.

### 3.3 `lab.sh` verbs

| Verb | Does |
|---|---|
| `addr` | finds clat-world (decision 20), writes `disks/build/ssh_config`: hosts `clat-world` (root) and `clat-opn` (root, `ProxyJump clat-world`), `IdentityFile`, `IdentitiesOnly yes`, `BatchMode yes`, `StrictHostKeyChecking accept-new`, `HostKeyAlias`, `UserKnownHostsFile disks/clat-known_hosts`, `GlobalKnownHostsFile /dev/null` (the user's own `~/.ssh` is never written) |
| `w <cmd>` / `c <cmd>` | run on clat-world / in the client namespace (`ispctl client ...`) |
| `o <cmd>` | run on clat-opn; the text is fed to `/bin/sh -s` on stdin, because root's shell hands remote commands to csh |
| `api GET\|POST <path> [json]` | curl from clat-world to `https://10.99.0.2`, key and secret from `/root/lab.env` |
| `st` | `O: configctl clat details`. Called once per step, never in a loop: each call runs `facts.php` twice plus `pkg` and `pfctl` and writes a configd log line. Anything sampled per second reads `status.json` |
| `world` | copies `world/rootfs`, `install.sh`, the lab private key (as `/root/.ssh/id_ed25519`) and `/root/lab.env` to clat-world, runs `install.sh`, prints the M3 checks as OK/FAIL lines |
| `opn-wait` | probes TCP 10.99.0.2:22 from clat-world (no login attempts: five failed logins put 10.99.0.1 into OPNsense's `sshlockout` table), up to 15 minutes, then exactly one key login |
| `opn-provision` | M6 |
| `plugin install\|remove` | tars `net/clat/src` (read only), copies it to clat-world, runs `install-plugin.sh` there; records the tar's sha256 |
| `opn-cfg set\|unset <path> [value]` | for settings that have no API (WAN IPv4 type, WAN MTU, PD length, outbound NAT mode, `system.state-policy`): a PHP one-liner on the box (`require_once 'config.inc'`, change `$config`, `write_config()`), then the matching `configctl` action. UNCONFIRMED; fallback is the web GUI through `lab.sh gui` |
| `soft-reset` | (1) `W: ispctl defaults`, then wait for the M5 state (session on `ppp0`, prefix file rewritten). (2) Plugin settings back to the model defaults (with `test_target` = 192.88.99.1), Unbound `forwarding.enabled` 0 and `general.dns64` 0, through the API plus `reconfigure`; `system.state-policy` unset if a test set it. (3) `O: configctl clat restart`: a new supervisor, so failure count, back-off, DNS query schedule, restart counter and tayga start time all begin at zero. (4) `C: ip route flush cache`: no cached path MTU on the client. (5) wait until `status.json` shows `active`, at most 120 s |
| `hvlog` | prints the newest `.work/results/hyperv-*.log` (for elevated mode) |
| `gui` | `ssh -N -L 8443:10.99.0.2:443 clat-world`, for a browser on the host at `https://127.0.0.1:8443` |

Container template, from Git Bash in `lab/` (only for what Windows lacks: Python for `seed_config.py`, `qemu-img`, `xorriso`; one container at a time; one retry after 30 s on `ERROR_TIMEOUT`). Only `.work` is writable inside a container; the script folder is mounted read-only and only for the Python step:

```bash
MSYS_NO_PATHCONV=1 wslc.exe run --rm -v "$(cygpath -w "$PWD/.work"):/work" -v "$(cygpath -w "$PWD/opnsense"):/lab/opnsense:ro" python:3.11-alpine sh -c '...' 2>&1 | tr -d '\0'
MSYS_NO_PATHCONV=1 wslc.exe run --rm -v "$(cygpath -w "$PWD/.work"):/work" alpine:3.22 sh -c 'apk add --no-cache qemu-img xorriso && ...' 2>&1 | tr -d '\0'
```

That wslc honours `:ro` is UNCONFIRMED (section 7 row 29): the first Python container runs `touch /lab/opnsense/.w` and the build stops if that succeeds. Fallback: `build.sh` copies `seed_config.py` to `.work/disks/build/` and mounts `.work` only.

Hashing, base64, sed, `openssl`, `ssh-keygen`, `tar`, `bzip2` and `curl` are the ones Git Bash already has (measured). Nothing is installed on Windows. When `icacls` or `fsutil` is called from Git Bash, `MSYS_NO_PATHCONV=1` is needed (measured: `/grant` is rewritten into a path otherwise).

---

## 4. Downloads

| What | URL | Size | Integrity check |
|---|---|---|---|
| OPNsense 26.7 nano image | `https://pkg.opnsense.org/releases/26.7/OPNsense-26.7-nano-amd64.img.bz2` | 490,849,116 bytes (468 MiB), measured by HEAD on 2026-10-12 | SHA-256 of the `.bz2` must equal the value in the checksum file. Read on 2026-10-12: `28d5e2f37e40d87468a924e3006ef10e2ddc6de485b85333d9e3958c84d0cb9d`. After decompression the file must be 3,221,225,472 bytes |
| OPNsense checksum file | `https://pkg.opnsense.org/releases/26.7/OPNsense-26.7-checksums-amd64.sha256` | 436 bytes | BSD format, one line per image: `SHA256 (<file>) = <hex>` (read on 2026-10-12). The script takes the 64 hex digits from the line naming the file |
| Debian 13 generic cloud image | `https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2` (redirects to a Debian mirror) | 435,355,648 bytes (415 MiB), measured on 2026-10-12; `latest` was build `20261001-2618` then and will move | SHA-512 must equal the line for this file name in `SHA512SUMS` fetched in the same run. On 2026-10-12: `6f0f9333...43950c841d` (full value goes into `results/assets.txt`) |
| Debian checksum file | `https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS` | 8,024 bytes | GNU format `<hex>  <file>`; served by cloud.debian.org itself |
| Debian packages, inside clat-world | Debian 13 repositories configured in the image (`deb.debian.org`, security) | UNCONFIRMED, estimate 150 to 250 MB: ppp, pppoe, radvd, kea-dhcp6-server, tayga, unbound, nftables, python3-scapy, udhcpc, iperf3, tcpdump, curl, iputils-ping, iputils-tracepath, iputils-arping, bind9-dnsutils, mtr-tiny, conntrack, ethtool, hyperv-daemons, jq, netcat-openbsd | apt's signed repository metadata |
| OPNsense packages and sets, inside clat-opn | `https://pkg.opnsense.org/FreeBSD:15:amd64/26.7/latest` (packages, tayga) and `.../26.7/sets/` (base 93 MB, kernel 31 MB) | base and kernel as given; the package upgrade from 26.7 is UNCONFIRMED (`pkg-static upgrade -n` prints it) | pkg repository signature; `opnsense-verify` for the sets |
| Container images | `alpine:3.22` and `python:3.11-alpine` through wslc (pulled if not present), plus apk `qemu-img`, `xorriso` | about 10 MB for alpine and some tens of MB for python, a few tens of MB of apk packages per run (UNCONFIRMED) | registry digest; apk signatures |

The review added no download: `flock` is in util-linux and `ethtool` was already in the list.

Not downloaded: the `.sig` and `.pub` files of OPNsense (not needed), the vga or serial image (only if section 7 row 6 fails), the opnsense/plugins repository (not part of this plan; section 9). The checksum files prove integrity of the transfer, both coming over HTTPS from the publisher's host; they are not a signature check.

---

## 5. What the lab creates on the Windows host

| Kind | Objects |
|---|---|
| Hyper-V switches | `clat-wan`, `clat-lan`, `clat-mgmt`: type Private, note `os-clat lab`, `SoftwareRscEnabled` False if the parameter can be set. They add no host adapter (checked in M2). The Default Switch and `WSL (Hyper-V firewall)` are never changed |
| Hyper-V VMs | `clat-world` (Generation 2), `clat-opn` (Generation 1), note `os-clat lab`, automatic start `Nothing`, automatic stop `ShutDown`, automatic checkpoints off |
| Checkpoints | `clat-base` on both VMs (others only if a test takes one) |
| Named pipes, only while a VM runs | `\\.\pipe\clat-world-com1`, `\\.\pipe\clat-opn-com1` |
| Files | everything in section 3.1 and 3.2, all under `<checkout>\lab\` (`<checkout>` is the top folder of the checkout). No VM file (disk, checkpoint, configuration) lies outside `lab\.work`. Hyper-V's own registration of the VMs and switches exists while the objects exist (in its management service; whether also as files under `C:\ProgramData\Microsoft\Windows\Hyper-V` is UNCONFIRMED) and goes with `Remove-VM` and `Remove-VMSwitch`; `status-lab.ps1` shows after clean-up what is left |
| ACL entries | `NT VIRTUAL MACHINE\<VM id>` on the attached files inside `.work\disks` (by Hyper-V or by `create-lab.ps1`). On the kept files (`base-world-seed.iso`, and the `base-*.vhdx` if Hyper-V adds one there) one entry per lab creation would pile up: `remove-lab.ps1` takes the entry of each VM off the kept files before it removes the VM |
| Log files | `.work\results\hyperv-<UTC>-<script>.log`, one per run of a `hyperv\*.ps1` script |
| Container image store | `alpine:3.22` and `python:3.11-alpine` (pulled for the build if not present) |
| Group membership, in group mode only | `<PC>\<user>` in `BUILTIN\Hyper-V Administrators` |
| Side effects by Windows | a `clat-world.mshome.net` line in `C:\Windows\System32\drivers\etc\hosts.ics` (written by the ICS service) and neighbour-cache entries for `02-C1-A7-00-01-01` |

Not created: host network adapters, NAT rules, firewall rules, services, scheduled tasks, installed software, entries in the user's `~/.ssh`.

---

## 6. Milestones

All commands from Git Bash in `lab/` unless they start with `PS>`. `PS> X` means `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <checkout>\lab\hyperv\X` (`<checkout>` is the top folder of the checkout), run unelevated (group mode) or in an elevated PowerShell (elevated mode: exactly the lines of the table in section 11; `bash lab.sh hvlog` reads the result). A milestone is finished only when every check line holds; the outputs go into `.work/results/first-run.txt`.

### M0. Rights (once)

Section 11. Check, unelevated:

```
whoami /groups | findstr /i "S-1-5-32-578"          -> BUILTIN\Hyper-V Administrators ... Enabled group
powershell -NoProfile -Command "Get-VMSwitch | Select-Object Name,SwitchType"   -> lists Default Switch, no permission error
```

### M1. Assets downloaded, verified, converted

```bash
bash build.sh
```

Steps inside, in this order: (0) stop if `results/lab-state.json` lists a VM and a `base-*` file or the seed would be rewritten (`--force` overrides); (1) free-space check; (2) `curl -fL --retry 3 -C -` the four files into `.work/cache/`; (3) `sha256sum` / `sha512sum` against the two checksum files; (4) once: `ssh-keygen -q -t ed25519 -N "" -C clat-lab -f .work/disks/build/lab_ed25519`, random PPPoE password, console password, API key and secret (`openssl rand -hex`), API secret hash `openssl passwd -6`; (5) render `clat-opn-config.xml` from the template: `@@LAN_IF@@`=`hn0`, `@@WAN_PORT@@`=`hn1`, `@@MGMT_IF@@`=`hn2`, the base64 values as in OPNsense sheet 6.3; render the cloud-init seed; (6) `bzip2 -dc` to `.work/disks/clat-opn.raw`; (7) container `python:3.11-alpine` (`.work` writable, `lab\opnsense` read-only): the `touch` test of section 3.3, `python -I /lab/opnsense/seed_config.py /work/disks/clat-opn.raw` (dry run), then with the config; (8) container `alpine:3.22` (`.work` only): `qemu-img convert -f raw -O vhdx -o subformat=dynamic` for OPNsense, `-f qcow2 -O vhdx -o subformat=dynamic` for Debian, `qemu-img info` on both, `xorriso -as mkisofs -o base-world-seed.iso -V CIDATA -J -r user-data meta-data network-config`; (9) delete the raw file; (10) write `results/assets.txt`. Existing, verified files are reused; secrets are generated once and kept, because the seeded base image contains them.

Checks (printed by the script, one line each):

- `OK sha256 OPNsense-26.7-nano-amd64.img.bz2` and `OK sha512 debian-13-generic-amd64.qcow2`.
- `OK raw 3221225472 bytes`.
- `OK script mount is read-only` (or `FALLBACK script copied into .work`).
- seed dry run: exactly two `factory=True` candidates, one of them `nano=True aligned=True`; then `replaced <n> bytes at offset <o>`. If the script prints `STOP`, the base is built from the unchanged image, `assets.txt` gets `OPN_CONFIG=factory`, and M4 uses Path B.
- `qemu-img info`: `file format: vhdx` for both, virtual size 3 GiB for OPNsense.
- `ls -l .work/disks`: the three `base-*` files exist, `clat-opn.raw` is gone.

### M2. Switches and VMs created

```
PS> create-lab.ps1 -SwitchesOnly
PS> create-lab.ps1 -NoStart
PS> status-lab.ps1
```

In elevated mode one line runs, `create-lab.ps1 -NoStart`: it creates the switches first and ends with the status listing. Never plain `create-lab.ps1` there: it would start both VMs at once, and clat-opn's one-time first boot (file system growth, seeded configuration) would run unobserved while clat-world is not yet provisioned.

Checks (from the output, or in elevated mode from `bash lab.sh hvlog`):

- three lines `created switch clat-... (Private)` and the line `unchanged host network adapters`.
- three lines `rsc clat-...: SoftwareRscEnabled=False`. `True` or an error from `Set-VMSwitch` does not stop the lab: it is recorded, and the capture of M10 decides (section 7 row 22).
- per VM: `created disk`, `created vm <name>: generation <n> ...`, and `ok acl` or `fixed acl` for every attached file.
- status listing: both VMs `Off`; clat-world Generation 2 with adapters nat/mgmt/wan/lan, clat-opn Generation 1 with adapters lan/wan/mgmt, each with the MAC and switch of section 1; `MacAddressSpoofing`, `DhcpGuard`, `RouterGuard` all `Off`; clat-opn's disk on IDE 0 0 with size 16 GB, clat-world's on SCSI with 8 GB and the DVD holding `base-world-seed.iso`; COM1 pipes set.

### M3. clat-world boots, is reachable, its ISP services work locally

```
PS> reset-lab.ps1 -Action Start -VM clat-world
bash lab.sh addr
bash lab.sh w 'cloud-init status --wait; hostname; ip -br link'
bash lab.sh world
bash lab.sh w reboot ; sleep 60 ; bash lab.sh addr ; bash lab.sh world     # second pass: idempotence and boot order
```

Checks:

- `lab.sh addr` prints the address and how it was found. `ssh ... root@clat-world.mshome.net hostname` prints `clat-world` (if the name does not resolve or is stale, the MAC lookup is used and that is recorded; the lab works either way).
- `cloud-init status`: `done`. `ip -br link`: `up0`, `wan0`, `mgmt0` with MACs `...01:01`, `...01:03`, `...01:02`; after `lab.sh world`, `ip -n client -br link` shows `lan0` with `...01:04`.
- `systemctl --failed --no-legend | wc -l` = 0; `systemctl is-active isp-base isp-pppoe isp-nat64 isp-www isp-iperf3 isp-client unbound nftables` = eight times `active`; radvd and kea-dhcp6-server are inactive (no session yet).
- `sh -n /usr/local/sbin/ispctl`, `nft -c -f /etc/nftables.conf`, `unbound-checkconf` exit 0. `nft list chain inet isp input` shows the `mgmt0` drop rule; the last rule of `chain forward` is the `reject with icmpv6 type no-route`.
- DNS, none of it needing the Internet: `dig +short @2001:db8:64::53 ipv4only.arpa AAAA` prints `64:ff9b::c000:aa` and `64:ff9b::c000:ab`; `dig @2001:db8:64::53 ipv4only.arpa AAAA` shows TTL 60. After `ispctl dns64 off`: the AAAA query returns NOERROR with no answer and the SOA in the authority section, the A query returns 192.0.0.170 and 192.0.0.171. Then `ispctl dns64 on` again. If `unbound-checkconf` refuses the `local-data` lines or the answers differ: section 7 row 21.
- Recorded, not required here (first needed in M6, section 7 row 12): `dig +short @10.99.0.1 pkg.opnsense.org A` prints an address.
- `ping -6 -c2 64:ff9b::c058:6301`: 2 received (NAT64 to the local target). `curl -s -o /dev/null -w '%{http_code}' http://192.88.99.1/` = 200.
- `ethtool -k wan0` and `ip netns exec client ethtool -k lan0`: `tcp-segmentation-offload`, `generic-segmentation-offload`, `generic-receive-offload` and `tx-checksumming` are `off` (a feature marked `[fixed]` is recorded).
- `nft list set inet isp provision4` shows no elements.
- after the reboot all of the above again.

### M4. clat-opn boots unattended and is reachable through the jump host

```
PS> reset-lab.ps1 -Action Start -VM clat-opn
bash lab.sh opn-wait
bash lab.sh o 'hostname; opnsense-version; uname -v; for i in 0 1 2; do ifconfig hn$i | grep -E "ether|options"; done; df -h /; netstat -rn -f inet | grep -c "^default"; dmesg | grep -c "exited on signal"'
bash lab.sh api GET /api/core/system/status
```

Checks:

- nobody touched a console; TCP 22 on 10.99.0.2 opens within 15 minutes; the single key login works.
- `clat-opn.internal`; `OPNsense 26.7 ...`.
- `ether 02:c1:a7:00:02:01`, `...:02`, `...:03` on `hn0`, `hn1`, `hn2`. The `options` lines are recorded (OPNsense's defaults switch checksum offload, TSO and LRO off; the seeded configuration does not change them).
- `/` is about 15 to 16 G.
- IPv4 default routes: 0. `exited on signal`: 0.
- the API call returns HTTP 200 with JSON.

If 10.99.0.2 stays silent, the lab finds out why without a login: `W: arping -c2 -I mgmt0 10.99.0.2`, `C: arping -c2 -I lan0 192.168.1.1`, `W: timeout 30 tcpdump -eni wan0 -c3 pppoed` (the PADI's source MAC is the adapter OPNsense uses as WAN port), and the same three probes on the other two links. Answers from unexpected MACs mean the `hn` order differs: reconnect with `Connect-VMNetworkAdapter -VMName clat-opn -Name <adapter> -SwitchName <switch>` so that the adapter that became `hn0` is on `clat-lan`, `hn1` on `clat-wan`, `hn2` on `clat-mgmt`. No answer anywhere means the boot failed: section 7, rows 6 and 7.

Path B (only with `OPN_CONFIG=factory`): the box comes up with LAN = first adapter = 192.168.1.1 and DHCP; then `bash lab.sh c sh /root/web-restore.sh /root/clat-opn-config.xml https://192.168.1.1`, the box reboots, and M4's checks apply.

### M5. OPNsense gets IPv6 over PPPoE and a delegated /56

No action: the seeded configuration dials at boot. Observe within two minutes of M4.

```
bash lab.sh o 'ifconfig pppoe0; grep -E "ipcp|ipv6cp|max-payload|keep-alive" /var/etc/mpd_wan.conf; cat /tmp/pppoe0_prefixv6; route -6 -n get default | grep -E "gateway|interface"; ifconfig hn0 | grep inet6; ping6 -c2 2001:db8:64::53; ping6 -c2 64:ff9b::c058:6301'
bash lab.sh w 'ispctl status; ispctl iface; tail -40 /var/log/isp/pppd.log; journalctl -u kea-dhcp6-server -n 20 --no-pager; ss -ulnp | grep 547; journalctl -k | grep -ci "apparmor.*denied"'
bash lab.sh c ip -br addr ; bash lab.sh c ping -c2 -W2 192.88.99.1
```

Checks:

- `pppoe0` is UP, MTU 1492, has a link-local address and no `inet` line. Whether it also has an address in `2001:db8:a::/64` is recorded, not required (the ISP's line may or may not give one).
- `mpd_wan.conf` has `set bundle disable ipcp` and `set bundle enable ipv6cp`; the `keep-alive` line is recorded (core writes `set link keep-alive 10 60`).
- `/tmp/pppoe0_prefixv6` is `2001:db8:5600::/56`; `hn0` has an address in `2001:db8:5600::/64`.
- IPv6 default route: interface `pppoe0`, gateway `fe80::1%pppoe0`.
- both `ping6` get 2 replies. The second one shows the PLAT is reachable over plain IPv6.
- clat-world: `ispctl iface` prints `ppp0`; IPv6CP up in `pppd.log`, no IPCP negotiated; Kea logs the lease for `2001:db8:5600::/56`; a UDP socket on port 547; no AppArmor denial.
- the client has `192.168.1.1xx/24`; its ping to 192.88.99.1 **fails**. That is the baseline: without the CLAT the LAN has no IPv4.

### M6. Update with the kernel held, tayga package

```
bash lab.sh opn-provision
```

which does:

```
W: ispctl provision on ; systemctl stop isp-pppoe           # no IPv6 default route on OPNsense while pkg runs
O: route add -inet default 10.99.0.1
O: fetch -qo /dev/null https://pkg.opnsense.org/ || printf 'nameserver 10.99.0.1\n' > /etc/resolv.conf
O: nohup sh /root/provision.sh > /root/provision.log 2>&1 &      # then poll the log for "PROVISION DONE rc=0"
     pkg update -f ; opnsense-update -pt opnsense ; pkg install -y tayga
     opnsense-update -b ; opnsense-update -kr 26.7.4 ; opnsense-update -L -k        (section 7, row 14)
O: route delete -inet default 10.99.0.1
W: ispctl provision off ; systemctl start isp-pppoe
O: configctl -d system reboot      ; then lab.sh opn-wait
```

Checks after the reboot:

- `opnsense-version`: 26.7.6 or later packages. `uname -v` contains `n283949-083dc7025377` (the 26.7.4 kernel) and not `n284150-0a7d52ef8757`. `opnsense-update -T -k; echo $?` prints 1.
- `sysctl -n hw.vmbus.tlb_hcall` = 0.
- `pkg query %v tayga` starts with `0.9.6`; `/usr/local/sbin/tayga` exists.
- `dmesg | grep -c 'exited on signal'` = 0.
- the M5 checks hold again.

### M7. Provisioning gateway removed; base checkpoint

```
bash lab.sh o 'netstat -rn -f inet | grep -c "^default"; configctl interface gateways status; ping -c1 -t2 192.88.99.1'
bash lab.sh w 'nft list set inet isp provision4'
bash lab.sh o 'cp /conf/config.xml /root/config.lab-base.xml'      # for the in-guest reset of section 10
PS> reset-lab.ps1 -Action Save -Name clat-base
PS> status-lab.ps1
bash lab.sh addr ; bash lab.sh opn-wait
```

Checks: 0 default routes; the gateway list has no IPv4 gateway; the ping from OPNsense fails with "No route to host"; the nftables set has no elements; the status listing (printed by `reset-lab.ps1` itself, in elevated mode read with `lab.sh hvlog`) shows a checkpoint `clat-base` on both VMs; after the restart the M5 checks hold.

### M8. Plugin installed

```
bash lab.sh plugin install
bash lab.sh o 'configctl clat status; pluginctl -g interfaces.clat; ifconfig tun464; ls -l /etc/rc.conf.d/clat /usr/local/etc/clat/; cat /var/lib/php/tmp/PHP_errors.log 2>/dev/null | tail -5; opnsense-log clat | tail -20'
```

Checks: both "Reloading template" lines end in `OK`; `configctl clat status` reports the service running with a pid; `interfaces.clat` shows `if` = `tun464`, `descr` = `CLAT`; `tun464` exists; `/etc/rc.conf.d/clat` has `clat_enable="YES"`; `clatd.json` exists; no PHP error mentions clat.

### M9. The CLAT activates

```
bash lab.sh st
bash lab.sh o 'netstat -rn -f inet | grep "^default"; pfctl -sn | grep tun464; pgrep -lf tayga; cat /tmp/tun464_router'
```

Checks, with no setting changed after the install: `state` = `active` within 60 s; `pref64.prefix` = `64:ff9b::/96`, `pref64.source` = `ra`; `address.clat6` is an even address in `2001:db8:56ff::/64`; `gateway.default` = true; `nat_rule` = true; `mtu.effective` 1492, `mtu.tun` 1492, `mtu.ipv4` 1472, `mtu.mss` 1432; default route `192.0.0.2` on `tun464`; a `nat on tun464 inet from (hn0:network) ...` line; one tayga process; the router file contains `192.0.0.2`.

**If M9 fails: separate the platform from the plugin before any plugin debugging.** Restore `clat-base` (no plugin), and run items 1 to 4 of DESIGN section 15 by hand with the repository's `docs/lab-spike-runbook.md` (its sections 5 and 6; the shell steps through `lab.sh o`, the two GUI steps 5.4 and 5.5 through `lab.sh gui`): tayga on a tun with a hand-made pass rule, the gateway, default route and automatic NAT rule from an interface record plus router file, end-to-end TCP, UDP and ICMP from the client, MSS and DF. Record per item `works` or `does not work` in `first-run.txt`. If the manual datapath works, the fault is in the plugin; if it does not, it is in 26.7 on this platform or in the design, and the plugin is not what gets debugged first. The runbook is itself untested.

### M10. The LAN client reaches the IPv4 test target

```
bash lab.sh c ping -c3 192.88.99.1
bash lab.sh c curl -sS -o /dev/null -w '%{http_code} %{size_download}\n' http://192.88.99.1/100M.bin
bash lab.sh c ping -c2 -W2 10.255.255.1
bash lab.sh w 'timeout 10 tcpdump -ni ppp0 -c4 "ip6 and host 64:ff9b::c058:6301"' & bash lab.sh c ping -c4 192.88.99.1
bash lab.sh c ping -c3 -s 1232 192.88.99.1 ; bash lab.sh c ping -c3 -s 1233 192.88.99.1
bash lab.sh o 'timeout 12 tcpdump -ni hn0 -c 20 greater 1515' & bash lab.sh c iperf3 -c 192.88.99.1 -t 8
```

Checks:

- 3 replies; `200 104857600`.
- the ping to 10.255.255.1 is answered "Destination Host Unreachable" by 192.0.0.2: the packet followed the default route into `tun464` and tayga refused a private destination under the well-known prefix.
- on `ppp0` the traffic is IPv6 from the CLAT address to `64:ff9b::c058:6301`.
- the fragment pair. `-s 1232` is a 1260-byte packet whose reply the PLAT returns unfragmented; `-s 1233` is the smallest whose reply comes back as two IPv6 fragments. Both answered: `FRAG_RETURN=ok`. Only the second unanswered: `FRAG_RETURN=lost` goes into `first-run.txt` as a finding of its own ("returned IPv6 fragments are lost"); M10 still counts as reached, and section 8 says what that blocks.
- the capture on `hn0` during the upload prints no packet: no frame above 1514 bytes reaches OPNsense's LAN. If it prints some, offloads are still active somewhere (section 7 row 22) and throughput and MSS results are not to be trusted until that is fixed.

After M10: `bash run-tests.sh all`.

Rough times, all UNCONFIRMED: M1 20 minutes, M2 5, M3 15, M4 10, M6 20, a full test run two to two and a half hours including six restores.

---

## 7. What the first run decides

| # | Open point | Primary route | Fallback | Decided by |
|---|---|---|---|---|
| 1 | Private switches without elevation | `create-lab.ps1 -SwitchesOnly` unelevated | run that one command elevated | an error from `New-VMSwitch` |
| 2 | Hyper-V reads qemu-img's VHDX | dynamic VHDX from qemu-img, then `Convert-VHD` | `qemu-img convert -O vpc -o subformat=fixed,force_size`, then `Convert-VHD` to VHDX (UNCONFIRMED) | `Get-VHD` in `create-lab.ps1` |
| 3 | Locally administered static MACs | `02C1A7...` | unused `00155D...` addresses, changed in `lab-common.ps1` and `world/network-config` together | an error from `Add-VMNetworkAdapter` |
| 4 | Debian generic boots as Generation 2 and cloud-init reads the ISO | Generation 2, ISO on SCSI DVD | seed on a small FAT VHDX labelled `CIDATA`; then Generation 1 | no ssh after 5 minutes; console by `vmconnect` |
| 5 | The nano image is as assumed (two factory configs, contiguous, long enough) | Path A | shorten the config (drop `ntpd`, `timeservers`); else Path B | `seed_config.py` dry run in M1 |
| 6 | A Generation 1 VM boots the BSD-labelled disk from IDE | as planned | install from the vga image at the console (extra download), then Path B | Heartbeat in `status-lab.ps1`, the probes of M4, the console |
| 7 | First boot needs no input | Path A | elevated serial reader started before `Start-VM` (OPNsense sheet 5.5) to see COM1; Path C or D | TCP 22 within 15 minutes |
| 8 | `hn` order = add order | lan, wan, mgmt | reconnect adapters to switches (M4) | `ifconfig hnN \| grep ether` |
| 9 | `clat-world.mshome.net` | name | neighbour table by MAC, then KVP | `lab.sh addr` |
| 10 | Kernel-mode PPPoE with pppd 2.5.2; CHAP with mpd5 | `-k -g pppoe.so`, `require-chap` | user-mode PPPoE; `require-pap` | `journalctl -u isp-pppoe`, `pppd.log` in M5 |
| 11 | Kea on a ppp interface under AppArmor; dhcp6c and `NoAddrsAvail` for IA_NA | Kea, prefix only | WIDE `dhcp6s` with the DUID; or `dhcp6prefixonly` on OPNsense's WAN | Kea journal, `/tmp/pppoe0_prefixv6` in M5 |
| 12 | DNS recursion from clat-world through the Default Switch. No longer needed for prefix discovery (row 21); still needed for OPNsense's package download in M6 and for the optional Internet check | unbound recursion | `forward-zone "."` to the DNS server `up0` got by DHCP, **and** `module-config: "dns64 iterator"` (no validator: the ICS proxy does not do DNSSEC) | the recorded `dig` of M3, `pkg update -f` in M6 |
| 13 | Package download on OPNsense through the double NAT, DNS | local unbound | `/etc/resolv.conf` -> 10.99.0.1 for the duration (already in M6) | `pkg update -f` |
| 14 | Kernel | while 26.7.6 is the newest kernel set on the mirror: packages and base current, kernel 26.7.4 locked | if a newer kernel set exists when the lab is built: take packages, base and kernel current and do not lock, because that is what customers will run; go back to 26.7.4 and lock if `dmesg` shows any `exited on signal` within an hour | `fetch -qo - https://pkg.opnsense.org/FreeBSD:15:amd64/26.7/sets/` before M6; the `dmesg` guard in every test |
| 15 | API key seeded as `key\|$6$...` | as seeded (measured: an `openssl passwd -6` hash passes PHP `password_verify`) | create a key in the GUI; or steer by ssh and `configctl` only, which leaves just T14 untested | the API call in M4 |
| 16 | `opn-cfg` (PHP `write_config`) | as described | the web GUI through `lab.sh gui`, by hand | first use in T03b |
| 17 | Frames with a 1508-byte payload cross a private switch | T18's pre-check | jumbo tests reported as not runnable on this link | the ping in T18 |
| 18 | Guest shutdown by `Stop-VM`; checkpoint, restore, start | `reset-lab.ps1` | shut down over ssh, then `-TurnOff`; in-guest reset (section 10) | M7 |
| 19 | OPNsense's unbound can recurse through the CLAT and the double NAT | used by T07b and the Internet check | those two are reported as not run | `drill` on the box while active |
| 20 | `tcpdump`, `drill`, `curl` exist on OPNsense | used | capture on clat-world instead | first use |
| 21 | Unbound accepts the `local-zone` and `local-data` lines of section 2.2 item 4 and answers `ipv4only.arpa` from them, not through the dns64 module | local zone | no local zone: the dns64 module synthesises from the real record, as in the ISP sheet section 6 (needs row 12). T08(c) then runs only if the real TTL is at most 300 s, and T08(a)'s result depends on the host's DNS | `unbound-checkconf` and the `dig` checks of M3 |
| 22 | `Set-VMSwitch -EnableSoftwareRsc $false` works on a private switch without elevation, and no frame above 1514 bytes reaches OPNsense | set in `create-lab.ps1` | run that line elevated; then `Set-VMNetworkAdapter -RscEnabled $false` on the lab adapters (the parameter exists, measured). If oversized frames remain, T24 and the MSS checks are reported with that remark | the `rsc` lines of M2; the `hn0` capture of M10 and T24 |
| 23 | One PPPoE session slot: mpd5 redials successfully although its first attempt after a reset can meet a busy slot | `-N 1` | `-N 8`; every `W:` command then takes the interface from `ispctl iface`, and T16(b) accepts any address in 100.64.0.0/24 | the reconnect time in T11(a) (more than 30 s decides for the fallback); `ispctl iface` in guard T00 |
| 24 | `ping -M probe` sets DF and ignores the cached path MTU; `ip route flush cache` empties the cache in the namespace | as in section 8 | `ip route flush cache` before every single `-M do` probe | T04 step 3 gets 20 errors for 20 probes; `C: ip route get 192.88.99.1` shows no `mtu` after a flush |
| 25 | `iperf3 --dont-fragment` exists in 3.18 (not checked against a source) | used in T04 | the forward MTU is judged by `ping -M probe`, `tracepath` and TCP only | `iperf3 --help` on clat-world |
| 26 | FreeBSD counts received RAs in `netstat -s -p icmp6` under a line "router advertisement" of the input histogram (label not checked against a source) | used in T10 | T10 reports "seen by the NIC; delivery to the ICMPv6 input not shown" | first use in T10 |
| 27 | `Start-Transcript` records everything the `.ps1` scripts print | transcript | the script body runs as `& { ... } *>&1 \| Tee-Object -Append <log>` | the M2 log contains the `created` lines |
| 28 | `icacls <file> /remove "NT VIRTUAL MACHINE\<id>"` removes the entry | as in `remove-lab.ps1` | remove by the raw SID `*S-1-5-83-1-...` as `icacls` prints it | the ACL lines of `status-lab.ps1` after clean-up |
| 29 | wslc honours `:ro` on a volume | read-only script mount | `build.sh` copies `seed_config.py` into `.work/disks/build/` and mounts `.work` only | the `touch` test in M1 |
| 30 | With the PPPoE server stopped, OPNsense loses its IPv6 default route (otherwise `suspended` cannot be reached) | T11(c) and T17(d) as written | none: if the route stays although the PPP link is down, that is recorded as a finding for DESIGN section 9 and the two cases are `fail` with that note | the sampler in T11(c) |

---

## 8. Test matrix

Run by `bash run-tests.sh all` or `bash run-tests.sh T04 T11`. "§15" is the item of DESIGN section 15.

**Reset column.** **H** = restore `clat-base` on both VMs, wait for M5, install the plugin, wait for `active` (T01 installs itself). **S** = `lab.sh soft-reset` (section 3.3): ISP defaults, plugin and Unbound settings back, `configctl clat restart`, client route cache flushed, wait for `active`. Every S test therefore starts with a supervisor whose failure count, back-off, DNS schedule and restart counter are zero and with a tayga that was just started. "from Txx" = no reset; the test continues from the state Txx left and says so.

**Profile P0** = `ispctl defaults`: SLAAC on, PREF64 on (`64:ff9b::/96`, lifetime 1800), DNS64 on, PD `2001:db8:5600::/56`, BNG MTU 1492, IPv4 off, RA interval 600 s.

**Sampler.** Where a transition matters, a loop on clat-opn writes one line per second: time; the content of `status.json` (state, reason, `withdrawn`, `pref64` with `expires`, `tayga.started`, `tayga.restarts`; the word `nofile` while the file does not exist); gateway and interface of the IPv4 default route; interface of the IPv6 default route; `pfctl -sn | grep -c 'nat on tun464'`; the tayga pid (`pgrep -x tayga`); whether `/tmp/tun464_router` exists; mtime of `/tmp/pppoe0_prefixv6`. A ping runs in the client namespace (`ping -D -i 0.5 192.88.99.1`). Times in the criteria are read from those two logs. The sampler never calls `configctl clat details`; `st` is called once per lettered step where a criterion names an `st` field.

**Was tayga restarted?** (decision 27)

- "tayga not restarted" = the same pid in every sample of the step and an unchanged `tayga.started`.
- "tayga restarted once" = the pid changed exactly once, `tayga.started` moved once, and `st.tayga.uptime` at the end is shorter than the step.
- `tayga.restarts` counts only exits the supervisor did not ask for. T13(a) expects plus 1 per kill. Every other test expects it unchanged, which means "tayga did not crash" and nothing more.
- A restart for a changed plan may come up to 60 s after the last tayga start (`RESTART_MIN_INTERVAL`); criteria that wait for one allow for it.

**DF probes from the client** use `ping -M probe` (DF set, the kernel's cached path MTU ignored), one packet per size. Linux caches a path MTU for 10 minutes from the first "frag needed"; with `-M do` every later oversize ping would fail locally and never reach the CLAT, and a later SYN would carry MSS 1432. So `C: ip route flush cache` runs in every soft reset and before every SYN capture, `tracepath` and `iperf3 --dont-fragment` run.

**`FRAG_RETURN`.** The PLAT here (tayga 0.9.2) returns every DF-clear echo reply above 1260 IPv4 bytes as IPv6 fragments. The plugin's own DF probe starts at 1500 bytes and then tries 1280 (clatctl.py 271-295), so all its replies are fragments. The fragment pair of M10 (`ping -s 1232` against `-s 1233`) is repeated in T01 and T04 and written to `env.txt`. With `FRAG_RETURN=lost`, every criterion on the plugin's probe size (T01(8), T04, T14(b), T18) and every "`-s N` answered" for N above 1232 is reported `blocked by FRAG_RETURN`, not `fail`; the forward MTU is then judged by the errors of the DF sweep, by UDP with DF and by TCP.

"**no-PREF64**" in a scenario means: `W: ispctl pref64 withdraw`, wait until the state in `status.json` has left `active` (the reload sends one RA with lifetime 0), then `W: ispctl pref64 off`.

Guard **T00** runs before and after every test: `opnsense-version` and `uname -v` recorded; `dmesg | grep -c 'exited on signal'` = 0; no IPv4 default route other than through `tun464`; no IPv4 gateway other than `CLAT_GW`; provisioning set empty; kernel lock present; `W: ispctl iface` prints `ppp0` (or nothing where the test left no session). A failed guard makes the result of that test "invalid", not "failed".

| ID | §15 | Reset | Scenario | Measured where | Pass criteria |
|---|---|---|---|---|---|
| T01 | 6, 8, 1 | H (no plugin) | Install on a clean box; activation by PREF64 only. `W: ispctl dns64 off`. Capture RS/RA on `ppp0`. Start the sampler. `install-plugin.sh install`. Change nothing else. After `active`: the fragment pair | O: sampler for 60 s, `st` once at the end; number of files in `/conf/backup` at install end and 60 s after `active`; `ps` of tayga. W: pcap read with scapy. C: fragment pair | (1) both template lines `OK`, no PHP error; (2) state `active` within 60 s; (3) `st.pref64` = `64:ff9b::/96`, source `ra`, lifetime between 1 and 1800; (4) `clat6` even, inside `2001:db8:56ff::/64`; `gateway.default` and `nat_rule` true; (5) pcap: 1 to 3 RS from OPNsense, then an RA addressed to OPNsense's link-local address that contains option 38; (6) one tayga, user `nobody`; (7) no file added to `/conf/backup` after the install finished; (8) `configctl clat test` answers "No test target is set."; after setting `test_target` to 192.88.99.1 through the API the first two tests are `ok`, and the size test is `ok` with 1472 (`blocked by FRAG_RETURN` if the fragment pair failed) |
| T02 | 2, 3 | S | pf while a client flow runs: `C: curl --limit-rate 2M http://192.88.99.1/100M.bin` | O: `pfctl -sr`, `pfctl -sn`, `pfctl -ss -v`; `/tmp/rules.debug` if `pfctl -sr` does not list the scrub lines | (1) exactly one rule `pass in [log] quick on tun464 inet6 ... keep state label ...`; (2) no rule on `tun464` contains `reply-to` or `route-to`; the plugin's rule is not IPv4; (3) the rule stands before every user rule in `pfctl -sr`; (4) at least one line `nat on tun464 inet from (hn0:network) to any ... -> (tun464:0...)`; (5) states: on `tun464` one whose source is `192.0.0.1:<port> (192.168.1.x:<port>)` to `192.88.99.1:80`, and IPv6 states `clat6 -> 64:ff9b::c058:6301` on `tun464` and on `pppoe0`; no state on `tun464` with a 192.168.1.x source that is not translated; (6) `scrub on tun464 inet6 ... max-mss 1432` present (core derives it from `mss` 1492 minus 60) |
| T03 | 2, 1, 7 | S | Gateway, default route, datapath for TCP, UDP, ICMP, the firewall's own IPv4, the strict-prefix refusal, the bypass | O: `netstat -rn -f inet`, `configctl interface gateways status`, `/tmp/tun464_router`, `ifconfig tun464`, `netstat -rn -f inet6`, `ping -c3 192.88.99.1`. C: curl 100 MB, `iperf3 -c 192.88.99.1 -u -b 5M -t 5`, ping, `ping -c2 -W2 10.255.255.1`, `ping -c2 -W2 10.99.0.1`. W: counter of the `mgmt0` drop rule | exactly one IPv4 default route: gateway `192.0.0.2`, interface `tun464`; exactly one IPv4 gateway, `CLAT_GW`; router file `192.0.0.2`; `tun464` has `inet 192.0.0.1 --> 192.0.0.2 netmask 0xffffffff` and "Opened by PID" = tayga; one `/127` route for the CLAT pair on `tun464`; neither address of the pair is configured on any interface; OPNsense's own ping 3 of 3; client: HTTP 200 with 104857600 bytes, UDP loss at most 1 %, ping 3 of 3; the ping to 10.255.255.1 is answered "Destination Host Unreachable" from 192.0.0.2; the ping to 10.99.0.1 gets no reply and the drop counter on clat-world grows by 2 (it left by `hn2`, the bypass of section 1) |
| T03b | 3 | S | Interface-bound states. `opn-cfg set system.state-policy 1` (any non-empty value makes `filter.inc` 329 emit the line), `O: configctl filter reload`, `O: grep 'set state-policy if-bound' /tmp/rules.debug`, `O: configctl clat restart` (so that every CLAT state is made under the new policy), wait for `active`. Then the client flow of T02 and the client checks of T03. Afterwards `opn-cfg unset system.state-policy`, reload | O: `/tmp/rules.debug`, `pfctl -ss -v` during the flow. C: curl, iperf3 UDP, ping | the `set state-policy if-bound` line is present; the states of T02(5) exist and show `tun464` or `pppoe0` as their interface, none of them `all`; HTTP 200 with 104857600 bytes, UDP loss at most 1 %, ping 3 of 3; no `reply-to` on the plugin's rule; after the unset the line is gone and ping is 3 of 3 |
| T04 | 4 | S | MSS and DF at PPP MTU 1492, in this order. (1) `C: ip route flush cache`, then SYN and SYN-ACK captured during a curl, before any DF probe. (2) Fragment pair `ping -c3 -s 1232`, `-s 1233`. (3) DF sweep: `ping -M probe -c1 -W2 -s N` for N = 1444, then each N from 1445 to 1464. (4) flush, `tracepath -4 -n`. (5) flush, `iperf3 -u --dont-fragment -b 5M -l 1444`; flush, the same with `-l 1445` (without `--dont-fragment` Linux fragments locally after the first error and both sizes pass). (6) `O: configctl clat test` | C: `tcpdump` on `lan0`, ping output, tracepath, iperf3. W: `tcpdump` on `ppp0` for the IPv6 SYN; iperf3 server log | (1) client SYN leaves with MSS 1460; the SYN on `ppp0` has MSS 1432; the SYN-ACK reaching the client has MSS 1432. (2) both answered, else `FRAG_RETURN=lost` and the finding "returned IPv6 fragments are lost". (3) `-s 1444` (1472 bytes) answered (`blocked by FRAG_RETURN` otherwise); each of the 20 sizes from 1473 to 1492 bytes gets its own "Frag needed and DF set (mtu = 1472)", 20 of 20, and the sender is recorded (expected 192.0.0.2). (4) pmtu 1472. (5) at 1472 bytes at most 1 % loss; at 1473 bytes no datagram reaches the server. (6) the plugin's DF probe reports 1472 (`blocked by FRAG_RETURN` otherwise) |
| T05 | 5 | S | Dormant interface is inert. `W: ispctl dns64 off`, then no-PREF64. Observe 15 minutes | O: sampler every 10 s; `/conf/backup` count; mtime of `/tmp/rules.debug`; line counts of `opnsense-log clat` and of configd log lines naming clat, filter reload or newip; CPU time of clatd; API interface overview | whole window: state `listening`, reason `no_nat64_prefix`; no `CLAT_GW`; no NAT line on `tun464`; no IPv4 default route; no router file; `tun464` exists without an `inet` address; no tayga; `/conf/backup` count unchanged; `rules.debug` not rewritten; 0 new clat log lines after the state change; 0 configd actions caused by clat; clatd CPU time grows by less than 2 s; the interface list shows CLAT without an IPv4 address; `ping6` from OPNsense to `2001:db8:64::53` still works |
| T06 | 6 | S, DNS64 off | PREF64 lifetime. (a) `ispctl pref64 withdraw` while active. (b) `ispctl pref64 on 64:ff9b::/96 64`, wait for `active`, `ispctl pref64 off`. (c) active with lifetime 1800, then `ispctl pref64 on 2001:db8:64:ff9b::/96 1800`. (d) `ispctl set RA_UNSOLICITED off; ispctl apply`, then `O: configctl clat restart`. (e) `ispctl set RA_INTERVAL 20; ispctl pref64 on 64:ff9b::/96 64` for 3 minutes | O: sampler, `st` once per step. W: pcap of RAs with timestamps; start time of `kea-dhcp6-server` | (a) `listening` / `no_nat64_prefix` within 10 s of the RA with lifetime 0; default route and NAT line gone; no state for 192.0.0.1; (b) still `active` 30 s after `pref64 off` (an RA without the option does not withdraw); deactivation between 64 and 80 s after the last RA that carried the option; (c) after 60 s `st.pref64.prefix` is still `64:ff9b::/96` and tayga was not restarted; (d) `active` within 30 s; the pcap shows an RS and a unicast RA with option 38 and no multicast RA; Kea's start time did not change (`apply` no longer restarts it); (e) `pref64.expires` is always in the future, state stays `active`, tayga not restarted. In all steps `tayga.restarts` unchanged |
| T07 | 6 | S | DNS discovery on a default box. No-PREF64 (DNS64 stays on at the ISP). OPNsense untouched: Unbound recursive. 5 minutes. (b) only if section 7 row 19 holds: while active by RA with lifetime 64, `O: drill AAAA ipv4only.arpa @127.0.0.1`, then `ispctl pref64 off` and wait for expiry | O: sampler, `drill AAAA ipv4only.arpa`, clat log | (a) `listening` / `no_nat64_prefix` for the whole 5 minutes; no `CLAT_GW`; the lookup returns no AAAA record (the answer code is recorded: here SERVFAIL is expected because the lab has no IPv6 Internet; a real line gives an empty answer); (b) the lookup returns NOERROR with no AAAA; after expiry the state is `listening` and stays so for 3 minutes |
| T08 | 6 | from T07 (PREF64 off, ISP DNS64 on, the plugin's DNS retry already backed off) | DNS discovery, four steps. Pre-check `O: cat /etc/resolv.conf; ls /tmp/*nameserver*` shows `2001:db8:64::53` learned from the RA (if not: enter it as system DNS server with `opn-cfg` and record that). (a) "Use System Nameservers": API `POST /api/unbound/settings/set {"unbound":{"forwarding":{"enabled":"1"}}}`, `POST /api/unbound/service/reconfigure` (field name from the model file; the payload is confirmed by its first use). (c) `W: ispctl dns64 off`. (d) "DNS64 in Unbound with forwarding": the ISP's DNS64 stays off; API `{"unbound":{"general":{"dns64":"1"}}}`, reconfigure. Then `general.dns64` 0, reconfigure, `W: ispctl dns64 on`, wait for `active` with source `dns`. (b) `W: ispctl pref64 on` | O: `drill AAAA ipv4only.arpa @127.0.0.1` per step, sampler, `st` once per step. C: ping | (a) the lookup returns `64:ff9b::c000:aa` and `64:ff9b::c000:ab`; `active` within 330 s of the reconfigure with nothing else done (after T07's failures the plugin's next query can be 300 s away; the measured latency is recorded, it is what a customer waits after ticking the box); `st.pref64` = `64:ff9b::/96`, source `dns`, lifetime null; client ping 3 of 3. (c) within 130 s of `dns64 off` (TTL 60 + refresh interval 60 + 10): `pref64` null, `listening` / `no_nat64_prefix`, default route and NAT line gone; the time is recorded. (d) the lookup returns the two addresses, now synthesised by OPNsense's own Unbound; `active` within 130 s of the reconfigure, source `dns`; ping 3 of 3. (b) within 30 s the source becomes `ra`; tayga not restarted (same prefix). `tayga.restarts` unchanged throughout |
| T09 | 6 | S | Static prefix. `W: ispctl dns64 off`, no-PREF64 -> `listening`. (a) API: `settings/set {"clat":{"general":{"prefix":"64:ff9b::/96"}}}`, `service/reconfigure`. (b) `W: ispctl pref64 on 2001:db8:64:ff9b::/96`. (c) API prefix `2001:db8:5600:ff00::/96`. (d) no-PREF64 again, then API prefix empty | O: `st`. C: ping | (a) `active` within 30 s; source `static`, lifetime null; ping 3 of 3; (b) after 60 s the prefix is still `64:ff9b::/96`, source `static`; (c) `blocked`, reason `pref64_overlap`, the message names the prefix, no `CLAT_GW`; (d) `listening` / `no_nat64_prefix` within 30 s of the reconfigure |
| T10 | 6 | S | Forged RA from the LAN, sent with the BNG's own address as source, so that only the interface check of `accept_ra()` (discovery.py 96-104) stands between it and acceptance. `R` = the gateway printed by `O: route -6 -n get default`, without the zone (expected `fe80::1`). The script sends hop limit 255. Per case two preconditions, else the case is void: `O: tcpdump -ni hn0 -c1 'icmp6 and ip6[40]==134'` sees a frame (if not: RouterGuard), and the "router advertisement" input counter of `O: netstat -s -p icmp6` grows by the number sent. (a) dormant (`ispctl dns64 off`, no-PREF64): `C: python3 /usr/local/lib/isp/send-ra-pref64.py --src R --prefix 64:ff9b::/96 --count 3`. (b) active by RA: `--src R --prefix 2001:db8:bad:64::/96`. (c) active: `--src R --prefix 64:ff9b::/96 --lifetime 0`, then `--lifetime 65528`. (d) separate case, reported as such: (a) and (c) once more with the script's default source `fe80::bad:64` (rejected by the source test alone) | O: `status.json` before and 30 s after each send; tayga pid; `route -6 -n get default`; the counter. C: ping during (b) and (c) | (a) still `listening`, `pref64` null, no tayga; (b) prefix and source unchanged, tayga not restarted, 0 of 20 pings lost; (c) the prefix is still there after the forged withdrawal, `pref64.expires` is the same value before and after both sends, state `active`, tayga not restarted, 0 of 20 lost; (d) as (a) and (c). In every case the IPv6 default route is still on `pppoe0` through `R`, and `tayga.restarts` is unchanged |
| T11 | 8 | S | PPPoE session loss. (a) `W: ispctl session reset`. (b) `W: ispctl session drop` (no PADT, no terminate). (c) suspend, the standard customer: `W: systemctl stop isp-pppoe`, wait 45 s, `W: systemctl start isp-pppoe` | O: sampler 300 s per step. C: ping log. W: `/run/isp/session`, `pppd.log` | (a) `active` no later than 30 s after `/tmp/pppoe0_prefixv6` was rewritten by the new session; `clat6` unchanged; tayga not restarted; pings answered again within 10 s of `active`; no sample with an IPv4 default route present and the NAT line absent; afterwards no untranslated 192.168.1.x state on `tun464`; the time from the reset to the new session is recorded (section 7 row 23). (b) recorded: how long OPNsense needs to notice (core writes `set link keep-alive 10 60`, so up to 60 s, during which the state stays `active` and pings are lost); `suspended` is expected only if the IPv6 default route is missing for more than 15 s; after the reconnect `active` within 30 s of the prefix file being rewritten; tayga not restarted. (c) `suspended` between 15 and 30 s after the IPv6 default route disappeared, `withdrawn` false; from then until the start, in every sample: router file present, `192.0.0.1` on `tun464`, IPv4 default route on `tun464`, NAT line present, same tayga pid; after the start `active` within 30 s of the prefix file being rewritten, tayga not restarted, pings answered again. `tayga.restarts` unchanged in all three |
| T13 | 8 | S | tayga crash: `O: pkill -KILL -x tayga`, three times, each after `active` returned. (b) `O: kill -KILL $(cat /var/run/clat.pid)`, later `configctl clat start` | O: sampler, `st`, `pgrep`. C: ping log | (a) each time: router file absent while no tayga runs; `active` again within 20 s, 25 s and 45 s (back-off 5, 10, 30 s plus start; this presupposes a failure count of 0, which the soft reset's service restart gives); `tayga.restarts` plus 1 each; exactly one tayga afterwards; pings resume; (b) no tayga process 5 s after the kill; `st.state` = `stopped`; after `start`: `active` within 60 s, one clatd, one tayga |
| T14 | 8 | S | API. (a) `GET /api/clat/service/status`. (b) `POST /api/clat/service/test`. (c) `settings/set` `mss_offset` 20, `service/reconfigure`. (d) `mss_offset` empty again and `ipv6_mtu` 1400, reconfigure. (e) `enabled` 0, reconfigure. (f) `enabled` 1, reconfigure. (g) `prefix` = `banana` | W: HTTP codes and bodies. O: sampler, `pfctl -sr`, `ifconfig tun464`, `pluginctl -g interfaces.clat`, `/etc/rc.conf.d/clat`. C: DF probes (`ping -M probe`) | (a) 200, service running, state `active`; (b) the first two tests `ok`; the size test `ok` with 1472 (`blocked by FRAG_RETURN` otherwise); (c) result saved, clatd pid unchanged, tayga not restarted, scrub on `tun464` inet6 now `max-mss 1412`; (d) within 75 s of the reconfigure (the restart waits until 60 s after the last tayga start): `tun464` MTU 1400, `st.mtu.ipv4` 1380, MSS 1340, tayga restarted once, `tayga.restarts` unchanged; then `-s 1352` answered (`blocked by FRAG_RETURN` otherwise) and `-s 1353` gets "mtu = 1380"; (e) `st.state` = `disabled`; no clatd, no tayga; `interfaces.clat` gone; no rule and no NAT line on `tun464`; no IPv4 default route; `clat_enable="NO"`; (f) `active` within 60 s with the same `clat6` as before (e); (g) the API answers with a validation error and the stored value is unchanged |
| T15 | 8, 6 | S | Reboot. (a) `O: configctl -d system reboot`. (b) the same in the DNS-only configuration: no-PREF64 (ISP DNS64 on), Unbound forwarding on as in T08(a), wait for `active` with source `dns`, then reboot | O after boot: sampler from the first ssh login, `/conf/backup` count before and after, `dmesg`. C: ping log | (a) with no manual step: `active` within 60 s of the first possible login (the absolute time from power-on to the first answered client ping is recorded); `/conf/backup` count unchanged across the boot; 0 `exited on signal`; kernel as before; ping 3 of 3. (b) with no manual step: `active` with source `dns` no later than 420 s after the IPv6 default route appeared (the plugin retries a failed query after 10, 30, 60 and 300 s); the time is recorded, and more than 120 s is reported as a finding (a customer on a DNS64-only line waits that long after every reboot); ping 3 of 3 |
| T22 | 7 | S | WAN without a SLAAC address: `W: ispctl slaac off; ispctl session reset` | O: `ifconfig pppoe0`, `st`. C: ping, 100 MB download | `pppoe0` has only a link-local IPv6 address; `active`; `clat6` in the delegated prefix; ping 3 of 3; download complete |
| T24 | 11 | S | Throughput, informational: `C: iperf3 -c 192.88.99.1 -t 10` and `-R`; during the first, `O: timeout 12 tcpdump -ni hn0 -c 20 greater 1515` | C: Mbit/s. O: `top -b -d 2` lines for tayga and clatd; the capture | no criterion for the numbers; they are recorded with the remark that this is a VM on the lab host and says nothing about customer hardware. The capture must print no packet; if it does, the numbers carry the remark "offloads active" (section 7 row 22) |
| T12 | 7, 8 | S; last of the S group | Renumbering. (a) `W: ispctl pd 2001:db8:5700::/56; ispctl session reset`. (b) a single /64: `opn-cfg set interfaces.wan.dhcp6-ia-pd-len 0`, `O: configctl interface reconfigure wan`, `W: ispctl pd 2001:db8:5800:1::/64; ispctl session reset`. At the end the length is set back to 8; the next test starts with an H reset anyway | O: sampler, `st`, `netstat -rn -f inet6`, `pfctl -ss`. W: `tcpdump` on `ppp0`. C: ping log | (a) prefix file = `2001:db8:5700::/56`; `clat6` inside `2001:db8:57ff::/64` within 120 s of the prefix file changing (the restart rate limit is 60 s); tayga restarted once, `tayga.restarts` unchanged; only the new `/127` on `tun464`; no state with a `2001:db8:56ff:` address; translated packets on `ppp0` carry the new source; pings answered afterwards. (b) prefix file = `2001:db8:5800:1::/64`; `active` within 150 s; `clat6` inside `2001:db8:5800:1::/64`; ping 3 of 3; 100 MB download complete; whether the LAN kept an IPv6 address is recorded |
| T16 | 10 | H | Native IPv4 through IPCP. (a) `W: ispctl ipv4 on; ispctl session reset` with WAN IPv4 None. (b) `opn-cfg set interfaces.wan.ipaddr pppoe`, `O: configctl interface reconfigure wan`. (c) from (b): `opn-cfg unset interfaces.wan.ipaddr`, reconfigure. (d) again (b), then `W: ispctl ipv4 off; ispctl session reset` (WAN type PPPoE without IPCP: what the setup wizard produces) | O: sampler, `ifconfig pppoe0`, `st`, routes. W: `pppd.log`, journal line of `ip-up.d/50-isp`, `tcpdump -ni ppp0 icmp`. C: ping | (a) `pppoe0` gets no IPv4 address; state returns to `active`; (b) `pppoe0` has 100.64.0.2; `native-ipv4` (reason `uplink`) within 10 s of the address; no tayga, no `CLAT_GW`, default route on `pppoe0`; the client's ping is answered and crosses `ppp0` as IPv4; preflight shows the warning `wan_ipv4_ppp_native`; (c) state `native-ipv4` with reason `hold`, then `active` between 60 and 150 s after the IPv4 address disappeared; (d) `blocked`, reason `wan_ipv4_ppp`, the message says to set IPv4 Configuration Type to None; the CLAT is not active. Whether IPv6 came up at all in (d) is recorded (DESIGN finding 6 expects that it does not) |
| T17 | 10 | H | Static IPv4 gateway on MGMT as a second WAN. (a) API `routing/settings/add_gateway` (name `LABGW`, interface `opt1`, 10.99.0.1, priority 255, not upstream, monitor off), `routing/settings/reconfigure`. (d) suspend with fail-over, from the (a) state: `W: systemctl stop isp-pppoe`, wait 45 s, `W: systemctl start isp-pppoe` (`facts.php` 230-236 reports `LABGW` as `fallback`: another IPv4 gateway with an address, on a device that has IPv4). (b) set it upstream (`defaultgw` 1), reconfigure. (c) delete it, reconfigure, and `route delete -inet default 10.99.0.1` if core left the route (recorded) | O: sampler, `st`, routes, `pfctl -ss` | (a) stays `active`, default route stays on `tun464`; (d) `suspended` between 15 and 30 s after the IPv6 default route disappeared, with `withdrawn` true, IPv4 default route through 10.99.0.1, no router file, tayga still running with the same pid; after the start: `active` within 30 s of the prefix file being rewritten, default route back on `tun464`, tayga not restarted, no untranslated 192.168.1.x state on `tun464`, ping 3 of 3; (b) `native-ipv4` (reason `gateway`) within 15 s; no `CLAT_GW`; default route by 10.99.0.1; no tayga; (c) `native-ipv4` / `hold`, then `active` between 60 and 150 s later, default route on `tun464` |
| T18 | 9 | H | Jumbo, WAN MTU field 1508 against an echoing BNG. `W: ispctl mtu 1500`. `opn-cfg set interfaces.wan.mtu 1508`, `O: configctl interface reconfigure wan`. Capture discovery: `W: tcpdump -eni wan0 -vv 'ether proto 0x8863'`. **Link pre-check**, once `ppp0` is up with MTU 1500: `W: ping -6 -c2 -M do -s 1452 <OPNsense link-local>%ppp0` (if `ppp0` is not at 1500, the cause is the negotiation, to be read from the capture, and not the switch). Then `W: ispctl session reset` | O: `ifconfig hn1`, `ifconfig pppoe0`, `st`, `configctl clat test`. W: pcap, `ip link show ppp0`. C: DF probes (`ping -M probe`, cache flushed), SYN capture | pre-check answered (a 1500-byte IPv6 packet crossed the private switch); if not, T18 to T20 are reported "not runnable on this virtual link" and stop. `hn1` MTU 1508; PADI and PADR carry PPP-Max-Payload 1500 and PADO and PADS return 1500; `pppoe0` and `ppp0` MTU 1500; `st.mtu`: effective 1500, tun 1500, ipv4 1480, mss 1440; `-s 1452` answered (`blocked by FRAG_RETURN` otherwise), `-s 1453` gets "mtu = 1480"; SYN on `ppp0` has MSS 1440; the DF probe reports 1480 (`blocked by FRAG_RETURN` otherwise); all of this still holds after the session reset |
| T19 | 9 | from T18 | Field 1508 against a BNG that does not echo: `W: ispctl mtu 1492` | as T18 | confirm or refute DESIGN 8.3 defect C: recorded are the tag in PADI, its absence in PADS, the MTU of `ppp0` (expected 1492) and of `pppoe0` (expected 1500), and whether 1493 to 1500-byte IPv6 packets from OPNsense vanish without an ICMP error. Criterion for the plugin: its DF probe reports at most 1472 although configured and effective MTU agree; state stays `active`; no restart loop (the tayga pid changes at most once) and no crash (`tayga.restarts` unchanged) |
| T20 | 9 | from T19 | Fields 1518 and 1528, each with `W: ispctl mtu 1500` | as T18 | recorded per field: the PPP-Max-Payload value in PADI (expected 1510 for 1518; no tag for 1528 = defect A), what the BNG returns (1500, not an echo), the MTU of `hn1`, `pppoe0` and `ppp0`, and the DF probe result. Criterion for the plugin as in T19, per field. Defect B (1501 to 1510 lost at reconnect) cannot be shown: the simulator never grants more than 1500 |
| T23 | D5 | H, optional | Outbound NAT mode manual: `opn-cfg set nat.outbound.mode advanced`, `O: configctl filter reload`; then API `manual_nat` 1, reconfigure | O: `st`, `pfctl -sn` | `blocked`, reason `nat_mode`, within 90 s; after `manual_nat`: `active`, and the status says the NAT rule is missing |
| T21 | 8 | H | Plugin removal: `install-plugin.sh remove`; then `install` again | O: `ifconfig tun464`, `pgrep`, `pluginctl -g interfaces.clat`, `pfctl -sr`, `pfctl -sn`, routes, gateway list, `ls` of the leftover paths | after removal: `tun464` does not exist; no clatd, no tayga; `interfaces.clat` empty; no rule and no NAT line naming `tun464`; no IPv4 default route; no `CLAT_GW`; `ping6` to `2001:db8:64::53` works; left behind are exactly `/etc/rc.conf.d/clat`, `/usr/local/etc/clat/`, `/var/run/clat/`, `/var/log/clat/` and the `<clat>` node in `config.xml`. After the second install: `active` within 60 s |
| T25 | 8 | S, by hand | Record drift: open `https://127.0.0.1:8443` (`lab.sh gui`), Interfaces > Assignments, save and apply the CLAT entry; also look at Services > CLAT | O: `pluginctl -g interfaces.clat`, clat log, `st` | within 5 minutes the supervisor has run the registration again (`type` and `internal_dynamic` are back, `ipaddr` is not `none`), the gateway is named `CLAT_GW` and the state is `active`. Not automated |

Order of a full run: T01, T02, T03, T03b, T04, T22, T05, T06, T07, T08, T09, T10, T11, T13, T14, T15, T24, T12, then with a restore before each group: T16; T17; T18 to T20; T23; T21. Only T23 and the hand test T25 are optional; T12(b) and T17 are part of every full run. `summary.tsv` has one line per test: id, `pass` / `fail` / `blocked (reason)` / `invalid` / `skipped (reason)`, seconds, note. A test whose precondition is an open point of section 7 reports `skipped` with that point, never `pass`.

How the matrix covers DESIGN section 15: item 1 T01, T03 (and the manual fallback of M9); item 2 T02, T03; item 3 T02, T03b; item 4 T04; item 5 T05; item 6 T01, T06 to T10, T15(b); item 7 T03, T12, T22; item 8 T11, T12(a), T13, T14, T15, T21, T25; item 9 T18 to T20; item 10 T16, T17; item 11 T24 (informational only).

---

## 9. What cannot be tested here and stays for a real line

1. **The real BNG.** Its RA flags and interval, whether solicited RAs carry PREF64 and with which lifetime, whether RDNSS addresses are global or link-local, how it refuses IPCP, whether mpd5 authenticates against it, how it treats a redial that arrives before the old session is closed. The simulator's values are assumptions.
2. **PPP MTU above 1500.** rp-pppoe 4.0 and pppd 2.5.2 stop at 1500. Not testable: DESIGN 8.3 defect B, the rows 1520 and 1528 of the table in 8.1 (a 1500-byte IPv4 MTU), the echo of a value above 1500, the post-fix fields 1528 and 1536.
3. **The ISP's NAT64.** ICMP echo translation, fragment handling, its IPv6 MTU. The lab's PLAT is tayga 0.9.2, which returns every DF-clear packet above 1260 bytes as IPv6 fragments; whether the plugin's DF probe gets its replies as fragments on the real network is unknown.
4. **IPv6 Internet.** The Default Switch gives IPv4 only. Not testable: DNS64 enabled in OPNsense's own Unbound in recursive mode (it needs IPv6-reachable authoritative servers before the CLAT is up; the variant with forwarding is T08(d)), the empty-answer flavour of "default box" before any activation, firmware and plugin download over an IPv6-only line, the ISP repository of DESIGN 14.
5. **The real `ipv4only.arpa` answer.** The lab serves the name from local data with TTL 60. The TTL a real DNS64 resolver returns, and with it how long the plugin keeps a DNS-learned prefix after the resolver stops synthesising, is not exercised.
6. **The package.** `make package`, `make lint`, `make style`, `pkg add`, `pkg upgrade`, `pkg delete` and the order in which pkg runs the `+PRE_DEINSTALL` and `+POST_*` scripts on an upgrade need a clone of opnsense/plugins, which this plan does not use. The lab runs the same script lines by hand. Also not testable: the 26.7 to 27.1 series upgrade.
7. **The customer's kernel.** The stock 26.7.6 kernel cannot be used on Hyper-V; the lab runs kernel 26.7.4 with 26.7.6 packages and base, and Hyper-V's `hn` NICs instead of real ones.
8. **Throughput and CPU** on customer hardware (§15 item 11).
9. **A second WAN with DHCP** (§15 item 10, the DHCP half). The static second gateway, including suspend with fail-over to it, is T17.
10. **Long-running behaviour**: renewals at real lifetimes over days, PREF64 refresh over days, a host that sleeps.
11. **The GUI** (settings page, status panel, log view) is only looked at by hand (T25); nothing checks it automatically.
12. **Physical-layer matters**: VLAN-tagged PPPoE, the MTU of a real NIC or ONT, hardware offloads.

---

## 10. Reset between tests; clean-up

**Hard reset (primary).** `PS> reset-lab.ps1 -Action Restore -Name clat-base`: turns both VMs off, restores the off-state checkpoint on both, starts clat-world, then clat-opn. Then `lab.sh addr`, `lab.sh opn-wait`, the M5 checks, `lab.sh plugin install`. The checkpoint is taken with both VMs shut down so that no PPPoE session, lease or clock state is frozen into it. It contains: updated OPNsense with tayga and the held kernel, no plugin, no IPv4 route; clat-world fully installed with profile P0. After a change to the ISP files or to `provision.sh` the checkpoint is taken again (`-Action Save`); a change to the plugin needs no new checkpoint.

**Soft reset.** `lab.sh soft-reset` (section 3.3) between the tests of one group. It restores the ISP and the settings, restarts the plugin's service and flushes the client's route cache, so no test inherits the supervisor's failure count, back-off, DNS schedule or restart counter, or the client's cached path MTU. A test that deliberately continues from another (T08 from T07, T19 from T18, T20 from T19) says so in the Reset column and skips it.

**Without Hyper-V rights (elevated mode).** The runner cannot restore. With `--reset guest` (the default there) it uses an in-guest reset for every H: `install-plugin.sh remove`, `rm -rf /usr/local/etc/clat /var/run/clat /var/log/clat /etc/rc.conf.d/clat`, copy the saved `/root/config.lab-base.xml` (taken at M7) back to `/conf/config.xml`, reboot; `W: ispctl defaults`. This goes beyond what a package removal does and is weaker than a checkpoint; the report says which reset each run used. With `--reset manual` the runner stops before each H group, prints `WAITING FOR RESTORE` with the command line of section 11, and continues by itself once clat-world has stopped answering and answers again.

**Complete clean-up.**

1. `PS> remove-lab.ps1` : takes each VM's ACL entry off the kept `base-*` files, removes the two VMs (with their checkpoints), the three switches, every `clat-*` file and folder under `.work\disks`, and `results\lab-state.json`. It touches only objects that have the `clat-` prefix **and** the note `os-clat lab` (switches also: type Private). Run it again after a minute if it reports a locked file (checkpoint merge). Use the same mode (elevated or not) that created the lab.
2. `PS> status-lab.ps1` : no lab switch, no lab VM, no `clat-*` file; no file named after a lab VM id under `C:\ProgramData\Microsoft\Windows\Hyper-V` (or "not readable", then look once from the elevated console); the ACLs of the kept files show no `NT VIRTUAL MACHINE` entry and no unresolved `S-1-5-83-...` SID; `Get-NetAdapter` as before.
3. Delete `<checkout>\lab\.work` to remove downloads, base images, keys, secrets, logs and results (about 4 GB at that point). To rebuild later without downloading, keep `cache\`.
4. `wslc.exe image rm alpine:3.22`, and `wslc.exe image rm python:3.11-alpine` unless something else uses it.
5. If the group was joined only for the lab: elevated `Remove-LocalGroupMember -SID 'S-1-5-32-578' -Member '<PC>\<user>'`, then sign out and in.
6. Left by Windows itself and harmless: a stale `clat-world.mshome.net` line in `hosts.ics`.

---

## 11. Steps done by hand

1. **Choose how Hyper-V is driven.**
   - **Group mode (recommended), once:** in an elevated PowerShell `Add-LocalGroupMember -SID 'S-1-5-32-578' -Member '<PC>\<user>'`, then sign out of Windows and sign in again (a lock is not enough; programs started before the sign-in keep the old token). From then on everything runs unelevated, including resets. To know: after this, any program running as this user can control Hyper-V without a UAC prompt.
   - **Elevated mode, without the group:** the lines of the table below are run in an elevated PowerShell, each at the step named. Every line is `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <checkout>\lab\hyperv\<script> <arguments>`. Each script writes what it printed to `.work\results\hyperv-<UTC>-<script>.log`; `bash lab.sh hvlog` reads that file, and everything else runs over ssh.

   | When | Script and arguments | What is read or done next |
   |---|---|---|
   | M2, after `build.sh` | `create-lab.ps1 -NoStart` | the `created switch`, `rsc`, `created vm`, `acl` lines and the status listing. Never plain `create-lab.ps1` (it starts both VMs at once) |
   | M3 | `reset-lab.ps1 -Action Start -VM clat-world` | `lab.sh addr`, `lab.sh world` |
   | M4 | `reset-lab.ps1 -Action Start -VM clat-opn` | `lab.sh opn-wait`, the M4 to M6 checks |
   | M7 | `reset-lab.ps1 -Action Save -Name clat-base` | the checkpoint lines of the status listing; `lab.sh addr`, `lab.sh opn-wait` |
   | each H reset, only when the runner was started with `--reset manual` and prints `WAITING FOR RESTORE` (six times in a full run) | `reset-lab.ps1 -Action Restore -Name clat-base` | continues by itself |
   | after a change to the ISP files or `provision.sh` | `reset-lab.ps1 -Action Save -Name clat-base` | as M7 |
   | whenever the VM state is needed | `status-lab.ps1` | the listing |
   | at the end | `remove-lab.ps1`, then `status-lab.ps1` | the clean-up checks of section 10 |

2. **Only if asked by the first run:** run `create-lab.ps1 -SwitchesOnly` elevated (section 7 rows 1 and 22); reconnect an adapter with the `Connect-VMNetworkAdapter` line of M4 (row 8); start the elevated serial reader, or look at the console with `vmconnect.exe localhost clat-opn` (rows 6 and 7).
3. **Keep the host awake** while the VMs run; a full test run takes two hours or more.
4. **T25**, the one hand test: three clicks in the OPNsense GUI through `lab.sh gui`.
5. **Later, not needed for this plan:** a clone of github.com/opnsense/plugins inside clat-opn would allow building and testing the real package (section 9 item 6).

---

## 12. Measurements, and sources

Measured on the lab host on 2026-10-12, read-only:

- `HEAD` on the two image URLs: sizes and dates as in section 4. The Debian URL redirects to a mirror; `SHA512SUMS` is served by cloud.debian.org itself. Both checksum files were read; their formats and the two values are in section 4.
- Git Bash has `ssh`, `scp`, `ssh-keygen`, `tar`, `base64`, `sha256sum`, `sha512sum`, `curl`, `bzip2`, `openssl`. It has no `jq`, `xorriso`, `qemu-img`, `arping`, `nc`, and no Python.
- A throwaway ed25519 key in a folder with a wide ACL: Git Bash's `ssh-keygen -y` loads it; Windows' `ssh-keygen.exe -y` refuses it ("UNPROTECTED PRIVATE KEY FILE"). Hence decision 20.
- A hash from `openssl passwd -6` is accepted by PHP 8.3 `password_verify()` (one run of a `php:8.3-cli-alpine` container). Core's API authenticator calls `password_verify()` on the stored value (`Auth/API.php` in the reference clone, master).
- From the installed Hyper-V module's metadata (`Get-Command`, reflection; no Hyper-V call): `Set-VMSwitch` has the parameters `EnableSoftwareRsc` and `EnableRscOffload`; the `VMSwitch` object has the properties `SoftwareRscEnabled` and `RscOffloadEnabled`; `Set-VMNetworkAdapter` has `RscEnabled`. What these settings do to a FreeBSD router VM was not measured.
- Read in the reference clone of opnsense/core (master): Unbound model fields `forwarding.enabled`, `general.dns64` and `general.dns64prefix`, and `unbound.inc` 207-219 (with `dns64` set the module list gets `dns64`); configd actions `interface reconfigure`, `interface gateways status`, `interface routes configure`; routing API actions `addGateway`, `setGateway`, `delGateway`, `toggleGateway`, `reconfigure`; `filter.inc` clamps to `mss - 40` (IPv4) and `mss - 60` (IPv6); `filter.inc` 329-330 writes `set state-policy if-bound` when `system.state-policy` is not empty; `interfaces.inc` 1252 writes `set link keep-alive 10 60`.
- Read in the plugin source: the model fields used by the tests (`enabled`, `prefix`, `discover_dns`, `keep_with_native`, `mss_offset`, `ipv6_mtu`, `manual_nat`, `test_target`), the status JSON of `clatctl.py`, the reasons `no_nat64_prefix`, `uplink`, `gateway`, `hold`, the preflight ids `wan_ipv4_ppp`, `wan_ipv4_ppp_native`, `nat_mode`, `pref64_overlap`, and the timers (debounce 2 s, uplink grace 15 s, native-gone hold 60 s, restart interval 60 s, back-off 5/10/30/60/300 s reset after 300 s of `active`, at most 3 Router Solicitations 4 s apart). For the review also:
  - `lib/supervisor.py`: `restarts` is incremented only in `tayga_exit()` (739-750); `renumber()` (763-770) does not touch it; the failure count is reset only by the tick after 300 s of `active` (187-190); suspend withdraws only when the gateway facts name a `fallback` (497-500).
  - `lib/discovery.py`: `accept_ra()` (96-104) tests interface and hop limit, then the source; DNS re-query after `max(TTL, 60)` s, capped at 300 s for an answer without a prefix, and after 10/30/60/300 s for a failure (38-40, 216-233).
  - `lib/sysif.py` 384-396: SERVFAIL is a failure, NOERROR without AAAA is an answer whose TTL comes from the SOA.
  - `clatctl.py`: for source `dns` the status has lifetime null (197-201, with supervisor.py 782-787); the DF probe tries the configured IPv4 MTU, then 1280, then bisects (271-295); `details` runs `facts.php` twice, `pkg query` and `pfctl -sn` (167-213).
  - `facts.php` 230-236: `fallback` = the default core would pick without the CLAT gateway, if it has an address and its device has IPv4. `lib/facts.py` 223-234: a gateway at priority 255, not upstream and not selected, is not "native".
- Read in the reference clone of tayga: `nat64.c` 379-383 answers an unmappable destination with ICMP type 3 code 1; `addrmap.c` 97-132 lists 10.0.0.0/8 among the ranges refused under the well-known prefix.

Everything else in this plan rests on the three sheets, which state their own sources and mark what is unconfirmed.

---

## 13. Review of 2026-10-12: what changed where

All twelve issues were valid; none was rejected.

| # | Issue | Changed in |
|---|---|---|
| 1 | The negative test pinged 10.99.0.1, a connected network of OPNsense | destination 10.255.255.1 (sections 1, 2 decision 26, M10, T03); bypass statement (section 1, README row in 3.1); `mgmt0` input drop on clat-world (2.2 item 2) |
| 2 | T10 was rejected by the source test alone | T10 sends with the BNG's address as source; NIC and ICMPv6-input preconditions; the old source is a separate case (2.2 item 5) |
| 3 | `tayga.restarts` does not count planned restarts | decision 27 and the definitions at the head of section 8; T06, T08, T10, T11, T12, T14, T19, T20 |
| 4 | Interface name and IPCP address depended on the session slot; three simulator faults | `-N 1` (decision 9, 2.2 item 1, row 23 with the other alternative as fallback); `ispctl iface` in guard T00; Kea restart only on change, IPv6 reject rule, `flock` (2.2 items 2 and 6) |
| 5 | Path-MTU cache on the client; wrong fragment boundary | `ping -M probe`, cache flush, SYN capture first (section 8 head, T04, soft reset); fragment pair and `FRAG_RETURN` (M10, T01, T04, T14, T18). One addition to the review's commands: `iperf3 --dont-fragment`, without which Linux fragments locally |
| 6 | DNS discovery tests depended on timing, on a TTL outside the lab and on Internet DNS | local `ipv4only.arpa` zone (decision 13, 2.2 item 4, M3, row 21); T08(a) 330 s with the latency recorded, T08(c), T15(b); row 12 fallback without the validator. Also corrected: for source `dns` the status lifetime is null, not a number |
| 7 | `suspended` was never reliably reached; fail-over was wrongly listed as untestable | T11(c), T17(d), row 30; section 9 item 9 |
| 8 | Gaps against DESIGN section 15 | T03b (if-bound); T12(b) and T17 mandatory; T08(d); manual fallback in M9; coverage line under the matrix |
| 9 | Soft reset kept supervisor and client state; T01 polled `details` | soft reset in 3.3 and section 10; sampler reads `status.json`; decision 22 |
| 10 | Offloads were not addressed | decision 28, 2.2 items 6 and 8, M2, M3, M10, T24, row 22 |
| 11 | Elevated mode needed more command lines than listed | the table in section 11; logs (decision 29, 2.2 item 7); `lab.sh hvlog`; `run-tests.sh --reset` |
| 12 | Container mount, ProgramData statement, ACL leftovers, seed rebuild | container template in 3.3 (row 29); section 5; `remove-lab.ps1` and `status-lab.ps1` (2.2 items 9 and 10, row 28); `build.sh` refusal (3.1, M1 step 0) |
