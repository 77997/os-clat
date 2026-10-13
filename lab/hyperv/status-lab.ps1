# status-lab.ps1 - lists the state of the os-clat lab. Changes nothing.
#
# Run as:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file>
#
# Without Hyper-V rights it prints what needs none: free space, files, the ACL of the kept
# base-* files, lab-state.json, addresses the host has seen for the lab MACs.
# With Hyper-V rights also: switches, VMs, adapters, disks, DVD, COM ports, checkpoints,
# integration services.
# Output also goes to .work\results\hyperv-<UTC>-status-lab.log (not when another lab script
# calls this one: then it is part of that script's log).
#
# NOT TESTED ON HYPER-V: no Hyper-V cmdlet of this file has run yet.

[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lab-common.ps1')

function Show-LabFiles {
    try {
        $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Lab.Work)))
        Write-Host ('--- free space: {0} GB free on {1}' -f (Format-LabUnit $drive.AvailableFreeSpace 1GB '0.0'), $drive.Name)
    } catch {
        Write-Host ('--- free space: not available ({0})' -f $_.Exception.Message)
    }

    Write-Host '--- files (cache, disks)'
    foreach ($d in @($Lab.Cache, $Lab.Disks)) {
        if (-not (Test-Path -LiteralPath $d)) { Write-Host ('(missing) ' + $d); continue }
        $entries = @(Get-ChildItem -LiteralPath $d -Force | Sort-Object Name)
        if ($entries.Count -eq 0) { Write-Host ('(empty) ' + $d) }
        foreach ($e in $entries) {
            if ($e.PSIsContainer) { Write-Host ('{0,12}  {1}' -f '<DIR>', $e.FullName) }
            else { Write-Host ('{0,9} MB  {1}  [{2}]' -f (Format-LabUnit $e.Length 1MB '0'), $e.FullName, $e.Attributes) }
        }
    }
    $labFiles = @()
    if (Test-Path -LiteralPath $Lab.Disks) { $labFiles = @(Get-ChildItem -LiteralPath $Lab.Disks -Force | Where-Object { $_.Name -like ($Lab.Prefix + '?*') }) }
    Write-Host ('lab files and folders (clat-*) in disks: {0}' -f $labFiles.Count)

    Write-Host '--- acl of the kept files (base-*); vm-entries must be 0 when no lab VM exists'
    $kept = @(Get-LabKeptFiles)
    if ($kept.Count -eq 0) { Write-Host '(no base-* file)' }
    foreach ($f in $kept) {
        $acl = Invoke-LabNative 'icacls.exe' @($f.FullName)
        $entries = @($acl.Lines | Where-Object { $_ -match 'NT VIRTUAL MACHINE\\|S-1-5-83-' })
        Write-Host ('acl {0}: vm-entries={1}' -f $f.FullName, $entries.Count)
        foreach ($l in $acl.Lines) {
            $t = $l.Replace($f.FullName, '').Trim()
            if ($t -and $t -notmatch '^Successfully processed') { Write-Host ('    ' + $t) }
        }
    }
}

function Show-LabState {
    Write-Host '--- lab-state.json (written by create-lab.ps1, deleted by remove-lab.ps1)'
    if (-not (Test-Path -LiteralPath $Lab.StateFile)) {
        Write-Host ('(missing) ' + $Lab.StateFile)
        Write-Host 'no VM ids to look for in the Hyper-V data folder (remove-lab.ps1 prints that check for the VMs it removes)'
        return
    }
    $ids = @()
    try {
        $entries = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Lab.StateFile))
        foreach ($e in $entries) {
            Write-Host ('state {0}: id={1} generation={2} nics={3}' -f $e.Name, $e.Id, $e.Generation, (@($e.Nics) -join ' '))
            $ids += [string]$e.Id
        }
    } catch {
        Write-Host ('lab-state.json is not readable: ' + $_.Exception.Message)
    }
    if ($ids.Count -gt 0) { Show-LabLeftovers $ids }
}

function Show-LabAddresses {
    Write-Host '--- addresses the host has seen for the lab MACs (neighbour table, no Hyper-V call)'
    $seen = 0
    foreach ($v in $Lab.VMs) {
        foreach ($n in $v.Nics) {
            $ip = Get-LabAddressByMac $n.Mac
            if ($ip) { Write-Host ('{0}/{1} {2} -> {3}' -f $v.Name, $n.Name, $n.Mac, $ip); $seen++ }
        }
    }
    if ($seen -eq 0) { Write-Host '(none)' }
    $named = @(Get-LabHostAdapters | Where-Object { $_ -like '*clat*' })
    if ($named.Count -eq 0) { Write-Host 'host network adapters with "clat" in the name: none' }
    else { Write-Host ('host network adapters with "clat" in the name: ' + ($named -join ', ')) }
}

function Show-LabHyperV {
    Import-Module Hyper-V

    $defName = ''
    $def = @(Get-VMSwitch | Where-Object { $_.Id -eq $Lab.DefaultSwitchId })
    if ($def.Count -eq 1) {
        $defName = [string]$def[0].Name
        Write-Host ('--- default switch: "{0}" type={1} (only read, never changed)' -f $defName, $def[0].SwitchType)
    } else {
        Write-Host ('--- default switch: NOT FOUND (id {0})' -f $Lab.DefaultSwitchId)
    }

    Write-Host '--- switches with the lab prefix'
    $sws = @(Get-VMSwitch | Where-Object { $_.Name -like ($Lab.Prefix + '*') } | Sort-Object Name)
    if ($sws.Count -eq 0) { Write-Host '(none)' }
    foreach ($sw in $sws) {
        Write-Host ('switch {0}: type={1} note="{2}" SoftwareRscEnabled={3} id={4}' -f $sw.Name, $sw.SwitchType, (Get-LabNote $sw), (Get-LabProp $sw 'SoftwareRscEnabled'), $sw.Id)
    }

    Write-Host '--- virtual machines with the lab prefix'
    $vms = @(Get-VM | Where-Object { $_.Name -like ($Lab.Prefix + '*') } | Sort-Object Name)
    if ($vms.Count -eq 0) { Write-Host '(none)' }
    foreach ($m in $vms) {
        Write-Host ('vm {0}: state={1} generation={2} cpu={3} memoryMB={4} dynamic-memory={5} uptime={6} heartbeat={7}' -f $m.Name, $m.State, $m.Generation,
            (Get-LabProp $m 'ProcessorCount'), (Format-LabUnit (Get-LabProp $m 'MemoryStartup') 1MB '0'), (Get-LabProp $m 'DynamicMemoryEnabled'),
            (Get-LabProp $m 'Uptime'), (Get-LabProp $m 'Heartbeat'))
        Write-Host ('  note="{0}" id={1} auto-start={2} auto-stop={3} auto-checkpoints={4} checkpoint-type={5}' -f (Get-LabNote $m), $m.Id,
            (Get-LabProp $m 'AutomaticStartAction'), (Get-LabProp $m 'AutomaticStopAction'), (Get-LabProp $m 'AutomaticCheckpointsEnabled'), (Get-LabProp $m 'CheckpointType'))

        $have = @()
        foreach ($n in @(Get-VMNetworkAdapter -VM $m)) {
            Write-Host ('  nic {0}: switch={1} mac={2} MacAddressSpoofing={3} DhcpGuard={4} RouterGuard={5} ip={6}' -f $n.Name, $n.SwitchName, (Get-LabProp $n 'MacAddress'),
                (Get-LabProp $n 'MacAddressSpoofing'), (Get-LabProp $n 'DhcpGuard'), (Get-LabProp $n 'RouterGuard'), (@(Get-LabProp $n 'IPAddresses') -join ' '))
            $have += ('{0}={1}@{2}' -f $n.Name, ([string](Get-LabProp $n 'MacAddress')).ToUpper(), $n.SwitchName)
        }
        # the same adapters (name, MAC, switch) as the settings block? The order is not compared.
        $spec = $Lab.VMs | Where-Object { $_.Name -eq $m.Name } | Select-Object -First 1
        if ($spec) {
            $want = @()
            foreach ($n in $spec.Nics) {
                $swName = $n.Switch
                if ($swName -eq '@default') { $swName = $defName }
                $want += ('{0}={1}@{2}' -f $n.Name, $n.Mac.ToUpper(), $swName)
            }
            $same = ((($want | Sort-Object) -join ' ') -eq (($have | Sort-Object) -join ' '))
            Write-Host ('  adapters as in lab-common.ps1: {0}' -f $same)
            if (-not $same) { Write-Host ('    expected: ' + ($want -join ' ')) }
        }
        foreach ($d in @(Get-VMHardDiskDrive -VM $m)) {
            $size = 'n/a'; $file = 'n/a'; $type = 'n/a'
            try {
                $h = Get-VHD -Path $d.Path
                $size = Format-LabUnit $h.Size 1GB '0.#'; $file = Format-LabUnit $h.FileSize 1MB '0'; $type = $h.VhdType
            } catch { }
            Write-Host ('  disk {0} {1} {2}: {3} sizeGB={4} fileMB={5} type={6}' -f $d.ControllerType, $d.ControllerNumber, $d.ControllerLocation, $d.Path, $size, $file, $type)
        }
        foreach ($d in @(Get-VMDvdDrive -VM $m)) {
            $p = [string]$d.Path
            if (-not $p) { $p = '(empty)' }
            Write-Host ('  dvd {0} {1} {2}: {3}' -f (Get-LabProp $d 'ControllerType'), $d.ControllerNumber, $d.ControllerLocation, $p)
        }
        foreach ($c in @(Get-VMComPort -VM $m)) {
            $p = [string]$c.Path
            if (-not $p) { $p = '(not set)' }
            Write-Host ('  {0}: {1}' -f $c.Name, $p)
        }
        $snaps = @(Get-VMSnapshot -VM $m)
        if ($snaps.Count -eq 0) { Write-Host '  checkpoints: none' }
        foreach ($s in $snaps) {
            Write-Host ('  checkpoint {0}: type={1} created={2}' -f $s.Name, (Get-LabProp $s 'SnapshotType'), (Get-LabProp $s 'CreationTime'))
        }
        foreach ($i in @(Get-VMIntegrationService -VM $m)) {
            Write-Host ('  integration {0}: enabled={1} status={2}' -f $i.Name, (Get-LabProp $i 'Enabled'), (Get-LabProp $i 'PrimaryStatusDescription'))
        }
    }
}

function Invoke-StatusLab {
    $r = Get-LabRights
    Write-Host ('rights: user={0} elevated={1} hyper-v-administrators={2}' -f $r.User, $r.Elevated, $r.HvAdmin)
    Show-LabFiles
    Show-LabState
    Show-LabAddresses
    if ($r.Elevated -or $r.HvAdmin) {
        Show-LabHyperV
    } else {
        Write-Host '--- switches and virtual machines'
        Write-Host 'No Hyper-V rights in this session: switches and VMs are not shown.'
        Write-Host 'Run this script elevated, or as a member of "Hyper-V Administrators", to see them.'
    }
    Write-Host '--- end of status'
}

$rc = [int](@(Invoke-LabScript -ScriptName 'status-lab' -CommandLine (Get-LabCommandLine $PSCommandPath $PSBoundParameters) -NoRightsNeeded -Body { Invoke-StatusLab })[-1])
if ($rc -ne 0) { exit $rc }
