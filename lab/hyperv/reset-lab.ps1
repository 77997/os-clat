# reset-lab.ps1 - start, stop, checkpoint and restore the two lab VMs.
#
#   reset-lab.ps1 -Action Start   [-VM clat-world|clat-opn]             start both (clat-world first) or one
#   reset-lab.ps1 -Action Stop    [-VM clat-world|clat-opn] [-TurnOff]  guest shutdown of both (clat-opn first)
#                                                                       or one; -TurnOff powers off instead
#   reset-lab.ps1 -Action Save    [-Name clat-base]   shut both guests down, take the checkpoint on both
#                                                     (an older one of that name is replaced), start both
#   reset-lab.ps1 -Action Restore [-Name clat-base]   turn both off, apply the checkpoint on both, start both
#
# Run as:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file> -Action <...>
# from an elevated PowerShell, or from any PowerShell of a "Hyper-V Administrators" member.
#
# The checkpoint is taken with both VMs off, so that no PPPoE session, lease or clock state is
# frozen into it; a restore therefore costs one boot of each VM.
# It touches only the VMs of the settings block of lab-common.ps1, and only when they carry the
# note 'os-clat lab'. Checkpoint names must start with 'clat-'.
# Ends with the listing of status-lab.ps1. Output also goes to .work\results\hyperv-<UTC>-reset-lab.log.
#
# NOT TESTED ON HYPER-V: no Hyper-V cmdlet of this file has run yet.

[CmdletBinding()]
param(
    [ValidateSet('Save', 'Restore', 'Start', 'Stop')]
    [string]$Action,
    [string]$Name,              # checkpoint name; default: Checkpoint in lab-common.ps1 (clat-base)
    [string]$VM,                # Start and Stop only: limit the action to this VM
    [switch]$TurnOff            # Stop only: power off instead of a guest shutdown
)

. (Join-Path $PSScriptRoot 'lab-common.ps1')

if (-not $Action) {
    Write-Host 'usage: reset-lab.ps1 -Action Save|Restore|Start|Stop [-Name clat-base] [-VM clat-world|clat-opn] [-TurnOff]'
    Write-Host '  Start    start both VMs (clat-world first), or only -VM'
    Write-Host '  Stop     guest shutdown of both VMs (clat-opn first), or only -VM; -TurnOff powers off instead'
    Write-Host '  Save     shut both guests down, take the checkpoint -Name on both (replacing an older one), start both'
    Write-Host '  Restore  turn both VMs off, apply the checkpoint -Name on both, start both'
    exit 1
}
if (-not $Name) { $Name = $Lab.Checkpoint }

# NOTE: the parameter is called -VM, so no other variable in this file may be called $vm
# (PowerShell variable names are not case sensitive). Machines are $m here.

# The VM names an action applies to, in start order.
function Get-ResetTargets {
    $all = @($Lab.VMs | ForEach-Object { $_.Name })
    if (-not $VM) { return $all }
    if ($Action -eq 'Save' -or $Action -eq 'Restore') {
        throw ("-VM is for Start and Stop only. {0} always works on both VMs, so that their checkpoints belong together." -f $Action)
    }
    if ($all -notcontains $VM) { throw ("'{0}' is not a lab VM. Lab VMs: {1}." -f $VM, ($all -join ', ')) }
    return @($VM)
}

function Get-LabCheckpoints([string]$VmName, [string]$Checkpoint) {
    @(Get-VMSnapshot -VMName $VmName | Where-Object { $_.Name -eq $Checkpoint })
}

function Save-LabCheckpoint([string]$VmName, [string]$Checkpoint) {
    $old = @(Get-LabCheckpoints $VmName $Checkpoint)
    if ($old.Count -gt 0) {
        Remove-VMSnapshot -VMName $VmName -Name $Checkpoint -Confirm:$false
        Write-LabStep 'removed' ("checkpoint {0} on {1} (replaced by the new one)" -f $Checkpoint, $VmName)
    }
    # After a checkpoint was removed, Hyper-V merges its disk in the background; a new
    # checkpoint may be refused until that is done. Only in that case: retry for 10 minutes.
    $tries = 0
    while ($true) {
        try {
            Checkpoint-VM -Name $VmName -SnapshotName $Checkpoint
            break
        } catch {
            $tries++
            if ($old.Count -eq 0 -or $tries -ge 40) { throw }
            if ($tries -eq 1) { Write-Host ('checkpoint on {0} not possible yet ({1}); retrying every 15 s for up to 10 minutes while the old one is merged' -f $VmName, $_.Exception.Message) }
            Start-Sleep -Seconds 15
        }
    }
    $now = @(Get-LabCheckpoints $VmName $Checkpoint)
    if ($now.Count -ne 1) { throw ("After Checkpoint-VM, {0} has {1} checkpoints named '{2}'; expected 1." -f $VmName, $now.Count, $Checkpoint) }
    Write-LabStep 'saved' ("checkpoint {0} on {1}" -f $Checkpoint, $VmName)
}

function Invoke-ResetLab {
    Assert-LabName $Name
    $names = @(Get-ResetTargets)
    $machines = @()
    foreach ($n in $names) { $machines += Get-LabReadyVM $n }       # stops here, before any change, if a VM is missing
    $reverse = @()
    for ($i = $machines.Count - 1; $i -ge 0; $i--) { $reverse += $machines[$i] }

    if ($Action -eq 'Start') {
        foreach ($m in $machines) { Start-LabGuest $m }
    }
    elseif ($Action -eq 'Stop') {
        foreach ($m in $reverse) { Stop-LabGuest $m -TurnOff:$TurnOff }
    }
    elseif ($Action -eq 'Save') {
        foreach ($m in $reverse) { Stop-LabGuest $m }               # clean guest shutdown: no memory state in the checkpoint
        foreach ($m in $machines) { Save-LabCheckpoint $m.Name $Name }
        foreach ($m in $machines) { Start-LabGuest (Get-LabReadyVM $m.Name) }
    }
    elseif ($Action -eq 'Restore') {
        foreach ($m in $machines) {
            $have = @(Get-LabCheckpoints $m.Name $Name)
            if ($have.Count -ne 1) { throw ("{0} has {1} checkpoints named '{2}'; exactly 1 is needed. Nothing was changed. ('reset-lab.ps1 -Action Save -Name {2}' takes it.)" -f $m.Name, $have.Count, $Name) }
        }
        foreach ($m in $reverse) { Stop-LabGuest $m -TurnOff }
        foreach ($m in $machines) {
            Restore-VMSnapshot -VMName $m.Name -Name $Name -Confirm:$false
            Write-LabStep 'restored' ("checkpoint {0} on {1}" -f $Name, $m.Name)
        }
        foreach ($m in $machines) { Start-LabGuest (Get-LabReadyVM $m.Name) }
    }

    & (Join-Path $PSScriptRoot 'status-lab.ps1')
}

$rc = [int](@(Invoke-LabScript -ScriptName 'reset-lab' -CommandLine (Get-LabCommandLine $PSCommandPath $PSBoundParameters) -Body { Invoke-ResetLab })[-1])
if ($rc -ne 0) { exit $rc }
