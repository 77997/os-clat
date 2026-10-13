# Sheet: Hyper-V mechanics for the os-clat lab

Research sheet, written 2026-10-11. No Hyper-V cmdlet was run and nothing was downloaded.
Nothing below is tested. Section 9 lists what the first run has to confirm.

## 0. How to read this sheet

Every statement carries a source tag. Statements without a primary source are marked **UNCONFIRMED**.

| Tag | Source | Weight |
|---|---|---|
| [MOD] | The Hyper-V PowerShell module shipped with Windows (2.0.0.0), read with `Get-Command <name> -Syntax` and enum reflection. This reads metadata only; no cmdlet was invoked. | Exact parameter names and enum values for that module version |
| [M] | Measured on the lab host with non-Hyper-V, read-only commands (`whoami`, `Get-Volume`, `Get-NetAdapter`, `fsutil` on a scratch file, one throwaway `python:3.11-alpine` container) | Fact for that host |
| [MS-n] | Microsoft documentation, list in section 10. Pages on learn.microsoft.com were read in full | Primary |
| [MSR-n] | Microsoft cmdlet reference read from the MicrosoftDocs GitHub repository as fetched excerpts (short quotes) | Primary, but re-read the page if the exact wording matters |
| [SRC-n] | Source code (Linux v6.12, opnsense/src stable/26.7, qemu v9.2.0), read as fetched excerpts, or in a local reference clone | Primary, same caveat |
| [BLOG-n] | Microsoft employee blog posts (archived on learn.microsoft.com, or Microsoft Tech Community posts read through a mirror) | Good, but old |
| UNCONFIRMED | Not checked against a source: inference or community reports only | Must be confirmed by the first run |

What this sheet requires of the lab host:

- The account that runs the lab is either elevated or a member of `BUILTIN\Hyper-V Administrators` (SID `S-1-5-32-578`, section 1.3). "Elevated" means the same user after a UAC consent prompt, not a different account.
- Windows with Hyper-V (Windows 10/11 Pro or later) and Windows PowerShell 5.1 (scripts must run on 5.1: no `&&`, no ternary, no `??`).
- Services `vmms`, `vmcompute`, `hns` and `SharedAccess` (ICS) must be running.
- The checkout must be on a fixed NTFS volume, not compressed and not encrypted.
- Host adapter `vEthernet (Default Switch)` is Up; ICS picks its /20, which community reports say is re-chosen at boot (2.2). Another Hyper-V switch may exist, `WSL (Hyper-V firewall)`: it belongs to WSL/wslc and must never be touched.
- `ssh.exe`, `scp.exe`, `ssh-keygen.exe`, `vmconnect.exe`, `fsutil.exe`, `icacls.exe` must be present in System32.
- Run the scripts with `-ExecutionPolicy Bypass` on the command line.

---

## 1. Rights

### 1.1 What "Hyper-V Administrators" gives without elevation

- "Members of the Hyper-V Administrators group have complete and unrestricted access to all the features in Hyper-V." SID `S-1-5-32-578`, default members none, default user rights none. [MS-1] The local group description on the lab host says the same. [M]
- "Hyper-V allows anyone to create and control virtual machines, without being administrator, as long as they are part of the 'Hyper-V Administrators' group." If cmdlets only work "As Administrator", "your account is a member of the 'Administrators' group - but not the 'Hyper-V Administrators' group". After adding the account: "you will need to log out and log back in. Then you will be able to use Hyper-V in PowerShell without running as administrator." [BLOG-1]
- Covered by that statement, each item still to be seen working unelevated on the first run:
  - VMs: create, configure, start, stop, remove (New-VM, Set-VM*, Start-VM, Stop-VM, Remove-VM).
  - Checkpoints: Checkpoint-VM, Restore-VMSnapshot, Remove-VMSnapshot.
  - Virtual disks through VMMS: Convert-VHD, Resize-VHD, Get-VHD.
  - COM port configuration: Set-VMComPort (configuration only, see below for opening the pipe).
  - The console window: `vmconnect.exe localhost clat-opn`. An old post says Virtual Machine Connection needs either "As Administrator" or membership of the Hyper-V Administrators role (search result only, UNCONFIRMED wording).
- **Private switches unelevated: UNCONFIRMED.** The group text says "all the features", but Microsoft's current how-to for switches says "Run PowerShell on your computer in an elevated session" and lists "Have administrative rights" as a prerequisite, for all switch types. [MS-3] No Microsoft page read for this sheet says explicitly that a group member can run `New-VMSwitch -SwitchType Private` unelevated. The scripts therefore create the switches first and have a `-SwitchesOnly` mode, so that if this one step is refused, that step alone is run elevated, once.

### 1.2 What still needs an elevated session

| Action | Needs elevation? | Source |
|---|---|---|
| Adding the user to the group (once) | Yes | [BLOG-2] |
| Opening a VM's COM-port named pipe (`\\.\pipe\<name>`) | Yes: "The debugger must be running in elevated mode when debugging a VM over a serial pipe." | [MS-10] |
| `New-VMSwitch -SwitchType Private` | UNCONFIRMED (see 1.1) | [MS-3] vs [MS-1] |
| Anything on the host's own network stack (New-NetNat, New-NetIPAddress, Set-NetAdapterAdvancedProperty, firewall rules) | Yes, but the lab needs none of it | general Windows behaviour, UNCONFIRMED per item |
| WMI screen thumbnail / keyboard (section 6.3) | Microsoft's sample says "must be run with Administrator privileges"; the class pages say access "might be restricted by UAC Filtering". Whether group membership is enough is UNCONFIRMED | [MS-14] |
| `icacls` / `fsutil sparse` on files the user owns | No | [M] for fsutil |

### 1.3 The exact command

In an elevated PowerShell (Win+X, "Terminal (Admin)"):

```powershell
Add-LocalGroupMember -SID 'S-1-5-32-578' -Member '<PC>\<user>'
```

- `Add-LocalGroupMember [-SID] <SecurityIdentifier> [-Member] <LocalPrincipal[]>` exists on the lab host. [M] Using the SID avoids the localised group name. Microsoft's own one-liner is `([adsi]"WinNT://./Hyper-V Administrators,group").Add("WinNT://$env:UserDomain/$env:Username,user")` with the notes "You do need to run PowerShell 'As Administrator' to run this one command" and "You will need to log out and log back in for this change to take effect." [BLOG-2] Equivalent: `net localgroup "Hyper-V Administrators" "<PC>\<user>" /add` (UNCONFIRMED, standard net.exe syntax).
- Then **sign out of Windows and sign in again** (a restart also does it; locking the screen does not). The group is added to the logon token only at sign-in, so every program, including the shells that run the lab, must be started after the new sign-in. [BLOG-1][BLOG-2]
- Check afterwards, unelevated, without any Hyper-V call:

```powershell
whoami /groups | findstr /i "S-1-5-32-578"     # expect: BUILTIN\Hyper-V Administrators ... Enabled group
```

  then the first harmless Hyper-V call: `Get-VMSwitch` (must list "Default Switch" instead of a permission error).
- Undo: `Remove-LocalGroupMember -SID 'S-1-5-32-578' -Member '<PC>\<user>'`, then sign out and in.
- Consequence to know: after this, any program running as this user can create and control VMs without a UAC prompt. [MS-1]

### 1.4 Running the scripts elevated instead

It works for creation, but then EVERY later Hyper-V action also needs an elevated console: start/stop, checkpoint restore between tests, reading guest addresses with `Get-VMNetworkAdapter`, status. In that mode an unelevated shell can still, without Hyper-V cmdlets, find clat-world by its static MAC (`Get-NetNeighbor`) or by name (`clat-world.mshome.net`), and use ssh. Resets between tests would have to be done inside the guests, or by running a script elevated. Group membership is the mode that lets the tests run unattended.

Command line for an elevated console:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <checkout>\lab\hyperv\create-lab.ps1
```

(`<checkout>` is the top folder of the checkout, here and in the paths below.)

Create and remove in the same mode (files and VM folders made by an elevated run may not be removable by an unelevated one; UNCONFIRMED).

---

## 2. Cmdlets, exactly

All syntax lines are from [MOD] unless tagged otherwise. Enum values from [MOD]:
`VMSwitchType = Private, Internal, External`; `OnOffState = On, Off`; `StartAction = Nothing, StartIfRunning, Start`; `StopAction = TurnOff, Save, ShutDown`; `CheckpointType = Disabled, Production, ProductionOnly, Standard`; `ControllerType = IDE, SCSI, PMEM`; `VhdType = Unknown, Fixed, Dynamic, Differencing`; `ConsoleModeType = Default, COM1, COM2, None`; `BootDevice = Floppy, CD, IDE, LegacyNetworkAdapter, NetworkAdapter, VHD`.

### 2.1 Private switches

```powershell
New-VMSwitch -Name 'clat-wan'  -SwitchType Private -Notes 'os-clat lab'
New-VMSwitch -Name 'clat-lan'  -SwitchType Private -Notes 'os-clat lab'
New-VMSwitch -Name 'clat-mgmt' -SwitchType Private -Notes 'os-clat lab'
```

- Syntax: `New-VMSwitch [-Name] <string> -SwitchType <VMSwitchType> [-Notes <string>] ...`. [MOD] "-SwitchType: Allowed values are Internal and Private." [MS-4]
- "Private virtual switch - Connects to a network that can be used only by the virtual machines running on the host that has the virtual switch, but doesn't provide networking between the host and the virtual machines." "Internal virtual switch - ... and between the host and the virtual machines." [MS-2]
- **"A private switch adds no host network adapter and changes no host network setting": not stated in those words by any page read for this sheet.** It follows from [MS-2] (no host connectivity, so no host vNIC), and the `-AllowManagementOS` parameter exists only in the external-switch parameter sets. [MOD][MS-4] The script proves it on the first run: it lists `Get-NetAdapter -IncludeHidden` before and after and prints the difference (expected: none; an Internal switch would add `vEthernet (<name>)`). UNCONFIRMED until then.
- Existence test that does not depend on error behaviour: `Get-VMSwitch | Where-Object { $_.Name -eq 'clat-wan' }`.

### 2.2 The Default Switch and `<guest>.mshome.net`

```powershell
$default = Get-VMSwitch -Id 'c08cb7b8-9b3c-408e-8e30-5e16a3aeb444'    # read only; use $default.Name as -SwitchName
```

- Syntax `Get-VMSwitch [[-Id] <guid[]>]`. [MOD]
- "The switch named 'Default Switch' or 'Layered_ICS', allows virtual machines to share the host's network connection." "It has the same name and device ID (GUID c08cb7b8-9b3c-408e-8e30-5e16a3aeb444) on all Windows 10 hosts". "You can't delete it." [BLOG-3] "You can't delete or rename it." "the default switch does automatically assign an IP to the virtual machine (DNS and DHCP)". [BLOG-4] (Both are Microsoft Virtualization Blog posts from 2017, read through a mirror.)
- The host side is `vEthernet (Default Switch)` with a /20 that ICS chooses. [M] Community reports say the subnet is re-chosen at host boot (UNCONFIRMED): never hard-code the address.
- Name resolution, as measured here [M]: the ICS service keeps `C:\WINDOWS\System32\drivers\etc\hosts.ics` ("automatically generated for use by Microsoft Internet Connection Sharing ... mappings of IP addresses to host names for the home network"), with lines like `<host address> <PC>.mshome.net # <timestamp>`; the file is readable unelevated; `Resolve-DnsName <PC>.mshome.net` returns the host's Default Switch address. So a guest that sends its host name in its DHCP request should become `clat-world.mshome.net` on the host. That a guest gets an entry this way is UNCONFIRMED until seen (no Microsoft page describes it).
- Known weakness: the file can hold truncated or stale lines from earlier leases. [M] Stale or duplicate names are a reported problem, so treat the name as the last fallback, not the first (section 4).

### 2.3 Creating a VM from an existing VHDX

```powershell
$vm = New-VM -Name 'clat-world' -Generation 2 -MemoryStartupBytes 2GB `
             -VHDPath '<checkout>\lab\.work\disks\clat-world.vhdx' `
             -Path    '<checkout>\lab\.work\vm\clat-world'
Set-VM -VM $vm -Notes 'os-clat lab' -StaticMemory -ProcessorCount 2 `
       -AutomaticStartAction Nothing -AutomaticStopAction ShutDown `
       -AutomaticCheckpointsEnabled $false -CheckpointType Standard
```

- `New-VM [[-Name] <string>] [[-MemoryStartupBytes] <long>] [[-Generation] <int16>] -VHDPath <string> [-BootDevice <BootDevice>] [-SwitchName <string>] [-Path <string>] ...`. [MOD] "-Path: Specifies the directory to store the files for the new virtual machine." "-VHDPath: Specifies the path to a virtual hard disk file." Example: `New-VM -Name "VM01" -MemoryStartupBytes 1GB -VHDPath D:\vhd\BaseImage.vhdx`. [MSR-1]
- "Hyper-V automatically creates a virtual machine with one virtual network adapter". [MSR-1] So remove it and add the lab's adapters in order (2.5).
- Whether `-Path X` puts the files in `X\<VMName>\...` or directly in `X\...` is UNCONFIRMED; giving each VM its own `-Path ...\vm\<name>` keeps everything under one `clat-*` folder either way.
- Processors: `Set-VM -ProcessorCount <long>` or `Set-VMProcessor -VMName <n> -Count <long>`; both exist. [MOD]
- Memory: `-StaticMemory` "configures the virtual machine to use static memory". [MSR-2] Equivalent: `Set-VMMemory -VMName <n> -DynamicMemoryEnabled $false -StartupBytes <long>`. [MOD] Static is also required for OPNsense: dynamic memory is not available for FreeBSD guests. [MS-7]
- **Automatic start/stop: there is no "Nothing" for the stop action.** `-AutomaticStartAction Nothing` is valid; `-AutomaticStopAction` accepts only `TurnOff, Save, ShutDown`. [MOD] Use `ShutDown` (clean guest shutdown when the host shuts down) or `TurnOff` (fastest). Avoid `Save`: for a running VM it is believed to reserve a memory-sized state file on disk (UNCONFIRMED).
- `-AutomaticCheckpointsEnabled $false`: "Automatic checkpoints are enabled by default on Windows 10 and disabled by default on Windows Server." "Hyper-V creates a checkpoint when you start virtual machines." [BLOG-4] Left on, every Start-VM would create a checkpoint and grow .avhdx files. That VMs made with New-VM on Windows 11 also get it enabled is UNCONFIRMED; setting it is harmless.
- Sizes: OPNsense documentation says "Minimum required RAM is 3 GB" and "Minimum recommended virtual disk size of 8 GB". [OPN-1] Suggested: clat-opn 3072 MB, clat-world 2048 MB, 2 vCPU each (the host needs about 5 GB of free RAM and 4 threads for both).

Generation 1 or 2 (the image sheet decides; mechanics for both):

| | Generation 1 | Generation 2 | Source |
|---|---|---|---|
| Firmware | BIOS | UEFI, Secure Boot on by default | [MS-5] |
| Boot disk | IDE controller only | SCSI VHDX | [MS-5] |
| DVD after New-VM | exists on IDE (UNCONFIRMED: at 1:0) | none: "the generation 2 virtual machine doesn't have a DVD drive" until added | [MS-5] |
| COM ports | emulated UART present | "COM ports aren't available in generation 2 virtual machines until you add them" | [MS-5] |
| Debian / FreeBSD | both generations listed (Debian up to 12, FreeBSD up to 13.5) | same | [MS-5] |

- The Microsoft tables stop at Debian 12 and FreeBSD 13.5. [MS-6][MS-7] The lab uses Debian 13 and OPNsense 26.7, whose base is FreeBSD 15.1 (`UPDATING` in the opnsense-src clone: "stable/15", "15.1-RELEASE-p4"). [SRC-4] Not listed does not mean not working; OPNsense's own page says "Both Hyper-V Generation 1 and 2 virtual machines are supported out of the box with no additional drivers or tools needed." [OPN-1]
- "We don't support or recommend that you create a single virtual disk ... that is bootable to both generation 1 and generation 2". "if the virtual hard drive is a bootable VHDX file [made for generation 2], the generation 1 virtual machine fails to boot." [MS-5] Decide the generation per image and keep it.

### 2.4 Secure Boot on Generation 2

```powershell
Set-VMFirmware -VMName 'clat-opn'   -EnableSecureBoot Off
Set-VMFirmware -VMName 'clat-world' -EnableSecureBoot Off
```

- `Set-VMFirmware ... [-EnableSecureBoot <OnOffState>] [-SecureBootTemplate <string>] [-FirstBootDevice <VMComponentObject>] [-ConsoleMode <ConsoleModeType>]`. [MOD] "This cmdlet is supported only when run against Generation 2 virtual machines." [MS-8] The VM must be off (UNCONFIRMED; [MS-5] says "Make sure the virtual machine is in an Off state" in the COM-port procedure).
- FreeBSD: the "Secure boot" row is empty for every FreeBSD version, [MS-7] and OPNsense says "Secure Boot must be disabled". [OPN-1] So Off is mandatory for clat-opn.
- Debian: "Secure boot" is ticked for Debian 10 to 12, [MS-6] and "To Secure Boot generation 2 Linux virtual machines, you need to choose the UEFI CA Secure Boot template". [MS-5] The command would be `Set-VMFirmware -VMName clat-world -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority`; that template name was not checked against a source and was not found on any page read for this sheet: UNCONFIRMED. The Microsoft notes for Debian and Ubuntu only give `Set-VMFirmware -VMName "VMname" -EnableSecureBoot Off`. [MS-6] **Use Off for both VMs**: one setting, confirmed syntax, nothing gained from Secure Boot in a lab.
- Boot from the disk explicitly, after all drives are attached:

```powershell
Set-VMFirmware -VMName 'clat-world' -FirstBootDevice (Get-VMHardDiskDrive -VMName 'clat-world' | Select-Object -First 1)
```

  "-FirstBootDevice ... acceptable values: VMBootSource, VMNetworkAdapter, HardDiskDrive, DVDDrive". [MS-8]
- Linux GRUB on Generation 2: "the grub menu timer counts down too quickly ... immediately loading the default entry". [MS-9] Harmless here.

### 2.5 Network adapters in a defined order with static MACs

```powershell
Get-VMNetworkAdapter -VMName 'clat-world' | Remove-VMNetworkAdapter      # the one New-VM created
Add-VMNetworkAdapter -VMName 'clat-world' -Name 'nat'  -SwitchName $default.Name -StaticMacAddress '02C1A7000101'
Add-VMNetworkAdapter -VMName 'clat-world' -Name 'mgmt' -SwitchName 'clat-mgmt'   -StaticMacAddress '02C1A7000102'
Add-VMNetworkAdapter -VMName 'clat-world' -Name 'wan'  -SwitchName 'clat-wan'    -StaticMacAddress '02C1A7000103'
Add-VMNetworkAdapter -VMName 'clat-world' -Name 'lan'  -SwitchName 'clat-lan'    -StaticMacAddress '02C1A7000104'

Get-VMNetworkAdapter -VMName 'clat-opn' | Remove-VMNetworkAdapter
Add-VMNetworkAdapter -VMName 'clat-opn' -Name 'mgmt' -SwitchName 'clat-mgmt' -StaticMacAddress '02C1A7000201'
Add-VMNetworkAdapter -VMName 'clat-opn' -Name 'wan'  -SwitchName 'clat-wan'  -StaticMacAddress '02C1A7000202'
Add-VMNetworkAdapter -VMName 'clat-opn' -Name 'lan'  -SwitchName 'clat-lan'  -StaticMacAddress '02C1A7000203'
```

- `Add-VMNetworkAdapter [-VMName] <string[]> [-SwitchName <string>] [-IsLegacy <bool>] [-Name <string>] [-StaticMacAddress <string>] ...`. [MOD] "-StaticMacAddress: Assigns a specific MAC address to the new virtual network adapter." The page gives no string format. [MSR-3] Twelve hex digits without separators is the form the module prints; accepted input forms are UNCONFIRMED.
- MAC choice: `02-C1-A7-...` is a locally administered unicast prefix, chosen so it cannot collide with Hyper-V's dynamic pool (this host's vNICs use `00-15-5D-...` [M]). That Hyper-V accepts locally administered static MACs is UNCONFIRMED; fallback is any unused `00155Dxxxxxx`.
- Synthetic adapters only (no `-IsLegacy`): "remove all legacy network adapters when using Hyper-V-specific network adapters in a Linux virtual machine", [MS-9] and legacy adapters do not exist in Generation 2. [MS-2]
- Static MACs are what Microsoft recommends where a guest's network configuration must survive ("ensure that each virtual network adapter has a static MAC address"). [MS-9]
- **Order in the guest: UNCONFIRMED. Do not rely on it.** What is known:
  - FreeBSD names interfaces `hn<unit>` from the device unit (`if_initname(ifp, device_get_name(dev), device_get_unit(dev))`), [SRC-2] in the order the VMBus devices attach. A 2015 FreeBSD bug (205156) about swapped hn0/hn1 was a guest-side race, fixed then; the report says the host offers the NICs in the same order each time (search summary only).
  - Linux: a 2019/2020 netvsc patch names NICs by VMBus offer sequence (search summary only); Debian then may or may not rename them.
  - No source says "offer order = the order of Add-VMNetworkAdapter".
  - Therefore: in Debian match by MAC (cloud-init/netplan `match: macaddress:` with `set-name:`); for OPNsense read `ifconfig` on first boot, record which `hnX` has which MAC, and only then write interface assignments. The first run must record the mapping for both guests; if it equals the add order every time, the lab can rely on it afterwards.
  - With `mgmt` added first on clat-opn it will probably be `hn0`, which OPNsense's factory configuration would take as LAN. This is a guess; the provisioning sheet must not depend on it without the check.

### 2.6 DVD/ISO (cloud-init seed) and a second disk

```powershell
# Generation 2: no DVD drive exists yet
Add-VMDvdDrive -VMName 'clat-world' -Path '<checkout>\lab\.work\disks\clat-world-seed.iso'
# Generation 1: reuse the existing drive
Get-VMDvdDrive -VMName 'clat-world' | Select-Object -First 1 | Set-VMDvdDrive -Path '...\clat-world-seed.iso'
# second disk (for example a small FAT image with OPNsense's config.xml)
Add-VMHardDiskDrive -VMName 'clat-opn' -ControllerType SCSI -Path '<checkout>\lab\.work\disks\clat-opn-conf.vhdx'                                           # gen 2
Add-VMHardDiskDrive -VMName 'clat-opn' -ControllerType IDE -ControllerNumber 0 -ControllerLocation 1 -Path '...\clat-opn-conf.vhdx'                         # gen 1
```

- `Add-VMDvdDrive [-VMName] <string[]> [[-ControllerNumber] <int>] [[-ControllerLocation] <int>] [[-Path] <string>]`; `Set-VMDvdDrive [-VMDvdDrive] <DvdDrive[]> [[-Path] <string>]`; `Add-VMHardDiskDrive [-VMName] <string[]> [[-ControllerType] <ControllerType>] [[-ControllerNumber] <int>] [[-ControllerLocation] <int>] [[-Path] <string>]`. [MOD] Example `Add-VMDvdDrive -VMName Test -Path D:\ISOs\disc1.iso`. [MSR-4]
- "The virtual DVD drive in generation 2 virtual machines only supports ISO image files." "You can add a DVD drive while the virtual machine is running." [MS-5]
- In Generation 2 the DVD is a SCSI CD-ROM, in Generation 1 an IDE CD-ROM. [MS-5] Whether the Debian "genericcloud" kernel has the CD-ROM and ISO9660 drivers for either is a question for the image sheet. A seed on a small VHDX (FAT, label CIDATA) attached with Add-VMHardDiskDrive avoids the question; that cloud-init accepts it is for the image sheet to confirm.

### 2.7 MAC address spoofing

```powershell
Set-VMNetworkAdapter -VMName 'clat-world' -Name 'lan' -MacAddressSpoofing On      # only if needed, see below
```

- "-MacAddressSpoofing: Specifies whether virtual machines may change the source MAC address in outgoing packets to one not assigned to them." [MSR-5] Syntax `Set-VMNetworkAdapter [-VMName] <string> [-Name <string>] [-MacAddressSpoofing <OnOffState>]`. [MOD] Off is the default (UNCONFIRMED, standard behaviour).
- Needed only when frames leave a vNIC with a source MAC other than the one Hyper-V assigned (Microsoft's FreeBSD example is CARP). [MS-11]
  - PPPoE client or server on the NIC: frames carry the NIC's own MAC. Not needed.
  - LAN client in a network namespace: **not needed if the Hyper-V NIC itself is moved into the namespace** (`ip link set dev <lan-if> netns <ns>`). The netvsc driver sets no "netns-local" flag and has code to keep a VF in "the same namespace as the synthetic NIC", so moving it is supported. [SRC-1] Needed (On, on clat-world's `lan` adapter) if the namespace is attached through a veth pair plus bridge, or macvlan, because those send from other MACs.
  - OPNsense in this lab: no CARP, no bridge. Not needed.
- Leave `-DhcpGuard` and `-RouterGuard` Off (their defaults, UNCONFIRMED): RouterGuard would "drop Router Advertisement and Redirection messages from unauthorized virtual machines" and DhcpGuard would "drop DHCP messages from a virtual machine claiming to be a DHCP server". [MSR-5] OPNsense sends RAs and DHCP on the LAN switch. The status script prints both.

### 2.8 COM port to a named pipe

```powershell
Set-VMComPort -VMName 'clat-opn'   -Number 1 -Path '\\.\pipe\clat-opn-com1'
Set-VMComPort -VMName 'clat-world' -Number 1 -Path '\\.\pipe\clat-world-com1'
```

- `Set-VMComPort [-VMName] <string[]> [-Number] <int> [[-Path] <string>] [-DebuggerMode <OnOffState>]`. [MOD] "-Number: Specifies the Id (1 or 2) of the COM port". "-Path: ... Specify local pipes as '\\.\pipe\PipeName'". [MS-12]
- Generation 2: "COM ports aren't available in generation 2 virtual machines until you add them"; "Configured COM ports aren't listed in the settings of a virtual machine in Hyper-V Manager." [MS-5] "stop and cold start the VM to activate the COM ports in the VM. The emulated UARTS aren't available ... unless at least one is actually configured with a pipe name and they cannot be hot-added." [MS-10] So set it before the first start. Microsoft's procedure disables Secure Boot first, [MS-5] which the lab does anyway.
- **Who may open the pipe: an elevated process.** "Start the debugger in elevated mode ... The debugger must be running in elevated mode when debugging a VM over a serial pipe." [MS-10] So the serial log is available to an elevated session only; a Hyper-V Administrators member who is not elevated should expect "access denied" (first run confirms).
- The pipe exists only while the VM runs, and one client at a time (UNCONFIRMED). A reader, to be run elevated right after Start-VM:

```powershell
$p = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'clat-opn-com1', [System.IO.Pipes.PipeDirection]::InOut)
$p.Connect(10000)
$buf = New-Object byte[] 4096
while (($n = $p.Read($buf, 0, $buf.Length)) -gt 0) { [Console]::Out.Write([Text.Encoding]::ASCII.GetString($buf, 0, $n)) }
```

- The guest must also use the UART as console (Linux `console=ttyS0,115200`; OPNsense serial console setting or the serial image). Whether FreeBSD 15 finds the UART of a Generation 2 VM is UNCONFIRMED. The lab must not depend on the serial console: it is a diagnostic extra. `Set-VMFirmware -ConsoleMode COM1` exists ("allows a virtual machine to run without graphical user interface") [MS-8] but its effect on these guests is UNCONFIRMED; do not use it.

### 2.9 Checkpoints for resetting between tests

```powershell
Set-VM -Name 'clat-opn' -CheckpointType Standard -AutomaticCheckpointsEnabled $false
# save a baseline: both VMs shut down first, so there is no memory state and both disks are from the same moment
Stop-VM -Name 'clat-opn','clat-world' -Force            # guest shutdown through the integration service
Checkpoint-VM -Name 'clat-opn'   -SnapshotName 'clat-baseline'
Checkpoint-VM -Name 'clat-world' -SnapshotName 'clat-baseline'
# reset
Stop-VM -Name 'clat-opn','clat-world' -TurnOff -Force
Restore-VMSnapshot -VMName 'clat-opn'   -Name 'clat-baseline' -Confirm:$false
Restore-VMSnapshot -VMName 'clat-world' -Name 'clat-baseline' -Confirm:$false
Start-VM -Name 'clat-world'; Start-VM -Name 'clat-opn'
# delete
Remove-VMSnapshot -VMName 'clat-opn' -Name 'clat-baseline' -IncludeAllChildSnapshots
```

- `Checkpoint-VM [-Name] <string[]> [[-SnapshotName] <string>]`; `Restore-VMSnapshot [-Name] <string> [-VMName] <string>`; `Remove-VMSnapshot [-VMName] <string[]> [[-Name] <string[]>] [-IncludeAllChildSnapshots]`; `Get-VMSnapshot [-VMName] <string[]>`. On the lab host `Restore-VMCheckpoint`, `Remove-VMCheckpoint`, `Get-VMCheckpoint` are aliases of the `*-VMSnapshot` cmdlets. [MOD] "Restore-VMCheckpoint -Name <checkpoint name> -VMName <VMName> -Confirm:$false". [MS-13]
- Standard: "takes a snapshot of the virtual machine and virtual machine memory state". Production: "uses Volume Shadow Copy Service or File System Freeze on a Linux virtual machine ... No snapshot of the virtual machine memory state is taken." "Production checkpoints are selected by default". With `Production`, "if the production checkpoint fails a standard checkpoint is being created"; `ProductionOnly` does not fall back. After applying a production checkpoint "the virtual machine is in an off state"; after a standard one the VM is back in the exact running state. [MS-13]
- Recommendation: **checkpoint with both VMs off.** A restored running-state checkpoint of one VM would resume with a stale PPPoE session, stale neighbour caches and a jumped clock against the other VM. Off-state checkpoints need no guest agent (production checkpoints of a running Debian need the VSS/freeze daemon from `hyperv-daemons` [MS-6]) and cost one boot per reset. That an off-state checkpoint behaves the same for both types is UNCONFIRMED; `Standard` is set so that a checkpoint taken while running never depends on guest daemons.
- "checkpoints are stored as .avhdx files in the same location as the .vhdx files"; deleting a checkpoint merges it; "You should not delete the .avhdx files directly." [MS-13] So `disks\` grows while checkpoints exist.

### 2.10 Start, stop

```powershell
Start-VM -Name 'clat-world'
Stop-VM  -Name 'clat-world'            # asks the guest to shut down
Stop-VM  -Name 'clat-world' -TurnOff   # power off
```

- `Start-VM [-Name] <string[]>`; `Stop-VM [-Name] <string[]> [-Save] [-TurnOff] [-Force]`. [MOD] `Stop-VM -Name TestVM`: "Shuts down virtual machine TestVM through the guest operating system." `-TurnOff`: "equivalent to disconnecting the power from the virtual machine". `-Force`: "Hyper-V gives the guest five minutes to save data, then forces a shutdown." [MS-15]
- Guest shutdown needs the shutdown integration service in the guest: for FreeBSD it is in the `hv_utils` driver ("Integrated shutdown: Guest partitions running FreeBSD can be shut down from Hyper-V Manager"), [SRC-4] for Linux it is the kernel module `hv_utils`. [MS-16] Works for these two guests: first run confirms.
- Do not call Stop-VM on a VM that is already Off (error or warning; UNCONFIRMED): check `.State` first.
- Boot detection without the network: `(Get-VM clat-world).Heartbeat`. Possible values: `Unknown, Disabled, NoContact, Error, LostCommunication, OkApplicationsUnknown, OkApplicationsHealthy, OkApplicationsCritical, Paused`. [MOD] Heartbeat is in `hv_utils` for both guests. [SRC-4][MS-16] Which value a booted Debian or OPNsense reports (expected one of the `Ok...` values) is UNCONFIRMED.

### 2.11 Complete removal

```powershell
Stop-VM -Name 'clat-opn' -TurnOff -Force
Remove-VM -Name 'clat-opn' -Force
Remove-VMSwitch -Name 'clat-wan' -Force
Remove-Item '<checkout>\lab\.work\disks\clat-opn*.vhdx', '<checkout>\lab\.work\disks\clat-opn*.avhdx'
Remove-Item '<checkout>\lab\.work\vm\clat-opn' -Recurse
```

- "Running this cmdlet deletes the virtual machine's configuration file, but does not delete any virtual hard drives. If the virtual machine has any snapshots, these are deleted and merged into the virtual hard disk files after the virtual machine is deleted." `-Force` suppresses the confirmation. [MS-15] The merge runs after Remove-VM returns, so deleting the disk files right away can fail with "file in use": retry for a while.
- `Remove-VMSwitch [-Name] <string[]> [-Force]`; "-Force: Forces the command to run without asking for user confirmation"; no wildcards in `-Name`. [MOD][MSR-6]
- The Default Switch is never removed or changed ("You can't delete it" [BLOG-3]); the scripts only read it.

---

## 3. Frame size (MTU 1508 to 1536 on the WAN link)

What is established:

- "Jumbo frames" is a supported feature of the guest for Debian (ticked for all listed versions) and FreeBSD (ticked, with the note "9126 is the maximum supported MTU size"). [MS-6][MS-7]
- Linux `hv_netvsc`: "MTU range: 68 - 1500 or 65521"; the larger limit applies with NVSP protocol version 2 or later. Changing the MTU detaches and re-attaches the device, and the guest tells the host its MTU plus the Ethernet header (`send_ndis_config.mtu = ndev->mtu + ETH_HLEN`). [SRC-1]
- FreeBSD `hn(4)` (OPNsense): `SIOCSIFMTU` is refused above `HN_MTU_MAX` = `65535 - ETHER_ADDR_LEN`; the driver suspends the interface, re-attaches its NVS/RNDIS parts with the new MTU, reads the MTU back from the host and uses the lower value if the host reports less. [SRC-2]
- So in both guests the synthetic NIC's MTU is a guest setting that is negotiated with the host; there is no per-switch MTU parameter in `New-VMSwitch`. [MOD]

What is NOT established (UNCONFIRMED):

- That a private switch forwards frames with a 1508 to 1536 byte payload between two synthetic NICs with no host-side setting. Community guides say the virtual switch needs no jumbo setting and that only physical NICs (external switches) and the host vNIC (internal switches) have one; a private switch has neither. No Microsoft page read for this sheet states the frame limit of a private switch.

What to set, in the guests only:

| Guest | Command (runtime) | Note |
|---|---|---|
| clat-world (Debian) | `ip link set dev <wan-if> mtu 1508` (or up to 1536) | before the PPPoE server starts; the link flaps during the change [SRC-1] |
| clat-opn (OPNsense) | `ifconfig hnX mtu 1508` for the WAN parent, in practice through OPNsense's interface/PPPoE MTU settings | the link flaps during the change [SRC-2]; how OPNsense derives the parent MTU from the PPPoE MTU belongs to the plugin/provisioning sheet |

Default, if nothing is set: both NICs run at MTU 1500, so PPPoE gets 1492 and RFC 4638 cannot be exercised.

First-run test, before any PPPoE: with both WAN NICs at MTU 1508 or more, send a non-fragmentable packet that fills the frame, for example from clat-world `ping -6 -M do -s 1460 -c 3 fe80::<opn-wan-ll>%<wan-if>` (1460 + 8 + 40 = 1508 bytes of Ethernet payload), and the same at 1536 if that value is wanted. If it fails, the lab can still test with PPP MTU 1492, and the RFC 4638 path remains untested: say so in the report.

---

## 4. Reading guest addresses from the host

Order of preference:

1. **KVP** (needs Hyper-V rights and a daemon in the guest):

```powershell
(Get-VMNetworkAdapter -VMName 'clat-world' -Name 'nat').IPAddresses
Get-VMIntegrationService -VMName 'clat-world'      # row "Key-Value Pair Exchange": Enabled, PrimaryStatusDescription OK
```

   - `Get-VMNetworkAdapter [-VMName] <string[]> [[-Name] <string>]`; the returned object has a property `IPAddresses` of type String[]. [MOD] No Microsoft page read for this sheet describes how it is filled; the mechanism is documented from the guest side: FreeBSD "the get IP functionality is used to update the guest IP address in the Hyper-V management console window"; [SRC-4] Linux `hv_kvp_daemon` answers `KVP_OP_GET_IP_INFO` by finding the interface whose MAC matches and returning its IPv4/IPv6 addresses. [SRC-1]
   - Debian: package `hyperv-daemons` ("contains the key-value pair, fcopy, and VSS daemons" [MS-6]; in trixie version 6.12.x [DEB-1]). It is probably not in the cloud image (UNCONFIRMED), so the address only appears after the package is installed and the daemon runs.
   - OPNsense/FreeBSD: `devd` starts `/usr/sbin/hv_kvp_daemon` when the `hv_kvp_dev` device appears (`sbin/devd/hyperv.conf` in opnsense/src stable/26.7); [SRC-2] OPNsense's build configuration has no `WITHOUT_HYPERV`. [SRC-3] Whether the daemon is really in the 26.7 image: first run (`pgrep -lf hv_kvp_daemon`). Not essential: OPNsense's management address is static and known.
   - "Each service you want to use must be enabled in both the host and guest"; Linux check: `lsmod | grep hv_utils`, `ps -ef | grep hv`. [MS-16]
2. **Neighbour table by static MAC** (no Hyper-V rights needed; `Get-NetNeighbor` runs unelevated [M]):

```powershell
Get-NetNeighbor -AddressFamily IPv4 -LinkLayerAddress '02-C1-A7-00-01-01' -ErrorAction SilentlyContinue |
    Where-Object { $_.State -notin 'Unreachable','Incomplete' } | Select-Object -ExpandProperty IPAddress
```

   Works only after the host has exchanged a packet with the guest (the guest's DHCP request to the host's ICS service should be enough; UNCONFIRMED).
3. **Name**: `Resolve-DnsName clat-world.mshome.net` or simply `ssh debian@clat-world.mshome.net` (section 2.2; can be stale).
4. For a run without Hyper-V rights, `create-lab.ps1` also writes `lab\.work\results\lab-state.json` (VM ids, MACs) so the MAC lookup needs no cmdlet.

OPNsense is not on the Default Switch; it is reached through clat-world: `ssh -J debian@<clat-world> root@<opn-mgmt-address>` (addresses from the provisioning sheet).

---

## 5. VHDX files made with qemu-img

### 5.1 Conversion (in a throwaway container, one container at a time)

```bash
# from Git Bash anywhere inside the checkout
MSYS_NO_PATHCONV=1 wslc.exe run --rm -v "$(cygpath -w "$(git rev-parse --show-toplevel)/lab/.work"):/work" alpine:3.22 sh -c '
  apk add --no-cache qemu-img >/dev/null &&
  qemu-img convert -p -f raw   -O vhdx -o subformat=dynamic /work/cache/OPNsense-26.7-nano-amd64.img        /work/disks/base-opnsense-26.7.vhdx &&
  qemu-img convert -p -f qcow2 -O vhdx -o subformat=dynamic /work/cache/debian-13-genericcloud-amd64.qcow2 /work/disks/base-debian-13.vhdx &&
  qemu-img info /work/disks/base-opnsense-26.7.vhdx && qemu-img info /work/disks/base-debian-13.vhdx
' 2>&1 | tr -d '\0'
```

(File names are examples; the image sheet fixes them. The `.img.bz2` must be decompressed to a plain file first.)

- qemu's VHDX create options: `size` ("max of 64TB"), `log_size` (default 1 MiB), `block_size` ("min 1MB, max 256MB. 0 means auto-calculate based on image size", default 0), `subformat` ("can be either 'dynamic' or 'fixed'", default dynamic), `block_state_zero` ("Non-standard, but default"). Auto block size: 8 MiB up to 1 GiB, 16 MiB up to 100 GiB, 32 MiB above. Logical and physical sector size are both written as 512. Differencing images are not supported by qemu. [SRC-5]
- So `-o subformat=dynamic` is the default and may be given for clarity; no other option is needed.

### 5.2 Known incompatibilities and what the scripts do about them

| Risk | Status | Handling |
|---|---|---|
| NTFS sparse flag: Hyper-V refuses with "Virtual hard disk files must be uncompressed and unencrypted and must not be sparse" (0xC03A001A). Reported for qemu-img running on Windows (qemu issues 136, 2204) | Error text from community reports, no Microsoft page found (UNCONFIRMED wording). **Measured on the lab host: files written with holes from a wslc container through the bind mount (`drvfs`/virtiofs) arrive on NTFS fully allocated and NOT flagged sparse**, owner `<PC>\<user>`. [M] (measured on a volume other than the checkout's; the mechanism is the same there) | Script checks `(Get-Item f).Attributes` for `SparseFile`, `Compressed`, `Encrypted`; clears sparse with `fsutil sparse setflag <file> 0`, which works unelevated on own files [M]; stops with a clear message for the other two |
| Hyper-V cannot parse the qemu-made VHDX at all | UNCONFIRMED either way | `Get-VHD -Path <base>` must succeed; then the VM disk is produced by Hyper-V itself (5.3). Plan B if Hyper-V rejects the file: let qemu write the old format (`qemu-img convert -O vpc -o subformat=fixed,force_size ... x.vhd`) and convert with `Convert-VHD x.vhd x.vhdx -VHDType Dynamic`; plan B is not checked against a source, UNCONFIRMED |
| Block size: Hyper-V's default is 32 MB and Microsoft recommends 1 MB for Linux file systems on dynamic VHDX ("use 1 MB BlockSizeBytes (from the default 32 MB)") [MS-9]; qemu picks 8 or 16 MiB | Cosmetic for a lab (disk space only) | Optional `-BlockSizeBytes 1MB` on Convert-VHD; not needed |
| Image smaller than wanted | Expected: cloud and nano images are a few GB | `Resize-VHD -Path <disk> -SizeBytes 8GB` on the copy: "can expand both VHD and VHDX files"; for IDE-attached disks only while the VM is off. [MSR-7] After growing, "use a utility like fdisk or parted to update the partition ... structures"; a GPT warning about the backup header is expected and "safe". [MS-9] Whether the guests grow their root file system by themselves is for the image sheet |

### 5.3 Import step (recommended): let Hyper-V write the VM's disk

```powershell
Get-VHD     -Path '<checkout>\lab\.work\disks\base-debian-13.vhdx'      # must print VhdFormat VHDX, VhdType Dynamic, Size, FileSize, BlockSize
Convert-VHD -Path '<checkout>\lab\.work\disks\base-debian-13.vhdx' `
            -DestinationPath '<checkout>\lab\.work\disks\clat-world.vhdx' -VHDType Dynamic
Resize-VHD  -Path '<checkout>\lab\.work\disks\clat-world.vhdx' -SizeBytes 8GB
```

- `Convert-VHD [-Path] <string> [-DestinationPath] <string> [-VHDType <VhdType>] [-BlockSizeBytes <uint32>] [-DeleteSource]`; `Resize-VHD [-Path] <string[]> [-SizeBytes] <uint64>`; `Get-VHD [-Path] <string[]>`; `Test-VHD [-Path] <string[]>`; `Optimize-VHD [-Path] <string[]> [-Mode <VhdCompactMode>]`. [MOD]
- "The Convert-VHD cmdlet converts a virtual hard disk file by copying the data from a source virtual hard disk file". "Conversion is an offline operation; the virtual hard disk must not be attached when the operation is started." [MSR-8]
- Why: the base image stays untouched for quick re-creation; the file the VM runs on, gets checkpoints (.avhdx) and is resized, is one written by Hyper-V; and the step fails early if Hyper-V cannot read qemu's output. Calling this a "repair" of a bad qemu file is UNCONFIRMED: if Hyper-V cannot read the source, Convert-VHD cannot either (then plan B above).
- `Optimize-VHD` only compacts ("optimizes the allocation of space"; "the virtual hard disk must not be attached or must be attached in read-only mode"). [MSR-9] It is not a repair tool and the lab does not need it.

### 5.4 File permissions for disks outside the default folder

- "Every Hyper-V virtual machine has a unique Virtual Machine ID (SID). If the Virtual Machine SID is missing from the security permissions on the .vhd or .avhd file, the virtual machine does not start, and you receive the error 0x80070005 (General access denied error)". Fix: `icacls <Path of .vhd or .avhd file> /grant "NT VIRTUAL MACHINE\<Virtual Machine ID>":(F)`. [MS-17]
- **That New-VM, Add-VMHardDiskDrive and Add-VMDvdDrive add this entry themselves when they attach a file is UNCONFIRMED** (community sources say Hyper-V Manager does; no Microsoft page read for this sheet says it for the cmdlets). The script checks and repairs:

```powershell
$id = (Get-VM -Name 'clat-opn').Id                      # the Virtual Machine ID (a GUID)
icacls '<checkout>\lab\.work\disks\clat-opn.vhdx'  # look for NT VIRTUAL MACHINE\<that GUID>
icacls '<checkout>\lab\.work\disks\clat-opn.vhdx' /grant "NT VIRTUAL MACHINE\${id}:(F)"   # only if missing
```

  The same applies to the seed ISO and the second disk. The files are owned by the user, [M] so changing their ACL should not need elevation (UNCONFIRMED for the VM-SID name lookup).

---

## 6. Further points that decide whether the lab is drivable

### 6.1 Locations

```
<checkout>\lab\hyperv\lab-common.ps1, create-lab.ps1, remove-lab.ps1, status-lab.ps1
<checkout>\lab\.work\cache\      downloads (never deleted by remove-lab)
<checkout>\lab\.work\disks\      base-*.vhdx (kept), clat-*.vhdx, clat-*.avhdx, clat-*.iso (removed by remove-lab)
<checkout>\lab\.work\vm\clat-*\  VM configuration folders (New-VM -Path); a fourth folder next to the lab's three
<checkout>\lab\.work\results\    lab-state.json, logs
```

To keep to the lab's three folders, drop `-Path`: Hyper-V then keeps the configuration in its own default folder under `C:\ProgramData\Microsoft\Windows\Hyper-V` (exists [M]), which is outside the project.

### 6.2 Names

Switches `clat-wan`, `clat-lan`, `clat-mgmt`; VMs `clat-world`, `clat-opn`; every switch and VM carries the note `os-clat lab`. Removal requires prefix AND note (and, for switches, type Private), so a foreign object that merely has the prefix is skipped with a warning.

### 6.3 Seeing and typing on the console without elevation and without a GUI (optional fallback)

- `Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage(TargetSystem, WidthPixels, HeightPixels)` returns the screen as "raw RGB 565"; namespace `Root\Virtualization\V2`. [MS-14] `Msvm_Keyboard` has `TypeText` ("Simulates a series of typed characters"), `TypeKey`, `PressKey`, `ReleaseKey`, `TypeCtrlAltDel`, `TypeScancodes`. [MS-14]
- With these, a script can save a PNG of a VM's console and type on it (for example at OPNsense's console menu) when neither ssh nor the serial pipe is available. Untested sketch, parameter names not checked against a source (UNCONFIRMED):

```powershell
$ns   = 'root\virtualization\v2'
$vm   = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='clat-opn'"
$vssd = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData -Association Msvm_SettingsDefineState
$svc  = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$r    = Invoke-CimMethod -InputObject $svc -MethodName GetVirtualSystemThumbnailImage -Arguments @{ TargetSystem = $vssd; WidthPixels = [uint16]1024; HeightPixels = [uint16]768 }
# $r.ImageData: 1024*768*2 bytes, RGB565 -> System.Drawing.Bitmap(Format16bppRgb565) -> Save as PNG
$kb   = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_Keyboard
Invoke-CimMethod -InputObject $kb -MethodName TypeText -Arguments @{ asciiText = 'root' }
Invoke-CimMethod -InputObject $kb -MethodName TypeKey  -Arguments @{ keyCode = [uint32]13 }
```

- By hand: `vmconnect.exe localhost clat-opn` opens the console window.

---

## 7. Script layout

Four small files in `lab\hyperv\`. ASCII only (Windows PowerShell 5.1 reads BOM-less files as ANSI). No `#Requires -RunAsAdministrator`: the scripts accept either an elevated session or Hyper-V Administrators membership and say what to do when there is neither.

What was checked for this sheet, and what was not:

- All four files, extracted from this sheet, parse without error in Windows PowerShell 5.1 and contain only ASCII. [M]
- The parts that make no Hyper-V call were executed in a scratch folder: the name guard (accepts `clat-wan`; refuses `clat-`, `Default Switch`, `WSL (Hyper-V firewall)`, `xclat-opn`), the path guard (refuses `..` escapes, `C:\Windows\x` and a sibling folder `.workx`), the rights check (prints the instructions and exits with code 2 without rights), the sparse-flag fix, the MAC lookup, and the no-rights path of status-lab.ps1. [M]
- Every object property the scripts read exists in the installed module (checked by reflection): `VirtualMachine` Name, Id, State, Generation, Uptime, Heartbeat, MemoryAssigned, Notes; `VMNetworkAdapter` Name, SwitchName, MacAddress, IPAddresses (String[]), MacAddressSpoofing, DhcpGuard, RouterGuard; `VMSwitch` Name, Id, SwitchType, Notes; `VMSnapshot` Name, SnapshotType, CreationTime; `HardDiskDrive`/`DvdDrive` ControllerType, ControllerNumber, ControllerLocation, Path; `VMComPort` Name, Path; `VMIntegrationComponent` Name, Enabled, PrimaryStatusDescription; `VirtualHardDisk` VhdFormat, VhdType, FileSize, Size, MinimumSize, BlockSize, LogicalSectorSize, PhysicalSectorSize, Attached. [MOD]
- **No line that calls a Hyper-V cmdlet has ever run.** Parameter names are right ([MOD]); behaviour is not verified.

### 7.1 lab-common.ps1 (dot-sourced; makes no Hyper-V call when loaded)

```powershell
# FILE: lab-common.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$LabRoot = Split-Path -Parent $PSScriptRoot          # ...\lab  (this file is in ...\lab\hyperv)
$Lab = @{
    Prefix          = 'clat-'
    Tag             = 'os-clat lab'
    Work            = Join-Path $LabRoot '.work'
    DefaultSwitchId = [guid]'c08cb7b8-9b3c-408e-8e30-5e16a3aeb444'
    HvAdminsSid     = 'S-1-5-32-578'
    Switches        = @('clat-wan', 'clat-lan', 'clat-mgmt')
    VMs             = @(
        @{ Name = 'clat-world'; Generation = 2; MemoryMB = 2048; Cpu = 2; SizeGB = 8
           Base = 'base-debian-13.vhdx'; Dvd = 'clat-world-seed.iso'; ExtraDisk = $null
           Nics = @(
               @{ Name = 'nat';  Switch = '@default';  Mac = '02C1A7000101' },
               @{ Name = 'mgmt'; Switch = 'clat-mgmt'; Mac = '02C1A7000102' },
               @{ Name = 'wan';  Switch = 'clat-wan';  Mac = '02C1A7000103' },
               @{ Name = 'lan';  Switch = 'clat-lan';  Mac = '02C1A7000104' }) },
        @{ Name = 'clat-opn'; Generation = 2; MemoryMB = 3072; Cpu = 2; SizeGB = 8
           Base = 'base-opnsense-26.7.vhdx'; Dvd = $null; ExtraDisk = 'clat-opn-conf.vhdx'
           Nics = @(
               @{ Name = 'mgmt'; Switch = 'clat-mgmt'; Mac = '02C1A7000201' },
               @{ Name = 'wan';  Switch = 'clat-wan';  Mac = '02C1A7000202' },
               @{ Name = 'lan';  Switch = 'clat-lan';  Mac = '02C1A7000203' }) }
    )
}
$Lab.Disks   = Join-Path $Lab.Work 'disks'
$Lab.VmDir   = Join-Path $Lab.Work 'vm'
$Lab.Results = Join-Path $Lab.Work 'results'

function Write-LabStep([string]$State, [string]$What) { Write-Host ('{0,-10} {1}' -f $State, $What) }

function Assert-LabName([string]$Name) {
    if ($Name -notlike ($Lab.Prefix + '?*')) { throw "Refusing to touch '$Name': the name does not start with '$($Lab.Prefix)'." }
}

function Assert-LabPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($Lab.Work).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to touch '$full': it is outside $root" }
    return $full
}

function Get-LabRights {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    New-Object psobject -Property @{
        User     = $id.Name
        Elevated = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        HvAdmin  = $p.IsInRole([Security.Principal.SecurityIdentifier]$Lab.HvAdminsSid)
    }
}

function Assert-LabRights {
    $r = Get-LabRights
    Write-Host ('rights: user={0} elevated={1} hyper-v-administrators={2}' -f $r.User, $r.Elevated, $r.HvAdmin)
    if ($r.Elevated -or $r.HvAdmin) { return }
    Write-Host ''
    Write-Host 'This session cannot manage Hyper-V. Either:'
    Write-Host ("  a) once, in an elevated PowerShell:  Add-LocalGroupMember -SID '{0}' -Member '{1}'" -f $Lab.HvAdminsSid, $r.User)
    Write-Host '     then sign out of Windows, sign in again, and re-run this script; or'
    Write-Host '  b) run this script from an elevated PowerShell:'
    Write-Host ('     powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $MyInvocation.PSCommandPath)
    exit 2
}

function Get-LabVM([string]$Name)     { Assert-LabName $Name; Get-VM       | Where-Object { $_.Name -eq $Name } }
function Get-LabSwitch([string]$Name) { Assert-LabName $Name; Get-VMSwitch | Where-Object { $_.Name -eq $Name } }

# Hyper-V refuses disk files that are sparse, compressed or encrypted.
function Assert-LabPlainFile([string]$Path) {
    $sparse = [IO.FileAttributes]::SparseFile
    $bad    = $sparse -bor [IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::Encrypted
    $a = (Get-Item -LiteralPath $Path).Attributes
    if ($a -band $sparse) {
        & fsutil.exe sparse setflag $Path 0 | Out-Null
        $a = (Get-Item -LiteralPath $Path).Attributes
        Write-LabStep 'fixed' "sparse flag cleared on $Path"
    }
    if ($a -band $bad) { throw "$Path is sparse, compressed or encrypted ($a). Hyper-V will not attach it." }
}

# The VM's own SID must be able to open every file attached to it.
function Confirm-LabVmFileAccess($Vm, [string]$Path) {
    $id  = $Vm.Id.ToString()
    $acl = (& icacls.exe $Path) -join "`n"
    if ($acl -match [regex]::Escape($id)) { Write-LabStep 'ok' "acl $Path"; return }
    & icacls.exe $Path /grant ('NT VIRTUAL MACHINE\{0}:(F)' -f $id) | Out-Null
    Write-LabStep 'fixed' "acl $Path (VM SID added)"
}

# Works without Hyper-V rights. $Mac like 02C1A7000101.
function Get-LabAddressByMac([string]$Mac) {
    $dashed = ($Mac -replace '(..)(?!$)', '$1-').ToUpper()
    Get-NetNeighbor -AddressFamily IPv4 -LinkLayerAddress $dashed -ErrorAction SilentlyContinue |
        Where-Object { $_.State -notin 'Unreachable', 'Incomplete' } |
        Select-Object -First 1 -ExpandProperty IPAddress
}
```

### 7.2 create-lab.ps1

Order: rights, switches (with host-adapter diff), then per VM: disk, VM, settings, adapters, drives, firmware, COM port, ACL check; then start (clat-world first). An existing switch or VM is reported and left as it is; a new run only creates what is missing.

```powershell
# FILE: create-lab.ps1
param([switch]$SwitchesOnly, [switch]$NoStart)
. (Join-Path $PSScriptRoot 'lab-common.ps1')
Assert-LabRights
Import-Module Hyper-V

# 1. private switches; the before/after list shows that the host got no new adapter
$before = @(Get-NetAdapter -IncludeHidden | ForEach-Object { $_.Name })
foreach ($s in $Lab.Switches) {
    $sw = Get-LabSwitch $s
    if ($sw) {
        if ($sw.SwitchType -ne 'Private') { throw "Switch '$s' exists but is $($sw.SwitchType), not Private. Not touching it." }
        Write-LabStep 'exists' "switch $s"
    } else {
        New-VMSwitch -Name $s -SwitchType Private -Notes $Lab.Tag | Out-Null
        Write-LabStep 'created' "switch $s (Private)"
    }
}
$added = @(Get-NetAdapter -IncludeHidden | ForEach-Object { $_.Name } | Where-Object { $before -notcontains $_ })
if ($added.Count -gt 0) { Write-Warning ('host adapters appeared: ' + ($added -join ', ')) }
else { Write-LabStep 'unchanged' 'host network adapters' }
if ($SwitchesOnly) { return }

$default = Get-VMSwitch -Id $Lab.DefaultSwitchId          # read only, never modified
if (-not $default) { throw 'The Default Switch was not found.' }

# 2. virtual machines
foreach ($v in $Lab.VMs) {
    $name = $v.Name
    $vm = Get-LabVM $name
    if ($vm) {
        if ($vm.Notes -notlike ($Lab.Tag + '*')) { throw "VM '$name' exists but is not tagged '$($Lab.Tag)'. Not touching it." }
        Write-LabStep 'exists' "vm $name ($($vm.State))"
        continue
    }

    $base = Assert-LabPath (Join-Path $Lab.Disks $v.Base)
    $disk = Assert-LabPath (Join-Path $Lab.Disks ($name + '.vhdx'))
    if (-not (Test-Path -LiteralPath $disk)) {
        if (-not (Test-Path -LiteralPath $base)) { throw "Base image missing: $base (build the images first)." }
        Assert-LabPlainFile $base
        Get-VHD -Path $base | Out-Null                    # fails here if Hyper-V cannot read qemu-img's file
        Convert-VHD -Path $base -DestinationPath $disk -VHDType Dynamic
        $want = [int64]$v.SizeGB * 1GB
        if ((Get-VHD -Path $disk).Size -lt $want) { Resize-VHD -Path $disk -SizeBytes $want }
        Write-LabStep 'created' "disk $disk"
    }

    $vmPath = Assert-LabPath (Join-Path $Lab.VmDir $name)
    $vm = New-VM -Name $name -Generation $v.Generation -MemoryStartupBytes ([int64]$v.MemoryMB * 1MB) -VHDPath $disk -Path $vmPath
    $set = @{ VM = $vm; Notes = $Lab.Tag; StaticMemory = $true; ProcessorCount = $v.Cpu
              AutomaticStartAction = 'Nothing'; AutomaticStopAction = 'ShutDown'
              AutomaticCheckpointsEnabled = $false; CheckpointType = 'Standard' }
    Set-VM @set

    Get-VMNetworkAdapter -VM $vm | Remove-VMNetworkAdapter      # the adapter New-VM adds by itself
    foreach ($n in $v.Nics) {
        if ($n.Switch -eq '@default') { $swName = $default.Name } else { Assert-LabName $n.Switch; $swName = $n.Switch }
        Add-VMNetworkAdapter -VM $vm -Name $n.Name -SwitchName $swName -StaticMacAddress $n.Mac
    }

    $files = @($disk)
    if ($v.Dvd) {
        $iso = Assert-LabPath (Join-Path $Lab.Disks $v.Dvd)
        if (-not (Test-Path -LiteralPath $iso)) { throw "Seed image missing: $iso" }
        $dvd = Get-VMDvdDrive -VM $vm | Select-Object -First 1
        if ($dvd) { Set-VMDvdDrive -VMDvdDrive $dvd -Path $iso } else { Add-VMDvdDrive -VM $vm -Path $iso }
        $files += $iso
    }
    if ($v.ExtraDisk) {
        $extra = Assert-LabPath (Join-Path $Lab.Disks $v.ExtraDisk)
        if (-not (Test-Path -LiteralPath $extra)) { throw "Second disk missing: $extra" }
        Assert-LabPlainFile $extra
        if ($v.Generation -eq 2) { Add-VMHardDiskDrive -VM $vm -ControllerType SCSI -Path $extra }
        else { Add-VMHardDiskDrive -VM $vm -ControllerType IDE -ControllerNumber 0 -ControllerLocation 1 -Path $extra }
        $files += $extra
    }

    if ($v.Generation -eq 2) {
        $boot = Get-VMHardDiskDrive -VM $vm | Where-Object { $_.Path -eq $disk } | Select-Object -First 1
        Set-VMFirmware -VM $vm -EnableSecureBoot Off -FirstBootDevice $boot
    }
    Set-VMComPort -VM $vm -Number 1 -Path ('\\.\pipe\' + $name + '-com1')
    foreach ($f in $files) { Confirm-LabVmFileAccess $vm $f }
    Write-LabStep 'created' ("vm {0}: generation {1}, {2} MB, {3} vCPU, adapters {4}" -f $name, $v.Generation, $v.MemoryMB, $v.Cpu, (($v.Nics | ForEach-Object { $_.Name + '=' + $_.Mac }) -join ' '))
}

# 3. state file for shells without Hyper-V rights
New-Item -ItemType Directory -Force -Path $Lab.Results | Out-Null
$state = @(foreach ($v in $Lab.VMs) {
    $vm = Get-LabVM $v.Name
    if ($vm) { New-Object psobject -Property @{ Name = $vm.Name; Id = $vm.Id.ToString(); Generation = $vm.Generation
                                                Nics = @($v.Nics | ForEach-Object { $_.Name + '=' + $_.Mac }) } }
})
ConvertTo-Json -InputObject $state -Depth 4 | Set-Content -Encoding ASCII -LiteralPath (Join-Path $Lab.Results 'lab-state.json')

# 4. start: the ISP side first
if (-not $NoStart) {
    foreach ($v in $Lab.VMs) {
        $vm = Get-LabVM $v.Name
        if ($vm.State -eq 'Running') { Write-LabStep 'running' "vm $($v.Name)" }
        else { Start-VM -VM $vm; Write-LabStep 'started' "vm $($v.Name)" }
    }
}
```

### 7.3 remove-lab.ps1

Removes only: VMs whose name starts with `clat-` and whose note is the lab tag; switches whose name starts with `clat-`, are Private and carry the tag; files `clat-*` in `.work\disks` and folders `clat-*` in `.work\vm`. Keeps `cache\` and `base-*.vhdx`. Safe to re-run: what is gone is not mentioned again.

```powershell
# FILE: remove-lab.ps1
param([switch]$KeepDisks)
. (Join-Path $PSScriptRoot 'lab-common.ps1')
Assert-LabRights
Import-Module Hyper-V

foreach ($vm in @(Get-VM | Where-Object { $_.Name -like ($Lab.Prefix + '*') })) {
    if ($vm.Notes -notlike ($Lab.Tag + '*')) { Write-Warning "VM '$($vm.Name)' has the prefix but not the lab tag: skipped."; continue }
    if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force -Confirm:$false; Write-LabStep 'turned off' "vm $($vm.Name)" }
    Remove-VM -VM $vm -Force
    Write-LabStep 'removed' "vm $($vm.Name)"
}

foreach ($sw in @(Get-VMSwitch | Where-Object { $_.Name -like ($Lab.Prefix + '*') })) {
    if ($sw.SwitchType -ne 'Private' -or $sw.Notes -ne $Lab.Tag) { Write-Warning "Switch '$($sw.Name)' is not a tagged private lab switch: skipped."; continue }
    $users = @(Get-VMNetworkAdapter -All | Where-Object { $_.SwitchName -eq $sw.Name })
    if ($users.Count -gt 0) { Write-Warning "Switch '$($sw.Name)' is still used by $($users.Count) adapter(s): skipped."; continue }
    Remove-VMSwitch -Name $sw.Name -Force
    Write-LabStep 'removed' "switch $($sw.Name)"
}

if (-not $KeepDisks) {
    $targets = @()
    if (Test-Path -LiteralPath $Lab.Disks) { $targets += @(Get-ChildItem -LiteralPath $Lab.Disks -File      | Where-Object { $_.Name -like ($Lab.Prefix + '*') }) }
    if (Test-Path -LiteralPath $Lab.VmDir) { $targets += @(Get-ChildItem -LiteralPath $Lab.VmDir -Directory | Where-Object { $_.Name -like ($Lab.Prefix + '*') }) }
    foreach ($t in $targets) {
        $p = Assert-LabPath $t.FullName
        # after Remove-VM, checkpoint files are merged in the background and stay locked for a while
        for ($i = 0; $i -lt 30 -and (Test-Path -LiteralPath $p); $i++) {
            try { Remove-Item -LiteralPath $p -Recurse -Force } catch { Start-Sleep -Seconds 2 }
        }
        if (Test-Path -LiteralPath $p) { Write-Warning "could not delete $p" } else { Write-LabStep 'deleted' $p }
    }
}
```

### 7.4 status-lab.ps1 (changes nothing)

```powershell
# FILE: status-lab.ps1
. (Join-Path $PSScriptRoot 'lab-common.ps1')
$r = Get-LabRights
Write-Host ('rights: user={0} elevated={1} hyper-v-administrators={2}' -f $r.User, $r.Elevated, $r.HvAdmin)

Write-Host '--- files'
foreach ($d in @((Join-Path $Lab.Work 'cache'), $Lab.Disks)) {
    if (Test-Path -LiteralPath $d) {
        Get-ChildItem -LiteralPath $d -File | ForEach-Object { '{0,9:N0} MB  {1}  [{2}]' -f ($_.Length / 1MB), $_.FullName, $_.Attributes }
    }
}

Write-Host '--- addresses seen by the host for the lab MACs (no Hyper-V call)'
foreach ($v in $Lab.VMs) { foreach ($n in $v.Nics) {
    $ip = Get-LabAddressByMac $n.Mac
    if ($ip) { '{0}/{1} {2} -> {3}' -f $v.Name, $n.Name, $n.Mac, $ip }
} }

if (-not ($r.Elevated -or $r.HvAdmin)) { Write-Host 'No Hyper-V rights in this session: VM state not shown.'; return }
Import-Module Hyper-V

Write-Host '--- switches'
Get-VMSwitch | Where-Object { $_.Name -like ($Lab.Prefix + '*') } | Format-Table Name, SwitchType, Notes -AutoSize | Out-String | Write-Host

Write-Host '--- virtual machines'
$vms = @(Get-VM | Where-Object { $_.Name -like ($Lab.Prefix + '*') })
$vms | Format-Table Name, State, Generation, Uptime, Heartbeat, @{ n = 'MemMB'; e = { [int]($_.MemoryAssigned / 1MB) } }, Notes -AutoSize | Out-String | Write-Host
foreach ($vm in $vms) {
    Write-Host ("--- {0} (id {1})" -f $vm.Name, $vm.Id)
    Get-VMNetworkAdapter -VM $vm | Format-Table Name, SwitchName, MacAddress, MacAddressSpoofing, DhcpGuard, RouterGuard, @{ n = 'IPAddresses'; e = { $_.IPAddresses -join ' ' } } -AutoSize | Out-String | Write-Host
    Get-VMHardDiskDrive -VM $vm | Format-Table ControllerType, ControllerNumber, ControllerLocation, Path -AutoSize | Out-String | Write-Host
    Get-VMDvdDrive -VM $vm | Format-Table ControllerNumber, ControllerLocation, Path -AutoSize | Out-String | Write-Host
    Get-VMComPort -VM $vm | Format-Table Name, Path -AutoSize | Out-String | Write-Host
    Get-VMSnapshot -VM $vm | Format-Table Name, SnapshotType, CreationTime -AutoSize | Out-String | Write-Host
    Get-VMIntegrationService -VM $vm | Format-Table Name, Enabled, PrimaryStatusDescription -AutoSize | Out-String | Write-Host
}
```

The property names used in the tables exist in the installed module (see the list at the top of this section). [MOD]

### 7.5 Not a separate script

Checkpoint save/restore (2.9) is six lines; it belongs in the test runner, not in a fifth script.

---

## 8. Corrections to common assumptions

1. "Automatic start/stop actions (set to Nothing)": only the start action has `Nothing`. Stop action is one of `TurnOff, Save, ShutDown`. [MOD]
2. "Convert-VHD / Optimize-VHD as a repair": Convert-VHD is a copy made by Hyper-V (useful as import and early check), Optimize-VHD only compacts. Neither repairs a file Hyper-V cannot read. [MSR-8][MSR-9]
3. "The need for the file not to be sparse": real for qemu-img on Windows, but files written from a wslc container arrive non-sparse on the lab host. [M] The check stays in the script because it is cheap.
4. COM-port pipes: configuration is a Hyper-V right, but opening the pipe needs an elevated process. [MS-10] In group-member mode there is no serial log unless the reader is started elevated.
5. Microsoft's support tables do not list Debian 13 or FreeBSD 15. [MS-6][MS-7]
6. Private-switch creation unelevated is not confirmed by current Microsoft pages (section 1.1).

---

## 9. What the first run has to confirm (in this order)

| # | Check | How | If it fails |
|---|---|---|---|
| 1 | Group membership is in the token | `whoami /groups \| findstr S-1-5-32-578` shows "Enabled group" | sign out and in again |
| 2 | Hyper-V cmdlets work unelevated | `Get-VMSwitch` lists "Default Switch" with id c08cb7b8-... | run elevated |
| 3 | Private switches can be created unelevated and add no host adapter | `create-lab.ps1 -SwitchesOnly` prints "created" three times and "unchanged host network adapters" | run that one command elevated |
| 4 | Hyper-V reads qemu-img's VHDX | `Get-VHD` and `Convert-VHD` in create-lab succeed | plan B in 5.2 |
| 5 | New-VM with `-Path` on the checkout's volume works; locally administered static MACs accepted | create-lab prints "created vm ..." | drop `-Path`; use `00155D...` MACs |
| 6 | The VM SID is on every attached file | lines "ok acl ..." (or "fixed acl ...") | 5.4 |
| 7 | Both guests boot (Generation 2, Secure Boot off) | Heartbeat column, screenshot or vmconnect | try Generation 1 for that image |
| 8 | Guest NIC order | in each guest list interface name and MAC; compare with the add order | keep matching by MAC |
| 9 | clat-world gets an address on the Default Switch and the host finds it | status-lab "addresses seen by the host"; `Resolve-DnsName clat-world.mshome.net`; later the IPAddresses column | use whichever of the three works |
| 10 | KVP in both guests | `Get-VMIntegrationService`; IPAddresses filled | not essential |
| 11 | Frames of 1508 (and 1536) bytes payload pass on clat-wan | ping test in section 3 | test with PPP MTU 1492 and report RFC 4638 as untested |
| 12 | Guest shutdown through Stop-VM works for both | `Stop-VM -Name ...` returns and State is Off | use ssh shutdown, then `-TurnOff` |
| 13 | Checkpoint, restore, start cycle | 2.9; note the time it takes | reset inside the guests |
| 14 | COM pipe | elevated reader shows boot text; unelevated open is refused | ignore: diagnostic only |
| 15 | remove-lab leaves nothing | status-lab shows no switches, VMs, `clat-*` files; `Get-NetAdapter` unchanged | re-run after a minute (merge) |

---

## 10. Sources

Microsoft documentation (read in full unless noted):

- [MS-1] Active Directory security groups, section "Hyper-V Administrators": https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/understand-security-groups
- [MS-2] Plan for Hyper-V networking in Windows Server: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/plan-hyper-v-networking-in-windows-server
- [MS-3] Create and configure a virtual switch with Hyper-V: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/create-a-virtual-switch-for-hyper-v-virtual-machines
- [MS-4] New-VMSwitch: https://learn.microsoft.com/en-us/powershell/module/hyper-v/new-vmswitch?view=windowsserver2025-ps
- [MS-5] Should I create a generation 1 or 2 virtual machine in Hyper-V?: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/plan/should-i-create-a-generation-1-or-2-virtual-machine-in-hyper-v
- [MS-6] Supported Debian virtual machines on Hyper-V: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/supported-debian-virtual-machines-on-hyper-v
- [MS-7] Supported FreeBSD virtual machines on Hyper-V: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/supported-freebsd-virtual-machines-on-hyper-v
- [MS-8] Set-VMFirmware: https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmfirmware?view=windowsserver2025-ps
- [MS-9] Best practices for running Linux on Hyper-V: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/best-practices-for-running-linux-on-hyper-v
- [MS-10] Setting up kernel-mode debugging of a virtual machine manually using a virtual COM port: https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/attaching-to-a-virtual-machine--kernel-mode-
- [MS-11] Best practices for running FreeBSD on Hyper-V: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/best-practices-for-running-freebsd-on-hyper-v
- [MS-12] Set-VMComPort: https://learn.microsoft.com/en-us/powershell/module/hyper-v/set-vmcomport?view=windowsserver2025-ps
- [MS-13] Using checkpoints: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/checkpoints
- [MS-14] GetVirtualSystemThumbnailImage: https://learn.microsoft.com/en-us/windows/win32/hyperv_v2/getvirtualsystemthumbnailimage-msvm-virtualsystemmanagementservice ; Msvm_Keyboard: https://learn.microsoft.com/en-us/windows/win32/hyperv_v2/msvm-keyboard
- [MS-15] Stop-VM: https://learn.microsoft.com/en-us/powershell/module/hyper-v/stop-vm?view=windowsserver2025-ps ; Remove-VM: https://learn.microsoft.com/en-us/powershell/module/hyper-v/remove-vm?view=windowsserver2025-ps
- [MS-16] Manage Hyper-V Integration Services: https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/manage-hyper-v-integration-services
- [MS-17] Hyper-V virtual machine doesn't start with error 0x80070005: https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-not-start-0x80070005

Microsoft cmdlet reference read from https://github.com/MicrosoftDocs/windows-powershell-docs (branch live, `docset/winserver2025-ps/Hyper-V/<Name>.md`) as fetched excerpts:

- [MSR-1] New-VM.md  [MSR-2] Set-VM.md  [MSR-3] Add-VMNetworkAdapter.md  [MSR-4] Add-VMDvdDrive.md, Add-VMHardDiskDrive.md  [MSR-5] Set-VMNetworkAdapter.md  [MSR-6] Remove-VMSwitch.md, Checkpoint-VM.md, Restore-VMSnapshot.md, Remove-VMSnapshot.md  [MSR-7] Resize-VHD.md  [MSR-8] Convert-VHD.md  [MSR-9] Optimize-VHD.md

Microsoft blogs:

- [BLOG-1] Ben Armstrong, "Why do you have to elevate PowerShell to use Hyper-V cmdlets?", 2015-08-17: https://learn.microsoft.com/en-us/archive/blogs/virtual_pc_guy/why-do-you-have-to-elevate-powershell-to-use-hyper-v-cmdlets
- [BLOG-2] Ben Armstrong, "Adding yourself to the Hyper-V Administrators group with PowerShell", 2016-05-30: https://learn.microsoft.com/en-us/archive/blogs/virtual_pc_guy/adding-yourself-to-the-hyper-v-administrators-group-with-powershell
- [BLOG-3] Microsoft Virtualization Blog, "Hyper-V virtual machine gallery and networking improvements", 2017-07-26, original https://techcommunity.microsoft.com/t5/Virtualization/Hyper-V-virtual-machine-gallery-and-networking-improvements/ba-p/382375 (read through the mirror https://thewindowsupdate.com/?p=43676)
- [BLOG-4] Microsoft Virtualization Blog, "What's new in Hyper-V for Windows 10 Fall Creators Update?", 2017-11-13, original https://techcommunity.microsoft.com/t5/Virtualization/What-s-new-in-Hyper-V-for-Windows-10-Fall-Creators-Update/ba-p/382399 (read through the mirror https://thewindowsupdate.com/2019/03/21/whats-new-in-hyper-v-for-windows-10-fall-creators-update/)

Source code and other projects:

- [SRC-1] Linux v6.12: `drivers/net/hyperv/netvsc_drv.c` (MTU range, change_mtu, VF namespace code), `drivers/net/hyperv/netvsc.c` (send_ndis_config.mtu), `tools/hv/hv_kvp_daemon.c` (KVP_OP_GET_IP_INFO): https://raw.githubusercontent.com/torvalds/linux/v6.12/...
- [SRC-2] opnsense/src stable/26.7: `sys/dev/hyperv/netvsc/if_hn.c`, `sys/dev/hyperv/netvsc/if_hnvar.h` (HN_MTU_MAX), `sbin/devd/hyperv.conf`: https://raw.githubusercontent.com/opnsense/src/stable/26.7/...
- [SRC-3] opnsense/tools `config/26.7/src.conf` (no WITHOUT_HYPERV): https://raw.githubusercontent.com/opnsense/tools/master/config/26.7/src.conf
- [SRC-4] Local reference clone `refs/opnsense-src` (stable/26.7): `UPDATING`, `share/man/man4/hv_kvp.4`, `hv_utils.4`, `hv_netvsc.4`, `hv_vss.4` (read directly)
- [SRC-5] qemu v9.2.0 `block/vhdx.c`, `block/vhdx.h`: https://raw.githubusercontent.com/qemu/qemu/v9.2.0/block/vhdx.c
- [OPN-1] OPNsense documentation, "Virtual & Cloud based Installation": https://docs.opnsense.org/manual/virtuals.html (fetched excerpt)
- [DEB-1] https://packages.debian.org/trixie/hyperv-daemons (fetched excerpt)

Community material used only for statements marked UNCONFIRMED: qemu issues https://gitlab.com/qemu-project/qemu/-/issues/136 and /2204 (sparse VHDX on Windows); https://bugs.freebsd.org/205156 (hn ordering); search summaries about the Default Switch subnet and `hosts.ics`.
