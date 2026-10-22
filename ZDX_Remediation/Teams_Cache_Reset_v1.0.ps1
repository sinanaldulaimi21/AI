# ZDX Teams Cache Reset
# Version 1.0 - REMEDIATION (makes changes) - ASCII
# Closes Teams for the logged-on user, renames the Teams cache folder
# (a backup is kept), and reopens Teams if it was running before.
# Run with Elevated Permissions (System Account).

$ErrorActionPreference = "SilentlyContinue"
$Version = "1.0"

# ---------------- Settings ----------------
$DryRun        = $false   # $true = report only, change nothing
$SkipIfInCall  = $true    # do nothing if Teams is using the mic/camera (user in a call)
$RelaunchTeams = $true    # reopen Teams for the user if it was running before the reset
$KeepBackups   = 1        # cache backups to keep per folder (older ones are deleted)
# ------------------------------------------

$StartTime = Get-Date
$Stamp = $StartTime.ToString("yyyyMMdd_HHmmss")
$Findings = @()
$Actions = @()

function Add-Finding {
    param([string]$Severity, [string]$Message)
    $script:Findings += "[$Severity] $Message"
}

function Add-Action {
    param([string]$Message)
    $script:Actions += "- $Message"
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    return ("{0:N0} MB" -f ($Bytes / 1MB))
}

function Get-FolderSize {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $s = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
              Measure-Object Length -Sum).Sum
        if ($s) { return [double]$s }
    } catch {}
    return 0
}

function Get-InteractiveUser {
    try {
        $u = (Get-CimInstance Win32_ComputerSystem).UserName
        if ([string]::IsNullOrWhiteSpace($u)) { return "No Interactive User" }
        return $u
    } catch { return "Unknown" }
}

function Get-UserProfileInfo {
    param([string]$UserName)
    if ($UserName -in @("Unknown","No Interactive User")) { return $null }
    $profiles = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath })
    $p = $null
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $p = $profiles | Where-Object { $_.SID -eq $sid } | Select-Object -First 1
    } catch {}
    if (-not $p) {
        $sam = ($UserName -split "\\")[-1]
        $p = $profiles | Where-Object { (Split-Path $_.LocalPath -Leaf) -ieq $sam } | Select-Object -First 1
    }
    if (-not $p) {
        $loaded = @($profiles | Where-Object { $_.Loaded })
        if ($loaded.Count -eq 1) { $p = $loaded[0] }
    }
    if ($p) { return [pscustomobject]@{ Path = $p.LocalPath; SID = $p.SID } }
    return $null
}

function Get-UserTeamsProcesses {
    param([string]$UserName)
    $all = @(Get-Process -Name "ms-teams","Teams" -IncludeUserName -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return @() }
    $mine = @($all | Where-Object { $_.UserName -ieq $UserName })
    # If owner names cannot be read at all, fall back to every Teams process.
    if ($mine.Count -eq 0 -and @($all | Where-Object { $_.UserName }).Count -eq 0) { return $all }
    return $mine
}

function Test-TeamsInCall {
    param([string]$Sid)
    if (-not $Sid) { return $false }
    $base = "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore"
    foreach ($cap in @("microphone","webcam")) {
        $keys = @()
        $pkgKey = "$base\$cap\MSTeams_8wekyb3d8bbwe"
        if (Test-Path -LiteralPath $pkgKey) { $keys += $pkgKey }
        $npKey = "$base\$cap\NonPackaged"
        if (Test-Path -LiteralPath $npKey) {
            $keys += @(Get-ChildItem -LiteralPath $npKey | Where-Object { $_.PSChildName -match 'Teams\.exe$' } | ForEach-Object { $_.PSPath })
        }
        foreach ($k in $keys) {
            $v = Get-ItemProperty -LiteralPath $k
            if ($v -and $v.LastUsedTimeStart -gt 0 -and $v.LastUsedTimeStop -eq 0) { return $true }
        }
    }
    return $false
}

function Rename-WithRetry {
    param([string]$Path, [string]$NewName)
    for ($i = 1; $i -le 4; $i++) {
        try {
            Rename-Item -LiteralPath $Path -NewName $NewName -ErrorAction Stop
            return $true
        } catch { Start-Sleep -Seconds 3 }
    }
    return $false
}

function Remove-OldBackups {
    param([string]$Parent, [string]$Prefix)
    if (-not (Test-Path -LiteralPath $Parent)) { return }
    $b = @(Get-ChildItem -LiteralPath $Parent -Directory -Force |
           Where-Object { $_.Name -like "$Prefix.bak_*" } | Sort-Object Name -Descending)
    if ($b.Count -le $KeepBackups) { return }
    foreach ($x in $b[$KeepBackups..($b.Count - 1)]) {
        Remove-Item -LiteralPath $x.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $x.FullName)) { Add-Action "Removed old backup $($x.Name)" }
    }
}

function Start-AppForUser {
    param([string]$UserName, [string]$Exe, [string]$Arguments)
    $taskName = "ZDX_TeamsRelaunch_" + [guid]::NewGuid().ToString("N").Substring(0,8)
    try {
        $action = New-ScheduledTaskAction -Execute $Exe -Argument $Arguments
        $principal = New-ScheduledTaskPrincipal -UserId $UserName -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Start-Sleep -Seconds 5
        return $true
    } catch {
        return $false
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ---------------- Discovery ----------------
$Context = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$User = Get-InteractiveUser
$ProfileInfo = Get-UserProfileInfo $User
$ProfilePath = $null
$Sid = $null
if ($ProfileInfo) { $ProfilePath = $ProfileInfo.Path; $Sid = $ProfileInfo.SID }

$NewCache = $null
$ClassicCache = $null
$NewTeamsVersion = "Not Detected"
$ClassicDetected = "No"

if ($ProfilePath) {
    $p = Join-Path $ProfilePath "AppData\Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams"
    if (Test-Path -LiteralPath $p) { $NewCache = $p }
    $p = Join-Path $ProfilePath "AppData\Roaming\Microsoft\Teams"
    if (Test-Path -LiteralPath $p) { $ClassicCache = $p; $ClassicDetected = "Yes" }
}
try {
    $pkg = Get-AppxPackage -AllUsers -Name MSTeams | Sort-Object Version -Descending | Select-Object -First 1
    if ($pkg) { $NewTeamsVersion = [string]$pkg.Version }
} catch {}

$NewCacheSize = Get-FolderSize $NewCache
$ClassicCacheSize = Get-FolderSize $ClassicCache

$Before = @(Get-UserTeamsProcesses $User)
$NewWasRunning = @($Before | Where-Object { $_.ProcessName -ieq "ms-teams" }).Count -gt 0
$ClassicWasRunning = @($Before | Where-Object { $_.ProcessName -ieq "Teams" }).Count -gt 0
$InCall = Test-TeamsInCall $Sid

# ---------------- Decide ----------------
$Status = "NO ACTION"
$Relaunch = "Not needed"
$NewResult = "Not found"
$ClassicResult = "Not found"
if ($NewCache) { $NewResult = "Pending" }
if ($ClassicCache) { $ClassicResult = "Pending" }

if ($User -in @("Unknown","No Interactive User")) {
    Add-Finding "INFO" "No logged-on user. Teams cache is per user, so nothing was changed."
} elseif (-not $ProfilePath) {
    Add-Finding "WARNING" "User profile for $User could not be found. Nothing was changed."
} elseif (-not $NewCache -and -not $ClassicCache) {
    Add-Finding "INFO" "No Teams cache folder found for $User. Nothing was changed."
} elseif ($SkipIfInCall -and $InCall) {
    $Status = "SKIPPED - USER IN CALL"
    if ($NewCache) { $NewResult = "Skipped" }
    if ($ClassicCache) { $ClassicResult = "Skipped" }
    Add-Finding "WARNING" "Teams is using the microphone or camera. User appears to be in a call. Run again later."
} elseif ($DryRun) {
    $Status = "DRY RUN"
    if ($NewCache) { $NewResult = "Would rename (dry run)" }
    if ($ClassicCache) { $ClassicResult = "Would rename (dry run)" }
    Add-Finding "INFO" "Dry run. Teams would be closed and the cache renamed. Nothing was changed."
} else {
    # ---------------- Remediate ----------------
    if ($Before.Count -gt 0) {
        $Before | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        Add-Action "Closed $($Before.Count) Teams process(es) for $User"
    }
    if ($NewCache) {
        $esc = [regex]::Escape($NewCache)
        $wv = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" | Where-Object { $_.CommandLine -match $esc })
        if ($wv.Count -gt 0) {
            $wv | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Add-Action "Closed $($wv.Count) Teams WebView2 process(es)"
        }
    }
    for ($i = 0; $i -lt 15; $i++) {
        if (@(Get-UserTeamsProcesses $User).Count -eq 0) { break }
        Start-Sleep -Seconds 1
    }

    $ok = 0
    $fail = 0
    if ($NewCache) {
        $name = "MSTeams.bak_$Stamp"
        if (Rename-WithRetry $NewCache $name) {
            $NewResult = "Renamed to $name"; $ok++
            Add-Action "New Teams cache renamed to $name ($(Format-Size $NewCacheSize))"
            Remove-OldBackups (Split-Path $NewCache -Parent) "MSTeams"
        } else {
            $NewResult = "FAILED (files in use)"; $fail++
            Add-Finding "WARNING" "New Teams cache could not be renamed. Files are still in use."
        }
    }
    if ($ClassicCache) {
        $name = "Teams.bak_$Stamp"
        if (Rename-WithRetry $ClassicCache $name) {
            $ClassicResult = "Renamed to $name"; $ok++
            Add-Action "Classic Teams cache renamed to $name ($(Format-Size $ClassicCacheSize))"
            Remove-OldBackups (Split-Path $ClassicCache -Parent) "Teams"
        } else {
            $ClassicResult = "FAILED (files in use)"; $fail++
            Add-Finding "WARNING" "Classic Teams cache could not be renamed. Files are still in use."
        }
    }

    if ($fail -eq 0) { $Status = "RESET COMPLETE" }
    elseif ($ok -gt 0) { $Status = "PARTIAL" }
    else { $Status = "FAILED" }

    # ---------------- Relaunch ----------------
    if ($RelaunchTeams -and ($NewWasRunning -or $ClassicWasRunning)) {
        $started = $false
        if ($NewWasRunning) {
            $started = Start-AppForUser $User "explorer.exe" "shell:AppsFolder\MSTeams_8wekyb3d8bbwe!MSTeams"
        } elseif ($ClassicWasRunning) {
            $upd = Join-Path $ProfilePath "AppData\Local\Microsoft\Teams\Update.exe"
            if (Test-Path -LiteralPath $upd) { $started = Start-AppForUser $User $upd '--processStart "Teams.exe"' }
        }
        $running = $false
        for ($i = 0; $i -lt 10; $i++) {
            if (@(Get-UserTeamsProcesses $User).Count -gt 0) { $running = $true; break }
            Start-Sleep -Seconds 2
        }
        if ($running) {
            $Relaunch = "Teams reopened for the user"
            Add-Action "Teams reopened for $User"
        } else {
            $Relaunch = "Could not confirm. Ask the user to open Teams."
            Add-Finding "INFO" "Teams relaunch could not be confirmed (task started: $started). Ask the user to open Teams."
        }
    } elseif ($NewWasRunning -or $ClassicWasRunning) {
        $Relaunch = "Disabled in settings. Ask the user to open Teams."
    } else {
        $Relaunch = "Teams was not running, so it was not reopened"
    }

    Add-Finding "INFO" "The user may need to sign in to Teams again. Teams rebuilds the cache on first start, so the first launch can be slower."
}

# ---------------- Output ----------------
$Elapsed = [int]((Get-Date) - $StartTime).TotalSeconds

$Lines = @(
"============================================================",
"Teams Cache Reset",
"============================================================",
"",
"Version : $Version",
"Execution Time : $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))",
"Execution Context : $Context",
"Logged-On User : $User",
"User Profile : $(if($ProfilePath){$ProfilePath}else{'Unavailable'})",
"Dry Run : $DryRun",
"",
"Before",
"------",
"New Teams Version : $NewTeamsVersion",
"New Teams Running : $(if($NewWasRunning){'Yes'}else{'No'})",
"New Teams Cache : $(if($NewCache){Format-Size $NewCacheSize}else{'Not found'})",
"Classic Teams Found : $ClassicDetected",
"Classic Teams Running : $(if($ClassicWasRunning){'Yes'}else{'No'})",
"Classic Teams Cache : $(if($ClassicCache){Format-Size $ClassicCacheSize}else{'Not found'})",
"Teams In Call : $(if($InCall){'Yes'}else{'No'})",
"",
"Result",
"------",
"New Teams Cache : $NewResult",
"Classic Teams Cache : $ClassicResult",
"Teams Relaunch : $Relaunch",
"",
"Actions Taken",
"-------------"
)

if ($Actions.Count -eq 0) { $Lines += "No changes were made." } else { $Lines += $Actions }

$Lines += ""
$Lines += "Findings"
$Lines += "--------"
if ($Findings.Count -eq 0) { $Lines += "None." } else { $Lines += $Findings }

$Lines += ""
$Lines += "Reset Status : $Status"
$Lines += "Duration : $Elapsed seconds"
$Lines += ""
$Lines += "NOTE: Cache is renamed, not deleted. To roll back, close Teams and rename the .bak_ folder back."
$Lines += "============================================================"

$Output = $Lines -join [Environment]::NewLine

# Same ZDX output/result API pattern as the working Employee Experience Health Check.
Set-ZOutput $Output
Set-ZResult -Status Success -Message "Teams Cache Reset completed. Status: $Status"
