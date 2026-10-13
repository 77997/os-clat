# Lets the lab's WAN link carry frames tagged with VLAN 40, as the production line does.
#
#   wan-vlan.ps1 -Action Trunk    both WAN adapters (clat-opn "wan", clat-world "wan") pass VLAN 40; untagged frames still pass
#   wan-vlan.ps1 -Action Untagged back to the default (untagged only)
#   wan-vlan.ps1                  show the current setting
#
# It touches only the two adapters named "wan" of the VMs clat-opn and clat-world, on the private switch clat-wan.
# Needs Hyper-V rights (elevated, or a member of Hyper-V Administrators). Output is also written to
# lab\.work\results\hyperv-<UTC>-wan-vlan.log so that a shell without those rights can read the result.
[CmdletBinding()]
param(
    [ValidateSet('Trunk', 'Untagged', 'Show')]
    [string]$Action = 'Show'
)

$ErrorActionPreference = 'Stop'
$results = Join-Path (Split-Path $PSScriptRoot -Parent) '.work\results'
if (-not (Test-Path $results)) { New-Item -ItemType Directory -Path $results | Out-Null }
$log = Join-Path $results ('hyperv-{0}-wan-vlan.log' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
Start-Transcript -Path $log | Out-Null
$rc = 0
try {
    $vms = @('clat-opn', 'clat-world')
    foreach ($vm in $vms) {
        $nic = Get-VMNetworkAdapter -VMName $vm -Name 'wan'
        if ($nic.SwitchName -ne 'clat-wan') {
            throw ("adapter wan of {0} is on switch '{1}', not clat-wan. Not touching it." -f $vm, $nic.SwitchName)
        }
        if ($Action -eq 'Trunk') {
            Set-VMNetworkAdapterVlan -VMNetworkAdapter $nic -Trunk -AllowedVlanIdList '40' -NativeVlanId 0
            Write-Host ("set {0} wan: trunk, allowed 40, native 0" -f $vm)
        } elseif ($Action -eq 'Untagged') {
            Set-VMNetworkAdapterVlan -VMNetworkAdapter $nic -Untagged
            Write-Host ("set {0} wan: untagged" -f $vm)
        }
    }
    foreach ($vm in $vms) {
        $v = Get-VMNetworkAdapterVlan -VMName $vm -VMNetworkAdapterName 'wan'
        Write-Host ("vlan {0} wan: mode={1} allowed={2} native={3}" -f $vm, $v.OperationMode, (@($v.AllowedVlanIdList) -join ','), $v.NativeVlanId)
    }
} catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message)
    $rc = 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}
exit $rc
