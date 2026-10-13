# os-clat lab on Hyper-V

A test lab for the os-clat plugin (`../net/clat`) without physical hardware: two virtual machines on a Windows host with Hyper-V (Windows 10/11 Pro or later).

**Status: built and run (2026-10-11 and 12).** Both VMs exist and run. M2 to M6 and M8 to M10 are done, and every test from T01 to T24 has passed in profile P0. T25, the test of the GUI itself, is run by a script that presses the buttons in a browser (`lab.sh t25`, sections 6 and 15); it passed on 2026-10-12 after one change of the plugin's page. Since 2026-10-12 the lab's default is the production profile (section 13): the ISP as its public setup guide describes it, clat-opn configured by the steps of the customer page, and the production test set (T01, T26, T14, T13, T11, T15, T27, T28, T29, T12) has passed in it. The base checkpoint of M7 is prepared but not taken: the shells that run the lab have no Hyper-V rights, so every reset so far was the in-guest one. Since 2026-10-12 the WAN link is tagged: the `wan` adapters are in trunk mode, PPPoE runs on VLAN 40 as on the ISP's line, and both test sets have passed over it, T01 to T24 in profile P0 and the production set (section 13). Also since 2026-10-12 the lab builds the package, signs a repository with a lab key, serves it over HTTPS and IPv6, and installs, upgrades and removes the plugin on clat-opn through the firmware pages' API, as a subscriber will (section 14). And a tool takes pictures of the GUI for the customer page with a headless browser (section 15): 29 are taken, all of them again on 2026-10-12 in the final state (PPPoE on the VLAN with a session, the package `1.0` installed). After a review the plugin's size test was corrected and tried here against four conditions of the path, and `lab.sh opn-vlan` now keeps the configurations of the in-guest reset in step (sections 10 and 13). Section 10 has the list, `.work/results/first-run.txt` the outputs of M3 to M10 (M2 is in the `hyperv-*.log` files), and `.work/results/changes.md` every change made since, with its symptom and re-test, and the result of every test run.

## 1. What the lab is

```
 Windows host (Git Bash: build.sh, lab.sh, run-tests.sh; PowerShell: hyperv\*.ps1)
   |
 [Default Switch] ---- nat  02:C1:A7:00:01:01  up0    DHCP, Internet by NAT ----------+
   (exists, only read)                                                               |
 [clat-mgmt] --+------ mgmt 02:C1:A7:00:01:02  mgmt0  10.99.0.1/24                   |  VM clat-world
 [clat-wan] ---|--+--- wan  02:C1:A7:00:01:03  wan0   PPPoE server on wan0.40 (ISP)  |  Debian 13, Generation 2
 [clat-lan] ---|--|-+- lan  02:C1:A7:00:01:04  lan0   in namespace "client", --------+  2 vCPU, 2048 MB, 8 GB
               |  | |                                 IPv4 only, DHCP from OPNsense
               |  | +- lan  02:C1:A7:00:02:01  hn0    LAN   192.168.1.1/24 ----------+
               |  +--- wan  02:C1:A7:00:02:02  hn1    under vlan0.40; WAN = pppoe0   |  VM clat-opn
               +------ mgmt 02:C1:A7:00:02:03  hn2    MGMT  10.99.0.2/24, no gateway +  OPNsense 26.7 nano, Generation 1
                                                                                        2 vCPU, 4096 MB, 16 GB
```

- **clat-world** plays the ISP: PPPoE server with IPv6CP only (one session, always `ppp0`), Router Advertisements (radvd), DHCPv6-PD (Kea), a DNS64 resolver (unbound), NAT64 for `64:ff9b::/96` (tayga 0.9.2), IPv4 test target `192.88.99.1` (HTTP with a 100 MB file, iperf3, ping; the name `v4only.clat.lab` has this A record only). `ispctl` on clat-world changes all of this (`ispctl` without arguments lists the verbs). It also holds the IPv4-only LAN client: network namespace `client` with the `lan` adapter (`ispctl client6 on` gives it IPv6 for one test). And it serves the lab's package repository, `https://repo.clat.lab/os-clat` (section 14).
- The ISP has two profiles. The **production profile** is the default (`ispctl defaults`), in the shape of the ISP's public setup guide: the WAN gets `2001:db8:4800::/64` by SLAAC and Kea delegates `2001:db8:4800:100::/56`; the simulator's RA carries no PREF64 and no RDNSS, M and O flags clear; PPP-Max-Payload echoed up to 1500. The resolver also answers on Google's public DNS64 addresses `2001:4860:4860::6464` and `2001:4860:4860::64`, which are on clat-world's `isp0`, so the addresses of the customer page work literally. **Profile P0** (`ispctl defaults p0`) is what the first runs used: WAN `2001:db8:a::/64`, PD `2001:db8:5600::/56`, PREF64 and RDNSS `2001:db8:64::53` in the RA, PPP MTU 1492. Section 13 has the production profile on the OPNsense side.
- **clat-opn** is OPNsense with the plugin. Its WAN has IPv4 type None; MGMT has no gateway. During tests it has no native IPv4 gateway, otherwise the plugin correctly stays dormant.
- The three `clat-*` switches are private: no host adapter. The host reaches clat-world by ssh on the Default Switch, and clat-opn through clat-world (`ProxyJump`). The test bodies run on clat-world.
- **What bypasses the CLAT:** 192.168.1.0/24 (LAN) and 10.99.0.0/24 (MGMT) are connected networks of OPNsense. A packet from the LAN client to an address in either never enters `tun464`. Never use such an address as a CLAT test destination; the negative test uses `10.255.255.1`.
- Logins: clat-world accepts only the lab ssh key (`.work/disks/build/lab_ed25519`); its console password is `CONSOLE_PASS` in `.work/disks/build/secrets.env`. clat-opn accepts the lab key and, as from the factory, user `root` with password `opnsense` (ssh and GUI; `GUI_USER` and `GUI_PASS` in `secrets.env` are this login, for `screens/capture.mjs`); it is reachable only on the private switches.

The plan behind all of this, with the reasons, is `docs/PLAN.md` (a reference copy; its head says where it is out of date). Scripts cite it as "PLAN".

## 2. Files

| Path | What |
|---|---|
| `build.sh` | M1: downloads, checksums, lab key and secrets, rendering, seeding, conversion. Git Bash |
| `lab.sh` | the driver: `bash lab.sh --help` lists the verbs. Git Bash |
| `run-tests.sh` | the test runner T01 to T29, with the two profiles of section 6; its inner part runs on clat-world |
| `hyperv/create-lab.ps1`, `remove-lab.ps1`, `status-lab.ps1`, `reset-lab.ps1`, `wan-vlan.ps1`, `lab-common.ps1` | the only scripts that call Hyper-V. Names, MACs and sizes are in `lab-common.ps1` |
| `world/` | cloud-init seed templates, `install.sh` and the file tree of clat-world (`rootfs/`) |
| `opnsense/` | configuration template, `seed_config.py`, `provision.sh`, `install-plugin.sh`, `web-restore.sh`, `guiform.py` (reads and sends a form of the GUI as a browser does; `lab.sh gui-form`) |
| `screens/` | `capture.mjs` and `steps.mjs`: pictures of the GUI for the customer page, taken with headless Edge (`lab.sh screens`, section 15); `t25.mjs`: test T25, the buttons of the GUI pressed in the same browser (`lab.sh t25`, sections 6 and 15) |
| `docs/` | `PLAN.md` and the three research sheets it was written from |
| `.work/cache` | the two downloads and their checksum files (0.9 GB) |
| `.work/disks` | `base-*` files (kept on removal), later `clat-*` VM disks, checkpoints and VM folders; `build/` holds the key, `secrets.env`, the rendered configuration and seed, `ssh_config`, and the `repo-*` files of section 14 (the lab's signing key, its CA and the certificate of `repo.clat.lab`) |
| `.work/results` | every log and result (section 8) |

`.work/` is ignored by git: it exists only on the machine that runs the lab, and so do the files under `.work/results` that this document cites.

## 3. Prerequisites

- Hyper-V enabled and Hyper-V rights for whoever runs `hyperv\*.ps1` (section 4).
- Git Bash (ssh, tar, curl, openssl, bzip2: present) and `wslc.exe` (used by `build.sh` only, for throwaway containers).
- About 17 GB free on the checkout's volume at the peak.
- Internet through the Default Switch for clat-world (Debian packages, about 200 MB) and, during M6 only, for clat-opn through clat-world (OPNsense packages and sets).
- Nothing is installed on Windows. Keep the host awake while the VMs run.

## 4. Hyper-V rights: choose one way

Check at any time: `bash lab.sh rights` (Git Bash), or in cmd or PowerShell `whoami /groups | findstr /i "S-1-5-32-578"` (must show "Enabled group"; Git Bash's own `whoami` cannot do this).

**a) Group mode (recommended), once.** In an elevated PowerShell (Win+X, "Terminal (Admin)"):

```
Add-LocalGroupMember -SID 'S-1-5-32-578' -Member '<PC>\<user>'
```

`<PC>\<user>` stands for the Windows account that runs the lab, as `whoami` prints it in cmd or PowerShell (not elevated). Then sign out of Windows and sign in again (locking is not enough; programs started before the sign-in keep the old token). From then on every step runs without elevation, including the resets between tests: `bash lab.sh hv <script.ps1> [arguments]`. To know: afterwards any program running as this user can control Hyper-V without a UAC prompt.

**b) Elevated mode, without the group.** Run these lines in an elevated PowerShell, each at the step named in the first column. Every line is

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <checkout>\lab\hyperv\<script> <arguments>
```

`<checkout>` stands for the top folder of the checkout. Each script writes what it printed to `.work\results\hyperv-<UTC>-<script>.log`; `bash lab.sh hvlog` reads it, and everything else runs over ssh.

| When | Script and arguments | What is read or done next |
|---|---|---|
| M2 | `create-lab.ps1 -NoStart` | reads the `created switch`, `rsc`, `created vm`, `acl` lines and the status listing |
| M3 | `reset-lab.ps1 -Action Start -VM clat-world` | `lab.sh addr --wait`, `lab.sh world` |
| M4 | `reset-lab.ps1 -Action Start -VM clat-opn` | `lab.sh opn-wait`, M4 to M6 |
| M7 | `reset-lab.ps1 -Action Save -Name clat-base` | reads the checkpoint lines; `lab.sh addr --wait`, `lab.sh opn-wait` |
| each H reset, only with `run-tests.sh --reset manual`, when it prints `WAITING FOR RESTORE` (six times in a full run) | `reset-lab.ps1 -Action Restore -Name clat-base` | continues by itself |
| after a change to `world/` or `provision.sh` | `reset-lab.ps1 -Action Save -Name clat-base` | as M7 |
| for PPPoE on VLAN 40 (section 13), once | `wan-vlan.ps1 -Action Trunk` | reads the two `vlan ... mode=Trunk` lines; `lab.sh opn-vlan on`, `ispctl vlan on` |
| whenever the VM state is needed | `status-lab.ps1` | reads the listing |
| at the end | `remove-lab.ps1` | reads its log |

Never run plain `create-lab.ps1` for the first creation: it starts both VMs at once. Create and remove the lab the same way (a or b). Without rights every script stops with exit code 2 and prints both ways with the exact command line.

Only if the first run asks for it: `create-lab.ps1 -SwitchesOnly` elevated (rows 1 and 22 of section 9); `Connect-VMNetworkAdapter -VMName clat-opn -Name <adapter> -SwitchName <switch>` (row 8); the console `vmconnect.exe localhost clat-opn` (rows 6 and 7).

## 5. Steps, in order

From Git Bash in `lab/` of the checkout. `PS> X` means the hyperv script `X`: `bash lab.sh hv X` in group mode, or its elevated line of section 4. A step is done when its checks hold; copy the outputs into `.work/results/first-run.txt`. The full check lines are in `docs/PLAN.md` section 6. Times are estimates, unconfirmed: M2 5 minutes, M3 15, M4 10, M6 20.

**M0. Rights.** Section 4.

**M1. Build (done).** `bash build.sh` repeats it; with nothing changed it only re-checks and takes half a minute. It must end with `OK build finished: OPN_CONFIG=seeded`. `--factory` builds the OPNsense base without the seeded configuration (Path B), `--force` allows a rebuild while VMs exist.

**M2. Switches and VMs.**

```
PS> create-lab.ps1 -NoStart
```

Checks: three lines `created switch clat-... (Private)`; `unchanged host network adapters`; three lines `rsc clat-...: SoftwareRscEnabled=False`; per VM `created disk`, `created vm`, and `ok acl` or `fixed acl` per attached file; in the listing both VMs `Off`, `adapters as in lab-common.ps1: True`, clat-opn `disk IDE 0 0 ... sizeGB=16`, clat-world 8 GB with the DVD `base-world-seed.iso`.

**M3. clat-world.**

```
PS> reset-lab.ps1 -Action Start -VM clat-world
bash lab.sh addr --wait
bash lab.sh world
bash lab.sh w reboot ; sleep 60 ; bash lab.sh addr --wait ; bash lab.sh world
```

`lab.sh world` pushes `world/`, runs `install.sh` and prints OK/FAIL lines. Check: `M3 checks: 0 failed`, both times (the second pass shows idempotence and the boot order). `install.sh` always ends the PPP session and resets the ISP to its defaults.

**M4. clat-opn boots unattended.**

```
PS> reset-lab.ps1 -Action Start -VM clat-opn
bash lab.sh opn-wait
bash lab.sh o 'hostname; opnsense-version; uname -v; for i in 0 1 2; do ifconfig hn$i | grep -E "ether|options"; done; df -h /; netstat -rn -f inet | grep -c "^default"; dmesg | grep -c "exited on signal"'
bash lab.sh api GET /api/core/system/status
```

Checks: nobody touched a console; `clat-opn.internal`; `ether 02:c1:a7:00:02:01`, `:02`, `:03` on `hn0`, `hn1`, `hn2`; `/` about 15 G; 0 IPv4 default routes; 0 `exited on signal`; `HTTP 200`.

If 10.99.0.2 stays silent, find out why without a login: `bash lab.sh w 'arping -c2 -I mgmt0 10.99.0.2'`, `bash lab.sh c arping -c2 -I lan0 192.168.1.1`, `bash lab.sh w 'timeout 30 tcpdump -eni wan0 -c3 pppoed'`. Answers from unexpected MACs: the `hn` order differs, reconnect adapters (row 8). No answer anywhere: the boot failed (rows 6 and 7), look at the console.

Path B, only when the seeded image does not come up (or `build.sh` reported `OPN_CONFIG=factory`): `PS> remove-lab.ps1`, `bash build.sh --factory`, M2 and M3 again, start clat-opn, give the factory configuration about three minutes to boot (LAN = first adapter = 192.168.1.1 with DHCP), then `bash lab.sh c sh /root/web-restore.sh /root/clat-opn-config.xml https://192.168.1.1` and `bash lab.sh opn-wait`. Path B has never been needed, and `web-restore.sh` has never run.

**Profile for M5 to M10.** The checks below name the values of profile P0, which the seeded configuration of clat-opn fits: run `bash lab.sh w ispctl defaults p0` before M5. With the ISP's default (the production profile) M5 shows the prefix `2001:db8:4800:100::/56` instead, and the plugin of M9 stays in `listening` until clat-opn has the DNS settings of section 13, because that ISP announces no PREF64.

**M5. IPv6 over PPPoE and a /56.** No action; observe within two minutes of M4.

```
bash lab.sh o 'ifconfig pppoe0; grep -E "ipcp|ipv6cp|max-payload|keep-alive" /var/etc/mpd_wan.conf; cat /tmp/pppoe0_prefixv6; route -6 -n get default | grep -E "gateway|interface"; ifconfig hn0 | grep inet6; ping6 -c2 2001:db8:64::53; ping6 -c2 64:ff9b::c058:6301'
bash lab.sh w 'ispctl status; ispctl iface; tail -40 /var/log/isp/pppd.log; journalctl -u kea-dhcp6-server -n 20 --no-pager; journalctl -k | grep -ci "apparmor.*denied"'
bash lab.sh c ip -br addr ; bash lab.sh c ping -c2 -W2 192.88.99.1
```

Checks: `pppoe0` up, MTU 1492, no `inet` line; `set bundle disable ipcp`; prefix file `2001:db8:5600::/56`; IPv6 default route by `fe80::1%pppoe0`; both `ping6` answered; `ispctl iface` is `ppp0`; Kea logged the lease; no AppArmor denial; the client has 192.168.1.1xx and its ping to 192.88.99.1 **fails** (no CLAT yet: the baseline).

**M6. Update, kernel policy, tayga.**

```
bash lab.sh opn-provision
```

It gives clat-opn a temporary IPv4 route through clat-world, runs `opnsense/provision.sh` on the box, takes the route and the NAT away again on every way out, and reboots. Checks (printed at the end): packages 26.7.x current; the kernel policy line (`hold 26.7.4` with the lock test printing 1, or `current <version>` when a kernel set newer than 26.7.6 exists); `hw.vmbus.tlb_hcall=0`; tayga 0.9.6; 0 `exited on signal`; 0 IPv4 default routes. Then the M5 checks again.

**M7. Base checkpoint.**

```
bash lab.sh o 'netstat -rn -f inet | grep -c "^default"; configctl interface gateways status; ping -c1 -t2 192.88.99.1'
bash lab.sh w 'nft list set inet isp provision4'
bash lab.sh o 'cp /conf/config.xml /root/config.lab-base.xml'
PS> reset-lab.ps1 -Action Save -Name clat-base
bash lab.sh addr --wait ; bash lab.sh opn-wait
```

Checks: 0 default routes; no IPv4 gateway; the ping fails with "No route to host"; the set has no elements; the status listing shows `checkpoint clat-base` on both VMs; afterwards M5 holds again. The copy of the configuration is what the in-guest reset uses.

**M8. Plugin.**

```
bash lab.sh plugin install
bash lab.sh o 'configctl clat status; pluginctl -g interfaces.clat; ifconfig tun464; ls -l /etc/rc.conf.d/clat /usr/local/etc/clat/; tail -20 /var/log/clat/clat_*.log'
```

Checks: both `Reloading template ...: OK`; last line `PLUGIN INSTALL rc=0`; the service runs; `interfaces.clat` has `if` `tun464`; `tun464` exists. (`opnsense-log clat` finds the log only after core's hourly `syslog archive` job, at minute 1, has made `/var/log/clat/latest.log`; until then read the dated file.)

**M9. The CLAT activates**, with no setting changed.

```
bash lab.sh st
bash lab.sh o 'netstat -rn -f inet | grep "^default"; pfctl -sn | grep tun464; pgrep -lf tayga; cat /tmp/tun464_router'
```

Checks: `state` `active` within 60 s; prefix `64:ff9b::/96`, source `ra`; `clat6` in `2001:db8:5600:ff::/64` (the highest /64 of the /56); MTU 1492 / IPv4 1472 / MSS 1432; default route `192.0.0.2` on `tun464`; a `nat on tun464` line; one tayga. If this fails, separate platform from plugin first: restore `clat-base` and run `../docs/lab-spike-runbook.md` by hand (docs/PLAN.md, M9).

**M10. The LAN client reaches IPv4.**

```
bash lab.sh c ping -c3 192.88.99.1
bash lab.sh c 'curl -sS -o /dev/null -w "%{http_code} %{size_download}\n" http://192.88.99.1/100M.bin'
bash lab.sh c ping -c2 -W2 10.255.255.1
bash lab.sh c ping -c3 -s 1232 192.88.99.1 ; bash lab.sh c ping -c3 -s 1233 192.88.99.1
bash lab.sh o 'timeout 12 tcpdump -ni hn0 -c 20 greater 1515' & bash lab.sh c iperf3 -c 192.88.99.1 -t 8
```

Checks: 3 replies; `200 104857600`; 10.255.255.1 is answered "Destination Host Unreachable" by 192.0.0.2; both sizes answered (only the second lost: record `FRAG_RETURN=lost`, a finding of its own. Seen on the first run, and it is about ICMP only: the PLAT returns the 1261-byte echo reply as two IPv6 fragments and tayga does not translate a fragmented ICMP message, while a UDP reply returned as two IPv6 fragments passes); the capture on `hn0` prints no packet (no frame above 1514 bytes; otherwise offloads are still active, row 22).

## 6. Tests

```
bash run-tests.sh selftest          # the runner's parsers, on clat-world; needs no OPNsense
bash run-tests.sh T00               # the guard alone, on the lab as it is (no reset); every test runs it before and after
bash run-tests.sh T02               # one test
bash run-tests.sh all               # the set of the profile: the production set by default (ten tests, about an hour, one H reset); with --profile p0: T01 ... T21 in the plan's order, two hours or more, six H resets
bash run-tests.sh list              # ids, reset kind, title
bash run-tests.sh --reset guest|manual|hyperv T16
bash run-tests.sh --profile p0 T04  # the profile of the run: prod (default) or p0
bash lab.sh t25                     # T25: the buttons of the GUI in a browser (section 15); four minutes, it changes the box
```

**Profiles.** `--profile prod` (the default) runs against the production profile of section 13: the ISP as `ispctl defaults` sets it, clat-opn as `/root/config.lab-prod.xml` has it. `all` is then the production set, `T01 T26 T14 T13 T11 T15 T27 T28 T29 T12`: T01, T11 to T15 with the values of this profile (prefix by DNS, MTU 1500/1480/1440, a renumbering of both prefixes in T12), and four tests written for it: T26 (what a subscriber has after the page's steps), T27 (the DNS64 resolver silent for 10 minutes, a service start during such an outage, an Unbound restart), T28 (15 minutes idle: Router Solicitations and DNS queries counted on the PPP link), T29 (the page's "Devices translate" steps on the LAN together with the plugin). Every other test is skipped in this profile. `--profile p0` runs every test T01 to T24 (T25 only when it is named) against profile P0 and `/root/config.lab-base.xml`, as before. An S test needs the box in the profile of the run (`/root/lab-profile` on clat-opn says which); the in-guest reset of an H test, T01 first, puts it there.

Every run pushes the current `../net/clat/src` and installs it on a clean box, so a plugin change needs no new checkpoint. Result per test: `pass`, `fail`, `blocked (reason)`, `invalid` (the lab was not in the needed state, or the guard T00 failed), `skipped (reason)`. Exit status 0 only when every test passed. T25 is not part of the runner's sets: `bash lab.sh t25` runs it (`screens/t25.mjs`, section 15), with the same result lines. `bash run-tests.sh T25` is still the hand test of the plan, which waits 20 minutes for somebody to save and apply the CLAT entry in Interfaces > Assignments; `bash lab.sh t25 drift` in a second shell is that somebody.

Where the runner deviates from the plan's criteria it says so in its output: with `FRAG_RETURN=lost` (M10) T01, T04, T14 and T18 to T20 run `ispctl echodf on` after the fragment pair, which makes the test target answer echo with DF set, so that their checks on a reply above 1260 bytes and on the plugin's DF probe are measured instead of reported `blocked` (the test switches it off at its end); before that, T04 checks that the plugin's size test says "inconclusive" and names 1260 bytes (check 2b); T11(c) and T17(d) count from the moment `pppoe0` loses the flag UP, because OPNsense keeps its IPv6 default route while the PPP session is gone (section 9 row 30); T13(b) waits for the status file of the new supervisor; T07(a) asks the first name server of `/etc/resolv.conf` and not a random one; T09(c) uses 2001:db8:5600:ff::/96; T02(5) is weaker when pf lists floating states without `origif`; T10 pings longer and orders its cases b, c, d, a; T13 allows one sample without tayga within 2 s of a kill; T16(b2) measures from the IPv4 default route appearing; T21 does not fail when `/var/run/clat` or `/var/log/clat` is absent; T24 treats an oversize frame on `hn0` as a failed check; T18 checks the MTU of the device PPPoE runs on (`vlan0.40` on the tagged link, `hn1` on an untagged one) and records that of `hn1`, which core sets 4 bytes higher under a VLAN device; wherever a test says "tayga not restarted", a `tayga.started` that moves by at most 2 s under an unchanged pid is no restart (the plugin publishes that time in wall-clock seconds, and it follows a correction of the system clock).

## 7. Reset

- **Hard reset (H):** `PS> reset-lab.ps1 -Action Restore -Name clat-base` turns both VMs off, applies the checkpoint, starts both. The runner does this itself with Hyper-V rights (`--reset hyperv`, the default then).
- **Without Hyper-V rights:** `--reset guest` (the default then) removes the plugin (the copied files, or the package of section 14 together with its repository definition) and its leftovers inside the guest, puts the configuration of the run's profile back (`/root/config.lab-prod.xml`, or `/root/config.lab-base.xml` with `--profile p0`; `lab.sh opn-vlan` keeps the PPPoE port and the VLAN device in both as on the box, section 13) and reboots; weaker than a checkpoint. `--reset manual` waits for the Restore line to be run by hand instead.
- **Soft reset (S)**, between tests of one group, inside the runner: the ISP's defaults for the profile, plugin and Unbound settings back, `configctl clat restart`, client route cache flushed, wait for `active`.
- By hand: `bash lab.sh w ispctl defaults` puts the ISP back into the production profile (`ispctl defaults p0`: profile P0); `PS> reset-lab.ps1 -Action Stop` / `-Action Start` stops and starts both VMs.
- After a change to `world/` or `opnsense/provision.sh`: apply it (`lab.sh world`, `lab.sh opn-provision`), then take the checkpoint again (`-Action Save`).

## 8. Where results land

Everything is under `.work/results/`:

| File | Content |
|---|---|
| `assets.txt` | hashes and sizes of downloads and base files, the output of `seed_config.py` and `qemu-img` (written by `build.sh`); `assets-prefetch.txt` is the record of the first download |
| `lab.log` | every `lab.sh` call with its output |
| `hyperv-<UTC>-<script>.log` | what each `hyperv\*.ps1` run printed (`bash lab.sh hvlog`) |
| `lab-state.json` | VM ids and MACs while the VMs exist |
| `provision-<UTC>.log` | the log of `provision.sh` from clat-opn |
| `<UTC run id>/` | one folder per test run: `summary.tsv`, `env.txt`, `console.log`, and per test `result.tsv`, `checks.txt`, `commands.log`, samplers, captures |
| `first-run.txt` | the first run (2026-10-11): the outputs of M3 to M10 and what was seen for the rows of section 9 |
| `changes.md` | every change to the plugin and the lab since the first run: symptom with the decisive line, cause, change, re-test; and a table of every test run |
| `stage-*/` | evidence taken by hand outside a test run (`stage-package/`: the package, the repository and the firmware pages' API; `stage-screens/`: what was done to the lab for the pictures; `stage-review-fixes/`: the corrected size test, and `opn-vlan` saving the configurations for the reset; `stage-review-fixes-2/`: the package `1.0_3` with the reworded text of that test; `stage-vlan/`: the switch to VLAN 40, the MTU measurements on the tagged link, the test runs over it and the package `1.0`; `stage-gui/`: the runs of T25 with a picture of the window at each step, the service buttons before and after the change of the plugin's page, and what was done for the final pictures; `stage-review-apply/`: the findings of the two reviews of the final pass applied, with the copies from before of the files changed (`before/`), the profile built in the page's order, the plugin installed again from the lab repository, T00 and T26, and the picture of step 2 taken again) |
| `screens/` | the pictures of section 15 and `screens.json`, which says per picture what is readable in it; `vlan-preview/` holds trial pictures of the VLAN steps |
| `t25-<UTC>/` | one folder per run of `lab.sh t25` without `--out`: `t25.txt` (the lines it printed) and the pictures of the window |

## 9. What the first run has to confirm

Each row is an open point with its fallback. The row numbers are the ones scripts cite ("PLAN section 7 row N"). What the first run saw for each row is in `.work/results/first-run.txt` (the summaries of M3 and of M4 to M6, and the test runs named in the last column); row 30 is the one whose answer changed the plugin.

| # | Open point | Fallback if it fails | Seen in |
|---|---|---|---|
| 1 | `New-VMSwitch -SwitchType Private` works for a group member without elevation | `create-lab.ps1 -SwitchesOnly`, elevated | M2 |
| 2 | Hyper-V reads qemu-img's VHDX (dynamic, 16 MiB blocks): `Get-VHD`, `Convert-VHD`, `Resize-VHD` | convert with `qemu-img -O vpc -o subformat=fixed,force_size`, then `Convert-VHD` | M2 |
| 3 | Hyper-V accepts the static MACs `02C1A7...` | unused `00155D...` addresses, changed in `lab-common.ps1` and `world/network-config` together | M2 |
| 4 | The Debian generic image boots as Generation 2 with Secure Boot off, and cloud-init reads the CIDATA ISO | seed on a small FAT VHDX; then Generation 1 | M3 |
| 5 | The seeded image is what OPNsense boots with (the 5234 bytes at offset 712876032 are `/usr/local/etc/config.xml`) | Path B (`build.sh --factory`, `web-restore.sh`) | M4 |
| 6 | A Generation 1 VM boots the BSD-labelled disk from IDE 0:0, and the file system grows to 16 GB | install from the vga image at the console, then Path B | M4 |
| 7 | The first boot needs no input | elevated serial reader on `\\.\pipe\clat-opn-com1`, or the console | M4 |
| 8 | `hn0`, `hn1`, `hn2` come in the order the adapters were added (lan, wan, mgmt) | reconnect adapters to switches | M4 |
| 9 | `clat-world.mshome.net` resolves on the host | neighbour table by MAC, then KVP; or `bash lab.sh addr <address>` | M3 |
| 10 | Kernel-mode PPPoE with pppd 2.5.2; CHAP with mpd5; IPv6CP only | user-mode PPPoE (drop `-k -g pppoe.so`); `require-pap` | M5 |
| 11 | Kea delegates on a ppp interface under AppArmor; dhcp6c accepts the answer | WIDE `dhcp6s`; or prefix-only on OPNsense's WAN | M5 |
| 12 | DNS recursion from clat-world through the Default Switch (needed for M6 only) | `forward-zone "."` to the DHCP-given resolver, without the validator | M3, M6 |
| 13 | Package download on OPNsense through the double NAT | `/etc/resolv.conf` pointing at 10.99.0.1 (already in M6) | M6 |
| 14 | Kernel: hold 26.7.4 and lock while 26.7.6 is the newest set; take a newer one unlocked if it exists | back to 26.7.4 and lock if `dmesg` shows `exited on signal` | M6, guard T00 |
| 15 | The seeded API key (`key|$6$...`) is accepted | create a key in the GUI; or ssh and `configctl` only (T14 then untested) | M4 |
| 16 | The runner's config.xml helper (PHP `write_config`) works | the GUI through `lab.sh gui`, by hand | first S test |
| 17 | A 1508-byte payload crosses a private switch | jumbo tests reported as not runnable | T18 |
| 18 | `Stop-VM` is a clean guest shutdown for both guests; checkpoint, restore, start work | shut down over ssh, then `-TurnOff`; in-guest reset | M7 |
| 19 | OPNsense's Unbound recurses through the CLAT and the double NAT | T07(b) and the Internet check reported as not run | T07 |
| 20 | `tcpdump`, `drill`, `curl` exist on OPNsense | capture on clat-world instead | first use |
| 21 | Debian's unbound answers `ipv4only.arpa` from the local zone, not through its dns64 module | no local zone (then the result depends on the host's DNS) | M3 |
| 22 | `Set-VMSwitch -EnableSoftwareRsc $false` works on a private switch, and no frame above 1514 bytes reaches OPNsense | elevated; then `Set-VMNetworkAdapter -RscEnabled $false` | M2, M10, T24 |
| 23 | One PPPoE slot: mpd5 redials although its first attempt can meet a busy slot | `-N 8` in `isp-pppoe.service` | T11(a) |
| 24 | `ping -M probe` sets DF and ignores the cached path MTU | flush the route cache before every probe | T04 |
| 25 | `iperf3 --dont-fragment` exists | forward MTU judged by ping, tracepath and TCP only | T04 |
| 26 | FreeBSD counts received RAs under "router advertisement" in `netstat -s -p icmp6` | T10 reports "seen by the NIC" only | T10 |
| 27 | `Start-Transcript` records everything the `.ps1` scripts print, also in an elevated console | run the body through `Tee-Object` | M2 log |
| 28 | `icacls /remove "NT VIRTUAL MACHINE\<id>"` removes the entry from kept files | remove by the raw SID | remove |
| 29 | wslc honours `:ro` on a volume | (confirmed during the build: the script mount was read-only) | M1 |
| 30 | With the PPPoE server stopped, OPNsense loses its IPv6 default route | Seen 2026-10-12: it does not. `pppoe0` keeps its index, the route and the prefix file; the device goes down (no flag UP, no address). The plugin now takes a default route on a device that is not up as no uplink, and T11(c) and T17(d) count from the moment `pppoe0` loses UP (`.work/results/changes.md`, stage part 2) | T11(c) |

Also to confirm, from notes made while the scripts were written:

- The note `os-clat lab` set by `New-VMSwitch -Notes` / `Set-VM -Notes` reads back unchanged (the scripts recognise their own objects by it).
- The ACL lines of M2: `ok acl` or `fixed acl`; a `WARNING` there means a VM may not start (0x80070005).
- `cloud-init status --long` done with datasource NoCloud; root login with the lab key; NIC names `up0`, `wan0`, `lan0`, `mgmt0`.
- systemd accepts the six `isp-*` unit files; `nft -c` passes with a kernel behind it; Debian's tayga 0.9.2 accepts `tayga-nat64.conf`.
- The PPP hooks run, `PPPD_PID` reaches them, and after `ispctl session reset` the old `_down` and the new `_up` do not cross.
- ssh from clat-world to `root@10.99.0.2` with `/bin/sh -s` works through opnsense-shell and csh (every `O:` command rests on it).
- The output formats the runner parses on FreeBSD 15.1 and Debian 13 (netstat, pfctl, ifconfig, ping, iperf3 JSON, tcpdump link types).
- What one soft reset costs in time (it decides the length of a full run).
- `remove-lab.ps1`: files can be deleted after the checkpoint merge (a second run may be needed); its leftover lines for `C:\ProgramData\Microsoft\Windows\Hyper-V` give an answer only from an elevated run.

## 10. What has run, and what has not

Run on the host (no VM involved):

- The four downloads match the publishers' checksum files (SHA-256 for OPNsense, SHA-512 for Debian). That is an integrity check over HTTPS, not a signature check.
- `build.sh`, twice (the second run kept everything). The lab configuration replaced 5234 bytes at offset 712876032 of the OPNsense image; it was read back out of the finished `base-opnsense-26.7.vhdx` and equals the rendered configuration; the next file in the image is unchanged. `qemu-img check` and `qemu-img compare` pass for both VHDX files. The seed ISO has the volume id `CIDATA` and its three files equal their sources. The base files are not sparse, compressed or encrypted.
- Syntax: `bash -n` (three bash scripts), `sh -n` with dash and busybox (nine sh scripts), shellcheck at warning level (clean; SC2034 and SC2046 excluded for `run-tests.sh`), the PowerShell parser (five files, 0 errors), Python `ast` (three sources), PyYAML and XML parsers on the templates and the rendered files.
- `bash run-tests.sh --inside selftest` in a container: 0 failures (parsers only).
- Dry runs against fakes: the `.ps1` logic against stub cmdlets; `install.sh` and every `ispctl` verb with stubbed system commands; the generated radvd, Kea, unbound and pppd files accepted by Alpine's builds of those programs (not Debian's); every test function walked against a fake lab; `install-plugin.sh` against a fake box; `lab.sh` against a fake ssh. These show that the code runs, not that the lab works.
- `lab.sh rights`, `lab.sh addr` (no VM found, as expected) and the plugin bundle (26 files).

Run on the lab, 2026-10-11 and 12 (outputs in `.work/results/first-run.txt`, changes and result tables in `.work/results/changes.md`; the test runs of 2026-10-12 named here and in sections 13 and 14 are numbered 1 to 7 in time order):

- `create-lab.ps1 -NoStart` and `reset-lab.ps1 -Action Start` for each VM, in an elevated console (the three `hyperv-*.log` files), and on 2026-10-12 `wan-vlan.ps1 -Action Trunk` (the fourth). Nothing else has been done to the VMs from the host: no stop, checkpoint or restore.
- M3 (`lab.sh world`, also after a reboot of clat-world), M4 (the seeded OPNsense image booted unattended), M5, M6 (`lab.sh opn-provision`: OPNsense 26.7.6_3, kernel 26.7.4 held, tayga 0.9.6), the in-guest part of M7 (`/root/config.lab-base.xml`), M8 to M10 with the plugin.
- Every test T00 to T24, most of them several times; the last result of each is `pass`. The in-guest reset (`--reset guest`: plugin removed, base configuration back, reboot from inside) ran for every H test. On 2026-10-12 all of them ran once more in one go with PPPoE on VLAN 40 (`run-tests.sh --profile p0 all`, run 3: 24 passed; T18 passed in run 4, after its check of the NIC's MTU was changed for the VLAN, section 6).
- Three plugin changes came out of the tests, and two more out of the review of the results (the size test's "inconclusive", and a reload that asks DNS again); all are in `changes.md`.
- By hand, outside a test: both outcomes of the plugin's size test (`ispctl echodf off` and `on`), and the activation by DNS after an Apply on the plugin's settings (`stage-housekeeping/`).
- The size test after its correction (`stage-review-fixes/`, 2026-10-12, production profile, package upgraded to `1.0_1` and `1.0_2` from the lab repository): `ispctl echodf on`, ok with 1480; `echodf off`, inconclusive with 1260; with a rule on clat-world that drops IPv6 packets above 1420 bytes without an error, inconclusive with 1400 (the code before reported ok with 1400); with the NAT64 device of clat-world at MTU 1400, ok with 1380. Each by `configctl clat test` and by `POST /api/clat/service/test`. The rule and the MTU were set by hand for the test and taken back (`nft delete table inet labhole`, `ip link set dev nat64 mtu 1600`). A second review reworded the inconclusive text ("the next larger ping got no reply ..."); that tree ran on the box as `1.0_3`, and the first two conditions were run again with it (`stage-review-fixes-2/`).
- The production profile (section 13, `stage-production/`): the steps of the customer page on clat-opn through the GUI's pages and API, by hand and then as `lab.sh opn-prod`; `lab.sh plugin remove`; the production set with `run-tests.sh --profile prod`. Of the VLAN switch only what needs no trunk: `lab.sh opn-vlan on` and `off`, and `ispctl vlan on` ending in its `vlan on FAILED` message because no tagged frame arrives.
- PPPoE on the tagged VLAN 40 (section 13, `stage-vlan/`, 2026-10-12), after `wan-vlan.ps1 -Action Trunk`: `lab.sh opn-vlan on` and the success path of `ispctl vlan on`; the session on `vlan0.40` and `wan0.40`, and no session for a box that dials untagged; the MTU fields of UPLINK and WAN at 1508, with UPLINK empty and with both empty, each after Apply and after a reboot, with DF pings at the limit and the frames of a transfer counted on the wire; the pictures of the set `vlan` with a session behind them; `run-tests.sh --profile p0 all` and `run-tests.sh --profile prod all`, each in one go (runs 3 and 5; T18 and T27 failed there on a check of the runner each and passed in runs of their own after the two changes of section 6); the package `1.0` built from the final tree, installed through the firmware pages' API before the test runs and again after them, with T26, T14 and T13 on it.
- The pictures of the GUI (section 15, `stage-screens/`): `lab.sh screens` for the sets `now` and `fresh`, the latter between `lab.sh fw remove os-clat` and `lab.sh fw install os-clat`; and the set `vlan` as a trial, between `lab.sh opn-vlan on` and `off`, without a PPPoE session. This is the first time a browser rendered the GUI: the pages of the base steps, the firmware tabs, the plugin's page and its log. All 29 pictures were taken again on 2026-10-12, in the final state (`stage-gui/`).
- T25, the GUI with its buttons pressed (section 15, `stage-gui/`, 2026-10-12): `bash lab.sh t25`, the whole of it five times and single parts several more, on the package `1.0`. The last whole run, `stage-gui/t25-run9-final-all/`, ended `RESULT  T25 pass (218 s) 49 checks passed`. One change of the plugin's page came out of it (the service buttons in the page head, section 15); the package was rebuilt as `1.0` with it, and T26, T14 and T13 passed on that package (run 7).
- The package and its repository (section 14, `stage-package/`): `../packaging/build-package.sh` and `make-repo.sh` on clat-opn; the site on clat-world; the install line; the Plugins tab, an installation, the update check, an upgrade and a removal through the firmware pages' API; the firmware check with the site refusing connections, silent, and signed by a key the box does not trust; the recovery line.

Not run:

- In a browser, anything but the buttons of T25 (section 15 lists them and what they leave out). The steps 1 to 9 of the customer page were not clicked through: they went through the API, `configctl`, or the forms of the legacy pages sent by `guiform.py`; only the window of step 4 was opened and saved, with nothing changed. The browser is headless Edge on the host: no other browser, no phone. `lab.sh gui` itself has not run (the tools open the same tunnel on a port of their own), and neither has `bash run-tests.sh T25`, the form of the test that waits for clicks by hand.
- The base checkpoint (`reset-lab.ps1 -Action Save`), the hard reset (`-Action Restore`), `-Action Stop`, `status-lab.ps1`, `remove-lab.ps1`, `lab.sh hv`: the shells that run the lab have had no Hyper-V rights since the VMs were started.
- Path B (`build.sh --factory`, `web-restore.sh`).
- The way back to an untagged link: `ispctl vlan off` and `wan-vlan.ps1 -Action Untagged` (`lab.sh opn-vlan off` has run). A NIC whose driver has no `VLAN_MTU`: the lab's `hn1` has it, so a tagged frame may exceed the MTU by the 4 bytes of the tag.
- The tests other than the production set against the production profile: they are written for profile P0 and are skipped with `--profile prod`.
- `ispctl ramtu off` with a WAN MTU field of 1518 or 1528 (DESIGN.md section 8.3).
- Of the release pipeline (section 14): the build on plain FreeBSD 15.1, which is the workflow's machine (the lab builds on clat-opn); every GitHub workflow; GitHub Pages; the release signing key.

Not testable in this lab at all (docs/PLAN.md section 9): the real BNG and its timing; PPP MTU above 1500 (the lab's PPPoE server grants 1500 at most); the ISP's NAT64 (the lab's PLAT is tayga 0.9.2, which returns every DF-clear packet above 1260 bytes as fragments); IPv6 Internet; the real `ipv4only.arpa` TTL; the stock 26.7.6 kernel (it crashes on Hyper-V, so the lab holds 26.7.4); throughput on customer hardware; a second WAN with DHCP; behaviour over days; real NICs.

## 11. What the lab creates on the host

| Kind | Objects |
|---|---|
| Hyper-V switches | `clat-wan`, `clat-lan`, `clat-mgmt`: Private, note `os-clat lab`. No host adapter. The Default Switch is only read |
| Hyper-V VMs | `clat-world` (Generation 2), `clat-opn` (Generation 1): note `os-clat lab`, automatic start `Nothing`, automatic checkpoints off |
| Checkpoints | `clat-base` on both VMs |
| Named pipes, while a VM runs | `\\.\pipe\clat-world-com1`, `\\.\pipe\clat-opn-com1` |
| Files | all under `<checkout>\lab\.work`: VM disks `clat-*.vhdx`, checkpoint files `clat-*.avhdx`, VM folders `clat-*.vm\`, `clat-known_hosts`, logs. Hyper-V's own registration of the VMs exists while they exist |
| ACL entries | `NT VIRTUAL MACHINE\<VM id>` on the files attached to a VM; `remove-lab.ps1` takes them off the kept `base-*` files |
| Container images | `alpine:3.22` and `python:3.11-alpine` (pulled for the build if not present) |
| Group membership, only with way a) | `<PC>\<user>` in `BUILTIN\Hyper-V Administrators` |
| By Windows itself | a `clat-world.mshome.net` line in `C:\Windows\System32\drivers\etc\hosts.ics`, neighbour-cache entries for `02-C1-A7-00-01-01` |

Not created: host network adapters, NAT or firewall rules, services, scheduled tasks, installed software, anything in the user's `~/.ssh`.

## 12. Remove everything

1. `PS> remove-lab.ps1` removes the two VMs with their checkpoints, the three switches, every `clat-*` file and folder in `.work\disks`, and `lab-state.json`. It touches only objects with the `clat-` prefix **and** the note `os-clat lab` (switches also: Private and unused). Run it again after a minute if it reports a locked file. Its log also lists what is left under `C:\ProgramData\Microsoft\Windows\Hyper-V` for the VMs it removed (readable only from an elevated run). `-KeepDisks` keeps the files.
2. `PS> status-lab.ps1`: no lab switch, no lab VM, `lab files and folders (clat-*) in disks: 0`, `vm-entries=0` on the kept files.
3. Delete `<checkout>\lab\.work` to remove downloads, base images, key, secrets, logs and results. To rebuild later without downloading, keep `.work\cache`.
4. `wslc.exe image rm alpine:3.22`, and `wslc.exe image rm python:3.11-alpine` unless something else uses it.
5. If the group was joined only for the lab: elevated `Remove-LocalGroupMember -SID 'S-1-5-32-578' -Member '<PC>\<user>'`, then sign out and in.
6. Left by Windows and harmless: a stale `clat-world.mshome.net` line in `hosts.ics`.

## 13. The production profile, and the switch to VLAN 40

The production profile is the lab's default since 2026-10-12. It copies the ISP's public setup guide, the router-setup page https://gettuckamore.ca/router/setup: the ISP side as the page describes it (section 1), and what its OPNsense section tells the subscriber to set. Since the switch below was made (2026-10-12) PPPoE runs on `vlan0.40`, as in production. One thing differs from the page as it was: the MTU fields are 1508 where the page said 1528, because 1508 is what holds on OPNsense 26.7 (DESIGN.md section 8.3).

**clat-opn by the steps of the page.** `bash lab.sh opn-prod` does them, each through the page or the API that the GUI itself uses (`guiform.py` logs in and sends the legacy `*.php` forms as a browser does; the other pages are API calls). The plugin must not be installed. The verb does step 2 of the page as well, so the switch to VLAN 40 below must have been made: it refuses while the PPPoE server of clat-world is not on `wan0.40` (`/etc/isp/vlan-on`). The verb writes the result to `/root/config.lab-prod.xml`, which the in-guest reset of `run-tests.sh` (profile `prod`) puts back, and `prod` to `/root/lab-profile`.

| Step of the page | What the verb does on 26.7.6 |
|---|---|
| 0 (not on the page) | starts from the lab's base configuration with the WAN as a factory box has it: `hn1` with DHCP and DHCPv6, no PPPoE device, no VLAN device; reboot |
| 1 Clear the WAN port | `interfaces.php?if=wan`: both types None; Save, Apply changes |
| 2 Add VLAN 40 | `api/interfaces/vlan_settings`: Device `vlan0.40`, Parent `hn1`, VLAN tag 40, no Description; Apply. The Parent reads `hn1 (02:c1:a7:00:02:02) [WAN]` at this step |
| 3 Add PPPoE | `interfaces_ppps_edit.php`: Link Type PPPoE, Link interface(s) `vlan0.40`, Username, Password; Save |
| 4 Make PPPoE your WAN | `api/interfaces/assignment`: row WAN gets Device `pppoe0`; a new row on `hn1` with Description UPLINK; Apply |
| 5 Set UPLINK | `interfaces.php?if=opt2`: Enable, both types None, MTU 1508; Save, Apply changes |
| 6 Set up the WAN | `interfaces.php?if=wan`: Enable, IPv4 None, IPv6 DHCPv6, MTU 1508, Prefix delegation size 56, Request prefix only, Send prefix hint; Save, Apply changes |
| 7 Share a /64 | nothing to change: Identity association, the Dnsmasq router advertisements and the range with Constructor LAN are the factory configuration |
| 8 Set your DNS | `system_general.php`: the two DNS servers, the override cleared; Save |
| 9 Forward lookups to DNS64 | `api/unbound/settings`: Use System Nameservers; Apply |

Two things the verb copes with, and a person at the GUI would notice: the Device list of Assignments shows the new `pppoe0` only 15 s (`stage-production/62-opn-prod.txt`) to 50 s (the run in the page's order) after step 3, because core keeps that list for 60 s (`cache_ttl:60` of the configd action `interface list assign-opts`): the Apply of step 2 renews it, the legacy page of step 3 does not; and the Apply of step 6 can end with a closed connection, because the web GUI restarts when the WAN comes up (the apply itself completes; `guiform.py` then looks at the page again).

Then `bash lab.sh plugin install`; the CLAT is active within seconds, with the prefix from DNS. What each step showed is in `.work/results/changes.md` (stage "production profile") and `.work/results/stage-production/20-walk.txt`. At first the verb left step 2 out and dialled on `hn1`, and `lab.sh opn-vlan on` added the VLAN afterwards. The first run in the page's order (`stage-review-apply/11-opn-prod-page-order.txt`) ended with `pppoe0` at 1500, `vlan0.40` and `hn1` at 1508, the prefix `2001:db8:4800:100::/56` and `set pppoe iface vlan0.40`; the plugin, installed after it from the lab repository (`lab.sh repo subscribe`, `lab.sh fw install os-clat`), was active 11 s after the call, and T26 passed (changes.md, stage "review findings of the final pass applied").

**The switch to VLAN 40.** It was made on 2026-10-12; these are its steps, for a lab that is built anew. A new lab has the `wan` adapters of both VMs in untagged mode, and in that mode no tagged frame crosses the Hyper-V switch (seen 2026-10-12: each side captured only its own tagged frames). The order matters, because `ispctl vlan on` waits for a tagged frame from OPNsense:

1. In an elevated PowerShell: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <checkout>\lab\hyperv\wan-vlan.ps1 -Action Trunk`. Check with `bash lab.sh hvlog wan-vlan`: two lines `vlan clat-... wan: mode=Trunk allowed=40 native=0`. Untagged frames still pass, so the lab keeps working after this step alone.
2. `bash lab.sh opn-vlan on`: steps 2 and 3 of the page on clat-opn (VLAN device `vlan0.40` on `hn1` with tag 40; the Point-to-Point device gets Link interface(s) `vlan0.40`), then Save and Apply changes on the WAN. From here OPNsense dials on the VLAN and has no session. The verb also writes the PPPoE port and the VLAN device into the two configurations that the in-guest reset of `run-tests.sh` puts back, `/root/config.lab-prod.xml` and `/root/config.lab-base.xml`, and prints one line `saved ...` for each. A reset therefore keeps PPPoE on the VLAN. Only these two nodes are copied from the running configuration, so the plugin may be installed. If a line says `NOT SAVED`, the verb prints the three commands to run by hand and ends with exit status 1.
3. `bash lab.sh w ispctl vlan on`: the PPPoE server of clat-world moves to `wan0.40`. The verb waits up to 60 s for the first frame tagged 40; without one it prints `vlan on FAILED`, puts the server back on `wan0` and exits 2.
4. Check: `bash lab.sh w ispctl status` (PPPoE server on `wan0.40`, session `ppp0` with MTU 1500), `bash lab.sh o 'ifconfig hn1 | head -1; ifconfig vlan0.40 | head -1; ifconfig pppoe0 | head -1'` and `bash lab.sh st` (active).
5. Nothing is copied by hand: step 2 has saved the configurations for the reset. On clat-world the choice is kept in `/etc/isp/vlan-on`; `ispctl defaults`, `lab.sh world` and a reboot leave it alone. `bash lab.sh opn-prod` can run from here on: it builds the profile with the VLAN device and PPPoE on `vlan0.40`, in the page's order.
6. `bash run-tests.sh all`.
7. `bash lab.sh screens --set vlan`: the pictures of the steps that show the VLAN (section 15).

Back to untagged: `bash lab.sh w ispctl vlan off`, `bash lab.sh opn-vlan off` (it writes PPPoE on `hn1` and no VLAN device into the two saved configurations), and `wan-vlan.ps1 -Action Untagged`, elevated. If `ispctl vlan on` of step 3 ends in `vlan on FAILED`, run `bash lab.sh opn-vlan off` as well: both sides and the saved configurations are untagged again.

Seen with the trunk (2026-10-12, `.work/results/stage-vlan/`; `.work/results/changes.md`, stage "the tagged production link", has the lines):

- The switch. `ispctl vlan on` printed `vlan on: the PPPoE server is on wan0.40; the first tagged frame arrived after 1 s`. `ispctl status` then has the PPPoE server on `wan0.40` and the session `ppp0` with MTU 1500; clat-opn has `hn1` at 1508, `vlan0.40` at 1508 and `pppoe0` at 1500, and the CLAT is active. With the server on `wan0.40`, a box that dials on `hn1` (`lab.sh opn-vlan off`) gets no session: its untagged PADI frames arrive on `wan0` and nothing answers them.
- What the link carries. Frames of 1526 bytes on `wan0` (14 Ethernet, 4 tag, 8 PPPoE and PPP, a 1500-byte IPv6 packet) in both directions during a transfer, and DF pings of 1500 bytes each way; one byte more is refused at the sender.
- The UPLINK MTU field. With 1508 `hn1` reads 1508 after Apply and after a reboot. With the field empty the session is the same 1500, and `hn1` reads 1508 until the next reboot and 1512 after it: core gives the NIC under a VLAN device the VLAN's MTU plus 4, unless the NIC is an interface with an MTU of its own. So 1508 is the value that makes `hn1` read the same every time.
- Both MTU fields empty (the page's "UPLINK at 1500"): PPPoE 1492 on both sides, IPv4 through the CLAT 1472, MSS 1432; after a reboot `hn1` and `vlan0.40` are at 1500.
- The reset and the tests. The in-guest reset has put back both saved configurations with the VLAN in them (the H tests of both profiles), and both test sets passed over the VLAN: `run-tests.sh --profile p0 all` (T18 after its check was changed to the MTU of the device PPPoE runs on, section 6) and `run-tests.sh --profile prod all` (T27 after "tayga not restarted" was changed to allow for a correction of the system clock, section 6). T26, T14 and T13 also passed on the package `1.0` installed from the lab repository (run 6).

Seen before that, without the trunk (2026-10-12, `.work/results/stage-production/63-vlan-dry-run.txt`): `lab.sh opn-vlan on` makes `vlan0.40` and points PPPoE at it (`set pppoe iface vlan0.40`, `set pppoe max-payload 1500`); `vlan0.40` has MTU 1508, and `hn1` 1508 while UPLINK has 1508 in its MTU field, 1512 after a reboot with that field empty. `ispctl vlan on` then ended after 60 s with `vlan on FAILED: no frame tagged with VLAN 40 arrived on wan0 within 60 s`, exit status 2, the server back on `wan0`. `lab.sh opn-vlan off` brought the untagged session back.

Seen of the saving in step 2 (2026-10-12, `.work/results/stage-review-fixes/30-opn-vlan-on.txt` and `32-opn-vlan-off.txt`), with the package installed and still no trunk: `opn-vlan on` printed `saved      /root/config.lab-prod.xml: PPPoE on vlan0.40, 1 VLAN device(s)` and the same for `config.lab-base.xml`; each file then differed from its copy of before in the `ports` line of the PPPoE device and in the VLAN section, and in nothing else. `opn-vlan off` printed `PPPoE on hn1, 0 VLAN device(s)` for both, and each file was as before except for the time stamp of its empty VLAN section.

## 14. The package and its repository

`../packaging/README.md` says how a release is made and has the list of commands ("In the lab, before a release"). The lab runs the same two scripts on clat-opn, serves the result from clat-world, and then lets clat-opn be a subscriber's router. First run on 2026-10-12; evidence in `.work/results/stage-package/`.

What stands in for what:

| A release | The lab |
|---|---|
| the workflow's build machine, FreeBSD 15.1 | clat-opn (OPNsense 26.7.6, pkg 2.8.4). `lab.sh repo build` copies `../net/clat` and `../packaging` to `/root/os-clat` and runs `build-package.sh` and `make-repo.sh` there as `publish.yml` does. The build installs `tayga` on the box when it is missing |
| `https://os-pkg.gettuckamore.ca` | `https://repo.clat.lab/os-clat`: `isp-repo.service` on clat-world serves `/srv/isp-repo` over HTTPS. The name is local data of the ISP's resolver; its address, `2606:50c0:8000::153`, is one of GitHub Pages' own, put on `isp0` as Google's DNS64 addresses are. An address in 2001:db8::/32 does not work: OPNsense's Unbound removes such answers (rebind protection). The unit's journal shows every request of the router |
| a certificate every router trusts | a certificate from a lab CA. `lab.sh repo subscribe` adds the CA under System > Trust > Authorities (API `trust/ca/add`) before it runs the install line. Without it `fetch` refuses the site (`Certificate verification failed`) |
| the release signing key, and its fingerprint in `packaging/repo-key.sha256` | `repo-signing.key` and `repo-signing.sha256` in `.work/disks/build/`, with the CA and the certificate (`repo-ca.*`, `repo-tls.*`); all made by `lab.sh repo build` on its first run. The fingerprint file goes into the copy on clat-opn only |
| the commit as `PLUGIN_HASH` | the SHA-256 of the plugin bundle (`os-clat.sha256`) |
| OPNsense's mirror over IPv6 | the lab has no IPv6 Internet and `pkg.opnsense.org` has an AAAA record, so the ISP's resolver ignores that record (`dns64-ignore-aaaa`) and the box reaches the mirror through the NAT64, with or without the plugin. The firmware pages need the mirror: they update every repository |

A box as a subscriber has it before the plugin has no tayga, nothing left of an earlier installation and no repository definition:

```
bash lab.sh plugin remove
bash lab.sh o 'pkg delete -y tayga
rm -rf /usr/local/etc/clat /var/run/clat /var/log/clat /etc/rc.conf.d/clat /tmp/tun464_router
rm -rf /usr/local/etc/pkg/repos/os-clat.conf /usr/local/etc/pkg/fingerprints/os-clat
cp /root/config.lab-prod.xml /conf/config.xml; rm -f /tmp/config.cache; (sleep 2; reboot) >/dev/null 2>&1 &'
bash lab.sh opn-wait
bash lab.sh repo subscribe
bash lab.sh fw install os-clat
```

The reboot also takes the lab CA out of the configuration again, so `repo subscribe` adds it each time.

The package and the test runner. `install-plugin.sh remove` (`lab.sh plugin remove`, and the in-guest reset of `run-tests.sh`) takes a package off with `pkg delete os-clat`, keeps tayga and marks it as installed on request; the reset also removes the repository definition. `install-plugin.sh install` refuses while the package is installed. So an H test puts the copied files in the package's place, and an S test runs against whatever is installed: T26, T14 and T13 passed against the package (run 1), and T01 passed with the reset meeting a package (run 2). After `lab.sh fw remove os-clat` tayga is gone (`pkg autoremove`); in the production profile `bash lab.sh o 'pkg install -y tayga'` brings it back for the file copy.

What the first run showed is in `../packaging/README.md` ("On the router" and "In the lab") and, with every number and the decisive lines, in `.work/results/changes.md` (stage "the package and the repository"). In short: both scripts ran unchanged; the install line worked in root's csh on the box with only IPv6; the Plugins tab listed os-clat 1.0 from repository os-clat at tier 4; the installation through the API took tayga from OPNsense's repository, ran the package scripts and had the CLAT active with a LAN client answered 9 s after the API call; the upgrade to 1.0_1 interrupted IPv4 for 6.1 and 6.5 s; the removal left Python's cache directory, which `+POST_DEINSTALL.post` now removes; with the site down the firmware check failed and listed nothing until the recovery line was run.

Not run here: the build on plain FreeBSD, the workflow, GitHub Pages. The buttons of the Plugins tab were pressed in a browser on 2026-10-12 (T25, section 15): the link, the `+`, `Install` in the notice, the bin and `OK` in `Confirm removal`. `Check for updates` and an upgrade were not pressed there; they ran through the API only. The tests of profile P0, T21 among them, have run with the changed deinstall script and installer since (section 10).

## 15. Pictures of the GUI for the customer page

The OPNsense section of the customer page gets one picture per step. `screens/capture.mjs` takes them: a Node script without dependencies that starts the host's Edge headless, with a throwaway profile, and drives it through the DevTools protocol. Nothing is installed. `screens/steps.mjs` is the list of pictures, as data; its head explains an entry.

```
bash lab.sh screens --list            # the steps: set, id, file, title
bash lab.sh screens                   # the set "now" into .work/results/screens
bash lab.sh screens --set fresh       # the Plugins tab before the installation
bash lab.sh screens --set vlan        # the steps that show PPPoE on VLAN 40
bash lab.sh screens 08-dns rt-3-clat  # single steps
bash lab.sh screens --debug DIR ...   # also the whole page of each step, as it was, into DIR
```

A run opens the lab's tunnel to the GUI on a free port (the ssh command of `lab.sh gui`), signs in with `GUI_USER` and `GUI_PASS` of `secrets.env` (neither is printed), and then per step: loads the page from an empty one, with nothing the GUI remembers in the browser; waits until the page is loaded, no request is under way and jQuery is idle; does the step's actions; checks what must be readable; saves the rectangle the step names as a PNG. At the end, also after an error or Ctrl-C, Edge and the tunnel are closed and the profile folder is removed. The 17 pictures of the set `now` take 45 s. Exit status 0 means every step was saved; a failed step prints `FAIL` with its reason and saves nothing.

What makes a picture fit for the page, and what the tool does about it:

- **Only the page, cut to the step.** The window is 1024 wide, so the content column is 768 pixels, about the width of the customer page's text column; a dialog is 900, and a grid with many columns is taken at 1280 (1067). A picture runs from the page's heading (the menu path) to the last row the step is about. Boxes of a long page that the step is not about are taken out (`hide`), so that the heading stands above the part shown; a dialog is taken alone.
- **The documented values, checked.** Each step lists what a reader must be able to see (`expect`: a text, or a field and its value). The check runs on the finished page and counts only what is inside the rectangle and neither covered nor cut short; when it fails, no picture is saved.
- **No secrets, no lab clutter.** The PPPoE user name is shown as `YOUR_USERNAME`, as the page writes it; a password field shows dots. A step fails when the value of `PPPOE_PASS`, `API_KEY`, `API_SECRET` or `CONSOLE_PASS` is readable in its rectangle. The lab's management port and, for the base steps, the plugin's interface are taken out of the interface lists, and so is the Loopback row of Interfaces > Overview, whose Routes column names the lab's management address (the step fails when `10.99.0.` is readable). The host name is outside every rectangle.
- **Nothing is changed.** An action changes only what the open page shows. Where a step is about values the box does not have (step 1 on a finished box, the Parent of the VLAN device in step 2 under its name at that step, `[WAN]`, and its empty Description, which the device of profile P0 does not have, and the three steps of "Devices translate"), the values are entered and not saved; a dialog is closed with Cancel. The tool answers a browser's own confirmation question with no.

The three sets, and the state of clat-opn each needs:

| Set | State | Pictures |
|---|---|---|
| `now` | production profile, the plugin installed from the repository, the CLAT active | steps 1, 7, 8, 9, the Overview, the three steps of "Devices translate", System > Firmware > Status with the repository, the Plugins tab with os-clat installed, Services > CLAT > Settings (status, settings) and the Log File |
| `fresh` | the same without the plugin, the repository definition in place: `bash lab.sh fw remove os-clat`, the pictures, `bash lab.sh fw install os-clat` | the Plugins tab with the link to the community plugins, the row of os-clat with its `+`, and the notice `Third party software` |
| `vlan` | PPPoE on `vlan0.40` with a session (section 13, after step 4) | steps 2 to 6 and the two Details windows of the MTU check |

Results: `.work/results/screens/opnsense-*.png` and `screens.json` (per picture: id, file, title, page, size, time, and what is readable in it). First run 2026-10-12: 17 pictures of `now`, 3 of `fresh`. The set `vlan` has run once as a trial, with the VLAN configured by `lab.sh opn-vlan on` and no session behind it; those nine pictures are in `.work/results/screens/vlan-preview/`. They show the configuration as the page documents it, but the MTU values in them were not measured on a tagged link, so they are not the final ones. The set ran again with the session on VLAN 40, and `screens.json` then listed `mtu | 1500` for the Details of WAN and `mtu | 1508` for the Details of UPLINK; the nine pictures now in `.work/results/screens/` are those of the next paragraph.

All 29 were taken again on 2026-10-12, with the package `1.0` as rebuilt that day (comment `464XLAT CLAT for IPv6-only uplinks`, 162KiB): `fresh` right after `bash lab.sh fw remove os-clat`, then `now` and `vlan` once T25 had installed the plugin through the browser and the WAN record was back in the form of the saved production configuration. No expectation of `steps.mjs` had to change. Each picture was looked at. 28 have the width and height they had; `opnsense-10-overview.png` is 1067x426 (it was 1067x600): it gained the row of `vlan0.40` and lost the Loopback row. `screens.json` again lists `mtu | 1500` and `mtu | 1508` for the two Details windows. `opnsense-02-vlan.png` was taken once more afterwards, with the Parent shown as `[WAN]` instead of `[UPLINK]` (`stage-review-apply/`); it is 900x363 as before.

Seen while the pictures were taken, and of use for the page:

- Services > CLAT > Log File lists nothing as it opens (`No results found`): the severity list above the grid stands at `Warning`, and the plugin logs at `Notice` and `Informational`. The picture is taken with `Informational` chosen.
- Interfaces > Overview has no MTU column. The value is in the window that the magnifier button of a row opens (tooltip `Details`), in the row `mtu`.
- Services > Dnsmasq DNS & DHCP > DHCP ranges shows one closed group per interface; the entries appear after a click on the arrow of `LAN`. With no `RA mode` selected the field reads `Default`.
- System > Firmware > Status shows `Repositories` `OPNsense (Priority: 11), os-clat (Priority: 5)` once the install line has run: the GUI's sign that the shell step worked.
- Services > Unbound DNS > Query Forwarding prints `The following nameservers are used:` with the two addresses of step 8 under `Use System Nameservers`.
- The Device column of Interfaces > Assignments cuts `pppoe0 (vlan0.40) - <user name>` short; the dialog `Edit Assignment` shows it in full.
- Interfaces > [UPLINK] shows `Lock` (`Prevent interface removal`) ticked in the picture of step 5, and Interfaces > [WAN] does not. Seen on 2026-10-12: a Save in the window `Edit Assignment` writes `<lock>0</lock>` into the records of the other interfaces as well; the page Interfaces > [NAME] shows the box ticked for any `lock` entry and saves `<lock>1</lock>` with its next Save. The lab's UPLINK got it that way when the profile was built. Whether a subscriber's box shows it depends on the order of the saves; it was not clicked through.

On the host a run leaves nothing: the profile is under the system's temporary folder (or where `--profile` says) and is removed, and no msedge or ssh process of the run stays (checked after the runs of 2026-10-12, also after failed ones). Edge windows of other profiles are not touched.

**T25: the buttons, pressed.** `screens/t25.mjs` uses the same browser, tunnel and login, and does what a capture never does: it changes the box. Every click is a press of the left mouse button at the place where the element is drawn, and fails when the element is not visible or something covers it; text is typed as key input; a page is reached through the menu on the left. After each step the script asks the box over ssh, and the LAN client on clat-world. It prints `PASS` or `FAIL` per check with what was seen, saves a picture of the window at each decisive moment (the PPPoE user name as `YOUR_USERNAME`; a picture in which a lab secret is readable is not saved) and ends with `RESULT  T25 pass|fail ...`. Exit status 0 only when every check passed.

```
bash lab.sh fw remove os-clat         # the start: no plugin, the repository definition in place
bash lab.sh t25                       # install settings assign drift remove install: about four minutes
bash lab.sh t25 settings              # single parts, in the order given
bash lab.sh t25 --out DIR ...         # pictures and t25.txt there instead of .work/results/t25-<UTC>
```

| Part | In the browser | Asked of the box afterwards |
|---|---|---|
| `install` | System > Firmware > Plugins; the link `Click to view the community plugins.`; the `+` of os-clat; `Install` in the notice `Third party software`; the Updates tab until its spinner stops; the Plugins tab | the package from the repository `os-clat`, and tayga with it; state `active` and the IPv4 default route; three pings and a page of the test target from the LAN client |
| `settings` | Services > CLAT > Settings; Mode `Disabled`, `Apply`; Mode `Automatic`, `Apply`; the heading `Advanced`; `Run tests` without a test target (only when the box has none), the target typed, `Apply`; `Run tests` with `ispctl echodf off` and with `on`; Services > CLAT > Log File, Severity `Informational` | disabled: no daemon, no tayga, no IPv4 default route, no interface CLAT, the client without IPv4. Enabled: `active` again and the client answered. In the page: the State row, the service buttons in its head, the three result lines of the tests, the activation in the log |
| `assign` | Interfaces > Assignments; the pencil of WAN; `Save` in `Edit Assignment` with nothing changed; `Apply` | the PPPoE session and the state; every setting of the WAN still there with its value; the client |
| `drift` | the same for the CLAT entry: the hand test of `docs/PLAN.md` | what Apply wrote into the plugin's interface record (read from core's revisions of `config.xml` in `/conf/backup`); the record registered again within five minutes; gateway `CLAT_GW`, state `active`; the client; the plugin's page |
| `remove` | System > Firmware > Plugins; the bin of os-clat; `OK` in `Confirm removal`; the Updates tab; the Plugins tab | no package, no tayga, no `tun464`, no IPv4 default route; the client without IPv4; no CLAT in the menu after a reload |

What it showed on 2026-10-12 (`.work/results/changes.md`, stage "the GUI in a browser", has the lines; the pictures are in `.work/results/stage-gui/`):

- **Install and removal.** The Updates tab ended with `***DONE***` 10 to 11 s after `Install` and 8 to 10 s after `OK`. The CLAT was `active` 11 to 13 s after the click on `Install`, and the client was answered. The menu of the page that is open has no Services > CLAT after the installation until the page is loaded again.
- **Mode Disabled, Apply.** State `Disabled.`; no service buttons in the page head. The device `tun464` stays, down and without an address; what goes is the interface CLAT (`interfaces.clat`).
- **Mode Automatic, Apply.** As Apply ends the State row reads `The CLAT service is starting.`; the page looks again by itself 5 s later and then reads `Active.`. Here the test found a defect of the page: the service buttons in the page head stayed at "stopped" (red, with a start button) beside State `Active.`. Core's Apply button asks for them once, when `clat start` returns, and the daemon writes its pid file about 150 ms after that (`stage-gui/10-pidfile-race.txt`). The page now asks for them with every refresh of its status rows; with that they read "running" at the page's second look.
- **Run tests.** `No test target is set.` on a box without one. With the lab's target: `IPv4 packet size: inconclusive (largest ping answered: 1260 bytes; ...)` in 11 to 12 s while its large replies come back as fragments, and `IPv4 packet size: ok (largest IPv4 packet that passes: 1480 bytes)` in 5 to 6 s with `ispctl echodf on`.
- **Edit Assignment, WAN.** `Save` with nothing changed brought the notice `The interface configuration has been changed. ...`; `Apply` took 7 to 8 s and dialled the PPPoE session again (a new pppd on the ISP side, a new mpd5 on the box). The CLAT stayed `active` and logged no change of state; the client was answered. The window rewrites the record: every setting kept its value, the empty `adv_dhcp6_...` entries are gone and `ipaddr` `none` is written. A second Save of such a record brings no notice, and Apply then does nothing.
- **Edit Assignment, CLAT.** Apply wrote the record as `enable`, `if`, `descr`, `mss`, `ipaddr` `none`, `ipaddrv6` `none`: without `internal_dynamic` and `type`, as DESIGN section 7.2 expects of 26.7.6. The plugin logged `the CLAT interface record was changed; running the interface registration`, and the record was whole again 1.1 to 1.2 s after the Apply. When the same edit was made 87 s after a repair, the gateway list named `CLAT_NONE` and the repair came 243 s after the Apply, because the plugin leaves 300 s between two repairs (330 s here). The state was `active` and the client answered, right after the Apply and after the repair.

What it leaves out:

- Every button not named in the table: `Check for updates` and an upgrade; the start, stop and restart buttons in the page head; the other settings of the plugin's page and what it says to a wrong value; the dashboard; the steps 1 to 9 of the customer page.
- Other browsers, a phone, the keyboard alone, and a person: the script waits for what it expects, and sees nothing else on the page.
- The client is asked once after each step, not while the step runs: an interruption shorter than that is not measured here (T11 and T13 measure those).
- `assign` shows a redial only for a WAN record that Interfaces > [WAN] wrote last, which is what the saved configurations of the reset hold. After a run the record has the window's form; `bash lab.sh gui-form post "/interfaces.php?if=wan" lock=` and the same with `--submit apply` put it back.
- `settings` types the lab's test target and needs `ispctl echodf` on clat-world. `drift` reads core's revisions of `config.xml`, which is how it sees a repair that is faster than a look at the box.
