# ZDX Device Self-Heal
# Version 1.0 - REMEDIATION (makes changes) - ASCII
# Created by: Sinan Aldulaimi
# Runs a full device health check, fixes what is safe to fix automatically
# (approved services, WMI, time sync, DNS, stuck print jobs, policy/Intune sync),
# and reports everything else with a health score and prioritized next steps.
# Never restarts the device, never touches user files, never changes security settings.
# Run with Elevated Permissions (System Account).

$ErrorActionPreference = "SilentlyContinue"
$Version = "1.0"

# ---------------- Settings ----------------
$DryRun                = $false  # $true = check and report only, change nothing
$MaxRuntimeMinutes     = 15      # optional slow steps are skipped to stay under this
$RepairServices        = $true   # start/enable services on the approved list below
$RepairWmi             = $true   # verify WMI and run the safe "salvage" repair if inconsistent
$RepairTime            = $true   # resync the clock if it is off
$MaxClockOffsetSeconds = 60      # clock offset that counts as a problem
$RepairDns             = $true   # flush DNS cache if name resolution fails
$DnsTestName           = "login.microsoftonline.com"
$ClearStuckPrintJobs   = $true   # remove print jobs stuck longer than $StuckPrintMinutes
$StuckPrintMinutes     = 60
$RefreshGroupPolicy    = $true   # gpupdate (computer policy) on domain-joined devices
$TriggerIntuneSync     = $true   # start an Intune (MDM) check-in on enrolled devices
$CheckComponentStore   = $true   # DISM CheckHealth (read-only, fast)
$RunDismRestoreHealth  = $false  # repair Windows component store if damaged (slow: 10-30 min)
$UptimeWarnDays        = 14
$EventDays             = 7
$WriteLocalLog         = $true   # also save the output to C:\ProgramData\ZDX_Remediation\Logs
# ------------------------------------------

# Approved services. Mode "Run" = should be running; "NotDisabled" = must not be disabled.
# FixDisabled = $false means a disabled service is reported but left alone, because
# companies often disable it on purpose (e.g. Print Spooler hardening).
$ServiceList = @(
    @{ Name = "Winmgmt";                   Label = "WMI";                        Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 10 },
    @{ Name = "EventLog";                  Label = "Windows Event Log";          Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 8 },
    @{ Name = "CryptSvc";                  Label = "Cryptographic Services";     Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 8 },
    @{ Name = "Dhcp";                      Label = "DHCP Client";                Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 8 },
    @{ Name = "Dnscache";                  Label = "DNS Client";                 Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 8 },
    @{ Name = "LanmanWorkstation";         Label = "Workstation";                Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 5 },
    @{ Name = "W32Time";                   Label = "Windows Time";               Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 5 },
    @{ Name = "Audiosrv";                  Label = "Windows Audio";              Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 5 },
    @{ Name = "AudioEndpointBuilder";      Label = "Audio Endpoint Builder";     Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 5 },
    @{ Name = "WlanSvc";                   Label = "WLAN AutoConfig (Wi-Fi)";    Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 5 },
    @{ Name = "ClickToRunSvc";             Label = "Office Click-to-Run";        Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 5 },
    @{ Name = "IntuneManagementExtension"; Label = "Intune Management Ext.";     Start = "Automatic"; Mode = "Run";         FixDisabled = $true;  Penalty = 5 },
    @{ Name = "wuauserv";                  Label = "Windows Update";             Start = "Manual";    Mode = "NotDisabled"; FixDisabled = $true;  Penalty = 5 },
    @{ Name = "BITS";                      Label = "BITS";                       Start = "Manual";    Mode = "NotDisabled"; FixDisabled = $true;  Penalty = 3 },
    @{ Name = "Spooler";                   Label = "Print Spooler";              Start = "Automatic"; Mode = "Run";         FixDisabled = $false; Penalty = 3 },
    @{ Name = "WSearch";                   Label = "Windows Search";             Start = "Automatic"; Mode = "Run";         FixDisabled = $false; Penalty = 3 }
)

$StartTime = Get-Date
$Drive = $env:SystemDrive
if (-not $Drive) { $Drive = "C:" }
if (-not $env:SystemRoot) { $env:SystemRoot = "$Drive\Windows" }
if (-not $env:ProgramData) { $env:ProgramData = "$Drive\ProgramData" }
$Sys32 = "$env:SystemRoot\System32"
$Checks = New-Object System.Collections.ArrayList
$Actions = @()

# ---------------- Helpers ----------------
function Add-Action {
    param([string]$Message)
    $script:Actions += "- $Message"
}

# Result: PASS, FIXED, WARN, FAIL, INFO, DONE, N/A, SKIP
# Penalty counts against the "before" score if IssueBefore, and against the
# "after" score if the final result is still WARN or FAIL.
function Add-Check {
    param([string]$Id, [string]$Category, [string]$Name, [string]$Before, [string]$Result,
          [string]$Detail, [int]$Penalty = 0, [bool]$IssueBefore = $false)
    [void]$script:Checks.Add([pscustomobject]@{
        Id = $Id; Category = $Category; Name = $Name; Before = $Before; Result = $Result
        Detail = $Detail; Penalty = $Penalty; IssueBefore = $IssueBefore
    })
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    return ("{0:N0} MB" -f ($Bytes / 1MB))
}

function Get-MinutesLeft {
    return [Math]::Max(0, $MaxRuntimeMinutes - ((Get-Date) - $StartTime).TotalMinutes)
}

function Test-IsLink {
    param([string]$Path)
    $a = ([IO.FileInfo]$Path).Attributes
    return ([int]$a -ne -1 -and [bool]($a -band [IO.FileAttributes]::ReparsePoint))
}

function Get-PendingReboot {
    $r = @()
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $r += "Windows servicing" }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $r += "Windows Update" }
    $pfr = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations).PendingFileRenameOperations
    if ($pfr) { $r += "Pending file operations" }
    return $r
}

function Get-ClockOffset {
    param([string]$Server)
    if (-not $Server) { return $null }
    $out = & "$Sys32\w32tm.exe" /stripchart /computer:$Server /samples:1 /dataonly 2>$null | Out-String
    if ($out -match '([+-]\d+[\.,]\d+)s') { return [double]($matches[1] -replace ',', '.') }
    return $null
}

function Test-Dns {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Resolve-DnsName -Name $DnsTestName -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
        $sw.Stop()
        if ($r) { return [pscustomobject]@{ Ok = $true; Ms = $sw.ElapsedMilliseconds } }
    } catch {}
    return [pscustomobject]@{ Ok = $false; Ms = $null }
}

function Start-WithTimeout {
    param([string]$Exe, [string]$Arguments, [double]$Minutes)
    $proc = Start-Process -FilePath $Exe -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    if (-not $proc) { return "Failed to start" }
    if ($proc.WaitForExit([int]($Minutes * 60 * 1000))) { return "Completed" }
    return "Still running in background"
}

function Write-LocalLog {
    param([string]$Name, [string]$Text)
    try {
        $trusted = @("S-1-5-18", "S-1-5-32-544")
        $base = Join-Path $env:ProgramData "ZDX_Remediation"
        $dir = Join-Path $base "Logs"
        foreach ($d in @($base, $dir)) {
            if (-not (Test-Path -LiteralPath $d)) {
                New-Item -ItemType Directory -Path $d -Force | Out-Null
                $acl = New-Object System.Security.AccessControl.DirectorySecurity
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($sid in $trusted) {
                    $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
                    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
                }
                Set-Acl -LiteralPath $d -AclObject $acl
            }
            if (Test-IsLink $d) { return $null }
            $owner = (Get-Acl -LiteralPath $d).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            if ($trusted -notcontains $owner) { return $null }
        }
        $file = Join-Path $dir "$Name.log"
        if ((Test-Path -LiteralPath $file) -and (Test-IsLink $file)) { return $null }
        if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 2MB) {
            Move-Item -LiteralPath $file -Destination "$file.old" -Force
        }
        Add-Content -LiteralPath $file -Value ($Text + [Environment]::NewLine) -Encoding ASCII
        return $file
    } catch { return $null }
}

# ---------------- Device information ----------------
$Context = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$CS = Get-CimInstance Win32_ComputerSystem
$OS = Get-CimInstance Win32_OperatingSystem
$Bios = Get-CimInstance Win32_BIOS
$User = [string]$CS.UserName
if (-not $User) { $User = "No Interactive User" }
$Ubr = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
$DisplayVer = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
$OsText = "$($OS.Caption) $DisplayVer (build $($OS.BuildNumber)$(if($Ubr){'.' + $Ubr}))"
$Dsreg = (& "$Sys32\dsregcmd.exe" /status 2>$null | Out-String)
$JoinParts = @()
if ($Dsreg -match '(?im)^\s*AzureAdJoined\s*:\s*YES') { $JoinParts += "Entra joined" }
if ($CS.PartOfDomain) { $JoinParts += "Domain joined ($($CS.Domain))" }
if ($JoinParts.Count -eq 0) { $JoinParts += "Workgroup" }
$JoinText = $JoinParts -join ", "
$LastBoot = $OS.LastBootUpTime
$UptimeDays = 0
if ($LastBoot) { $UptimeDays = [Math]::Round(((Get-Date) - $LastBoot).TotalDays, 1) }

# ================= 1. SERVICES =================
$n = 0
foreach ($s in $ServiceList) {
    $n++
    $id = "S{0:D2}" -f $n
    $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
    if (-not $svc) { Add-Check $id "Services" $s.Label "Not installed" "N/A" "Service not present on this device"; continue }
    $startType = [string]$svc.StartType
    $status = [string]$svc.Status
    $before = "$status / $startType"
    $disabled = ($startType -eq "Disabled")
    $issue = $disabled -or ($s.Mode -eq "Run" -and $status -ne "Running")
    if (-not $issue) { Add-Check $id "Services" $s.Label $before "PASS" "Running as expected"; continue }

    if ($disabled -and -not $s.FixDisabled) {
        Add-Check $id "Services" $s.Label $before "INFO" "Disabled; left as is (often disabled on purpose)"
        continue
    }
    if ($DryRun -or -not $RepairServices) {
        Add-Check $id "Services" $s.Label $before "WARN" "Would be repaired (dry run or repair off)" $s.Penalty $true
        continue
    }
    $steps = @()
    if ($disabled) {
        Set-Service -Name $s.Name -StartupType $s.Start -ErrorAction SilentlyContinue
        $steps += "set to $($s.Start)"
    }
    if ($s.Mode -eq "Run") {
        Start-Service -Name $s.Name -ErrorAction SilentlyContinue
        try { (Get-Service -Name $s.Name).WaitForStatus("Running", [TimeSpan]::FromSeconds(20)) } catch {}
        $steps += "started"
    }
    $svc = Get-Service -Name $s.Name
    $ok = ([string]$svc.StartType -ne "Disabled") -and ($s.Mode -ne "Run" -or [string]$svc.Status -eq "Running")
    if ($ok) {
        Add-Check $id "Services" $s.Label $before "FIXED" ("Service " + ($steps -join ", ")) $s.Penalty $true
        Add-Action "$($s.Label) service $($steps -join ' and ')"
    } else {
        Add-Check $id "Services" $s.Label $before "FAIL" "Could not repair (now $([string]$svc.Status) / $([string]$svc.StartType))" $s.Penalty $true
    }
}

# ================= 2. SYSTEM CORE =================
# WMI repository
& "$Sys32\wbem\winmgmt.exe" /verifyrepository 2>$null | Out-Null
$wmiOk = ($LASTEXITCODE -eq 0)
if ($wmiOk) {
    Add-Check "C01" "System Core" "WMI repository" "Consistent" "PASS" "Repository verified"
} elseif ($DryRun -or -not $RepairWmi) {
    Add-Check "C01" "System Core" "WMI repository" "Inconsistent" "WARN" "Would run safe salvage repair (dry run or repair off)" 15 $true
} else {
    & "$Sys32\wbem\winmgmt.exe" /salvagerepository 2>$null | Out-Null
    & "$Sys32\wbem\winmgmt.exe" /verifyrepository 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Add-Check "C01" "System Core" "WMI repository" "Inconsistent" "FIXED" "Salvaged and verified consistent" 15 $true
        Add-Action "WMI repository repaired (salvage) and verified"
    } else {
        Add-Check "C01" "System Core" "WMI repository" "Inconsistent" "FAIL" "Salvage did not fix it; escalate" 15 $true
    }
}

# Clock / time sync
$TimeSource = ((& "$Sys32\w32tm.exe" /query /source 2>$null | Out-String).Trim() -replace ',0x\w+$', '')
$LocalSource = (-not $TimeSource) -or ($TimeSource -match '(?i)Local CMOS|Free-running')
$RefServer = $TimeSource
if ($LocalSource) { $RefServer = "time.windows.com" }
$Offset = Get-ClockOffset $RefServer
if ($null -ne $Offset) { $OffsetText = "{0:N1} s" -f $Offset } else { $OffsetText = "Unknown" }
$timeIssue = ($null -ne $Offset -and [Math]::Abs($Offset) -gt $MaxClockOffsetSeconds)
if (-not $timeIssue -and $null -ne $Offset) {
    Add-Check "C02" "System Core" "Clock accuracy" "Offset $OffsetText" "PASS" "Source: $(if($LocalSource){'not configured'}else{$TimeSource})"
} elseif ($null -eq $Offset) {
    Add-Check "C02" "System Core" "Clock accuracy" "Offset unknown" "WARN" "Time server $RefServer not reachable (UDP 123 may be blocked)" 3 $true
} elseif ($DryRun -or -not $RepairTime) {
    Add-Check "C02" "System Core" "Clock accuracy" "Offset $OffsetText" "WARN" "Would resync (dry run or repair off)" 10 $true
} else {
    & "$Sys32\w32tm.exe" /resync /rediscover 2>$null | Out-Null
    Start-Sleep -Seconds 3
    $after = Get-ClockOffset $RefServer
    if ($null -ne $after -and [Math]::Abs($after) -le $MaxClockOffsetSeconds) {
        Add-Check "C02" "System Core" "Clock accuracy" "Offset $OffsetText" "FIXED" ("Resynced; offset now {0:N2} s" -f $after) 10 $true
        Add-Action ("Clock resynced (offset {0} -> {1:N2} s)" -f $OffsetText, $after)
    } else {
        Add-Check "C02" "System Core" "Clock accuracy" "Offset $OffsetText" "FAIL" "Resync did not correct the clock; check time source" 10 $true
    }
}
if ($LocalSource -and $null -ne $Offset) {
    Add-Check "C03" "System Core" "Time source" "Not configured" "WARN" "Clock syncs from local hardware only; review time policy" 3 $true
}

# Windows component store (read-only check, optional repair)
if ($CheckComponentStore) {
    $dismOut = & "$Sys32\Dism.exe" /Online /Cleanup-Image /CheckHealth 2>$null | Out-String
    $dismCode = $LASTEXITCODE
    if ($dismOut -match '(?i)not repairable') { $csState = "Not repairable" }
    elseif ($dismOut -match '(?i)repairable') { $csState = "Repairable" }
    elseif ($dismCode -eq 0) { $csState = "Healthy" }
    else { $csState = "Unknown" }

    if ($csState -eq "Healthy") {
        Add-Check "C04" "System Core" "Windows component store" "Healthy" "PASS" "No corruption detected"
    } elseif ($csState -eq "Unknown") {
        Add-Check "C04" "System Core" "Windows component store" "Unknown" "INFO" "DISM check returned code $dismCode"
    } elseif ($csState -eq "Repairable" -and $RunDismRestoreHealth -and -not $DryRun -and (Get-MinutesLeft) -gt 12) {
        $r = Start-WithTimeout "$Sys32\Dism.exe" "/Online /Cleanup-Image /RestoreHealth /Quiet /NoRestart" ((Get-MinutesLeft) - 2)
        $recheck = & "$Sys32\Dism.exe" /Online /Cleanup-Image /CheckHealth 2>$null | Out-String
        if ($r -eq "Completed" -and $recheck -notmatch '(?i)repairable') {
            Add-Check "C04" "System Core" "Windows component store" "Repairable" "FIXED" "RestoreHealth repaired the component store" 10 $true
            Add-Action "Windows component store repaired (DISM RestoreHealth)"
        } else {
            Add-Check "C04" "System Core" "Windows component store" "Repairable" "WARN" "RestoreHealth: $r; re-check needed" 10 $true
        }
    } else {
        $res = "WARN"; $pen = 10
        if ($csState -eq "Not repairable") { $res = "FAIL"; $pen = 15 }
        Add-Check "C04" "System Core" "Windows component store" $csState $res "Corruption detected; repair not run" $pen $true
    }
}

# ================= 3. NETWORK =================
$dns = Test-Dns
if ($dns.Ok -and $dns.Ms -le 500) {
    Add-Check "N01" "Network" "DNS resolution" "OK ($($dns.Ms) ms)" "PASS" "$DnsTestName resolved"
} elseif ($dns.Ok) {
    Add-Check "N01" "Network" "DNS resolution" "Slow ($($dns.Ms) ms)" "WARN" "Name resolution is slow" 5 $true
} elseif ($DryRun -or -not $RepairDns) {
    Add-Check "N01" "Network" "DNS resolution" "Failed" "WARN" "Would flush DNS cache (dry run or repair off)" 15 $true
} else {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $dns2 = Test-Dns
    if ($dns2.Ok) {
        Add-Check "N01" "Network" "DNS resolution" "Failed" "FIXED" "DNS cache flushed; resolves in $($dns2.Ms) ms" 15 $true
        Add-Action "DNS cache flushed; name resolution restored"
    } else {
        Add-Check "N01" "Network" "DNS resolution" "Failed" "FAIL" "Still failing after cache flush; check network/DNS" 15 $true
    }
}

# Active physical connection (read-only). Zscaler and other virtual adapters are ignored.
$adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" })
if ($adapters.Count -eq 0) {
    Add-Check "N02" "Network" "Active connection" "None" "WARN" "No physical network adapter is connected" 5 $true
} else {
    $a = $adapters | Sort-Object { if ($_.PhysicalMediaType -match '802\.11|Native 802') { 1 } else { 0 } } | Select-Object -First 1
    $isWifi = ([string]$a.PhysicalMediaType -match '802\.11|Native 802') -or ([string]$a.InterfaceDescription -match '(?i)wi-?fi|wireless|wlan')
    if ($isWifi) {
        $wl = & "$Sys32\netsh.exe" wlan show interfaces 2>$null | Out-String
        $signal = $null; $radio = "Unknown"; $ssid = "Unknown"
        if ($wl -match '(?im)^\s*Signal\s*:\s*(\d+)%') { $signal = [int]$matches[1] }
        if ($wl -match '(?im)^\s*Radio type\s*:\s*(.+?)\s*$') { $radio = $matches[1] }
        if ($wl -match '(?im)^\s*SSID\s*:\s*(.+?)\s*$') { $ssid = $matches[1] }
        $detail = "Wi-Fi '$ssid', $radio, $($a.LinkSpeed)"
        if ($null -eq $signal) {
            Add-Check "N02" "Network" "Active connection" "Wi-Fi" "INFO" $detail
        } elseif ($signal -lt 50) {
            Add-Check "N02" "Network" "Active connection" "Wi-Fi signal $signal%" "WARN" "$detail; weak signal" 5 $true
        } else {
            Add-Check "N02" "Network" "Active connection" "Wi-Fi signal $signal%" "PASS" $detail
        }
    } else {
        Add-Check "N02" "Network" "Active connection" "Ethernet" "PASS" "$($a.InterfaceDescription), $($a.LinkSpeed)"
    }
}

# ================= 4. PRINTING =================
$spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue
$spoolDir = "$Sys32\spool\PRINTERS"
if (-not $spooler -or [string]$spooler.StartType -eq "Disabled") {
    Add-Check "P01" "Printing" "Stuck print jobs" "Spooler off" "N/A" "Print Spooler not in use"
} else {
    $cut = (Get-Date).AddMinutes(-$StuckPrintMinutes)
    $stuck = @()
    if ((Test-Path -LiteralPath $spoolDir) -and -not (Test-IsLink $spoolDir)) {
        $stuck = @(Get-ChildItem -LiteralPath $spoolDir -File -Force | Where-Object {
            $_.LastWriteTime -lt $cut -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        })
    }
    $jobs = [int][Math]::Ceiling($stuck.Count / 2)   # each job = .SHD + .SPL file
    if ($stuck.Count -eq 0) {
        Add-Check "P01" "Printing" "Stuck print jobs" "None" "PASS" "No jobs older than $StuckPrintMinutes min"
    } elseif ($DryRun -or -not $ClearStuckPrintJobs) {
        Add-Check "P01" "Printing" "Stuck print jobs" "$jobs job(s)" "WARN" "Would clear (dry run or setting off)" 5 $true
    } else {
        $wasRunning = ([string]$spooler.Status -eq "Running")
        Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        foreach ($f in $stuck) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
        if ($wasRunning -or [string]$spooler.StartType -eq "Automatic") { Start-Service -Name Spooler -ErrorAction SilentlyContinue }
        $left = @($stuck | Where-Object { Test-Path -LiteralPath $_.FullName }).Count
        if ($left -eq 0) {
            Add-Check "P01" "Printing" "Stuck print jobs" "$jobs job(s)" "FIXED" "Cleared and Print Spooler restarted" 5 $true
            Add-Action "Cleared $jobs stuck print job(s) and restarted Print Spooler"
        } else {
            Add-Check "P01" "Printing" "Stuck print jobs" "$jobs job(s)" "FAIL" "$left file(s) could not be removed" 5 $true
        }
    }
}

# ================= 5. MANAGEMENT =================
if ($CS.PartOfDomain) {
    if (-not $RefreshGroupPolicy) {
        Add-Check "M01" "Management" "Group Policy refresh" "Domain joined" "SKIP" "Disabled in settings"
    } elseif ($DryRun) {
        Add-Check "M01" "Management" "Group Policy refresh" "Domain joined" "SKIP" "Dry run"
    } elseif ((Get-MinutesLeft) -lt 4) {
        Add-Check "M01" "Management" "Group Policy refresh" "Domain joined" "SKIP" "Skipped (time budget)"
    } else {
        & "$Sys32\gpupdate.exe" /target:computer /wait:120 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Add-Check "M01" "Management" "Group Policy refresh" "Domain joined" "DONE" "Computer policy refreshed"
            Add-Action "Computer Group Policy refreshed"
        } else {
            Add-Check "M01" "Management" "Group Policy refresh" "Domain joined" "WARN" "gpupdate failed (code $LASTEXITCODE); domain controller may be unreachable" 3 $true
        }
    }
} else {
    Add-Check "M01" "Management" "Group Policy refresh" "Not domain joined" "N/A" "Not applicable"
}

$pushTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskPath -like "\Microsoft\Windows\EnterpriseMgmt\*" -and $_.TaskName -eq "PushLaunch"
})
if ($pushTasks.Count -eq 0) {
    Add-Check "M02" "Management" "Intune (MDM) sync" "Not enrolled" "INFO" "No MDM enrollment found on this device"
} elseif (-not $TriggerIntuneSync -or $DryRun) {
    Add-Check "M02" "Management" "Intune (MDM) sync" "Enrolled" "SKIP" "Dry run or disabled in settings"
} else {
    $okSync = $false
    foreach ($t in $pushTasks) { try { Start-ScheduledTask -InputObject $t -ErrorAction Stop; $okSync = $true } catch {} }
    if ($okSync) {
        Add-Check "M02" "Management" "Intune (MDM) sync" "Enrolled" "DONE" "Check-in triggered"
        Add-Action "Intune (MDM) check-in triggered"
    } else {
        Add-Check "M02" "Management" "Intune (MDM) sync" "Enrolled" "WARN" "Could not start the sync task" 3 $true
    }
}

# ================= 6. HARDWARE & RESOURCES (report only) =================
# Free space on system drive
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'"
if ($disk -and $disk.Size) {
    $pct = [Math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
    $txt = "$(Format-Size $disk.FreeSpace) free ($pct%)"
    if ($pct -lt 10) { Add-Check "H01" "Hardware" "System drive space" $txt "FAIL" "Critically low; run Disk Space Cleanup" 10 $true }
    elseif ($pct -lt 15) { Add-Check "H01" "Hardware" "System drive space" $txt "WARN" "Low; run Disk Space Cleanup" 5 $true }
    else { Add-Check "H01" "Hardware" "System drive space" $txt "PASS" "Enough free space" }
}

# Physical disk health
$pdisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -notin @("USB","File Backed Virtual","Virtual") })
if ($pdisks.Count -eq 0) {
    Add-Check "H02" "Hardware" "Disk health" "Unknown" "INFO" "Storage health not available"
} else {
    foreach ($pd in $pdisks) {
        $rel = $pd | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
        $wear = $null
        if ($rel -and $null -ne $rel.Wear) { $wear = [int]$rel.Wear }
        $label = "$($pd.FriendlyName) ($($pd.MediaType), $(Format-Size $pd.Size))"
        $hs = [string]$pd.HealthStatus
        if ($hs -ne "Healthy" -and $hs) {
            Add-Check "H02" "Hardware" "Disk health" $hs "FAIL" "$label reports $hs; back up data and replace disk" 15 $true
        } elseif ($null -ne $wear -and $wear -ge 80) {
            Add-Check "H02" "Hardware" "Disk health" "Wear $wear%" "WARN" "$label is near end of life" 5 $true
        } else {
            Add-Check "H02" "Hardware" "Disk health" "Healthy$(if($null -ne $wear){", wear $wear%"})" "PASS" $label
        }
    }
}

# Battery health (laptops)
$full = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1
$design = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1
if ($full -and $design -and $design.DesignedCapacity -gt 0) {
    $bh = [Math]::Round(($full.FullChargedCapacity / $design.DesignedCapacity) * 100, 0)
    if ($bh -gt 100) { $bh = 100 }
    if ($bh -lt 60) { Add-Check "H03" "Hardware" "Battery health" "$bh% of design" "WARN" "Battery is worn; consider replacement" 5 $true }
    else { Add-Check "H03" "Hardware" "Battery health" "$bh% of design" "PASS" "Battery capacity is fine" }
} else {
    Add-Check "H03" "Hardware" "Battery health" "No battery" "N/A" "Desktop or battery data unavailable"
}

# Memory
if ($OS.TotalVisibleMemorySize) {
    $memPct = [Math]::Round((1 - ($OS.FreePhysicalMemory / $OS.TotalVisibleMemorySize)) * 100, 0)
    $totalGB = [Math]::Round($OS.TotalVisibleMemorySize / 1MB, 1)
    $top = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 3 |
             ForEach-Object { "$($_.ProcessName) $([Math]::Round($_.WorkingSet64 / 1MB)) MB" }) -join ", "
    if ($memPct -ge 90) { Add-Check "H04" "Hardware" "Memory usage" "$memPct% of $totalGB GB" "WARN" "High. Top: $top" 5 $true }
    else { Add-Check "H04" "Hardware" "Memory usage" "$memPct% of $totalGB GB" "PASS" "Top: $top" }
}

# CPU load (3 samples)
$loads = @()
for ($i = 0; $i -lt 3; $i++) {
    $l = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
    if ($null -ne $l) { $loads += $l }
    Start-Sleep -Seconds 1
}
if ($loads.Count -gt 0) {
    $cpu = [Math]::Round(($loads | Measure-Object -Average).Average, 0)
    if ($cpu -ge 85) { Add-Check "H05" "Hardware" "CPU load" "$cpu%" "WARN" "Sustained high CPU" 3 $true }
    else { Add-Check "H05" "Hardware" "CPU load" "$cpu%" "PASS" "Normal" }
}

# ================= 7. STABILITY (report only) =================
$since = (Get-Date).AddDays(-$EventDays)
$bsod = @(Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = 1001; ProviderName = "Microsoft-Windows-WER-SystemErrorReporting"; StartTime = $since } -ErrorAction SilentlyContinue).Count
$unexp = @(Get-WinEvent -FilterHashtable @{ LogName = "System"; Id = @(41, 6008); StartTime = $since } -ErrorAction SilentlyContinue).Count
$appc = @(Get-WinEvent -FilterHashtable @{ LogName = "Application"; Id = 1000; StartTime = $since } -ErrorAction SilentlyContinue).Count

if ($bsod -gt 0) { Add-Check "R01" "Stability" "Blue screens ($EventDays days)" "$bsod" "WARN" "Run Application Crash & Stability Analyzer" 10 $true }
else { Add-Check "R01" "Stability" "Blue screens ($EventDays days)" "0" "PASS" "None" }
if ($unexp -gt 0) { Add-Check "R02" "Stability" "Unexpected shutdowns" "$unexp" "WARN" "Power loss, forced restart or crash" 5 $true }
else { Add-Check "R02" "Stability" "Unexpected shutdowns" "0" "PASS" "None" }
if ($appc -ge 10) { Add-Check "R03" "Stability" "Application crashes" "$appc" "WARN" "Frequent; run Application Crash & Stability Analyzer" 3 $true }
else { Add-Check "R03" "Stability" "Application crashes" "$appc" "PASS" "Within normal range" }

$pending = @(Get-PendingReboot)
if ($UptimeDays -ge $UptimeWarnDays) { Add-Check "R04" "Stability" "Uptime" "$UptimeDays days" "WARN" "Restart recommended" 5 $true }
elseif ($LastBoot) { Add-Check "R04" "Stability" "Uptime" "$UptimeDays days" "PASS" "Last boot $($LastBoot.ToString('yyyy-MM-dd HH:mm'))" }
else { Add-Check "R04" "Stability" "Uptime" "Unknown" "INFO" "Boot time not available" }
if ($pending.Count -gt 0) { Add-Check "R05" "Stability" "Restart pending" "Yes" "WARN" ($pending -join ", ") 5 $true }
else { Add-Check "R05" "Stability" "Restart pending" "No" "PASS" "None" }

# ================= Scoring and summary =================
$penBefore = ($Checks | Where-Object { $_.IssueBefore } | Measure-Object Penalty -Sum).Sum
$penAfter = ($Checks | Where-Object { $_.Result -in @("WARN","FAIL") } | Measure-Object Penalty -Sum).Sum
if (-not $penBefore) { $penBefore = 0 }
if (-not $penAfter) { $penAfter = 0 }
$ScoreBefore = [Math]::Max(0, 100 - $penBefore)
$ScoreAfter = [Math]::Max(0, 100 - $penAfter)

function Get-Grade { param([int]$s)
    if ($s -ge 90) { return "HEALTHY" } elseif ($s -ge 75) { return "GOOD" } elseif ($s -ge 50) { return "DEGRADED" } else { return "POOR" }
}

$Found = @($Checks | Where-Object { $_.IssueBefore }).Count
$Fixed = @($Checks | Where-Object { $_.Result -eq "FIXED" }).Count
$Failed = @($Checks | Where-Object { $_.Result -eq "FAIL" }).Count
$Warned = @($Checks | Where-Object { $_.Result -eq "WARN" }).Count

if ($DryRun) { $HealStatus = "DRY RUN" }
elseif ($Found -eq 0) { $HealStatus = "HEALTHY - NO ACTION NEEDED" }
elseif ($Failed -eq 0 -and $Warned -eq 0) { $HealStatus = "FIXED" }
elseif ($Fixed -gt 0) { $HealStatus = "PARTIALLY FIXED - ATTENTION NEEDED" }
else { $HealStatus = "ATTENTION NEEDED" }

# Prioritized recommendations based on what is still open
$Rec = @()
$open = @($Checks | Where-Object { $_.Result -in @("WARN","FAIL") })
foreach ($c in ($open | Where-Object { $_.Id -eq "H02" -and $_.Result -eq "FAIL" })) { $Rec += "Back up user data now and replace the disk ($($c.Detail))." }
if ($open | Where-Object { $_.Id -eq "C01" }) { $Rec += "WMI could not be repaired automatically; escalate to desktop engineering." }
if ($open | Where-Object { $_.Id -eq "N01" -and $_.Result -eq "FAIL" }) { $Rec += "DNS still fails; check the network connection and DNS settings." }
if ($open | Where-Object { $_.Id -in @("R04","R05") }) { $Rec += "Restart the device (uptime $UptimeDays days$(if($pending.Count -gt 0){', restart pending'}))." }
if ($open | Where-Object { $_.Id -eq "H01" }) { $Rec += "Run 'Disk Space Cleanup' to free space on $Drive." }
if ($open | Where-Object { $_.Id -in @("R01","R03") }) { $Rec += "Run 'Application Crash & Stability Analyzer' to find the crashing component." }
if ($open | Where-Object { $_.Id -eq "C04" }) { $Rec += "Repair Windows: set `$RunDismRestoreHealth = `$true or run DISM /RestoreHealth." }
if ($open | Where-Object { $_.Id -in @("C02","C03") }) { $Rec += "Review time configuration; make sure the device can reach its time source." }
foreach ($c in ($open | Where-Object { $_.Category -eq "Services" })) { $Rec += "Check service '$($c.Name)': $($c.Detail)." }
if ($open | Where-Object { $_.Id -eq "N02" }) { $Rec += "Weak or missing network connection; move closer to the access point or use Ethernet." }
if ($open | Where-Object { $_.Id -eq "H04" }) { $Rec += "High memory use; ask the user to close unused apps or consider a RAM upgrade." }
if ($open | Where-Object { $_.Id -eq "H03" }) { $Rec += "Battery is worn; consider a battery replacement." }
if ($open | Where-Object { $_.Id -eq "R02" }) { $Rec += "Unexpected shutdowns found; check power/battery and crash history." }
if ($Rec.Count -eq 0) { $Rec += "No further action needed." }

# ================= Output =================
function Format-Row {
    param($c)
    $name = [string]$c.Name; if ($name.Length -gt 26) { $name = $name.Substring(0, 26) }
    $before = [string]$c.Before; if ($before.Length -gt 22) { $before = $before.Substring(0, 22) }
    return ("{0,-4} {1,-27}{2,-23}{3,-8} {4}" -f $c.Id, $name, $before, ("[" + $c.Result + "]"), $c.Detail)
}

$Elapsed = [int]((Get-Date) - $StartTime).TotalSeconds
$Line = "=" * 100
$Lines = @(
$Line,
"DEVICE SELF-HEAL REPORT",
$Line,
"",
"Version          : $Version",
"Execution Time   : $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))",
"Execution Context: $Context",
"Dry Run          : $DryRun",
"",
"DEVICE",
"------",
"Computer         : $($CS.Name)",
"Logged-On User   : $User",
"Model            : $($CS.Manufacturer) $($CS.Model)",
"Serial Number    : $($Bios.SerialNumber)",
"BIOS             : $($Bios.SMBIOSBIOSVersion)",
"Operating System : $OsText",
"Join Type        : $JoinText",
"Last Boot        : $(if($LastBoot){$LastBoot.ToString('yyyy-MM-dd HH:mm')}else{'Unknown'}) ($UptimeDays days)",
"",
"SUMMARY",
"-------",
"Health Score     : $ScoreBefore/100 ($(Get-Grade $ScoreBefore))  ->  $ScoreAfter/100 ($(Get-Grade $ScoreAfter))",
"Issues Found     : $Found",
"Fixed            : $Fixed",
"Still Open       : $($Failed + $Warned) ($Failed failed, $Warned need attention)",
"Self-Heal Status : $HealStatus",
"",
"CHECK RESULTS",
"-------------",
("{0,-4} {1,-27}{2,-23}{3,-8} {4}" -f "ID", "Check", "Before", "Result", "Detail")
)

foreach ($cat in @("Services","System Core","Network","Printing","Management","Hardware","Stability")) {
    $rows = @($Checks | Where-Object { $_.Category -eq $cat })
    if ($rows.Count -eq 0) { continue }
    $Lines += ""
    $Lines += "[$cat]"
    foreach ($c in $rows) { $Lines += (Format-Row $c) }
}

$Lines += ""
$Lines += "ACTIONS TAKEN"
$Lines += "-------------"
if ($Actions.Count -eq 0) { $Lines += "No changes were made." } else { $Lines += $Actions }

$Lines += ""
$Lines += "RECOMMENDED NEXT STEPS"
$Lines += "----------------------"
$i = 0
foreach ($r in $Rec) { $i++; $Lines += "$i. $r" }

$Lines += ""
$Lines += "Duration : $Elapsed seconds"
$Lines += ""
$Lines += "NOTE: Only services on the approved list were changed. No restart was performed."
$Lines += "NOTE: No user files, security settings or Zscaler components were touched."
$Lines += $Line

$Output = $Lines -join [Environment]::NewLine

if ($WriteLocalLog) { [void](Write-LocalLog "Device_Self_Heal" $Output) }

# Same ZDX output/result API pattern as the working Employee Experience Health Check.
Set-ZOutput $Output
Set-ZResult -Status Success -Message "Device Self-Heal: $HealStatus. Score $ScoreBefore -> $ScoreAfter. Fixed $Fixed of $Found issue(s)."
