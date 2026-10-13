# lab-common.ps1 - settings and helper functions of the os-clat Hyper-V lab.
#
# Dot-sourced by create-lab.ps1, remove-lab.ps1, status-lab.ps1 and reset-lab.ps1.
# Loading this file calls no Hyper-V cmdlet and changes nothing.
#
# Windows PowerShell 5.1 (no ternary, no &&, no ??). ASCII only: 5.1 reads a
# file without a byte order mark as ANSI.
#
# STATUS: NOT TESTED ON HYPER-V. No line that calls a Hyper-V cmdlet has run.
# The scripts were parsed, their cmdlet parameter names were compared with the
# installed Hyper-V module, and the parts that need no Hyper-V were executed.
#
# Rules the four scripts keep:
#   - every object they create has a name that starts with 'clat-' and, where
#     Hyper-V has a note field, the note 'os-clat lab';
#   - they change only objects that have both; the Default Switch is only read;
#   - every file they write or delete lies under <lab>\.work;
#   - host networking is not changed, apart from three private switches.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'              # no progress bars (Convert-VHD) in logs and captured output

# ============================================================================
# SETTINGS - the one block every name, path, size and address comes from
# ============================================================================

$LabRoot = Split-Path -Parent $PSScriptRoot           # ...\lab (this file is in ...\lab\hyperv)

$Lab = @{
    Prefix          = 'clat-'                         # every lab object name starts with this
    Tag             = 'os-clat lab'                   # note on every lab switch and finished VM
    TagIncomplete   = 'os-clat lab (incomplete)'      # note on a VM while create-lab.ps1 is still building it
    KeepPrefix      = 'base-'                         # files in disks\ that remove-lab.ps1 keeps
    Checkpoint      = 'clat-base'                     # default checkpoint name of reset-lab.ps1
    Work            = Join-Path $LabRoot '.work'
    HvDataDir       = Join-Path $env:ProgramData 'Microsoft\Windows\Hyper-V'   # only listed, never written
    DefaultSwitchId = [guid]'c08cb7b8-9b3c-408e-8e30-5e16a3aeb444'             # Hyper-V "Default Switch", only read
    HvAdminsSid     = 'S-1-5-32-578'                  # BUILTIN\Hyper-V Administrators
    Switches        = @('clat-wan', 'clat-lan', 'clat-mgmt')                   # all of type Private

    # Start order = order in this list (the ISP side first); stop order is the reverse.
    # Adapter order = order of Nics. Every entry needs every key (strict mode).
    VMs             = @(
        @{ Name = 'clat-world'; Generation = 2; MemoryMB = 2048; Cpu = 2; SizeGB = 8
           Base = 'base-debian-13.vhdx'; Dvd = 'base-world-seed.iso'
           Nics = @(
               @{ Name = 'nat';  Switch = '@default';  Mac = '02C1A7000101' },
               @{ Name = 'mgmt'; Switch = 'clat-mgmt'; Mac = '02C1A7000102' },
               @{ Name = 'wan';  Switch = 'clat-wan';  Mac = '02C1A7000103' },
               @{ Name = 'lan';  Switch = 'clat-lan';  Mac = '02C1A7000104' }) },
        @{ Name = 'clat-opn'; Generation = 1; MemoryMB = 4096; Cpu = 2; SizeGB = 16
           Base = 'base-opnsense-26.7.vhdx'; Dvd = $null
           Nics = @(
               @{ Name = 'lan';  Switch = 'clat-lan';  Mac = '02C1A7000201' },      # expected hn0
               @{ Name = 'wan';  Switch = 'clat-wan';  Mac = '02C1A7000202' },      # expected hn1
               @{ Name = 'mgmt'; Switch = 'clat-mgmt'; Mac = '02C1A7000203' }) }    # expected hn2
    )
}
$Lab.Cache     = Join-Path $Lab.Work 'cache'          # downloads; never touched here, only listed
$Lab.Disks     = Join-Path $Lab.Work 'disks'          # base-* (kept), clat-*.vhdx, clat-*.avhdx, clat-*.vm\
$Lab.VmDir     = $Lab.Disks                           # VM configuration folders: disks\<vm>.vm
$Lab.Results   = Join-Path $Lab.Work 'results'        # lab-state.json, hyperv-<UTC>-<script>.log
$Lab.StateFile = Join-Path $Lab.Results 'lab-state.json'

# ============================================================================
# output, guards
# ============================================================================

function Write-LabStep([string]$State, [string]$What) { Write-Host ('{0} {1}' -f $State, $What) }

# One line, never wrapped (Write-Warning wraps at the console width, which breaks the log for grep).
function Write-LabWarning([string]$Text) { Write-Host ('WARNING: ' + $Text) }

function Assert-LabName([string]$Name) {
    if ($Name -notlike ($Lab.Prefix + '?*')) {
        throw ("Refusing to touch '{0}': the name does not start with '{1}'." -f $Name, $Lab.Prefix)
    }
}

function Assert-LabPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($Lab.Work).TrimEnd('\') + '\'
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("Refusing to touch '{0}': it is outside {1}" -f $full, $root)
    }
    return $full
}

# Catches a typing error in the settings block before anything is created.
function Assert-LabSettings {
    $macs = @()
    foreach ($s in $Lab.Switches) { Assert-LabName $s }
    Assert-LabName $Lab.Checkpoint
    foreach ($v in $Lab.VMs) {
        Assert-LabName $v.Name
        if (@(1, 2) -notcontains $v.Generation) { throw ("Settings: {0} has generation '{1}'." -f $v.Name, $v.Generation) }
        foreach ($n in $v.Nics) {
            if ($n.Mac -notmatch '^[0-9A-Fa-f]{12}$') { throw ("Settings: MAC '{0}' of {1}/{2} is not 12 hex digits." -f $n.Mac, $v.Name, $n.Name) }
            if ($macs -contains $n.Mac) { throw ("Settings: MAC {0} is used twice." -f $n.Mac) }
            $macs += $n.Mac
            if ($n.Switch -ne '@default' -and ($Lab.Switches -notcontains $n.Switch)) {
                throw ("Settings: {0}/{1} names the switch '{2}', which is not a lab switch." -f $v.Name, $n.Name, $n.Switch)
            }
        }
    }
}

# Returns the value of a property, or 'n/a' when the object does not have it.
# Used where a script only prints: a wrong property name must not stop a listing.
function Get-LabProp($Object, [string]$Name) {
    if ($null -eq $Object) { return 'n/a' }
    try {
        $p = $Object.PSObject.Properties[$Name]
        if ($null -eq $p) { return 'n/a' }
        if ($null -eq $p.Value) { return '' }
        return $p.Value
    } catch { return 'n/a' }
}

function Format-LabUnit($Bytes, [double]$Unit, [string]$Format) {
    if ($null -eq $Bytes -or $Bytes -is [string]) { return 'n/a' }
    return ([double]$Bytes / $Unit).ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-LabNote($Object) { return ([string](Get-LabProp $Object 'Notes')).Trim() }

# ============================================================================
# rights
# ============================================================================

function Get-LabRights {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    New-Object psobject -Property @{
        User     = $id.Name
        Elevated = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        HvAdmin  = $p.IsInRole([Security.Principal.SecurityIdentifier]$Lab.HvAdminsSid)
    }
}

# The exact command line of the running script, to paste into an elevated console.
function Get-LabCommandLine([string]$ScriptPath, $Bound) {
    $line = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
    if ($null -ne $Bound) {
        foreach ($k in @($Bound.Keys)) {
            $val = $Bound[$k]
            if ($val -is [System.Management.Automation.SwitchParameter]) {
                if ($val.IsPresent) { $line += ' -' + $k }
            } else {
                $line += ' -{0} {1}' -f $k, $val
            }
        }
    }
    return $line
}

# Prints the rights of this session. Returns $false, after saying what to do, when it has none.
function Test-LabRights([string]$CommandLine) {
    $r = Get-LabRights
    Write-Host ('rights: user={0} elevated={1} hyper-v-administrators={2}' -f $r.User, $r.Elevated, $r.HvAdmin)
    if ($r.Elevated -or $r.HvAdmin) { return $true }
    Write-Host ''
    Write-Host 'ERROR: this PowerShell session has no Hyper-V rights. Nothing was done.'
    Write-Host ('The session of {0} is not elevated, and its logon token does not contain the group' -f $r.User)
    Write-Host ('"Hyper-V Administrators" ({0}).' -f $Lab.HvAdminsSid)
    Write-Host 'There are two ways to get the rights:'
    Write-Host ''
    Write-Host '  a) Join the group, once. In an elevated PowerShell (Win+X, "Terminal (Admin)"):'
    Write-Host ("       Add-LocalGroupMember -SID '{0}' -Member '{1}'" -f $Lab.HvAdminsSid, $r.User)
    Write-Host '     Then sign out of Windows and sign in again (locking the screen is not enough)'
    Write-Host '     and start this script again. Check without elevation:'
    Write-Host ('       whoami /groups | findstr /i "{0}"      (must show "Enabled group")' -f $Lab.HvAdminsSid)
    Write-Host '     After that every program running as this user can control Hyper-V without a UAC prompt.'
    Write-Host ''
    Write-Host '  b) Or run this script from an elevated PowerShell, every time:'
    Write-Host ('       ' + $CommandLine)
    Write-Host ''
    Write-Host 'Create and remove the lab in the same way (a or b).'
    return $false
}

# ============================================================================
# log: everything a script prints also goes to .work\results\hyperv-<UTC>-<script>.log
# ============================================================================

function Start-LabLog([string]$ScriptName) {
    $depth = 0
    $var = Get-Variable -Name ClatLabLogDepth -Scope Global -ErrorAction SilentlyContinue
    if ($var) { $depth = [int]$var.Value }
    $global:ClatLabLogDepth = $depth + 1
    if ($depth -gt 0) { return }                      # nested call (status from inside create): the outer log is running
    $global:ClatLabLogPath = $null
    try {
        New-Item -ItemType Directory -Force -Path $Lab.Results | Out-Null
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd\THHmmss\Z')
        $path  = Assert-LabPath (Join-Path $Lab.Results ('hyperv-{0}-{1}.log' -f $stamp, $ScriptName))
        Start-Transcript -Path $path -Append | Out-Null
        $global:ClatLabLogPath = $path
        Write-Host ('log: ' + $path)
    } catch {
        Write-Host ('log: NOT WRITTEN (' + $_.Exception.Message + ')')
    }
}

function Stop-LabLog {
    $var = Get-Variable -Name ClatLabLogDepth -Scope Global -ErrorAction SilentlyContinue
    if (-not $var) { return }
    $depth = [int]$var.Value - 1
    if ($depth -lt 0) { $depth = 0 }
    $global:ClatLabLogDepth = $depth
    if ($depth -gt 0) { return }
    if ($global:ClatLabLogPath) {
        try { Stop-Transcript | Out-Null } catch { }
        $global:ClatLabLogPath = $null
    }
}

function Write-LabFailure($ErrorRecord, [string]$CommandLine) {
    Write-Host ''
    Write-Host ('ERROR: ' + $ErrorRecord.Exception.Message)
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        Write-Host $ErrorRecord.InvocationInfo.PositionMessage
    }
    Write-Host 'The script stopped at this point. After the cause is fixed it can be run again:'
    Write-Host 'every step first looks at what exists.'
    $r = Get-LabRights
    if (-not $r.Elevated) {
        Write-Host 'If this is a permission error although the rights check passed, run the same'
        Write-Host 'command from an elevated PowerShell:'
        Write-Host ('  ' + $CommandLine)
    }
}

# Frame of every script: log, settings check, rights check, body, error report.
# Returns the exit code: 0 done, 1 error, 2 no Hyper-V rights.
function Invoke-LabScript {
    param([string]$ScriptName, [string]$CommandLine, [scriptblock]$Body, [switch]$NoRightsNeeded)
    $code = 1
    Start-LabLog $ScriptName
    try {
        Write-Host ('=== {0} {1} UTC' -f $ScriptName, [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))
        Assert-LabSettings
        $ok = $true
        if (-not $NoRightsNeeded) { $ok = Test-LabRights $CommandLine }
        if ($ok) {
            if (-not $NoRightsNeeded) { Import-Module Hyper-V }
            & $Body | Out-Host
            $code = 0
        } else {
            $code = 2
        }
    } catch {
        Write-LabFailure $_ $CommandLine
        $code = 1
    } finally {
        Stop-LabLog
    }
    return $code
}

# ============================================================================
# native tools (icacls, fsutil): output and exit code, never an exception
# ============================================================================

function Invoke-LabNative([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'               # local to this function; stderr lines must not stop the script
    $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
    $rc = $LASTEXITCODE
    New-Object psobject -Property @{ ExitCode = $rc; Lines = $lines; Text = ($lines -join "`n") }
}

# Hyper-V refuses disk files that are sparse, compressed or encrypted.
function Assert-LabPlainFile([string]$Path) {
    $Path   = Assert-LabPath $Path
    $sparse = [IO.FileAttributes]::SparseFile
    $bad    = $sparse -bor [IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::Encrypted
    $a = (Get-Item -LiteralPath $Path).Attributes
    if ($a -band $sparse) {
        Invoke-LabNative 'fsutil.exe' @('sparse', 'setflag', $Path, '0') | Out-Null
        $a = (Get-Item -LiteralPath $Path).Attributes
        if (-not ($a -band $sparse)) { Write-LabStep 'fixed' "sparse flag cleared on $Path" }
    }
    if ($a -band $bad) { throw ("{0} is sparse, compressed or encrypted ({1}). Hyper-V will not attach it." -f $Path, $a) }
}

# ============================================================================
# the ACL entry "NT VIRTUAL MACHINE\<VM id>" on files attached to a VM
# ============================================================================

function Get-LabVmSid([string]$VmId) {
    try {
        $acct = New-Object Security.Principal.NTAccount('NT VIRTUAL MACHINE', $VmId)
        return $acct.Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { return $null }
}

function Test-LabVmAclEntry([string]$Path, [string]$VmId, [string]$VmSid) {
    $pattern = [regex]::Escape($VmId)
    if ($VmSid) { $pattern = $pattern + '|' + [regex]::Escape($VmSid) }
    return ((Invoke-LabNative 'icacls.exe' @($Path)).Text -match $pattern)
}

# The VM's own SID must be able to open every file attached to it.
function Confirm-LabVmFileAccess($Vm, [string]$Path) {
    $Path = Assert-LabPath $Path
    $id  = $Vm.Id.ToString()
    $sid = Get-LabVmSid $id
    if (Test-LabVmAclEntry $Path $id $sid) { Write-LabStep 'ok' "acl $Path"; return }
    $g = Invoke-LabNative 'icacls.exe' @($Path, '/grant', ('NT VIRTUAL MACHINE\{0}:(F)' -f $id))
    if ($g.ExitCode -eq 0 -and (Test-LabVmAclEntry $Path $id $sid)) {
        Write-LabStep 'fixed' "acl $Path (VM SID added)"
    } else {
        Write-LabWarning ("acl {0}: the VM SID is missing and could not be added (icacls exit {1}: {2}). The VM may fail to start with 0x80070005." -f $Path, $g.ExitCode, (@($g.Lines) -join ' / '))
    }
}

# Takes a VM's entry off a file that stays when the VM goes (base-* files).
# Must run while the VM still exists: afterwards the name no longer resolves.
function Remove-LabVmFileAccess($Vm, [string]$Path) {
    $Path = Assert-LabPath $Path
    $id  = $Vm.Id.ToString()
    $sid = Get-LabVmSid $id
    if (-not (Test-LabVmAclEntry $Path $id $sid)) { return }
    Invoke-LabNative 'icacls.exe' @($Path, '/remove', ('NT VIRTUAL MACHINE\' + $id)) | Out-Null
    if ($sid -and (Test-LabVmAclEntry $Path $id $sid)) {
        Invoke-LabNative 'icacls.exe' @($Path, '/remove', ('*' + $sid)) | Out-Null
    }
    if (Test-LabVmAclEntry $Path $id $sid) {
        Write-LabWarning ("acl {0}: the entry of {1} ({2}) could not be removed." -f $Path, $Vm.Name, $id)
    } else {
        Write-LabStep 'removed' ("acl entry of {0} on {1}" -f $Vm.Name, $Path)
    }
}

# The files remove-lab.ps1 keeps: base-* directly in disks\.
function Get-LabKeptFiles {
    if (-not (Test-Path -LiteralPath $Lab.Disks)) { return }
    Get-ChildItem -LiteralPath $Lab.Disks -File -Force | Where-Object { $_.Name -like ($Lab.KeepPrefix + '*') } | Sort-Object Name
}

# ============================================================================
# files (no Hyper-V call in this section)
# ============================================================================

# Deletes clat-* files and folders directly in disks\. Nothing else, nowhere else.
function Remove-LabFiles {
    if (-not (Test-Path -LiteralPath $Lab.Disks)) { return }
    $targets = @(Get-ChildItem -LiteralPath $Lab.Disks -Force | Where-Object { $_.Name -like ($Lab.Prefix + '?*') } | Sort-Object Name)
    foreach ($t in $targets) {
        $p = Assert-LabPath $t.FullName
        if ($t.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-LabWarning ("{0} is a link or junction: not followed, not deleted." -f $p)
            continue
        }
        # after Remove-VM, checkpoint files are merged in the background and stay locked for a while
        for ($i = 0; $i -lt 30 -and (Test-Path -LiteralPath $p); $i++) {
            try { Remove-Item -LiteralPath $p -Recurse -Force } catch { Start-Sleep -Seconds 2 }
        }
        if (Test-Path -LiteralPath $p) {
            Write-LabWarning ("could not delete {0} (locked or not permitted). A checkpoint merge may still be running: run remove-lab.ps1 again in a minute, in the same way (elevated or not) the lab was created." -f $p)
        } else {
            Write-LabStep 'deleted' $p
        }
    }
}

# Looks for files named after a VM id in Hyper-V's own data folder. Lists only.
function Show-LabLeftovers([string[]]$Ids) {
    $root = $Lab.HvDataDir
    if (-not (Test-Path -LiteralPath $root)) { Write-Host ('leftovers: {0} does not exist' -f $root); return }
    $errs = @()
    $all = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable errs)
    $refused = @($errs).Count
    if ($all.Count -eq 0 -and $refused -gt 0) {
        Write-Host ('leftovers: {0} is not readable from this session; look from an elevated console' -f $root)
        return
    }
    foreach ($id in $Ids) {
        $hits = @($all | Where-Object { $_.Name -like ('*' + $id + '*') })
        if ($hits.Count -eq 0) { Write-Host ('leftovers {0}: none under {1}' -f $id, $root) }
        foreach ($h in $hits) { Write-Host ('leftovers {0}: {1}' -f $id, $h.FullName) }
    }
    if ($refused -gt 0) {
        Write-Host ('leftovers: {0} folder(s) under {1} are not readable from this session; the answer above covers only the rest' -f $refused, $root)
    }
}

# ============================================================================
# host side, without Hyper-V rights
# ============================================================================

function Get-LabHostAdapters { Get-NetAdapter -IncludeHidden | ForEach-Object { $_.Name } | Sort-Object }

# Proves that a step added no adapter to the host (an Internal switch would add "vEthernet (<name>)").
function Show-LabHostAdapterDiff([string[]]$Before) {
    $after = @(Get-LabHostAdapters)
    $added = @($after | Where-Object { $Before -notcontains $_ })
    $gone  = @($Before | Where-Object { $after -notcontains $_ })
    if ($added.Count -eq 0 -and $gone.Count -eq 0) { Write-LabStep 'unchanged' 'host network adapters'; return }
    if ($added.Count -gt 0) { Write-LabWarning ('host network adapters appeared during this run: ' + ($added -join ', ')) }
    if ($gone.Count -gt 0)  { Write-LabWarning ('host network adapters disappeared during this run: ' + ($gone -join ', ')) }
}

# $Mac like 02C1A7000101. Answers only after the host exchanged a packet with the guest.
function Get-LabAddressByMac([string]$Mac) {
    $dashed = ($Mac -replace '(..)(?!$)', '$1-').ToUpper()
    Get-NetNeighbor -AddressFamily IPv4 -LinkLayerAddress $dashed -ErrorAction SilentlyContinue |
        Where-Object { $_.State -notin 'Unreachable', 'Incomplete' } |
        Select-Object -First 1 -ExpandProperty IPAddress
}

# ============================================================================
# Hyper-V objects (everything below needs Hyper-V rights)
# ============================================================================

# Hyper-V allows two objects with the same name. The lab never guesses which one is meant.
function Get-LabVM([string]$Name) {
    Assert-LabName $Name
    $found = @(Get-VM | Where-Object { $_.Name -eq $Name })
    if ($found.Count -gt 1) { throw ("There are {0} virtual machines named '{1}'. Remove the extra ones by hand; this script touches none of them." -f $found.Count, $Name) }
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

function Get-LabSwitch([string]$Name) {
    Assert-LabName $Name
    $found = @(Get-VMSwitch | Where-Object { $_.Name -eq $Name })
    if ($found.Count -gt 1) { throw ("There are {0} virtual switches named '{1}'. Remove the extra ones by hand; this script touches none of them." -f $found.Count, $Name) }
    if ($found.Count -eq 1) { return $found[0] }
    return $null
}

# A VM of the settings block that exists and was finished by create-lab.ps1, or an error.
function Get-LabReadyVM([string]$Name) {
    $m = Get-LabVM $Name
    if (-not $m) { throw ("The VM '{0}' does not exist. Run create-lab.ps1 first." -f $Name) }
    if ((Get-LabNote $m) -ne $Lab.Tag) { throw ("The VM '{0}' does not carry the note '{1}' (it has '{2}'): not made, or not finished, by create-lab.ps1. Not touching it." -f $Name, $Lab.Tag, (Get-LabNote $m)) }
    return $m
}

function Start-LabGuest($Machine) {
    $name = $Machine.Name
    Assert-LabName $name
    if ($Machine.State -eq 'Running') { Write-LabStep 'running' "vm $name"; return }
    Start-VM -VM $Machine
    Write-LabStep 'started' "vm $name"
}

# Guest shutdown through the integration service, or power off with -TurnOff.
function Stop-LabGuest($Machine, [switch]$TurnOff) {
    $name = $Machine.Name
    Assert-LabName $name
    if ($Machine.State -eq 'Off') { Write-LabStep 'off' "vm $name (was off already)"; return }
    $t0 = Get-Date
    if ($TurnOff) {
        Stop-VM -VM $Machine -TurnOff -Force -Confirm:$false
        $how = 'turned off'
    } else {
        Write-Host ('guest {0}: state={1} heartbeat={2}' -f $name, $Machine.State, (Get-LabProp $Machine 'Heartbeat'))
        try { Stop-VM -VM $Machine -Force -Confirm:$false }
        catch {
            throw ("Guest shutdown of {0} failed: {1} Shut the guest down over ssh, or power it off with 'reset-lab.ps1 -Action Stop -VM {0} -TurnOff', then run this again." -f $name, $_.Exception.Message)
        }
        $how = 'shut down'
    }
    $deadline = (Get-Date).AddSeconds(360)
    while ((Get-LabVM $name).State -ne 'Off') {
        if ((Get-Date) -gt $deadline) { throw ("The VM {0} did not reach the state Off within 6 minutes after Stop-VM." -f $name) }
        Start-Sleep -Seconds 2
    }
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    Write-LabStep $how ("vm {0} ({1} s)" -f $name, $secs)
    if (-not $TurnOff -and $secs -ge 290) {
        Write-LabWarning ("{0} needed {1} s to stop: Hyper-V probably forced it after its 5 minute limit, so the guest may not have shut down cleanly." -f $name, $secs)
    }
}

# VM ids and MACs for shells without Hyper-V rights (lab.sh, build.sh read this file).
function Write-LabState {
    try {
        $state = @()
        foreach ($v in $Lab.VMs) {
            $m = Get-LabVM $v.Name
            if ($m) {
                $state += New-Object psobject -Property ([ordered]@{
                    Name       = [string]$m.Name
                    Id         = $m.Id.ToString()
                    Generation = [int]$m.Generation
                    Nics       = @($v.Nics | ForEach-Object { $_.Name + '=' + $_.Mac })
                })
            }
        }
        $file = Assert-LabPath $Lab.StateFile
        if ($state.Count -eq 0) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force; Write-LabStep 'deleted' $file }
            return
        }
        New-Item -ItemType Directory -Force -Path $Lab.Results | Out-Null
        $json = (ConvertTo-Json -InputObject $state -Depth 4) -replace "`r`n", "`n"
        [IO.File]::WriteAllText($file, ($json + "`n"), (New-Object Text.ASCIIEncoding))
        Write-LabStep 'wrote' ("{0} ({1} vm)" -f $file, $state.Count)
    } catch {
        Write-LabWarning ('lab-state.json was not updated: ' + $_.Exception.Message)
    }
}
