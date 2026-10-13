# create-lab.ps1 - creates the three private switches and the two VMs of the os-clat lab.
#
#   create-lab.ps1 -SwitchesOnly   switches only (the one step that may need elevation)
#   create-lab.ps1 -NoStart        switches and VMs, nothing started
#   create-lab.ps1                 the same, then starts clat-world and clat-opn
#
# Run as:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file> [-SwitchesOnly] [-NoStart]
# from an elevated PowerShell, or from any PowerShell of a "Hyper-V Administrators" member.
#
# Safe to run again: what exists is reported and left alone, what is missing is created.
# A VM that an earlier run left half built (note "os-clat lab (incomplete)") is removed and built again.
# Names, paths, sizes and MAC addresses: the settings block of lab-common.ps1.
# Ends with the listing of status-lab.ps1. Output also goes to .work\results\hyperv-<UTC>-create-lab.log.
#
# NOT TESTED ON HYPER-V: no Hyper-V cmdlet of this file has run yet.

[CmdletBinding()]
param([switch]$SwitchesOnly, [switch]$NoStart)

. (Join-Path $PSScriptRoot 'lab-common.ps1')

# 1. Private switches. The adapter list before and after shows that the host got no new adapter.
function New-LabSwitches {
    $before = @(Get-LabHostAdapters)
    foreach ($s in $Lab.Switches) {
        $sw = Get-LabSwitch $s
        if ($sw) {
            if ($sw.SwitchType -ne 'Private' -or (Get-LabNote $sw) -ne $Lab.Tag) {
                throw ("A switch named '{0}' exists, but it is not a Private switch with the note '{1}' (type {2}, note '{3}'). Not touching it." -f $s, $Lab.Tag, $sw.SwitchType, (Get-LabNote $sw))
            }
            Write-LabStep 'exists' "switch $s (Private)"
        } else {
            try { New-VMSwitch -Name $s -SwitchType Private -Notes $Lab.Tag | Out-Null }
            catch {
                throw ("New-VMSwitch failed for '{0}': {1} If this is a permission error, run 'create-lab.ps1 -SwitchesOnly' once from an elevated PowerShell." -f $s, $_.Exception.Message)
            }
            Write-LabStep 'created' "switch $s (Private)"
        }
    }
    Show-LabHostAdapterDiff $before

    # Software RSC off, on the lab switches only: the router under test must see the frames the client sent.
    # A failure here is recorded and does not stop the lab. The Default Switch is never passed to Set-VMSwitch.
    $canSet = (Get-Command Set-VMSwitch).Parameters.ContainsKey('EnableSoftwareRsc')
    foreach ($s in $Lab.Switches) {
        $value = Get-LabProp (Get-LabSwitch $s) 'SoftwareRscEnabled'
        if ($canSet -and ([string]$value -ne 'False')) {
            try { Set-VMSwitch -Name $s -EnableSoftwareRsc $false }
            catch { Write-LabWarning ("rsc {0}: Set-VMSwitch -EnableSoftwareRsc failed: {1}" -f $s, $_.Exception.Message) }
            $value = Get-LabProp (Get-LabSwitch $s) 'SoftwareRscEnabled'
        }
        Write-Host ('rsc {0}: SoftwareRscEnabled={1}' -f $s, $value)
    }
}

# 2. The VM's disk: a copy of the base image written by Hyper-V itself, enlarged before the first boot.
#    Built under a temporary name, so that a file with the final name is always complete.
function New-LabDisk($Spec) {
    $name = $Spec.Name
    $want = [int64]$Spec.SizeGB * 1GB
    $base = Assert-LabPath (Join-Path $Lab.Disks $Spec.Base)
    $disk = Assert-LabPath (Join-Path $Lab.Disks ($name + '.vhdx'))
    $tmp  = Assert-LabPath (Join-Path $Lab.Disks ($name + '.new.vhdx'))

    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force
        Write-LabStep 'deleted' "$tmp (left by an interrupted run)"
    }
    if (Test-Path -LiteralPath $disk) {
        Assert-LabPlainFile $disk
        if ((Get-VHD -Path $disk).Size -lt $want) { Resize-VHD -Path $disk -SizeBytes $want | Out-Null }
        Write-LabStep 'exists' ("disk {0} ({1} GB)" -f $disk, (Format-LabUnit (Get-VHD -Path $disk).Size 1GB '0.#'))
        return $disk
    }

    if (-not (Test-Path -LiteralPath $base)) { throw ("Base image missing: {0}. Build the images first (bash build.sh)." -f $base) }
    Assert-LabPlainFile $base
    try { $src = Get-VHD -Path $base }
    catch { throw ("Hyper-V cannot read {0} (written by qemu-img): {1} This is the open point 'Hyper-V reads qemu-img's VHDX' of the lab README." -f $base, $_.Exception.Message) }
    Write-Host ('base {0}: format={1} type={2} sizeGB={3} fileMB={4}' -f $base, $src.VhdFormat, $src.VhdType, (Format-LabUnit $src.Size 1GB '0.#'), (Format-LabUnit $src.FileSize 1MB '0'))

    Convert-VHD -Path $base -DestinationPath $tmp -VHDType Dynamic | Out-Null
    if ((Get-VHD -Path $tmp).Size -lt $want) { Resize-VHD -Path $tmp -SizeBytes $want | Out-Null }
    Rename-Item -LiteralPath $tmp -NewName ($name + '.vhdx')
    Write-LabStep 'created' ("disk {0} ({1} GB)" -f $disk, (Format-LabUnit (Get-VHD -Path $disk).Size 1GB '0.#'))
    return $disk
}

# 3. One VM: disk, VM, settings, adapters in order, DVD, firmware, COM port, ACL check.
function New-LabVm($Spec, $DefaultSwitch) {
    $name = $Spec.Name
    Assert-LabName $name

    $old = Get-LabVM $name
    if ($old) {
        $note = Get-LabNote $old
        if ($note -eq $Lab.Tag) { Write-LabStep 'exists' ("vm {0} ({1})" -f $name, $old.State); return }
        if ($note -ne $Lab.TagIncomplete) {
            throw ("A VM named '{0}' exists but does not carry the note '{1}' (it has '{2}'). Not touching it. If an interrupted run of this script left it, remove it by hand (Remove-VM -Name {0}) and run again." -f $name, $Lab.Tag, $note)
        }
        if ($old.State -ne 'Off') { throw ("The half-built VM '{0}' is in the state {1}; this script never starts an unfinished VM. Not touching it." -f $name, $old.State) }
        foreach ($f in @(Get-LabKeptFiles)) { Remove-LabVmFileAccess $old $f.FullName }
        Remove-VM -VM $old -Force
        Write-LabStep 'removed' "vm $name (left incomplete by an earlier run; it is built again now)"
    }

    $disk   = New-LabDisk $Spec
    $vmPath = Assert-LabPath (Join-Path $Lab.VmDir ($name + '.vm'))

    $vm = New-VM -Name $name -Generation $Spec.Generation -MemoryStartupBytes ([int64]$Spec.MemoryMB * 1MB) -VHDPath $disk -Path $vmPath
    Set-VM -VM $vm -Notes $Lab.TagIncomplete                    # marked first: a rerun then knows the VM is the lab's
    $set = @{ VM = $vm; StaticMemory = $true; ProcessorCount = $Spec.Cpu
              AutomaticStartAction = 'Nothing'; AutomaticStopAction = 'ShutDown'
              AutomaticCheckpointsEnabled = $false; CheckpointType = 'Standard' }
    Set-VM @set

    Get-VMNetworkAdapter -VM $vm | Remove-VMNetworkAdapter      # the adapter New-VM adds by itself
    foreach ($n in $Spec.Nics) {
        if ($n.Switch -eq '@default') { $swName = $DefaultSwitch.Name } else { Assert-LabName $n.Switch; $swName = $n.Switch }
        try { Add-VMNetworkAdapter -VM $vm -Name $n.Name -SwitchName $swName -StaticMacAddress $n.Mac }
        catch {
            throw ("Add-VMNetworkAdapter failed for {0}/{1} (switch '{2}', static MAC {3}): {4} If Hyper-V refuses the locally administered MAC, change the MACs in lab-common.ps1 and in world/network-config together." -f $name, $n.Name, $swName, $n.Mac, $_.Exception.Message)
        }
    }

    $files = @($disk)
    if ($Spec.Dvd) {
        $iso = Assert-LabPath (Join-Path $Lab.Disks $Spec.Dvd)
        if (-not (Test-Path -LiteralPath $iso)) { throw ("Seed image missing: {0}. Build the images first (bash build.sh)." -f $iso) }
        $dvd = Get-VMDvdDrive -VM $vm | Select-Object -First 1
        if ($dvd) { Set-VMDvdDrive -VMDvdDrive $dvd -Path $iso } else { Add-VMDvdDrive -VM $vm -Path $iso }
        $files += $iso
    }

    if ($Spec.Generation -eq 2) {
        # UEFI: Secure Boot off, boot from the disk. Generation 1 (BIOS) needs neither and has no Set-VMFirmware.
        $boot = Get-VMHardDiskDrive -VM $vm | Where-Object { $_.Path -eq $disk } | Select-Object -First 1
        if (-not $boot) { $boot = Get-VMHardDiskDrive -VM $vm | Select-Object -First 1 }
        Set-VMFirmware -VM $vm -EnableSecureBoot Off -FirstBootDevice $boot
    }

    Set-VMComPort -VM $vm -Number 1 -Path ('\\.\pipe\' + $name + '-com1')
    foreach ($f in $files) { Confirm-LabVmFileAccess $vm $f }

    Set-VM -VM $vm -Notes $Lab.Tag                              # finished
    Write-LabStep 'created' ("vm {0}: generation {1}, {2} MB, {3} vCPU, adapters {4}" -f $name, $Spec.Generation, $Spec.MemoryMB, $Spec.Cpu, (($Spec.Nics | ForEach-Object { $_.Name + '=' + $_.Mac }) -join ' '))
}

function Invoke-CreateLab {
    New-LabSwitches

    if (-not $SwitchesOnly) {
        $default = @(Get-VMSwitch | Where-Object { $_.Id -eq $Lab.DefaultSwitchId })        # read only, never modified
        if ($default.Count -ne 1) { throw ("The Hyper-V Default Switch (id {0}) was not found; clat-world needs it as its uplink." -f $Lab.DefaultSwitchId) }

        try { foreach ($v in $Lab.VMs) { New-LabVm $v $default[0] } }
        finally { Write-LabState }

        if ($NoStart) {
            Write-LabStep 'not started' 'virtual machines (-NoStart)'
        } else {
            foreach ($v in $Lab.VMs) { Start-LabGuest (Get-LabReadyVM $v.Name) }            # the ISP side first
        }
    }

    & (Join-Path $PSScriptRoot 'status-lab.ps1')
}

$rc = [int](@(Invoke-LabScript -ScriptName 'create-lab' -CommandLine (Get-LabCommandLine $PSCommandPath $PSBoundParameters) -Body { Invoke-CreateLab })[-1])
if ($rc -ne 0) { exit $rc }
