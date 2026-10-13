# remove-lab.ps1 - removes what create-lab.ps1 made, and prints every object it removes.
#
#   remove-lab.ps1               VMs (with their checkpoints), switches, clat-* files and folders
#   remove-lab.ps1 -KeepDisks    VMs and switches only
#
# Run as:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file> [-KeepDisks]
# in the same way (elevated or not) the lab was created.
#
# It removes only:
#   - VMs whose name starts with 'clat-' AND whose note is 'os-clat lab' (or the "incomplete" form of it);
#   - switches whose name starts with 'clat-' AND that are Private AND carry the note 'os-clat lab'
#     AND that no adapter is connected to any more;
#   - files and folders named clat-* directly in .work\disks, and .work\results\lab-state.json.
# It keeps: the Default Switch and every other switch and VM, .work\cache, the base-* files,
# .work\disks\build, the logs. An object that has the prefix but not the note is reported and skipped.
# Safe to run again: what is gone is not mentioned again.
# Output also goes to .work\results\hyperv-<UTC>-remove-lab.log.
#
# NOT TESTED ON HYPER-V: no Hyper-V cmdlet of this file has run yet.

[CmdletBinding()]
param([switch]$KeepDisks)

. (Join-Path $PSScriptRoot 'lab-common.ps1')

function Invoke-RemoveLab {
    $before     = @(Get-LabHostAdapters)
    $kept       = @(Get-LabKeptFiles)
    $removedIds = @()

    # 1. virtual machines
    foreach ($m in @(Get-VM | Where-Object { $_.Name -like ($Lab.Prefix + '?*') } | Sort-Object Name)) {
        $note = Get-LabNote $m
        if ($note -ne $Lab.Tag -and $note -ne $Lab.TagIncomplete) {
            Write-LabWarning ("VM '{0}' has the prefix but not the note '{1}' (it has '{2}'): not made by create-lab.ps1, skipped." -f $m.Name, $Lab.Tag, $note)
            continue
        }
        $id = $m.Id.ToString()
        if ($m.State -ne 'Off') {
            Stop-VM -VM $m -TurnOff -Force -Confirm:$false
            Write-LabStep 'turned off' "vm $($m.Name)"
        }
        # while the VM still exists: take its ACL entry off the files that stay
        foreach ($f in $kept) { Remove-LabVmFileAccess $m $f.FullName }
        Remove-VM -VM $m -Force
        Write-LabStep 'removed' ("vm {0} (id {1}, with its checkpoints)" -f $m.Name, $id)
        $removedIds += $id
    }
    $left = @(Get-VM | Where-Object { $_.Name -like ($Lab.Prefix + '?*') })

    # 2. switches
    foreach ($sw in @(Get-VMSwitch | Where-Object { $_.Name -like ($Lab.Prefix + '?*') } | Sort-Object Name)) {
        if ($sw.SwitchType -ne 'Private' -or (Get-LabNote $sw) -ne $Lab.Tag) {
            Write-LabWarning ("Switch '{0}' (type {1}, note '{2}') is not a private switch with the note '{3}': not made by create-lab.ps1, skipped." -f $sw.Name, $sw.SwitchType, (Get-LabNote $sw), $Lab.Tag)
            continue
        }
        $same = @(Get-VMSwitch | Where-Object { $_.Name -eq $sw.Name })
        if ($same.Count -ne 1) {
            Write-LabWarning ("There are {0} switches named '{1}': skipped, remove them by hand." -f $same.Count, $sw.Name)
            continue
        }
        $users = @(Get-VMNetworkAdapter -All | Where-Object { $_.SwitchName -eq $sw.Name })
        if ($users.Count -gt 0) {
            Write-LabWarning ("Switch '{0}' is still used by {1} adapter(s): skipped." -f $sw.Name, $users.Count)
            continue
        }
        Remove-VMSwitch -Name $sw.Name -Force
        Write-LabStep 'removed' "switch $($sw.Name) (Private)"
    }

    # 3. files. Not while a VM with the prefix is left: its disk would be among them.
    if ($left.Count -gt 0) {
        Write-LabWarning ("{0} VM(s) with the prefix are left ({1}): no file deleted, lab-state.json kept." -f $left.Count, (($left | ForEach-Object { $_.Name }) -join ', '))
    } else {
        if ($KeepDisks) {
            Write-LabStep 'kept' ("clat-* files and folders in {0} (-KeepDisks)" -f $Lab.Disks)
        } else {
            Remove-LabFiles
        }
        $state = Assert-LabPath $Lab.StateFile
        if (Test-Path -LiteralPath $state) {
            Remove-Item -LiteralPath $state -Force
            Write-LabStep 'deleted' $state
        }
    }

    # 4. what is left behind
    if ($removedIds.Count -gt 0) { Show-LabLeftovers $removedIds }
    Show-LabHostAdapterDiff $before
    $kept = @(Get-LabKeptFiles)
    if ($kept.Count -gt 0) { Write-LabStep 'kept' ("{0} base file(s) in {1}; downloads in {2}" -f $kept.Count, $Lab.Disks, $Lab.Cache) }
    Write-Host 'remove-lab finished. Run status-lab.ps1 to see what is left.'
}

$rc = [int](@(Invoke-LabScript -ScriptName 'remove-lab' -CommandLine (Get-LabCommandLine $PSCommandPath $PSBoundParameters) -Body { Invoke-RemoveLab })[-1])
if ($rc -ne 0) { exit $rc }
