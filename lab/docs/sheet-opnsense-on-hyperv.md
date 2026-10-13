# Sheet: OPNsense 26.7 on Hyper-V, unattended, with the os-clat plugin

Research sheet, written 2026-10-12. Reading only. No image was downloaded, no Hyper-V command was run, nothing here ran on OPNsense. One helper (section 5.2) was run against a synthetic file in a throwaway container; that is the only thing marked "tested".

Helper files: `seed_config.py` (section 5.2) and `config.xml.template` (section 6.1), printed below. The lab's own copies are in `lab/opnsense/`, and those apply.

## 0. Verdicts in short

| Question | Answer | Basis |
|---|---|---|
| Which image | **nano** (`OPNsense-26.7-nano-amd64.img.bz2`, 468M). It is the only image that is an installed system; dvd, vga and serial are live installers that need an interactive install | [REL] [TOOLS] [DOC-I] |
| Hyper-V generation | **Generation 1 is mandatory for the nano image.** It has a BSD disklabel and BIOS boot code only, no EFI partition. Generation 2 (UEFI only) cannot boot it. The mechanics sheet's default "Generation 2, Secure Boot off" must be changed for clat-opn | [TOOLS] nano.sh |
| Does a second disk with FAT and `conf/config.xml` give an unattended first boot | **No.** The importer needs a key press within 7 seconds and then a typed device name | [CORE] opnsense-importer:231-283, same on stable/26.7 |
| Unattended first boot, recommended | Replace the factory `config.xml` inside the raw image before it is converted to VHDX (same byte length, in place). First boot then comes up with the lab configuration, SSH on, no prompt answered. Logic tested on a synthetic file only; the real image must pass the script's own checks | section 5 |
| Fallbacks | B: boot with factory defaults and restore `config.xml` through the web GUI from clat-world over the LAN. C: serial pipe plus importer (elevated PowerShell only). D: typed at the console | section 5.4 to 5.6 |
| Known Hyper-V problem | **The 26.7.6 kernel makes userland programs crash on Hyper-V** (unbound and syslog-ng signal 11, python3.13 signal 6), Intel hosts included. Fixed only in test kernel `26.7.6-hyperv`; a 26.7.7 was announced for the week of 2026-10-12. The lab must not boot the stock 26.7.6 kernel | [FORUM] [SRC297] [SETS] |
| Temporary IPv4 for provisioning | A runtime route (`route add -inet default 10.99.0.1`), not a gateway in `config.xml`. Core never removes a kernel default route when no gateway is configured, so a config gateway needs a manual `route delete` afterwards anyway | [CORE] system.inc:703-711 |
| Plugin without a package | tar over ssh into `/usr/local`, chmod, then the seven lines of the generated `+POST_INSTALL` | section 8 |

Legend: **UNCONFIRMED** = not confirmed from a primary source. "by code" = read in source, never run. Source tags are listed in section 12. Core paths are from the local clone of opnsense/core **master** (5de9cc0, 2026-10-10); "26.7 checked" means the same file on branch stable/26.7 was read as a fetched excerpt and agrees.

---

## 1. Which image

### 1.1 The four images of 26.7

Directory `https://pkg.opnsense.org/releases/26.7/` (listing read 2026-10-12) [REL]:

| File | Size | What it is |
|---|---|---|
| `OPNsense-26.7-dvd-amd64.iso.bz2` | 471M | ISO, live system and installer, VGA console, "UEFI hybrid" |
| `OPNsense-26.7-vga-amd64.img.bz2` | 471M | USB image, live system and installer, VGA console, "UEFI hybrid" |
| `OPNsense-26.7-serial-amd64.img.bz2` | 471M | USB image, live system and installer, serial console 115200, "UEFI hybrid" |
| `OPNsense-26.7-nano-amd64.img.bz2` | 468M | preinstalled system, serial console 115200 first, VGA second; "about 3 GB", "resizes itself to the installed media after first boot" |
| `OPNsense-26.7-checksums-amd64.sha256` | 436 bytes | not read for this sheet. 436 bytes is exactly four lines of the form `SHA256 (<file>.bz2) = <64 hex>` for the four `.bz2` names, so the hashes are expected to be of the compressed files, in BSD format: UNCONFIRMED. The command in 1.2 takes the 64 hex digits from the line that names the file, whatever the format |

Also present: `*.sig`, `OPNsense-26.7.pub` (not needed for the checksum comparison).

| | nano | serial (vga: same build family, vga.sh not read: UNCONFIRMED) | dvd |
|---|---|---|---|
| Build script | `makefs -s 3G -B little -f 400000 -o version=2 -o label=OPNsense_Nano`, then on the image itself `gpart create -s BSD`, `gpart bootcode -b /boot/boot`, `gpart add -t freebsd-ufs` [TOOLS] nano.sh | `mkimg -s gpt -b pmbr [-p efi:=efiboot.img] -p freebsd-boot:=gptboot [-p freebsd-swap::512k] -p freebsd-ufs:=root.part` [TOOLS] serial.sh | ISO |
| Partition scheme | BSD disklabel on the whole disk, one UFS2 partition starting at offset 0 ("assume schema ada0a used by nano images", [CORE] src/etc/rc:53) | GPT with protective MBR, EFI partition, BIOS boot partition, UFS | ISO 9660 |
| Firmware | BIOS only | BIOS and UEFI | BIOS and UEFI |
| Hyper-V | **Generation 1** only | Generation 1 or 2 (Secure Boot off: "Secure Boot must be disabled" [DOC-V]) | Generation 1 or 2 |
| Root file system | `/dev/ufs/OPNsense_Nano / ufs rw,noatime 1 1 # notrim` [TOOLS] | `/dev/ufs/OPNsense_Install / ufs ro,noatime`, `/tmp` tmpfs: live, read-only | read-only |
| Boots into | the installed system, directly | live system; install needs login `installer` / `opnsense` and a dialog-driven installer [DOC-I] | same |
| Console at first boot | `boot.config`: `-S115200 -h -D`; `loader.conf`: `comconsole_speed="115200"`, `console="comconsole,vidconsole"`, `boot_multicons="YES"`, `boot_serial="YES"`. Factory config gets `<serialspeed>115200`, `<primaryconsole>serial`, `<secondaryconsole>video` [TOOLS] extras.conf nano_hook | serial only | VGA |
| Size after decompression | 3 GiB (3221225472 bytes, from `NANOSIZE="3G"`) | UNCONFIRMED | UNCONFIRMED |
| Grows on first boot | yes: image contains `/.probe.for.growfs` [TOOLS]; core's rc then runs `gpart recover <disk>`, `gpart resize -i 1 <disk>`, `growfs -y /` and removes the marker ([CORE] src/etc/rc:47-62, 125-138, 164) | no (installer partitions the target) | no |
| Other nano specifics | factory config also gets `use_mfs_tmp`, Hostwatch disabled, `<rrd>` removed; `loader.conf` gets `kern.cam.boot_delay="10000"` (10 s pause at first boot; core regenerates `loader.conf` during that boot) [TOOLS] | | |

Consequences for the nano image on Hyper-V:

- The serial console is first. Programs started by rc write to the first console only (FreeBSD behaviour, from general knowledge, not from a source read for this sheet: UNCONFIRMED; OPNsense's page says of the nano image "secondary VGA support (no kernel messages though)" [DOC-I]). **Expect the VM window to show little or nothing during the first boot until the login prompt.** The importer prompt and any interface-assignment prompt appear on COM1 only. After the first boot the console order follows `config.xml` (`system.primaryconsole`, [CORE] system.inc:1226-1261), which the lab configuration sets to VGA first.
- The disk must be enlarged **before** the first boot (the marker is deleted during it). To grow later: `touch /.probe.for.growfs` and reboot (by code, same rc lines).
- OPNsense documentation: "Minimum required RAM is 3 GB", "Minimum recommended virtual disk size of 8 GB" [DOC-V]. Suggested: 3 GB or 4 GB static memory, 2 vCPU, 16 GB dynamic VHDX (base set 93M, kernel set 32M and the package upgrade need room; a dynamic disk costs only what is written).

### 1.2 From download to VHDX

Not run for this sheet. One container at a time.

```bash
# from Git Bash at the top of the checkout
# 1. verify and decompress (sha256sum is in busybox; bzip2 from apk)
MSYS_NO_PATHCONV=1 wslc.exe run --rm -v "$(cygpath -w "$PWD/lab/.work"):/work" alpine:3.22 sh -c '
  set -e; apk add --no-cache bzip2 >/dev/null
  cd /work/cache
  want=$(grep -F "OPNsense-26.7-nano-amd64.img.bz2" OPNsense-26.7-checksums-amd64.sha256 | grep -oE "[0-9a-f]{64}" | head -n 1)
  have=$(sha256sum OPNsense-26.7-nano-amd64.img.bz2 | cut -d" " -f1)
  [ -n "$want" ] && [ "$want" = "$have" ] || { echo "CHECKSUM MISMATCH want=$want have=$have"; exit 1; }
  bzip2 -dc OPNsense-26.7-nano-amd64.img.bz2 > /work/disks/clat-opn.raw
  ls -l /work/disks/clat-opn.raw' 2>&1 | tr -d '\0'
# expected size: 3221225472

# 2. seed the lab configuration (section 5.2)
MSYS_NO_PATHCONV=1 wslc.exe run --rm -e PYTHONDONTWRITEBYTECODE=1 -v "$(cygpath -w "$PWD/lab"):/lab" python:3.11-alpine \
  python -I /lab/seed_config.py /lab/.work/disks/clat-opn.raw /lab/.work/disks/clat-opn-config.xml 2>&1 | tr -d '\0'

# 3. convert
MSYS_NO_PATHCONV=1 wslc.exe run --rm -v "$(cygpath -w "$PWD/lab/.work"):/work" alpine:3.22 sh -c '
  set -e
  apk add --no-cache qemu-img >/dev/null
  qemu-img convert -p -f raw -O vhdx -o subformat=dynamic /work/disks/clat-opn.raw /work/disks/base-opnsense-26.7.vhdx
  qemu-img info /work/disks/base-opnsense-26.7.vhdx' 2>&1 | tr -d '\0'
```

- The file is a plain raw disk image, so `-f raw` is right. `subformat=dynamic` is qemu-img's VHDX option name (UNCONFIRMED here: qemu-img was not run for this sheet).
- Enlarging: use the mechanics sheet's `Resize-VHD -Path <disk> -SizeBytes 16GB` on the VM's copy before the first start. A qemu-only way, UNCONFIRMED: `qemu-img create -f vhdx -o subformat=dynamic out.vhdx 16G` then `qemu-img convert -n -f raw -O vhdx clat-opn.raw out.vhdx`. Do not enlarge the raw file on the checkout's volume (on NTFS that may allocate the full size).
- The seeding step must run on the raw file, before conversion, and on a fresh decompression each time (the script refuses a file it has already changed).
- Sparse flag, ACLs and Hyper-V's own `Convert-VHD`: mechanics sheet, section 5.

---

## 2. Hyper-V specifics for OPNsense 26.7 (FreeBSD 15.1)

| Topic | Fact | Source |
|---|---|---|
| Base | opnsense/src stable/26.7 is FreeBSD 15.1-RELEASE-p4 (`sys/conf/newvers.sh`: REVISION 15.1, BRANCH RELEASE-p4) | [SRC] |
| Kernel | OPNsense kernel config `SMP` starts with `include GENERIC`; GENERIC has `device hyperv`. OPNsense's `src.conf` has no `WITHOUT_HYPERV` | [TOOLS] config/26.7/SMP, [SRC] sys/amd64/conf/GENERIC:367 |
| NIC driver and names | synthetic adapters are `hn0`, `hn1`, ... ("Hyper-V Network Interface", if_hn.c). Use the normal "Network Adapter", not the legacy one | [SRC] sys/dev/hyperv/netvsc/if_hn.c:2078 |
| NIC order | units are given in the order the VMBus channels are offered: each offer is queued to one attach task queue (`vmbus_chan.c`: `TAILQ_INSERT_TAIL`, `taskqueue_enqueue(chan->ch_mgmt_tq, &chan->ch_attach_task)`). That Hyper-V offers them in the order the adapters were added to the VM is **UNCONFIRMED**. Netgate's guide implies it (first adapter `hn0`, second `hn1`) and says to compare MAC addresses. A 2015 guest-side race that swapped units (FreeBSD bug 205156) is fixed. Use static MACs and check once | [SRC], [NG], search result for bug 205156 |
| OPNsense's own order | `get_interface_list()` follows `ifconfig -l`; the automatic assignment takes the first as LAN, the second as WAN | [CORE] interfaces.lib.inc:607-665, console.inc:181-221 |
| MTU | `hn(4)` accepts `SIOCSIFMTU` up to `HN_MTU_MAX`; Microsoft: "9126 is the maximum supported MTU size" for FreeBSD guests. OPNsense applies the WAN `mtu` value unchanged to the PPPoE parent device (see DESIGN 8.3 and docs/research/mtu-1), so `<mtu>1508</mtu>` on WAN sets `hn1` to 1508. Whether a private switch passes such frames: mechanics sheet section 3 | [SRC] if_hn.c:3736, [MS-FBSD] |
| Offloads | hardware checksum, TSO and LRO are off by default in OPNsense (model defaults `disablechecksumoffloading`, `disablesegmentationoffloading`, `disablelargereceiveoffloading` = 1); OPNsense's virtualisation page says to keep them off | [CORE] Interfaces/Settings.xml:7-18, [DOC-V] |
| Disk | Generation 1 boots from the IDE controller only. FreeBSD attaches Hyper-V IDE disks through `storvsc` ("Hyper-V IDE", a CAM SIM), so the disk is `da0`, a second one `da1`; the Generation 1 DVD drive is `cd0` (UNCONFIRMED name). The nano fstab uses the label `/dev/ufs/OPNsense_Nano`, so the device name does not matter | [SRC] storvsc/hv_storvsc_drv_freebsd.c:279-282, 1160 |
| Serial | Generation 1 has emulated COM1/COM2; `uart` is in GENERIC. `Set-VMComPort -VMName clat-opn -Number 1 -Path '\\.\pipe\clat-opn-com1'`; speed 115200. Opening the pipe needs an elevated process (mechanics sheet) | [SRC] GENERIC:220 |
| Integration services in the kernel | heartbeat, guest shutdown, time sync, KVP, VSS snapshot (`sys/dev/hyperv/utilities/`: vmbus_heartbeat.c, vmbus_shutdown.c, vmbus_timesync.c, hv_kvp.c, hv_snapshot.c) | [SRC] |
| KVP daemon (host sees guest addresses) | base ships `/etc/devd/hyperv.conf`: when `hv_kvp_dev` appears, devd runs `/usr/sbin/hv_kvp_daemon`; OPNsense starts stock `/sbin/devd` (`system_devd_configure()`). So `(Get-VMNetworkAdapter -VMName clat-opn).IPAddresses` should fill. That the daemon really runs on OPNsense 26.7: **UNCONFIRMED**; check `pgrep -lf hv_kvp_daemon` | [SRC] sbin/devd/hyperv.conf, [CORE] system.inc:1097-1106 |
| Time | Hyper-V time sync in the kernel keeps the clock; NTP is not needed for the lab | [SRC] |
| Memory | no Dynamic Memory for FreeBSD guests (both rows empty); use static memory | [MS-FBSD] |
| Secure Boot | not supported for FreeBSD; irrelevant on Generation 1 | [MS-FBSD] [DOC-V] |
| MAC spoofing | not needed on clat-opn: PPPoE uses the adapter's own MAC, there is no CARP or bridge. (clat-world may need it for a namespace on a macvlan or bridge; world sheet) | reasoning |
| Guards | DHCP guard and router guard must stay off on clat-opn's LAN adapter (it serves DHCP and RAs) and on clat-world's adapters | reasoning |
| Microsoft's support table | lists FreeBSD up to 13.5 only; 15.x is not listed. OPNsense: "Both Hyper-V Generation 1 and 2 virtual machines are supported out of the box" | [MS-FBSD] [DOC-V] |

### 2.1 Known problems

1. **26.7.6 kernel on Hyper-V: userland crashes.** Forum topic 53114 (opened 2026-10-08, "26.7.6: unbound (and syslog-ng) segfault with signal 11 after upgrade (Hyper-V)"): after the update to 26.7.6, `unbound` exits on signal 11 every 6 to 15 minutes, `syslog-ng` signal 11, `python3.13` signal 6; reported on Intel (Xeon E-2236) and AMD hosts; not seen on hardware. Cause, per the thread and the issue: a Hyper-V TLB patch that went into the 26.7.6 kernel for opnsense/src#297 (commit 5b7b70e, 2026-10-06, "hyperv: fix single page invalidation path", `sys/dev/hyperv/vmbus/hyperv_mmu.c`). Follow-up commit 412e762 (2026-10-09, "hyperv: two possible issues with patch") is the head of stable/26.7. Remedies named in the thread: `opnsense-update -zkr 26.7.6-hyperv` (test kernel; `kernel-26.7.6-hyperv-amd64.txz`, 32M, exists under `FreeBSD:15:amd64/snapshots/sets/`), or go back with `opnsense-update -kr 26.7.4` and reboot. franco, 2026-10-09: "We'll pick this up in a small .7 early next week." On 2026-10-12 the sets directory holds kernels 26.7, 26.7.2, 26.7.3, 26.7.4 and 26.7.6 only. [FORUM] [SRC297] [SETS]
   - The plugin runs under `/usr/local/bin/python3` (3.13 on 26.7, going by the crash reports) and resolves through unbound. This bug would look like a plugin defect. **Rule for the lab: never boot kernel 26.7.6.** Section 7.3 has the commands.
   - Extra guard, by code: the tunable `hw.vmbus.tlb_hcall` (read-only, loader tunable, default 1) decides whether the kernel replaces its TLB shootdown with the Hyper-V hypercall version (`if (hv_tlb_hcall) smp_targeted_tlb_shootdown = &hyperv_vm_tlb_flush;`). With `hw.vmbus.tlb_hcall=0` the patched code is not used at all. The lab configuration sets it. That this avoids the 26.7.6 crashes was not reported by anyone in the thread: UNCONFIRMED. [SRC] sys/dev/hyperv/vmbus/vmbus.c:155-157, 1519, 1543
2. **AMD Zen 1 / Zen 2 hosts**: kernel panic when a module is loaded with more than one vCPU (opnsense/src#297, 26.7 RC1 to 26.7.5). An Intel Xeon E-2336 was reported unaffected. Workaround there: the same tunable. [SRC297]
3. Interface names changing between boots: reports from 2016 only. [search]
4. Automatic checkpoints, stop action, file ACLs: mechanics sheet.
5. Lockout: more than 5 failed logins from one address ("Authentication error for ...", "Web GUI authentication error", "Invalid user") put that address into pf table `sshlockout`. A provisioning loop that tries wrong passwords from 10.99.0.1 locks clat-world out. Poll with a TCP connect, authenticate only with the right key. Clear with `pfctl -t sshlockout -T flush` on the console. [CORE] scripts/syslog/lockout_handler:39-110

---

## 3. First boot

### 3.1 With the factory configuration (nothing seeded)

Sequence, [CORE] src/etc/rc (26.7 not re-read; `opnsense-importer` and `console.inc` are 26.7 checked):

1. Loader (`autoboot_delay="3"`), kernel, 10 s CAM delay on the nano image.
2. rc: grow partition and file system (marker), `fsck`, `mount -a`.
3. `rc.syshook import` runs `/usr/local/sbin/opnsense-importer -b` (section 4): 7 seconds, then "Bootstrapping config.xml...done." (`cp /usr/local/etc/config.xml /conf/config.xml`).
4. `rc.bootup`: the factory config names devices `mismatch1` (WAN) and `mismatch0` (LAN), so `is_interface_mismatch()` is true: "Default interfaces not found -- Running interface assignment option." then "Press any key to start the manual interface assignment: " with a 7-second timeout (`timeout($wait = 7)`). Without a key the answers are given automatically: LAGGs `n`, VLANs `n`, **WAN = second interface** (`$ifnames[1]`), **LAN = first interface** (`$ifnames[0]`), no optional interface ("never configure OPT in automatic assign"), proceed `y`. [CORE] console.inc:31-46, 105-110, 186-221, 265-271, 336-341
5. Result ([CORE] config.xml.sample, 26.7 checked; console.inc:352-430):
   - LAN = `hn0`, 192.168.1.1/24, IPv6 `idassoc6` tracking WAN, prefix id 0.
   - WAN = `hn1`, IPv4 DHCP, IPv6 DHCPv6 (`dhcp6-ia-pd-len` 0), block private and bogon networks.
   - `hn2` unassigned.
   - DHCP on LAN by **dnsmasq** (`<dnsmasq><enable>1`, port 53053, ranges 192.168.1.100 to 192.168.1.199 and `::1000` to `::2000` with `ra_mode` slaac, `enable_ra` 1); DNS by unbound.
   - Firewall: two MVC rules "Default allow LAN to any rule" (inet) and "Default allow LAN IPv6 to any rule"; outbound NAT automatic.
   - User `root`, password `opnsense` (hash `$2y$10$YRVoF4SgskIsrXOvOQjGieB9XqHPRra9R7d80B3BZdbY/j21TwBfS`; "user root, password opnsense" [DOC-I]).
   - Web GUI https on all interfaces; `<trigger_initial_wizard/>` sends the first GUI login to the wizard.
   - **SSH off**: sshd runs only if `system.ssh.enabled` is set, or on install media (`is_install_media()`: root not writable). The nano root is writable. [CORE] openssh.inc:31-37, util.inc:1203 (26.7 checked)
   - Console: `<disableconsolemenu/>` is in the factory config and `isset()` is true for it, so the console asks for a login (getty type `Pc`/`3wire.115200` instead of the autologin types). [CORE] system.inc:1297-1303
6. Total wait added by prompts: 14 seconds. Nothing blocks.

### 3.2 With the seeded lab configuration (section 6)

- Step 3 is the same (7 seconds; `/conf/config.xml` does not exist yet), but the file copied is the lab configuration.
- Step 4 does not prompt: `hn0` and `hn2` exist, and `pppoe0` matches the volatile device pattern `^l2tp|^ppp`, which the mismatch test skips. [CORE] console.inc:48-76, plugins.inc.d/core.inc:234-239
- First boot also creates SSH host keys (rsa, ecdsa, ed25519, mldsa44-ed25519 in `/conf/sshd`) and the GUI certificate. Allow several minutes; time is UNCONFIRMED.
- During that boot core rewrites `/boot.config` and `/boot/loader.conf` from the configuration (console order, speed, and every `<sysctl>` item as a loader tunable). They take effect at the **second** boot. [CORE] system.inc:1201-1289

---

## 4. The configuration importer

Read: [CORE] src/sbin/opnsense-importer (26.7 checked, identical in the points below), src/etc/rc:188-189, src/etc/rc.syshook.d/import/20-importer.

- **When**: on every boot, early (before PHP is set up): `rc` runs `/usr/local/etc/rc.syshook import`, whose only script runs `/usr/local/sbin/opnsense-importer -b`.
- **With `-b`**:
  - `touch /.probe.for.readonly`; if that file exists (root is writable) **and** `/conf/config.xml` exists: exit at once, no prompt. This is every boot of an installed system after the first.
  - otherwise: prompt `Press any key to start the configuration importer: .......` (one dot per second, 7 seconds, `timeout 1 dd of=/dev/null count=1`). No key: `bootstrap_and_exit 0`, which creates `/conf/backup`, `/conf/sshd` and, if `/conf/config.xml` is missing, runs `cp /usr/local/etc/config.xml /conf/config.xml`.
  - key pressed: prints `camcontrol devlist` (plus ZFS pools, gmirror, graid) and asks `Select device to import from (e.g. ada0) or leave blank to exit: `. Blank exits; `!` opens csh.
- **No automatic search.** Nothing is probed without the typed device name. With only `-b` there is no code path that imports without a key press.
- **What it tries on the named device, in this order** (`import_start`): `/dev/<dev>s1a` as ufs; `/dev/<dev>p3` as ufs; a ZFS pool of that name (`<pool>/ROOT/default`); `/dev/<dev>s1` as msdos; `/dev/<dev>p1` as msdos; `/dev/<dev>` itself as cd9660. UFS gets `fsck -y` first.
- **What it takes**: only if `<mnt>/conf/config.xml` exists (decrypted with `opnsense-crypt` if it starts with `---- BEGIN config.xml ----`): `rm -rf /conf/*`, then copies `conf/captiveportal.sqlite`, `conf/config.xml`, `conf/netflow.tgz`, `conf/rrd.tgz`, `/var/db/dhcp6c_duid`, directories `conf/backup` and `conf/sshd` (host keys; `chmod 600` on `*key`). Otherwise "The file /conf/config.xml could not be found." and it asks again.
- Documentation agrees: press a key at "Press any key to start the configuration importer", type the device (`da0`, `nvd0`); the second drive is "formatted with FAT or FAT32", file at `/conf/config.xml`. [DOC-I]
- Other options: `-m` shell on the mounted device, `-p` reset root password, `-z` list pools.

**Answer: a second VHDX with FAT and `conf/config.xml` does not make the first boot unattended.** It only supplies the file for someone (or a serial script) who presses a key and types `da1`. By code an ISO works as well (`cd0`, cd9660) and is easier to make.

---

## 5. Getting the lab configuration in without anyone at the console

### 5.1 Path A (recommended): put the configuration into the image

Why it works, from primary sources:

- The image has no `/conf/config.xml`: tools creates only the empty `/conf` directory, the nano hook edits `CONFIG_XML="/usr/local/etc/config.xml"`, and core says of image builds "abort in case of no valid config for image install". [TOOLS] common.sh, [CORE] rc.configure_plugins:30-33. Confirmation on the real image is the script's own check below.
- So the first boot copies `/usr/local/etc/config.xml` to `/conf/config.xml` (section 4). Whatever that file contains is the first configuration.
- `/usr/local/etc/config.xml` is a small plain file in a UFS2 file system made by `makefs`. A file smaller than one block is one contiguous run of fragments, UFS2 has no data checksums, and the partition starts at image offset 0. Overwriting the file's bytes in the raw image with **exactly the same number of bytes** changes the content and nothing else. (UFS layout statement from general knowledge, not from a source read for this sheet: UNCONFIRMED; the script checks what it can.)
- The image holds two copies of the factory configuration: `config.xml.sample` (pristine; `@sample` in core's plist:2621 makes pkg copy it to `config.xml` at install) and `config.xml` (changed by the nano hook). Only the second is the one the importer copies. It is recognised by `<primaryconsole>serial</primaryconsole>`, which only the nano hook adds.
- Size: the stable/26.7 sample is about 5022 bytes with LF line ends; the nano copy is that plus the hook's lines. The lab configuration, with white space between elements removed, is about 4212 bytes with realistic key lengths. It fits with about 800 bytes to spare **if** the nano copy is not smaller than the sample: UNCONFIRMED until the real image is read (the dry run prints the length).
- Side effects to know: the patched file is also the box's factory default: core's fall-back "No valid config.xml found, attempting to restore factory config." loads it ([CORE] Core/Config.php:343-345, config/config.php:40 `configDefault`), and a factory reset (`rm -fr /conf/* /var/log/* /root/.history`, then shutdown, [CORE] system.inc:1350) ends in the same bootstrap copy at the next boot. That is convenient for the lab: "reset to factory defaults" returns to the lab configuration. A package upgrade keeps it: `@sample` only copies when the target is missing. If the patched file were not well-formed XML the box could not recover by itself; the script parses the result before and after writing.

### 5.2 seed_config.py

Tested 2026-10-12 in `python:3.11-alpine` against a 3 MiB synthetic file holding a pristine sample, a "nano" copy and a decoy config: dry run, replacement, read-back, refusal of a second run, sample left intact. Not run against a real image.

```python
#!/usr/bin/env python3
"""Replace the factory config.xml inside an OPNsense nano raw image, in place.

    seed_config.py IMAGE.raw [CONFIG.xml]

Without CONFIG.xml it only reports what it finds (dry run).

Why this works: the nano image has no /conf/config.xml.  On first boot
"opnsense-importer -b" waits 7 seconds for a key and then copies
/usr/local/etc/config.xml to /conf/config.xml (core src/sbin/opnsense-importer,
bootstrap_and_exit).  The file is small, so its data is one contiguous run in
the UFS2 file system, and UFS2 has no data checksums.  Overwriting exactly the
same number of bytes therefore changes the file content and nothing else.

The image holds two copies of the factory config: config.xml.sample (pristine)
and config.xml (changed by the nano build: serial console first).  Only the
second one is replaced; it is recognised by NANO_MARK.
"""
import hashlib
import re
import sys
import xml.etree.ElementTree as ET

HEAD = b'<?xml version="1.0"?>\n<opnsense>'
TAIL = b'</opnsense>\n'
FACTORY_MARK = b'<trigger_initial_wizard/>'
NANO_MARK = re.compile(rb'<primaryconsole>\s*serial\s*</primaryconsole>')
CHUNK = 32 * 1024 * 1024
MAXLEN = 32768          # one UFS2 block: a file below this size is contiguous


def find_all(path, needle):
    found, pos, prev = [], 0, b''
    with open(path, 'rb') as handle:
        while True:
            buf = handle.read(CHUNK)
            if not buf:
                break
            data = prev + buf
            base = pos - len(prev)
            idx = data.find(needle)
            while idx != -1:
                found.append(base + idx)
                idx = data.find(needle, idx + 1)
            prev = data[-(len(needle) - 1):]
            pos += len(buf)
    return found


def candidates(path):
    out = []
    with open(path, 'rb') as handle:
        for off in find_all(path, HEAD):
            handle.seek(off)
            data = handle.read(MAXLEN)
            end = data.find(TAIL)
            if end == -1:
                continue
            body = data[:end + len(TAIL)]
            out.append({
                'offset': off,
                'length': len(body),
                'factory': FACTORY_MARK in body,
                'nano': bool(NANO_MARK.search(body)),
                'aligned': off % 512 == 0,
                'sha256': hashlib.sha256(body).hexdigest(),
            })
    return out


def minify(path):
    root = ET.parse(path).getroot()          # also proves well-formedness
    if root.tag != 'opnsense':
        raise SystemExit('root element is <%s>, expected <opnsense>' % root.tag)
    for node in root.iter():
        if node.text is not None and not node.text.strip():
            node.text = None
        if node.tail is not None and not node.tail.strip():
            node.tail = None
    text = ET.tostring(root, encoding='unicode', short_empty_elements=True)
    return b'<?xml version="1.0"?>\n' + text.encode('utf-8')


def main(argv):
    if len(argv) not in (2, 3):
        raise SystemExit(__doc__)
    image = argv[1]
    found = candidates(image)
    for item in found:
        print('candidate offset=%(offset)d length=%(length)d factory=%(factory)s '
              'nano=%(nano)s aligned=%(aligned)s sha256=%(sha256)s' % item)
    targets = [c for c in found if c['factory'] and c['nano'] and c['aligned']]
    factory = [c for c in found if c['factory']]
    if len(targets) != 1 or len(factory) != 2:
        raise SystemExit('STOP: expected 2 factory configs of which 1 is the nano one, found '
                         '%d and %d. Do not boot this image unattended; use the fallback.'
                         % (len(factory), len(targets)))
    target = targets[0]
    if len(argv) == 2:
        print('dry run: would replace %(length)d bytes at offset %(offset)d' % target)
        return
    new = minify(argv[2])
    room = target['length'] - len(new) - 1
    if room < 0:
        raise SystemExit('STOP: new config is %d bytes too long (%d available)'
                         % (-room, target['length'] - 1))
    close = b'</opnsense>'
    if not new.endswith(close):
        raise SystemExit('STOP: unexpected serialisation')
    new = new[:-len(close)] + b' ' * room + close + b'\n'
    assert len(new) == target['length']
    with open(image, 'r+b') as handle:
        handle.seek(target['offset'])
        handle.write(new)
        handle.flush()
    with open(image, 'rb') as handle:          # read back and parse again
        handle.seek(target['offset'])
        back = handle.read(target['length'])
    ET.fromstring(back.decode('utf-8'))
    if back != new:
        raise SystemExit('STOP: read-back differs')
    print('replaced %d bytes at offset %d (%d bytes of padding), new sha256=%s'
          % (target['length'], target['offset'], room, hashlib.sha256(back).hexdigest()))


if __name__ == '__main__':
    main(sys.argv)
```

What the output must show on the real image, before anything is booted:

- exactly two `factory=True` candidates, one of them `nano=True aligned=True`; any other count means the assumption about the image is wrong: stop and use Path B;
- `length` of the nano candidate at least 4213 (or whatever the final configuration needs); if it is too small, shorten the configuration (drop `<ntpd>` and `<timeservers>`, about 310 bytes; Hyper-V keeps the clock);
- on a 3 GiB file the search reads the whole file once.

The padding is spaces in front of `</opnsense>`, inside the root element. OPNsense rewrites `/conf/config.xml` in its own formatting at the first save (`convert_config()` during the first boot).

### 5.3 What Path A leaves to confirm at first boot

1. A Generation 1 VM boots the disk from IDE 0:0 (BSD disklabel, no MBR partition table of its own: UNCONFIRMED on Hyper-V).
2. The file system grows to the VHDX size (`df -h /`).
3. No prompt blocks; `10.99.0.2` answers on the management switch; `ssh` with the key works; `hostname` is `clat-opn.internal`.
4. `ifconfig hn0`, `ifconfig hn1` and `ifconfig hn2` show, in their `ether` lines, the MACs the adapters were given in that order. If not: do not edit the configuration; reconnect the adapters to the switches so that the adapter that became `hn0` is on the LAN switch, `hn1` on WAN, `hn2` on management (`Connect-VMNetworkAdapter`), or regenerate with other `@@..._IF@@` values. To find the mapping without a login: the host's `IPAddresses` per adapter (KVP), or from clat-world `arping -I <each lab interface> 10.99.0.2`.

### 5.4 Path B (fallback): factory defaults, then restore through the web GUI from clat-world

Needs the adapter that becomes `hn0` on the LAN switch (section 3.1) and clat-world with an address in 192.168.1.0/24 on that switch (static 192.168.1.2/24, or a DHCP lease from OPNsense). By code ([CORE] src/www/csrf.inc, authgui.inc:132-216, diag_backup.php:176-372, 684-686; master, 26.7 not re-read), never run:

```sh
#!/bin/sh
# usage: opn-web-restore.sh /path/config.xml [https://192.168.1.1]
set -eu
CONF=$1; OPN=${2:-https://192.168.1.1}; JAR=$(mktemp)
tok() { sed -n 's/.*<input type="hidden" name="\([^"]*\)" value="\([^"]*\)" autocomplete="new-password" \/>.*/\1=\2/p' | head -n 1; }
T=$(curl -sk -c "$JAR" -b "$JAR" "$OPN/" | tok)
[ -n "$T" ] || { echo "no CSRF field on the login page"; exit 1; }
code=$(curl -sk -c "$JAR" -b "$JAR" -o /dev/null -w '%{http_code}' \
  --data-urlencode "${T%%=*}=${T#*=}" --data-urlencode usernamefld=root \
  --data-urlencode passwordfld=opnsense --data-urlencode login=1 "$OPN/")
[ "$code" = 302 ] || { echo "login failed, HTTP $code"; exit 1; }
T=$(curl -sk -c "$JAR" -b "$JAR" "$OPN/diag_backup.php" | tok)
curl -sk -c "$JAR" -b "$JAR" -o /tmp/opn-restore.html -w '%{http_code}\n' \
  -F "${T%%=*}=${T#*=}" -F "conffile=@${CONF};type=text/xml" \
  -F rebootafterrestore=on -F flush_history=on -F "restore=Restore configuration" "$OPN/diag_backup.php"
grep -o 'The configuration has been restored[^<]*' /tmp/opn-restore.html
```

- Every POST to a legacy page needs the session's CSRF field; its **name is random per session** and is inserted after each `<form method="post">` as `<input type="hidden" name="KEY" value="TOKEN" autocomplete="new-password" />`. A missing or wrong token gives "403 Forbidden", "CSRF check failed".
- Login fields: `usernamefld`, `passwordfld`, `login=1`; success is a redirect.
- Restore fields: `restore` (any non-empty value), file `conffile`, `rebootafterrestore`, `flush_history`; leave `keepconsole` out so the console settings of the uploaded file apply; leave `restorearea[]` out for a full restore. The page then calls `configd_run('system reboot', true)`. If the uploaded configuration names a missing device the reboot is postponed ("Interfaces do not seem to match").
- The API cannot do this step with the root password: the API accepts only key and secret (Basic auth, authenticator "Local API"), and core has no restore-upload API (`BackupController` has `providers`, `backups`, `diff`, `deleteBackup`, `revertBackup`, `download`).
- Do not send a `Referer` from another host name; access by IP address (DNS-rebind and referer checks, authgui.inc:107-167).

### 5.5 Path C (fallback, elevated PowerShell only): serial pipe and the importer

Attach an ISO made with `xorriso -as mkisofs -R -o clat-opn-config.iso <dir>` (the directory contains `conf/config.xml`) to the Generation 1 DVD drive, or a second disk with an MBR FAT partition. COM1 to a pipe. A reader must be connected before the VM starts. Texts to wait for and what to send:

| Wait for | Send |
|---|---|
| `Press any key to start the configuration importer:` | one byte, for example CR (within 7 seconds) |
| `leave blank to exit:` | `cd0` + CR (or `da1` + CR for a disk) |
| `Restoring config.xml...done.` | nothing; boot continues |
| only if devices do not match: `Press any key to start the manual interface assignment:` | nothing; 7 seconds later the automatic assignment runs (section 3.1) |

Sketch, UNCONFIRMED (never run; pipe access rules are in the mechanics sheet):

```powershell
$pipe = [System.IO.Pipes.NamedPipeClientStream]::new('.', 'clat-opn-com1', [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(60000)
$buf = New-Object byte[] 4096; $text = ''; $pos = 0
foreach ($s in @(@('Press any key to start the configuration importer:', "`r"),
                 @('leave blank to exit:', "cd0`r"),
                 @('Restoring config.xml...done.', $null))) {
    while (($i = $text.IndexOf($s[0], $pos)) -lt 0) {
        $n = $pipe.Read($buf, 0, $buf.Length); if ($n -le 0) { throw 'pipe closed' }
        $text += [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    }
    $pos = $i + $s[0].Length
    if ($s[1]) { $b = [Text.Encoding]::ASCII.GetBytes($s[1]); $pipe.Write($b, 0, $b.Length); $pipe.Flush() }
}
```

The same pipe, read to a file, gives a boot log of the first boot (the only console that shows it on the nano image).

### 5.6 Path D: by hand

`vmconnect.exe localhost clat-opn`, log in `root` / `opnsense` after the first boot, menu option 8 (shell). The console menu, verbatim [CORE] src/sbin/opnsense-shell:

```
  0) Logout                              7) Ping host
  1) Assign interfaces                   8) Shell
  2) Set interface IP address            9) pfTop
  3) Reset the root password            10) Firewall log
  4) Reset to factory defaults          11) Reload all services
  5) Power off system                   12) Update from console
  6) Reboot system                      13) Restore a backup
```

Prompt: `Enter an option: `. Option 1 runs the dialogue of section 3.1 interactively; option 2 sets an address.

---

## 6. config.xml for the lab

### 6.1 The file

Based on stable/26.7 `src/etc/config.xml.sample` (read as a fetched excerpt; it differs from master only by master's `<noroot>1</noroot>` under `<webgui>`). Differences from the sample are listed in 6.2. `@@...@@` are filled by the lab generator (6.3).

```xml
<?xml version="1.0"?>
<opnsense>
  <theme>opnsense</theme>
  <system>
    <optimization>normal</optimization>
    <hostname>clat-opn</hostname>
    <domain>internal</domain>
    <dnsallowoverride>1</dnsallowoverride>
    <dnsallowoverride_exclude/>
    <group>
      <name>admins</name>
      <description>System Administrators</description>
      <scope>system</scope>
      <gid>1999</gid>
      <member>0</member>
      <priv>page-all</priv>
    </group>
    <user>
      <name>root</name>
      <descr>System Administrator</descr>
      <scope>system</scope>
      <groupname>admins</groupname>
      <password>$2y$10$YRVoF4SgskIsrXOvOQjGieB9XqHPRra9R7d80B3BZdbY/j21TwBfS</password>
      <uid>0</uid>
      <authorizedkeys>@@AUTHORIZED_KEYS_B64@@</authorizedkeys>
      <apikeys>@@API_KEY@@|@@API_SECRET_CRYPT@@</apikeys>
    </user>
    <timezone>Etc/UTC</timezone>
    <timeservers>0.opnsense.pool.ntp.org 1.opnsense.pool.ntp.org 2.opnsense.pool.ntp.org 3.opnsense.pool.ntp.org</timeservers>
    <webgui>
      <protocol>https</protocol>
    </webgui>
    <disablenatreflection>yes</disablenatreflection>
    <usevirtualterminal>1</usevirtualterminal>
    <disableconsolemenu/>
    <ipv6allow>1</ipv6allow>
    <bogons>
      <interval>monthly</interval>
    </bogons>
    <pf_share_forward>1</pf_share_forward>
    <lb_use_sticky>1</lb_use_sticky>
    <ssh>
      <group>admins</group>
      <enabled>enabled</enabled>
      <permitrootlogin>1</permitrootlogin>
      <passwordauth>1</passwordauth>
    </ssh>
    <serialspeed>115200</serialspeed>
    <primaryconsole>video</primaryconsole>
    <secondaryconsole>serial</secondaryconsole>
  </system>
  <sysctl>
    <item>
      <tunable>hw.vmbus.tlb_hcall</tunable>
      <value>0</value>
      <descr>lab: Hyper-V TLB hypercalls off</descr>
    </item>
  </sysctl>
  <interfaces>
    <wan>
      <enable>1</enable>
      <if>pppoe0</if>
      <descr>WAN</descr>
      <ipaddrv6>dhcp6</ipaddrv6>
      <dhcp6-ia-pd-len>8</dhcp6-ia-pd-len>
      <blockpriv>1</blockpriv>
      <blockbogons>1</blockbogons>
    </wan>
    <lan>
      <enable>1</enable>
      <if>@@LAN_IF@@</if>
      <descr>LAN</descr>
      <ipaddr>192.168.1.1</ipaddr>
      <subnet>24</subnet>
      <ipaddrv6>idassoc6</ipaddrv6>
      <track6-interface>wan</track6-interface>
      <track6-prefix-id>0</track6-prefix-id>
    </lan>
    <opt1>
      <enable>1</enable>
      <if>@@MGMT_IF@@</if>
      <descr>MGMT</descr>
      <ipaddr>10.99.0.2</ipaddr>
      <subnet>24</subnet>
    </opt1>
  </interfaces>
  <ppps>
    <ppp>
      <ptpid>0</ptpid>
      <type>pppoe</type>
      <if>pppoe0</if>
      <ports>@@WAN_PORT@@</ports>
      <username>@@PPPOE_USER@@</username>
      <password>@@PPPOE_PASSWORD_B64@@</password>
    </ppp>
  </ppps>
  <dnsmasq>
    <enable>1</enable>
    <port>53053</port>
    <interface>lan</interface>
    <dhcp>
      <enable_ra>1</enable_ra>
    </dhcp>
    <dhcp_ranges>
      <interface>lan</interface>
      <start_addr>192.168.1.100</start_addr>
      <end_addr>192.168.1.199</end_addr>
    </dhcp_ranges>
    <dhcp_ranges>
      <interface>lan</interface>
      <start_addr>::1000</start_addr>
      <end_addr>::2000</end_addr>
      <constructor>lan</constructor>
      <ra_mode>slaac</ra_mode>
    </dhcp_ranges>
  </dnsmasq>
  <unbound>
    <enable>1</enable>
  </unbound>
  <nat>
    <outbound>
      <mode>automatic</mode>
    </outbound>
  </nat>
  <filter>
  </filter>
  <ntpd>
    <prefer>0.opnsense.pool.ntp.org</prefer>
    <ispool>0.opnsense.pool.ntp.org 1.opnsense.pool.ntp.org 2.opnsense.pool.ntp.org 3.opnsense.pool.ntp.org</ispool>
  </ntpd>
  <OPNsense>
    <Firewall>
      <Filter>
        <rules>
          <rule>
            <enabled>1</enabled>
            <statetype>keep</statetype>
            <sequence>1</sequence>
            <action>pass</action>
            <quick>1</quick>
            <interface>lan</interface>
            <direction>in</direction>
            <ipprotocol>inet</ipprotocol>
            <protocol>any</protocol>
            <source_net>lan</source_net>
            <destination_net>any</destination_net>
            <description>Default allow LAN to any rule</description>
          </rule>
          <rule>
            <enabled>1</enabled>
            <statetype>keep</statetype>
            <sequence>11</sequence>
            <action>pass</action>
            <quick>1</quick>
            <interface>lan</interface>
            <direction>in</direction>
            <ipprotocol>inet6</ipprotocol>
            <protocol>any</protocol>
            <source_net>lan</source_net>
            <destination_net>any</destination_net>
            <description>Default allow LAN IPv6 to any rule</description>
          </rule>
          <rule>
            <enabled>1</enabled>
            <statetype>keep</statetype>
            <sequence>21</sequence>
            <action>pass</action>
            <quick>1</quick>
            <interface>opt1</interface>
            <direction>in</direction>
            <ipprotocol>inet</ipprotocol>
            <protocol>any</protocol>
            <source_net>opt1</source_net>
            <destination_net>(self)</destination_net>
            <description>lab: MGMT to this firewall</description>
          </rule>
        </rules>
        <snatrules/>
        <npt/>
        <onetoone/>
      </Filter>
    </Firewall>
  </OPNsense>
</opnsense>
```

### 6.2 Element by element

| Element | Meaning and source |
|---|---|
| no `<trigger_initial_wizard/>` | the wizard is not offered ([CORE] src/www/index.php:35) |
| `system.hostname` / `domain` | `clat-opn.internal` |
| `system.user.password` | any hash `password_verify()` accepts ([CORE] Auth/Local.php:167). The sample's bcrypt hash is the password `opnsense`. The GUI writes `password_hash($password, PASSWORD_ARGON2ID)`, or `openssl passwd -6` (SHA-512 crypt) when the password policy option is on ([CORE] auth.inc:431-472, 26.7 checked). The system password database holds `*`; logins go through OPNsense's authenticator. The lab keeps `opnsense`: the box is on private switches only |
| `system.user.authorizedkeys` | **base64 of the text of `authorized_keys`** (one key per line). Core decodes it and writes `/root/.ssh/authorized_keys` at each account sync ([CORE] auth.inc:414-426, 26.7 checked) |
| `system.user.apikeys` | one line per key: the key, a vertical bar, the hash (as in 6.1), where hash is a crypt string of the secret; core creates it with `crypt($secret, '$6$')` and checks with `password_verify()`. The older form `<apikeys><item><key>..</key><secret>..</secret></item></apikeys>` is still read and converted ([CORE] Auth/FieldTypes/ApiKeyField.php, Auth/API.php:78-104; 26.7 checked). Key and hash must not contain a vertical bar |
| no `system.user.shell` | root's shell stays `/usr/local/sbin/opnsense-shell`. For `ssh host command` sshd runs `opnsense-shell -c "command"`, which does `exec /bin/csh -c "command"` ([CORE] src/sbin/opnsense-shell:25-45). So remote one-liners are parsed by **csh**. Send scripts as `ssh clat-opn /bin/sh -s < script.sh`. Alternative: add `<shell>/bin/sh</shell>` to the user (allowed for root, auth.inc:348-349); then the console shows a shell instead of the menu |
| `system.ssh` | `enabled` (any value; the GUI writes `enabled`), `permitrootlogin` and `passwordauth` (presence counts, `isset()`), optional `port`, optional `interfaces` (comma list such as `lan,opt1`; empty means all addresses). `AllowGroups wheel` is fixed. The lab leaves `interfaces` empty so sshd does not depend on address timing; WAN is closed by the default deny. Stricter alternative: `<interfaces>lan,opt1</interfaces>` ([CORE] openssh.inc:31-37, 95-199, 26.7 checked) |
| `system.primaryconsole` etc. | `video`, `serial`, `efi`, `null` ([CORE] system.inc:1169-1178). VGA first so `vmconnect` shows boot text and the login from the second boot on; serial second so a pipe reader still gets kernel messages and a login |
| `system.disableconsolemenu` | kept from the sample: console login needs the password |
| `sysctl.item` | `tunable`, `value`, `descr` (model `//sysctl`, [CORE] Core/Tunables.xml). Every item is written into `/boot/loader.conf` at boot ([CORE] system.inc:141-173, 1283-1289). Reason: section 2.1 |
| `interfaces.wan` | device `pppoe0`. **No `ipaddr` element = IPv4 Configuration Type None** (the GUI stores None as absence, [CORE] interfaces.php:649-690). With `ipaddrv6` `dhcp6` core writes `set bundle disable ipcp`, `set bundle enable ipv6cp` ([CORE] interfaces.inc:1059-1079, 1172-1173, 26.7 checked) |
| `dhcp6-ia-pd-len` | **8** = 64 minus 56: the delegation is a /56 (`sla-len 8`, `send ia-pd`). The sample's 0 means /64 |
| no `dhcp6prefixonly` | "Request only an IPv6 prefix" off: core also sends `send ia-na 0` (interfaces.inc:2980-2983, 3015-3017, 26.7 checked) |
| optional `<dhcp6-ia-pd-send-hint>1</dhcp6-ia-pd-send-hint>` | adds `prefix ::/56 infinity` to the request. Left out (customer default) |
| optional `<mtu>1508</mtu>` on wan | PPP MTU 1500 through `set pppoe max-payload 1500`; the value is also set on the parent `hn` device. Leave out for the default 1492 (interfaces.inc:1271-1279, 26.7 checked; DESIGN 8.3) |
| `blockpriv`, `blockbogons` on wan | kept as the wizard leaves them on customer boxes. Note for the world sheet: core's built-in bogon lists contain `2001:db8::/32`, `::/3` (which covers `64:ff9b::/96`), `192.0.0.0/24`, `192.0.2.0/24`, `198.18.0.0/15`, `198.51.100.0/24`, `203.0.113.0/24` ([CORE] src/etc/bogons.sample, bogonsv6.sample). The rule blocks such **sources** arriving on WAN for new connections only; replies to outbound traffic are matched by state. Unsolicited tests from the ISP side to the delegated prefix need real-looking sources or the option off |
| `interfaces.lan` | as the sample; `idassoc6` with `track6-interface` `wan`, `track6-prefix-id` 0: the first /64 of the /56 |
| `interfaces.opt1` | MGMT, static, **no `gateway` element**. An interface without a gateway is not a WAN for core, and by DESIGN 5.3 it is not "native IPv4" |
| `ppps.ppp` | `ptpid` 0, `type` pppoe, `if` = type + ptpid = `pppoe0`, `ports` = parent device name, `username`, `password` = **base64 of the password** (`base64_decode($ppp['password'])` when the mpd file is written). Leave out `ondemand`, `tcpmssfix`, `shortseq`, `acfcomp`, `protocomp`, `vjcomp`: their mere presence switches the option ([CORE] interfaces_ppps_edit.php:213-218, interfaces.inc:1178-1197, 1292-1298) |
| `dnsmasq`, `unbound`, `nat`, `filter`, `ntpd` | as the sample |
| rules | the sample's two LAN rules plus one for MGMT. Fields left out take the model's defaults (`setDefault()` sets the value when the model is built; a node missing in the config keeps it: [CORE] Base/BaseModel.php:272-277, FieldTypes/BaseField.php:882-886). Left out here: the booleans that are 0 and the empty fields. `(self)` is "This Firewall" (NetworkAliasField.php:70). The sample itself leaves optional fields out of its second rule |
| removed from the sample | `powerd_*` (unused unless powerd is on), `<rrd>` (the nano build removes it too) |

Booleans: core writes `true` as `1` and leaves `false` elements out ([CORE] Core/Config.php:214-220). List elements with a single entry (`user`, `group`, `item`, `ppp`, `rule`, `dhcp_ranges`) are still read as lists (config.inc:80-107).

### 6.3 Values the generator fills in

| Placeholder | How |
|---|---|
| `@@LAN_IF@@`, `@@WAN_PORT@@`, `@@MGMT_IF@@` | `hn0`, `hn1`, `hn2` if clat-opn's adapters are added in the order LAN, WAN, MGMT. That order is recommended because the factory assignment (first = LAN, second = WAN) then also fits, which Path B needs. If the mechanics sheet's order mgmt, wan, lan is kept: `hn2`, `hn1`, `hn0` |
| `@@AUTHORIZED_KEYS_B64@@` | `base64 -w0 < lab_ed25519.pub` (the file must end with a newline). The key pair can be made on Windows with the built-in `ssh-keygen -t ed25519 -N "" -f lab\.work\keys\lab_ed25519`, run at the top of the checkout |
| `@@API_KEY@@` | any string without a vertical bar, for example 40 hex characters |
| `@@API_SECRET_CRYPT@@` | `openssl passwd -6 -salt <16 chars> '<secret>'` in an alpine container (`apk add --no-cache openssl`), result `$6$salt$...`; or `python:3.11-alpine`: `python -c "import crypt; print(crypt.crypt('<secret>', crypt.mksalt(crypt.METHOD_SHA512)))"`. UNCONFIRMED until a request with it succeeds |
| `@@PPPOE_USER@@`, `@@PPPOE_PASSWORD_B64@@` | must match clat-world's PPPoE server; the second is the base64 of the password without a trailing newline (`printf %s '<password>'` piped into `base64`) |

Keep the generated file with LF line ends; `seed_config.py` parses it, so a broken file stops the build.

### 6.4 Temporary IPv4 gateway 10.99.0.1

clat-world must forward and masquerade traffic from 10.99.0.2 to its Default Switch interface for the duration (world sheet).

**Variant R (recommended): a route that is not in the configuration.**

```sh
route add -inet default 10.99.0.1        # add
route delete -inet default 10.99.0.1     # remove; a reboot removes it too
netstat -rn -f inet | grep '^default'    # must print nothing afterwards
```

By code, core leaves such a route alone: `system_routing_configure()` skips an address family for which it has no gateway (`if (empty($gateway['gateway'])) { continue; }`, [CORE] system.inc:703-711). The configuration never holds an IPv4 gateway, so nothing can be forgotten in it.

**Variant G: a gateway in the configuration** (the alternative; more steps, same result).

Add, with the API key, from clat-world:

```sh
A="-sk -u $KEY:$SECRET"; U=https://10.99.0.2
curl $A -H 'Content-Type: application/json' -d '{"gateway_item":{"name":"PROV_GW","interface":"opt1","ipprotocol":"inet","gateway":"10.99.0.1","defaultgw":"1","monitor_disable":"1","priority":"255","descr":"lab provisioning"}}' $U/api/routing/settings/add_gateway
curl $A -X POST -d '' $U/api/routing/settings/reconfigure      # runs: configctl interface routes configure
```

or seed it (inside `<OPNsense>`, model `//OPNsense/Gateways`, [CORE] Routing/Gateways.xml):

```xml
<Gateways version="1.0.0">
  <gateway_item uuid="5a8e7f0c-7c1d-4b9e-9a55-c1a700000001">
    <disabled>0</disabled>
    <name>PROV_GW</name>
    <descr>lab provisioning</descr>
    <interface>opt1</interface>
    <ipprotocol>inet</ipprotocol>
    <gateway>10.99.0.1</gateway>
    <defaultgw>1</defaultgw>
    <monitor_disable>1</monitor_disable>
    <priority>255</priority>
    <weight>1</weight>
  </gateway_item>
</Gateways>
```

Remove:

```sh
curl $A -X POST -d '' $U/api/routing/settings/del_gateway/<uuid>     # or .../toggle_gateway/<uuid>/0 to disable
curl $A -X POST -d '' $U/api/routing/settings/reconfigure
ssh clat-opn route delete -inet default 10.99.0.1                    # needed: see variant R, core does not remove it
```

Endpoints from [CORE] Routing/Api/SettingsController.php (`addGatewayAction`, `delGatewayAction`, `toggleGatewayAction`, `reconfigureAction`). While PROV_GW exists it is an upstream IPv4 gateway on an interface with an IPv4 address: the plugin would report `native-ipv4` and stay dormant (DESIGN 5.3). Whichever variant: verify before every test run that `netstat -rn -f inet` has no default route other than the CLAT's and `configctl interface gateways status` lists no IPv4 gateway other than `CLAT_GW`.

---

## 7. Packages on a box without IPv4

### 7.1 Order

Do the whole of section 7 **before clat-world's PPPoE server is started** (or with the WAN adapter disconnected). With an IPv6 default route to the simulated ISP, which has no Internet, `pkg` and `fetch` would try the mirrors' IPv6 addresses first and wait for time-outs. If the WAN is already up: `/etc/rc.d/ip6addrctl prefer_ipv4` (core runs the same script with `prefer_ipv6` at its next resolver configuration, [CORE] system.inc:204-205; [SRC] libexec/rc/rc.d/ip6addrctl).

Names are resolved by the local unbound (recursion over IPv4 through the temporary route). If that fails in this network, for the duration only: `printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf`; `configctl dns reload` or a reboot rewrites the file.

Run long steps detached and poll, because package upgrades restart services: `ssh clat-opn /bin/sh -s < provision.sh` where the script starts `nohup sh /root/prov-run.sh > /root/prov.log 2>&1 &`.

### 7.2 tayga

```sh
route add -inet default 10.99.0.1
pkg update -f                       # repository OPNsense, https://pkg.opnsense.org/FreeBSD:15:amd64/26.7/latest
pkg install -y tayga                # 0.9.6 expected (DESIGN section 2); pkg may upgrade itself first
pkg info tayga | sed -n '1,3p'; ls -l /usr/local/sbin/tayga
```

Small download (package size UNCONFIRMED, well under 1 MB expected). The repository's "latest" is the 26.7.6 package set; installing one package from it on the 26.7 image is expected to work (no library dependencies): UNCONFIRMED.

### 7.3 Updating: packages and base to current 26.7.x, kernel held at 26.7.4

The design's basis is 26.7.6 (core behaviour such as core#10996 is version-specific), so update. Do **not** take kernel 26.7.6 (section 2.1).

```sh
opnsense-update -pt opnsense        # what the GUI runs: pkg-static update && pkg-static upgrade -y
opnsense-update -b                  # base set, currently base-26.7.6-amd64.txz, 93M; prints "Please reboot."
opnsense-update -kr 26.7.4          # kernel-26.7.4-amd64.txz, 31M: the last kernel before the regression
opnsense-update -L -k               # lock: creates /usr/local/opnsense/version/kernel.lock
route delete -inet default 10.99.0.1
configctl -d system reboot          # opnsense-update never reboots by itself
```

After the reboot:

```sh
opnsense-version                    # OPNsense 26.7.6_x expected
uname -v                            # forum thread: 26.7.4 kernel = "15.1-RELEASE-p3 stable/26.7-n283949-083dc7025377";
                                    # the 26.7.6 kernel = "15.1-RELEASE-p4 stable/26.7-n284150-0a7d52ef8757" and must NOT appear
opnsense-update -T -k; echo $?      # 1 = kernel locked
sysctl -n hw.vmbus.tlb_hcall        # 0
dmesg | grep -c 'exited on signal'  # 0, also later during tests
netstat -rn -f inet | grep '^default'   # nothing
```

Facts used ([UPD] man page and script, fetched excerpts; [CORE] scripts/firmware/update.sh:53, 72-76; [SETS]):

- `-p` packages, `-b` base, `-k` kernel; give the selectors explicitly (the script reads as "Nothing to do." without one: UNCONFIRMED). `-r <release>` chooses a set version; `-z` takes sets from the snapshots directory; `-c` checks (exit 0 = update available); `-S` prints a set's download size; `-L` / `-U` lock and unlock a set (marker files `kernel.lock`, `base.lock`, `pkgs.lock`); `-T` tests the lock (exit 1 = locked); `-f` force; `-i` ignore signature; `-v` print version.
- Sets come from `https://pkg.opnsense.org/FreeBSD:15:amd64/26.7/sets/` as `base-<ver>-amd64.txz` and `kernel-<ver>-amd64.txz`, fetched with `opnsense-fetch -T 30 -q` and checked with `opnsense-verify`.
- Download size: 93M base + 31M kernel + packages. The package part is UNCONFIRMED; `pkg-static upgrade -n` prints it. Reboots: one.
- Combination "26.7.6 packages and base with the 26.7.4 kernel" is what forum users ran after reverting (2026-10-09 and 10). Base 26.7.6 on the image's 26.7 kernel is three kernels apart and not reported by anyone: avoid.
- Order: packages first, as the GUI's update script does; the base step then follows the upgraded `opnsense-update` package (why the order matters is an inference, UNCONFIRMED).
- Alternatives: `opnsense-update -zkr 26.7.6-hyperv` (the test kernel built for this thread; testers reported the crashes gone; what exactly it changes was not established here); or, once 26.7.7 is published and its notes name the Hyper-V fix, `opnsense-update -U -k` and `opnsense-update -k`. Record `opnsense-version` and `uname -v` in every result file.
- The GUI/API route (`configctl firmware update`, `POST /api/core/firmware/update`) runs `opnsense-update -bk` and reboots by itself; whether it honours the kernel lock in that combined call is UNCONFIRMED. Use the explicit commands.

A checkpoint of the VM after this section (mechanics sheet 2.9) saves repeating it.

---

## 8. Installing the plugin without building a package

### 8.1 What the package would do

[PLUG] Mk/plugins.mk: `install` copies every file under `src/` to `/usr/local/<same path>` with modes preserved (`install`, lines 241-262); the generated `+POST_INSTALL` is the `.pre` fragment, automatic lines, then the `.post` fragment (`scripts`, lines 167-239, and `Templates/*`). For `net/clat` (no `.pre`; `src/opnsense/service/conf/actions.d`, one model directory `OPNsense/Clat`, template directories `OPNsense/Clat` and `OPNsense/Syslog`), in this order:

```sh
if [ -f /usr/local/etc/rc.d/configd ]; then /usr/local/etc/rc.d/configd restart; fi
if [ -f /usr/local/opnsense/mvc/script/run_migrations.php ]; then /usr/local/opnsense/mvc/script/run_migrations.php OPNsense/Clat; fi
if [ -f /usr/local/etc/rc.configure_plugins ]; then echo "Reloading plugin configuration"; /usr/local/etc/rc.configure_plugins POST_INSTALL; fi
if [ -f /usr/local/sbin/configctl ]; then echo -n "Reloading template OPNsense/Clat: "; /usr/local/sbin/configctl template reload OPNsense/Clat; fi
if [ -f /usr/local/sbin/configctl ]; then echo -n "Reloading template OPNsense/Syslog: "; /usr/local/sbin/configctl template reload OPNsense/Syslog; fi
/usr/local/sbin/pluginctl -i || :
/usr/local/sbin/configctl clat restart || :
```

The last two lines are `net/clat/+POST_INSTALL.post`. The package also writes `/usr/local/opnsense/version/clat` (a JSON description) and registers files with pkg; neither affects behaviour. A plugin installed by hand does not appear under System > Firmware > Plugins.

### 8.2 Install (from the Windows host, Git Bash; `clat-opn` is an ssh alias through the jump host)

```bash
# from Git Bash anywhere inside the checkout
SRC="$(git rev-parse --show-toplevel)/net/clat/src"
LIST="$(git rev-parse --show-toplevel)/lab/.work/os-clat.files"
( cd "$SRC" && find . -type f | sed 's|^\./||' | LC_ALL=C sort ) > "$LIST"       # 26 files
ssh clat-opn 'cat > /root/os-clat.files' < "$LIST"
( cd "$SRC" && tar -cf - --owner=0 --group=0 --numeric-owner -T "$LIST" ) | ssh clat-opn 'tar -C /usr/local -xof -'
ssh clat-opn /bin/sh -s <<'EOF'
set -u
command -v tayga >/dev/null || { echo "tayga is not installed"; exit 1; }
cd /usr/local || exit 1
while read -r f; do chown root:wheel "$f"; chmod 644 "$f"; done < /root/os-clat.files
chmod 755 etc/rc.d/clat opnsense/scripts/clat/*.py opnsense/scripts/clat/*.php opnsense/scripts/clat/lib/*.py
if [ -f /usr/local/etc/rc.d/configd ]; then /usr/local/etc/rc.d/configd restart; fi
if [ -f /usr/local/opnsense/mvc/script/run_migrations.php ]; then /usr/local/opnsense/mvc/script/run_migrations.php OPNsense/Clat; fi
if [ -f /usr/local/etc/rc.configure_plugins ]; then echo "Reloading plugin configuration"; /usr/local/etc/rc.configure_plugins POST_INSTALL; fi
if [ -f /usr/local/sbin/configctl ]; then echo -n "Reloading template OPNsense/Clat: "; /usr/local/sbin/configctl template reload OPNsense/Clat; fi
if [ -f /usr/local/sbin/configctl ]; then echo -n "Reloading template OPNsense/Syslog: "; /usr/local/sbin/configctl template reload OPNsense/Syslog; fi
/usr/local/sbin/pluginctl -i || :
/usr/local/sbin/configctl clat restart || :
EOF
```

- The file list is kept in `/root` on the box because `/tmp` is cleaned at boot; the removal in 8.3 reads it again.
- The archive holds files only, so no existing directory's mode or owner is touched; missing directories are created by tar. Modes are set explicitly because Windows has no execute bit (Git Bash invents one for files starting with `#!`). The 755 list is the README's step 2; the skeleton sheet says all files under `opnsense/scripts/clat` are 755 in the package.
- The plugin files have LF line ends (checked: no CR in `net/clat`). The lab copy step must not convert them.
- Expected output: `OK` after each "Reloading template" line. `configctl` prints `OK` or an error text and exits 0 either way (skeleton sheet 7).
- What each line does and what can go wrong: skeleton sheet section 3.1 (migration persists `general.enabled=1`; `rc.configure_plugins` flushes caches and reloads syslog).
- Check: `configctl clat status`, `configctl clat details`, `pluginctl -g OPNsense.clat`, `ls -l /etc/rc.conf.d/clat /usr/local/etc/clat/`, `ifconfig tun464`, `opnsense-log clat`.

### 8.3 Removal (reverse; what `pkg delete os-clat` would do)

```bash
ssh clat-opn /bin/sh -s <<'EOF'
set -u
/usr/local/etc/rc.d/clat onestop >/dev/null 2>&1 || :                 # +PRE_DEINSTALL.pre
cd /usr/local || exit 1
while read -r f; do rm -f "$f"; done < /root/os-clat.files             # the package's file list
rm -rf opnsense/scripts/clat                                          # also Python cache files written at run time
rmdir opnsense/mvc/app/controllers/OPNsense/Clat/Api opnsense/mvc/app/controllers/OPNsense/Clat/forms \
      opnsense/mvc/app/controllers/OPNsense/Clat opnsense/mvc/app/models/OPNsense/Clat/ACL \
      opnsense/mvc/app/models/OPNsense/Clat/Menu opnsense/mvc/app/models/OPNsense/Clat \
      opnsense/mvc/app/views/OPNsense/Clat opnsense/service/templates/OPNsense/Clat 2>/dev/null
if [ -f /usr/local/etc/rc.configure_plugins ]; then echo "Reloading plugin configuration"; /usr/local/etc/rc.configure_plugins POST_DEINSTALL; fi
/usr/local/sbin/pluginctl -i || :                                     # from here: +POST_DEINSTALL.post, verbatim
clat_pid=$(/sbin/ifconfig tun464 2>/dev/null | /usr/bin/sed -n 's/.*Opened by PID \([0-9][0-9]*\).*/\1/p')
if [ -n "${clat_pid}" ]; then
	/bin/kill ${clat_pid} >/dev/null 2>&1 || :
	/bin/sleep 1
fi
timeout 10 /sbin/ifconfig tun464 destroy >/dev/null 2>&1 || :
/usr/local/sbin/configctl interface routes configure || :
EOF
```

Left behind, exactly as after a real package removal: `/etc/rc.conf.d/clat`, `/usr/local/etc/clat/`, `/var/run/clat/`, `/var/log/clat/`, the node `<OPNsense><clat>` in `config.xml`, and configd's loaded `clat` actions until configd restarts (the generated `+POST_DEINSTALL` has no configd line). For a clean slate between test runs add `service configd restart` and remove those paths, and say in the report that this goes beyond what the package does. Reverting to the checkpoint is cleaner.

### 8.4 Building the real package in the VM

Needs IPv4 Internet (temporary route) and a download the lab does not otherwise make: a clone of github.com/opnsense/plugins. The local reference clone must not be used for this (untrusted, never executed).

```sh
opnsense-code plugins                 # clones to /usr/plugins; installs git first if missing (UNCONFIRMED); branch for the installed series (UNCONFIRMED, expected stable/26.7)
mkdir -p /usr/plugins/net/clat        # then copy net/clat/ of this repository here: Makefile, pkg-descr, +*.pre, +*.post, src/
cd /usr/plugins/net/clat
chmod 755 src/etc/rc.d/clat src/opnsense/scripts/clat/*.py src/opnsense/scripts/clat/*.php src/opnsense/scripts/clat/lib/*.py
make package                          # stages to work/src, writes +MANIFEST, +POST_INSTALL..., runs pkg create; installs tayga with pkg if missing
ls work/pkg/                          # os-clat-1.0.pkg; "os-clat-devel-1.0" means the checkout is master (Mk/devel.mk)
pkg add work/pkg/os-clat-1.0.pkg      # or: make upgrade (deletes an installed os-clat / os-clat-devel, then pkg add)
pkg delete -y os-clat
```

`opnsense-code [-a account] [-d directory] [-r release] [-z] [-u] repo ...`, default directory `/usr` [UPD] opnsense-code.8. Make targets `package`, `upgrade`, `install`, `remove`, `collect` [PLUG] README.md:161-171, Mk/plugins.mk:297-340. `make` on the box, the size of the clone and the time are UNCONFIRMED. This is the only way to test the package scripts as pkg runs them (upgrade order, DESIGN 14); it is not needed to test the plugin itself.

---

## 9. Observing the box over ssh

`ssh clat-opn <command>` runs under csh (6.2); the commands below are single commands and safe that way. For anything with redirection or loops use `/bin/sh -s`.

| What | Command |
|---|---|
| Version | `opnsense-version`; `uname -v`; `pkg info tayga`; `opnsense-update -T -k; echo $?` (as sh) |
| Plugin | `configctl clat status` (rc.d wording); `configctl clat details` (JSON from `clatctl.py status`); `configctl clat test`; `configctl clat restart`, `stop`, `start`, `reload`; `cat /var/run/clat/status.json`; `cat /var/run/clat.pid`; `cat /usr/local/etc/clat/clatd.json /usr/local/etc/clat/tayga.conf`; `cat /tmp/tun464_router` |
| Plugin registration | `pluginctl -i` (re-run registration); `pluginctl -d` (devices); `pluginctl -S` (services, JSON); `pluginctl -s clat status`; `pluginctl -g OPNsense.clat`; `pluginctl -g interfaces.clat`; `pluginctl -r return_gateways_status` |
| configd | `configctl configd actions` (list); `configctl interface gateways status`; `configctl interface gateways list`; `configctl interface routes list`; `configctl interface routes configure`; `configctl interface reconfigure wan`; `configctl interface ppp configure wan`; `configctl filter reload`; `configctl dns reload`; `configctl template reload OPNsense/Clat`; `configctl -d system reboot` |
| Interfaces | `ifconfig -a`; `ifconfig pppoe0`; `ifconfig tun464`; `ifconfig hn1` (MTU of the PPPoE parent); `pluginctl -D pppoe0`; `ndp -i pppoe0`; `ndp -an`; `ndp -rn` |
| Routes | `netstat -rn -f inet`; `netstat -rn -f inet6`; `route -n get -inet default`; `route -6 -n get default`; `route -n get -inet6 64:ff9b::c000:201` |
| PPPoE | `cat /var/etc/mpd_wan.conf` (look for `set bundle disable ipcp`, `set bundle enable ipv6cp`, `set pppoe max-payload`); `opnsense-log ppps`; `cat /tmp/pppoe0_routerv6 /tmp/pppoe0_prefixv6` |
| DHCPv6 | `cat /var/etc/dhcp6c.conf` (expect `send ia-na 0;`, `send ia-pd 0;`, `sla-len 8;`); `pgrep -lf dhcp6c`; `pgrep -lf rtsold` |
| pf | `pfctl -sr` (rules); `pfctl -vsn` or `pfctl -sn` (NAT, expect the automatic rule on `tun464`); `pfctl -ss` (states); `pfctl -si`; `pfctl -sa`; `pfctl -t sshlockout -T show`; `cat /tmp/rules.debug`; `configctl filter list non_mvc_rules` |
| Packets | `tcpdump -ni pppoe0 -c 20 ip6`; `tcpdump -ni tun464 -c 20`; `tcpdump -ni hn1 -c 20 pppoed` (discovery on the parent); `tcpdump -ni pppoe0 -vv -c 5 'icmp6 and ip6[40] == 134'` (RAs; `-vv` prints options, PREF64 is option 38); `tcpdump -ni pflog0 -c 20` (blocked packets) |
| DNS | `cat /etc/resolv.conf`; `drill AAAA ipv4only.arpa`; `drill AAAA ipv4only.arpa @<resolver>`; `configctl system list nameservers` |
| Logs | `opnsense-log -l` (names); `opnsense-log clat`; `opnsense-log system`; `opnsense-log configd`; `opnsense-log ppps`; `opnsense-log gateways`; `opnsense-log resolver`; `opnsense-log filter`; `opnsense-log pkg`; `opnsense-log -f clat` (follow). Files: `/var/log/<name>/latest.log`, daily `/var/log/<name>/<name>_YYYYMMDD.log`; PHP errors `/var/lib/php/tmp/PHP_errors.log`; `dmesg` |
| Processes | `pgrep -lf clatd`; `pgrep -lf tayga`; `pgrep -lf mpd5`; `pgrep -lf dhcp6c`; `pgrep -lf unbound`; `sockstat -6l` |
| Hyper-V items | `sysctl hw.vmbus.tlb_hcall`; `sysctl dev.hn.0.%desc`; `pgrep -lf hv_kvp_daemon`; `dmesg` (search for hyperv, vmbus, hn0, "exited on signal") |
| Configuration | `cat /conf/config.xml`; `ls -t /conf/backup` (one file per change, newest first: shows whether a step wrote the config) |

`configctl` exits 0 whatever happened; read its output. `drill` and `tcpdump` being present on OPNsense: expected (FreeBSD base), UNCONFIRMED.

Web API with curl, from clat-world or through an ssh port forward. Key and secret are the user name and password of HTTP Basic auth ([CORE] Base/ApiControllerBase.php:277-330); the certificate is self-signed (`-k`):

```sh
A="-sk -u $KEY:$SECRET"; U=https://10.99.0.2
curl $A $U/api/core/system/status
curl $A $U/api/core/firmware/info
curl $A $U/api/interfaces/overview/interfaces_info
curl $A $U/api/routes/gateway/status
curl $A $U/api/diagnostics/interface/get_routes
curl $A $U/api/clat/service/status                       # the plugin's status (ServiceController::statusAction)
curl $A -X POST -d '' $U/api/clat/service/test           # the three tests
curl $A $U/api/clat/settings/get
curl $A -H 'Content-Type: application/json' -d '{"clat":{"general":{"enabled":"0"}}}' $U/api/clat/settings/set
curl $A -X POST -d '' $U/api/clat/service/reconfigure
```

URL form `/api/<module>/<controller>/<action>` with snake_case names for camelCase actions (skeleton sheet section 1). From the plugin's controllers: the settings root key is `clat` (`$internalModelName = 'clat'`); `status` answered to a GET also carries the details under `clat`; `test` runs only on POST (`net/clat/src/opnsense/mvc/app/controllers/OPNsense/Clat/Api/SettingsController.php:39`, `ServiceController.php:74-97`). The field names inside `general` are in `models/OPNsense/Clat/Clat.xml`. What a wrong API key returns and whether it counts for the lockout: UNCONFIRMED.

---

## 10. What the first run has to confirm, in order

| # | Check | How | If it fails |
|---|---|---|---|
| 1 | Checksum of the download | step 1 of 1.2 prints no mismatch; raw size 3221225472 | download again |
| 2 | The image is as assumed | `seed_config.py <raw>` (dry run): two factory configs, one nano, aligned; note the length | Path B |
| 3 | The lab config fits and parses | `seed_config.py <raw> <config>` prints "replaced ..." | shorten the config (5.2) |
| 4 | qemu-img writes a VHDX that Hyper-V reads | mechanics sheet: `Get-VHD`, `Convert-VHD` | VHD format (mechanics sheet 5.2) |
| 5 | Generation 1 boots the nano disk from IDE | heartbeat / screenshot / serial log; login prompt on VGA | vga image and a manual install at the console, then Path B's restore |
| 6 | First boot needs no input and finishes | 10.99.0.2 answers ping from clat-world within about 10 minutes | read COM1 (Path C tooling) or the VGA screenshot; Path D |
| 7 | Adapter order equals `hn` order | `ifconfig hn0`, `ifconfig hn1`, `ifconfig hn2`: the `ether` lines against the static MACs | 5.3 item 4 |
| 8 | ssh with the key through the jump host; csh behaviour | `ssh clat-opn hostname`; `ssh clat-opn /bin/sh -s < script` | password `opnsense` (passwordauth is on) |
| 9 | File system grew | `df -h /` shows about the VHDX size | `touch /.probe.for.growfs` and reboot |
| 10 | Tunable and console order after the second boot | `sysctl hw.vmbus.tlb_hcall` = 0; VGA shows the boot | check `/boot/loader.conf` |
| 11 | KVP | host: `(Get-VMNetworkAdapter -VMName clat-opn).IPAddresses`; guest: `pgrep -lf hv_kvp_daemon` | not needed |
| 12 | API key | `curl -sk -u key:secret https://10.99.0.2/api/core/system/status` returns JSON | regenerate the hash; use the `<item>` form |
| 13 | Temporary route, DNS, pkg | 7.2 | resolv.conf override (7.1) |
| 14 | Update with the kernel held | 7.3 checks | stay on the image's version and say so in the report |
| 15 | No IPv4 default route, no IPv4 gateway | `netstat -rn -f inet`; `configctl interface gateways status` | delete; reboot |
| 16 | PPPoE with IPv4 None | `/var/etc/mpd_wan.conf` has `set bundle disable ipcp`; `ifconfig pppoe0` has a link-local address; `/var/etc/dhcp6c.conf` asks for a prefix; LAN gets a /64 | this is the plugin's precondition; stop and analyse |
| 17 | Plugin install by hand | each "Reloading template" prints OK; `configctl clat status` | read `opnsense-log configd`, `opnsense-log system`, PHP error log |
| 18 | No program dies on a signal | `dmesg` has no "exited on signal" line after an hour | wrong kernel: 7.3 |
| 19 | Guest shutdown and checkpoint | `Stop-VM` returns, state Off; restore and start | `configctl -d system halt` over ssh first |

---

## 11. Points to settle (differences from other sheets)

1. **Generation**: clat-opn must be Generation 1 (nano image). The mechanics sheet treats Generation 2 as the default and leaves the choice to this sheet.
2. **Adapter order on clat-opn**: this sheet recommends LAN, WAN, MGMT; the mechanics sheet has mgmt, wan, lan. Either works with Path A if `@@LAN_IF@@`, `@@WAN_PORT@@`, `@@MGMT_IF@@` follow the chosen order; Path B needs the first adapter on a switch where clat-world can reach 192.168.1.1.
3. **"Read ifconfig on first boot, then write assignments"** (mechanics sheet 2.5) is not possible with Path A, where the configuration exists before the first boot. Replace it by check 7 and the reconnect remedy.
4. **Second disk with FAT config** (mechanics sheet 2.6): not unattended; only useful with Path C.
5. **Temporary gateway**: a config change plus configctl is the alternative; a runtime route is simpler and leaves no trace. A config gateway additionally needs `route delete`.
6. **"Update to 26.7.6"**: packages and base yes, kernel no (26.7.4, locked) until a fixed kernel is published.
7. **Disk size**: 16 GB suggested here; the mechanics sheet's example uses 8 GB. The growth step must happen before the first boot.
8. **Serial log of the first boot**: only on COM1, only with an elevated reader. Without it a failed first boot can be diagnosed only from the VGA screenshot (little text) or by attaching the disk elsewhere.
9. **Order of bring-up**: provision clat-opn (section 7) before clat-world starts its PPPoE service, or accept IPv6 time-outs.

---

## 12. Sources

| Tag | Source |
|---|---|
| [CORE] | local clone `refs/opnsense-core`, opnsense/core master 5de9cc0 (2026-10-10). Files read: `src/sbin/opnsense-importer`, `src/sbin/opnsense-shell`, `src/sbin/pluginctl`, `src/sbin/opnsense-log`, `src/etc/rc`, `src/etc/rc.bootup`, `src/etc/rc.configure_plugins`, `src/etc/rc.loader`, `src/etc/rc.loader.d/*`, `src/etc/rc.syshook.d/*`, `src/etc/config.xml.sample`, `src/etc/bogons.sample`, `src/etc/bogonsv6.sample`, `src/etc/inc/console.inc`, `config.inc`, `system.inc`, `interfaces.inc`, `interfaces.lib.inc`, `util.inc`, `auth.inc`, `plugins.inc.d/core.inc`, `plugins.inc.d/openssh.inc`, `src/www/authgui.inc`, `csrf.inc`, `diag_backup.php`, `interfaces.php`, `interfaces_ppps_edit.php`, `system_advanced_admin.php`, models and controllers under `src/opnsense/mvc/app` (Auth, Base, Core, Firewall, Interfaces, Routing), `src/opnsense/scripts/firmware/update.sh`, `scripts/shell/*`, `scripts/syslog/lockout_handler`, `service/conf/actions.d/*`, `plist`, `Keywords/sample.ucl` |
| "26.7 checked" | `https://raw.githubusercontent.com/opnsense/core/stable/26.7/...` for `src/etc/config.xml.sample`, `src/sbin/opnsense-importer`, `src/etc/inc/console.inc`, `src/etc/inc/interfaces.inc`, `src/etc/inc/plugins.inc.d/openssh.inc`, `src/etc/inc/auth.inc`, `Auth/FieldTypes/ApiKeyField.php` (fetched excerpts, short quotes). Everything else from core is master only |
| [SRC] | local clone `refs/opnsense-src`, stable/26.7 at 412e762 (2026-10-09), read with `git show HEAD:<path>` |
| [PLUG] | local clone `refs/opnsense-plugins`, master 1bc3c2f (2026-10-09): `Mk/plugins.mk`, `Mk/defaults.mk`, `Mk/devel.mk`, `Templates/*`, `README.md` |
| [TOOLS] | github.com/opnsense/tools master, read as fetched excerpts: `build/nano.sh`, `build/serial.sh`, `build/common.sh`, `config/26.7/extras.conf`, `config/26.7/src.conf`, `config/26.7/SMP`. Script lines were taken from excerpts; their wording may differ in detail |
| [REL] | `https://pkg.opnsense.org/releases/26.7/` (listing) and `.../README` |
| [SETS] | `https://pkg.opnsense.org/FreeBSD:15:amd64/26.7/sets/` and `https://pkg.opnsense.org/FreeBSD:15:amd64/snapshots/sets/` (listings, 2026-10-12) |
| [UPD] | github.com/opnsense/update master: `src/update/opnsense-update.8`, `src/update/opnsense-update.sh.in`, `src/code/opnsense-code.8` (fetched excerpts) |
| [DOC-I] | `https://docs.opnsense.org/manual/install.html` |
| [DOC-V] | `https://docs.opnsense.org/manual/virtuals.html` |
| [DOC-T] | `https://docs.opnsense.org/manual/opnsense_tools.html` (`opnsense-update -kr <version>`, then `opnsense-shell reboot`) |
| [FORUM] | `https://forum.opnsense.org/index.php?topic=53114.0` and `...topic=53114.15` |
| [SRC297] | `https://github.com/opnsense/src/issues/297`; commits `https://github.com/opnsense/src/commit/412e76211e74ab1576f3e3a14bf3300754fcefbc`, list `https://github.com/opnsense/src/commits/stable/26.7/sys/dev/hyperv` |
| [MS-FBSD] | `https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/supported-freebsd-virtual-machines-on-hyper-v` |
| [NG] | `https://docs.netgate.com/pfsense/en/latest/virtualization/virtualizing-pfsense-with-hyper-v.html` |
| project | `README.md`, `DESIGN.md`, `net/clat/*`, `docs/research/gap-5-wan-ipv4-none-precondition.md`, `docs/research/mtu-1-opnsense-jumbo-pppoe.md`, a plugin-skeleton sheet (working copy, not in this repository), `sheet-hyperv-mechanics.md` (same folder) |

Not reachable: `https://bugs.freebsd.org/205156` (bot protection); only a search summary was seen.
