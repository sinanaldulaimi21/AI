# ZDX Disk Space Cleanup (System Drive)
# Version 2.0 - REMEDIATION (makes changes) - ASCII
# Frees as much space as safely possible on the system drive (C:).
# Runs only when free space is at or below $RunIfFreeAtOrBelowGB.
# Never touches user documents, Desktop, Downloads, cookies, passwords or history.
# If space is still low afterwards, reports where the space went (big files,
# old profiles, OneDrive files stored locally) so the technician knows what to ask.
# Run with Elevated Permissions (System Account).

$ErrorActionPreference = "SilentlyContinue"
$Version = "2.0"

# ---------------- Settings ----------------
$DryRun                    = $false  # $true = measure only, delete nothing
$RunIfFreeAtOrBelowGB      = 20      # clean only if C: free space is this many GB or less (0 = always run)
$MaxRuntimeMinutes         = 40      # total time budget; slow steps are shortened or skipped to stay under it
$TempFileAgeHours          = 24      # temp files newer than this are kept (protects running installs)
$CleanSystemTemp           = $true   # Windows\Temp, WER reports, old CBS logs
$CleanUserTemp             = $true   # every profile: Temp, INetCache, CrashDumps, WER
$CleanBrowserCache         = $true   # Edge/Chrome cache only; skipped for a user whose browser is open
$CleanRecycleBin           = $true   # empties the Recycle Bin for ALL users on this drive
$CleanCrashDumps           = $true   # MEMORY.DMP, LiveKernelReports, minidumps older than $MinidumpAgeDays
$MinidumpAgeDays           = 30
$CleanWindowsUpdateCache   = $true   # SoftwareDistribution\Download
$CleanDeliveryOptimization = $true   # Delivery Optimization cache
$RunDiskCleanupTool        = $true   # cleanmgr (or DISM component cleanup if cleanmgr is missing)
$RemoveOldWindowsInstall   = $true   # Windows.old + upgrade leftovers, only if older than $WindowsOldMinDays (removes rollback)
$WindowsOldMinDays         = 10      # 0 = remove even right after an upgrade
$DiskCleanupTimeoutMinutes = 25      # if cleanmgr runs longer, it keeps running in the background
$DisableHibernation        = $false  # frees hiberfil.sys but turns off hibernate and Fast Startup
$RestorePointMaxPercent    = 0       # 0 = leave System Restore alone; e.g. 5 = cap restore points at 5% of C:
$DeepReportWhenLow         = $true   # if still below 15% free, scan profiles and report where the space is
$StaleProfileDays          = 90      # profiles unused this long are listed (never deleted)
$BigFileGB                 = 1       # files this size or larger in user profiles are listed (never deleted)
$WriteLocalLog             = $true   # also save the output to C:\ProgramData\ZDX\Logs on the device
# ------------------------------------------

$StartTime = Get-Date
$Drive = $env:SystemDrive
if (-not $Drive) { $Drive = "C:" }
$Findings = @()
$Steps = @()
$script:StepBytes = 0
$script:StepFiles = 0
$script:StepNote = ""

function Add-Finding {
    param([string]$Severity, [string]$Message)
    $script:Findings += "[$Severity] $Message"
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    return ("{0:N0} MB" -f ($Bytes / 1MB))
}

function Get-MinutesLeft {
    return [Math]::Max(0, $MaxRuntimeMinutes - ((Get-Date) - $StartTime).TotalMinutes)
}

function Get-DiskInfo {
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'"
        return [pscustomobject]@{ Free = [double]$d.FreeSpace; Size = [double]$d.Size }
    } catch { return [pscustomobject]@{ Free = 0; Size = 0 } }
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

function Set-StepNote {
    param([string]$Note)
    if ($script:StepNote) { $script:StepNote += "; " + $Note } else { $script:StepNote = $Note }
}

# Deletes files older than $Cutoff under $Path, then removes empty folders.
# Skips junctions/symlinks so it never follows a link outside the target folder.
function Remove-OldItems {
    param([string]$Path, [datetime]$Cutoff, [string[]]$Exclude = @())
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if ($Exclude -contains $item.Name) { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($item.PSIsContainer) {
            $dirTime = $item.LastWriteTime
            Remove-OldItems -Path $item.FullName -Cutoff $Cutoff -Exclude $Exclude
            if (-not $DryRun -and $dirTime -lt $Cutoff) {
                if (@(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        } elseif ($item.LastWriteTime -lt $Cutoff) {
            Remove-OneFile $item
        }
    }
}

function Remove-OneFile {
    param($File)
    $len = [double]$File.Length
    if ($DryRun) { $script:StepBytes += $len; $script:StepFiles++; return }
    try {
        Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop
        $script:StepBytes += $len; $script:StepFiles++
    } catch {}
}

function Remove-MatchingFiles {
    param([string]$Path, [string]$Filter, [datetime]$Cutoff)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Filter $Filter -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $Cutoff } | ForEach-Object { Remove-OneFile $_ }
}

function Invoke-CleanupStep {
    param([string]$Name, [bool]$Enabled, [scriptblock]$Action)
    if (-not $Proceed) { return }
    if (-not $Enabled) {
        $script:Steps += [pscustomobject]@{ Name = $Name; Freed = 0; Found = 0; Files = 0; Seconds = 0; Note = "Disabled in settings" }
        return
    }
    $script:StepBytes = 0
    $script:StepFiles = 0
    $script:StepNote = ""
    $before = (Get-DiskInfo).Free
    $t = Get-Date
    try { & $Action } catch { Set-StepNote ("Error: " + $_.Exception.Message) }
    $after = (Get-DiskInfo).Free
    $script:Steps += [pscustomobject]@{
        Name    = $Name
        Freed   = [Math]::Max(0, $after - $before)
        Found   = $script:StepBytes
        Files   = $script:StepFiles
        Seconds = [int]((Get-Date) - $t).TotalSeconds
        Note    = $script:StepNote
    }
}

function Get-RunningOwnerSids {
    param([string[]]$Names)
    $sids = @()
    foreach ($p in @(Get-Process -Name $Names -IncludeUserName -ErrorAction SilentlyContinue)) {
        if ($p.UserName) {
            try { $sids += (New-Object System.Security.Principal.NTAccount($p.UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch {}
        }
    }
    return @($sids | Select-Object -Unique)
}

# Starts a process and waits up to $Minutes. Returns "Completed", "Still running in background" or "Failed to start".
function Start-WithTimeout {
    param([string]$Exe, [string]$Arguments, [double]$Minutes)
    $proc = Start-Process -FilePath $Exe -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    if (-not $proc) { return "Failed to start" }
    if ($proc.WaitForExit([int]($Minutes * 60 * 1000))) { return "Completed" }
    return "Still running in background"
}

function Get-PendingReboot {
    $r = @()
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $r += "Windows servicing" }
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $r += "Windows Update" }
    $pfr = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations).PendingFileRenameOperations
    if ($pfr) { $r += "Pending file operations" }
    return $r
}

# Size of a folder tree without following junctions/symlinks (Windows.old contains
# links that point back to live folders such as C:\Users).
function Get-TreeSize {
    param([string]$Path)
    $total = 0.0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $entries = ([IO.DirectoryInfo]$d).GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($e.Attributes -band [IO.FileAttributes]::Directory) { $stack.Push($e.FullName) }
            else { $total += [double]$e.Length }
        }
    }
    return $total
}

# Deletes an old-Windows/upgrade folder that Disk Cleanup did not remove.
# Only the fixed folder names below are allowed. Links inside the folder are removed
# first, so taking ownership and deleting can never reach live folders like C:\Users.
function Remove-UpgradeFolder {
    param([string]$Path)
    $allowed = @("$Drive\Windows.old", "$Drive\`$WINDOWS.~BT", "$Drive\`$Windows.~WS", "$Drive\`$GetCurrent")
    if ($allowed -notcontains $Path) { return "Refused (path not allowed)" }
    if (-not (Test-Path -LiteralPath $Path)) { return "Removed" }
    $cmd = "$env:SystemRoot\System32\cmd.exe"

    for ($pass = 0; $pass -lt 3; $pass++) {
        $links = @(& $cmd /c "dir /AL /S /B `"$Path`"" 2>$null | Where-Object { $_ })
        if ($links.Count -eq 0) { break }
        # Shortest paths first, so an outer link is removed before anything reached through it.
        foreach ($l in @($links | Sort-Object Length)) {
            if (-not $l.StartsWith($Path + "\", [StringComparison]::OrdinalIgnoreCase)) { continue }
            # Skip anything reached through another link (it disappears when that link is removed).
            $throughLink = $false
            $parent = Split-Path $l -Parent
            while ($parent -and $parent.Length -gt $Path.Length) {
                $pa = ([IO.FileInfo]$parent).Attributes
                if ([int]$pa -ne -1 -and ($pa -band [IO.FileAttributes]::ReparsePoint)) { $throughLink = $true; break }
                $parent = Split-Path $parent -Parent
            }
            if ($throughLink) { continue }
            # Attributes of the link itself (not its target).
            $a = ([IO.FileInfo]$l).Attributes
            if ([int]$a -eq -1 -or -not ($a -band [IO.FileAttributes]::ReparsePoint)) { continue }
            # rmdir on a folder link and del on a file link remove only the link, never its target.
            if ($a -band [IO.FileAttributes]::Directory) { & $cmd /c "rmdir `"$l`"" 2>$null | Out-Null }
            else { & $cmd /c "del /f /q /a `"$l`"" 2>$null | Out-Null }
        }
    }
    $left = @(& $cmd /c "dir /AL /S /B `"$Path`"" 2>$null | Where-Object { $_ })
    if ($left.Count -gt 0) { return "Stopped: $($left.Count) link(s) inside could not be removed safely" }

    # /D Y answers the takeown prompt on English Windows.
    & "$env:SystemRoot\System32\takeown.exe" /F $Path /R /A /D Y 2>&1 | Out-Null
    & "$env:SystemRoot\System32\icacls.exe" $Path /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
    & $cmd /c "rd /s /q `"$Path`"" 2>&1 | Out-Null

    if (Test-Path -LiteralPath $Path) { return "Partly removed (some files locked; restart and run again)" }
    return "Removed"
}

function Write-LocalLog {
    param([string]$Name, [string]$Text)
    try {
        $dir = Join-Path $env:ProgramData "ZDX\Logs"
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $file = Join-Path $dir "$Name.log"
        if ((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 2MB) {
            Move-Item -LiteralPath $file -Destination "$file.old" -Force
        }
        Add-Content -LiteralPath $file -Value ($Text + [Environment]::NewLine) -Encoding ASCII
        return $file
    } catch { return $null }
}

# ---------------- Discovery ----------------
$Context = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Disk = Get-DiskInfo
$FreeBefore = $Disk.Free
$DiskSize = $Disk.Size
$Profiles = @(Get-CimInstance Win32_UserProfile | Where-Object {
    -not $_.Special -and $_.LocalPath -and $_.LocalPath -like "$Drive\*" -and (Test-Path -LiteralPath $_.LocalPath)
})
$TempCutoff = (Get-Date).AddHours(-$TempFileAgeHours)
$Now = (Get-Date).AddDays(1)   # "delete everything" cutoff
$ServicingBusy = [bool](Get-Process -Name TiWorker -ErrorAction SilentlyContinue)
$PendingReboot = @(Get-PendingReboot)
if ($RunIfFreeAtOrBelowGB -le 0) { $ThresholdText = "Always run" }
else { $ThresholdText = "$RunIfFreeAtOrBelowGB GB free or less" }
$Proceed = ($RunIfFreeAtOrBelowGB -le 0) -or ($FreeBefore -le ($RunIfFreeAtOrBelowGB * 1GB))

# Old Windows installation and upgrade leftovers
$SetupBusy = [bool](Get-Process -Name SetupHost,SetupPrep -ErrorAction SilentlyContinue)
$UpgradeFolders = @()
foreach ($name in @("Windows.old", "`$WINDOWS.~BT", "`$Windows.~WS", "`$GetCurrent")) {
    $path = "$Drive\$name"
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $gi = Get-Item -LiteralPath $path -Force
    $newest = $gi.CreationTime
    if ($gi.LastWriteTime -gt $newest) { $newest = $gi.LastWriteTime }
    $size = 0
    if ($Proceed) { $size = Get-TreeSize $path }
    $UpgradeFolders += [pscustomobject]@{
        Name = $name; Path = $path; AgeDays = [int]((Get-Date) - $newest).TotalDays
        Size = $size; Result = "Pending"
    }
}

# ---------------- Cleanup steps (fast first, slow last) ----------------

Invoke-CleanupStep "Windows temp and error reports" $CleanSystemTemp {
    Remove-OldItems "$env:SystemRoot\Temp" $TempCutoff
    foreach ($w in @("ReportArchive","ReportQueue","Temp")) {
        Remove-OldItems "$env:ProgramData\Microsoft\Windows\WER\$w" $Now
    }
    if ($ServicingBusy) {
        Set-StepNote "CBS logs skipped (Windows servicing busy)"
    } else {
        $cbs = "$env:SystemRoot\Logs\CBS"
        $old = (Get-Date).AddDays(-7)
        Remove-MatchingFiles $cbs "*.cab" $old
        Remove-MatchingFiles $cbs "CbsPersist_*.log" $old
    }
}

Invoke-CleanupStep "User temp files (all profiles)" $CleanUserTemp {
    foreach ($p in $Profiles) {
        $l = Join-Path $p.LocalPath "AppData\Local"
        Remove-OldItems "$l\Temp" $TempCutoff
        Remove-OldItems "$l\Microsoft\Windows\INetCache" $TempCutoff
        Remove-OldItems "$l\CrashDumps" $Now
        Remove-OldItems "$l\Microsoft\Windows\WER" $Now
    }
    Set-StepNote "$($Profiles.Count) profile(s)"
}

Invoke-CleanupStep "Browser cache (Edge/Chrome)" $CleanBrowserCache {
    $browsers = @(
        @{ Name = "Edge";   Proc = "msedge"; Rel = "AppData\Local\Microsoft\Edge\User Data" },
        @{ Name = "Chrome"; Proc = "chrome"; Rel = "AppData\Local\Google\Chrome\User Data" }
    )
    $skipped = 0
    foreach ($b in $browsers) {
        $openSids = Get-RunningOwnerSids @($b.Proc)
        foreach ($p in $Profiles) {
            $root = Join-Path $p.LocalPath $b.Rel
            if (-not (Test-Path -LiteralPath $root)) { continue }
            if ($openSids -contains $p.SID) { $skipped++; continue }
            Remove-OldItems "$root\ShaderCache" $Now
            Remove-OldItems "$root\GrShaderCache" $Now
            $bProfiles = @(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object {
                $_.Name -eq "Default" -or $_.Name -like "Profile *" -or $_.Name -eq "Guest Profile"
            })
            foreach ($bp in $bProfiles) {
                foreach ($c in @("Cache","Code Cache","GPUCache")) {
                    Remove-OldItems (Join-Path $bp.FullName $c) $Now
                }
            }
        }
    }
    if ($skipped -gt 0) { Set-StepNote "$skipped browser profile(s) skipped (browser open)" }
}

Invoke-CleanupStep "Crash dump files" $CleanCrashDumps {
    $md = "$env:SystemRoot\MEMORY.DMP"
    if (Test-Path -LiteralPath $md) { Remove-OneFile (Get-Item -LiteralPath $md -Force) }
    Remove-OldItems "$env:SystemRoot\LiveKernelReports" $Now
    Remove-OldItems "$env:SystemRoot\Minidump" (Get-Date).AddDays(-$MinidumpAgeDays)
}

Invoke-CleanupStep "Recycle Bin (all users)" $CleanRecycleBin {
    $rb = "$Drive\`$Recycle.Bin"
    if (Test-Path -LiteralPath $rb) {
        foreach ($sidDir in @(Get-ChildItem -LiteralPath $rb -Directory -Force)) {
            Remove-OldItems $sidDir.FullName $Now @("desktop.ini")
        }
    }
}

Invoke-CleanupStep "Windows Update download cache" $CleanWindowsUpdateCache {
    if ($ServicingBusy) { Set-StepNote "Skipped (Windows servicing busy, update may be installing)"; return }
    $dl = "$env:SystemRoot\SoftwareDistribution\Download"
    if ($DryRun) { Remove-OldItems $dl $Now; return }
    $svcs = @("wuauserv","bits")
    $wasRunning = @($svcs | Where-Object { (Get-Service $_).Status -eq "Running" })
    Stop-Service -Name $svcs -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Remove-OldItems $dl $Now
    foreach ($s in $wasRunning) { Start-Service -Name $s -ErrorAction SilentlyContinue }
}

Invoke-CleanupStep "Delivery Optimization cache" $CleanDeliveryOptimization {
    $doPath = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
    $script:StepBytes = Get-FolderSize $doPath
    if ($DryRun) { return }
    if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) {
        Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue | Out-Null
    } else {
        Set-StepNote "Delivery Optimization cmdlet not available"
    }
}

Invoke-CleanupStep "Hibernation file" $DisableHibernation {
    $hf = "$Drive\hiberfil.sys"
    if (-not (Test-Path -LiteralPath $hf)) { Set-StepNote "Hibernation already off"; return }
    $script:StepBytes = [double](Get-Item -LiteralPath $hf -Force).Length
    if (-not $DryRun) { & "$env:SystemRoot\System32\powercfg.exe" /hibernate off | Out-Null }
    Set-StepNote "Hibernate and Fast Startup turned off"
}

Invoke-CleanupStep "System Restore storage cap" ($RestorePointMaxPercent -gt 0) {
    if ($DryRun) { Set-StepNote "Dry run: would cap restore points at $RestorePointMaxPercent% of $Drive"; return }
    $out = & "$env:SystemRoot\System32\vssadmin.exe" resize shadowstorage /For=$Drive /On=$Drive /MaxSize=$RestorePointMaxPercent% 2>&1 | Out-String
    if ($out -match '(?i)success') { Set-StepNote "Capped at $RestorePointMaxPercent% (oldest restore points removed if over the cap)" }
    elseif ($out -match '(?i)no items found|not found') { Set-StepNote "No restore point storage on $Drive" }
    else { Set-StepNote "vssadmin did not confirm the change" }
}

$CleanMgrState = "Not run"
Invoke-CleanupStep "Windows Disk Cleanup" $RunDiskCleanupTool {
    $budget = [Math]::Min($DiskCleanupTimeoutMinutes, (Get-MinutesLeft) - 3)
    if ($budget -lt 2) {
        Set-StepNote "Skipped (time budget of $MaxRuntimeMinutes min nearly used)"
        $script:CleanMgrState = "Skipped (time budget)"
        return
    }

    $exe = "$env:SystemRoot\System32\cleanmgr.exe"
    if (-not (Test-Path -LiteralPath $exe)) {
        # Fallback for builds without cleanmgr: component store cleanup only.
        if ($DryRun) { $script:CleanMgrState = "Dry run (DISM fallback)"; return }
        $dism = "$env:SystemRoot\System32\Dism.exe"
        $script:CleanMgrState = "DISM: " + (Start-WithTimeout $dism "/Online /Cleanup-Image /StartComponentCleanup /Quiet" $budget)
        Set-StepNote "cleanmgr not found; used DISM component cleanup"
        return
    }

    $vc = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
    $flag = "StateFlags0777"
    $handlers = @(
        "Update Cleanup", "Windows Upgrade Log Files", "Upgrade Discarded Files",
        "Temporary Setup Files", "Setup Log Files", "Device Driver Packages",
        "Downloaded Program Files", "Temporary Files", "Windows Error Reporting Files",
        "Delivery Optimization Files", "D3D Shader Cache", "Old ChkDsk Files",
        "Thumbnail Cache", "Internet Cache Files", "Feedback Hub Archive log files",
        "Diagnostic Data Viewer database files", "RetailDemo Offline Content", "BranchCache"
    )
    if ($CleanCrashDumps) { $handlers += "System error memory dump files" }

    $wo = @($UpgradeFolders | Where-Object { $_.Name -eq "Windows.old" })
    if ($wo.Count -gt 0 -and $RemoveOldWindowsInstall -and $wo[0].AgeDays -ge $WindowsOldMinDays) {
        $handlers += "Previous Installations"
        Set-StepNote "Windows.old included"
    }

    if ($DryRun) { Set-StepNote "Dry run: Disk Cleanup not started"; $script:CleanMgrState = "Dry run"; return }

    # Clear any old selection under this ID, then select only our handlers.
    Get-ChildItem -LiteralPath $vc | ForEach-Object { Remove-ItemProperty -LiteralPath $_.PSPath -Name $flag -ErrorAction SilentlyContinue }
    foreach ($h in $handlers) {
        $k = Join-Path $vc $h
        if (Test-Path -LiteralPath $k) { New-ItemProperty -LiteralPath $k -Name $flag -Value 2 -PropertyType DWord -Force | Out-Null }
    }

    $script:CleanMgrState = Start-WithTimeout $exe "/sagerun:777" $budget
    if ($script:CleanMgrState -eq "Completed") {
        Get-ChildItem -LiteralPath $vc | ForEach-Object { Remove-ItemProperty -LiteralPath $_.PSPath -Name $flag -ErrorAction SilentlyContinue }
    } elseif ($script:CleanMgrState -eq "Still running in background") {
        Set-StepNote "Still running after $([int]$budget) min; more space will be freed when it finishes"
    }
}

# Removes whatever Disk Cleanup left behind (or everything, if Disk Cleanup did not run).
Invoke-CleanupStep "Old Windows install (Windows.old)" ($UpgradeFolders.Count -gt 0) {
    foreach ($f in $UpgradeFolders) {
        if (-not (Test-Path -LiteralPath $f.Path)) { $f.Result = "Removed by Disk Cleanup"; continue }
        if (-not $RemoveOldWindowsInstall) { $f.Result = "Kept (disabled in settings)"; continue }
        if ($f.AgeDays -lt $WindowsOldMinDays) { $f.Result = "Kept ($($f.AgeDays) days old, rollback still possible)"; continue }
        if ($SetupBusy) { $f.Result = "Skipped (Windows upgrade is running)"; continue }
        if ($CleanMgrState -eq "Still running in background") { $f.Result = "Skipped (Disk Cleanup is still removing it)"; continue }
        if ($DryRun) { $f.Result = "Would remove"; $script:StepBytes += $f.Size; continue }
        if ((Get-MinutesLeft) -lt 8) { $f.Result = "Skipped (time budget); run again"; continue }
        $f.Result = Remove-UpgradeFolder $f.Path
        if ($f.Result -eq "Removed") { $script:StepBytes += $f.Size }
    }
    Set-StepNote "$($UpgradeFolders.Count) folder(s) checked"
}
if (-not $Proceed) { foreach ($f in $UpgradeFolders) { $f.Result = "Present (cleanup not run, above threshold)" } }

# ---------------- Results ----------------
$Disk = Get-DiskInfo
$FreeAfter = $Disk.Free
$TotalFreed = [Math]::Max(0, $FreeAfter - $FreeBefore)
$FoundTotal = ($Steps | Measure-Object Found -Sum).Sum
$FilesTotal = ($Steps | Measure-Object Files -Sum).Sum
if (-not $FoundTotal) { $FoundTotal = 0 }
if (-not $FilesTotal) { $FilesTotal = 0 }
if ($DiskSize -gt 0) {
    $PctBefore = [Math]::Round(($FreeBefore / $DiskSize) * 100, 1)
    $PctAfter = [Math]::Round(($FreeAfter / $DiskSize) * 100, 1)
} else { $PctBefore = 0; $PctAfter = 0 }

if ($PctAfter -ge 15) { $Status = "HEALTHY" }
elseif ($PctAfter -ge 10) { $Status = "OK" }
elseif ($PctAfter -ge 5) { $Status = "LOW" }
else { $Status = "CRITICAL" }
if ($DryRun) { $Status = "DRY RUN (current: $Status)" }
if (-not $Proceed) {
    $Status = "NO ACTION NEEDED"
    $CleanMgrState = "Not needed"
    Add-Finding "INFO" "Free space $(Format-Size $FreeBefore) is above the $RunIfFreeAtOrBelowGB GB threshold. No cleanup was done."
}

if ($PendingReboot.Count -gt 0) {
    Add-Finding "INFO" "Restart pending ($($PendingReboot -join ', ')). A restart can free more space and lets update cleanup finish."
}
if ($Proceed -and $ServicingBusy) { Add-Finding "INFO" "Windows servicing (TiWorker) was running; update-related cleanup was limited. Run again later for more space." }
if ($CleanMgrState -eq "Still running in background") { Add-Finding "INFO" "Disk Cleanup is still running. Re-check free space in 30-60 minutes." }
foreach ($f in $UpgradeFolders) {
    if ($Proceed -and -not $DryRun -and $f.Result -notmatch '^Removed') {
        Add-Finding "INFO" "$($f.Path) ($(Format-Size $f.Size)) was not removed: $($f.Result)."
    }
}

# ---------------- Deep report: where is the remaining space? ----------------
$ProfileLines = @()
$BigFileLines = @()
$StaleLines = @()
$OneDriveLines = @()
if ($Proceed -and $PctAfter -lt 15 -and -not $DryRun) {
    Add-Finding "WARNING" "Free space is still below 15% after cleanup. Remaining space is likely user data or applications."
    if ($DeepReportWhenLow -and $Profiles.Count -gt 0) {
        if ((Get-MinutesLeft) -lt 4) {
            Add-Finding "INFO" "Detailed space report skipped to stay inside the $MaxRuntimeMinutes minute time budget."
        } else {
            $RecallMask = 0x400000 -bor 0x1000   # cloud-only (not stored locally) / offline
            $BigBytes = $BigFileGB * 1GB
            $big = New-Object System.Collections.ArrayList
            $stats = @()
            foreach ($p in $Profiles) {
                $root = $p.LocalPath
                $dl = Join-Path $root "Downloads"
                $odRoots = @(Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { $_.Name -like "OneDrive*" } | ForEach-Object { $_.FullName })
                $total = 0.0; $dlSize = 0.0; $odSize = 0.0
                Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
                    if ([int]$_.Attributes -band $RecallMask) { return }   # cloud-only file, uses no local space
                    $len = [double]$_.Length
                    $total += $len
                    $fp = $_.FullName
                    if ($fp.StartsWith($dl + "\", [StringComparison]::OrdinalIgnoreCase)) { $dlSize += $len }
                    foreach ($od in $odRoots) { if ($fp.StartsWith($od + "\", [StringComparison]::OrdinalIgnoreCase)) { $odSize += $len; break } }
                    if ($len -ge $BigBytes) { [void]$big.Add([pscustomobject]@{ Path = $fp; Size = $len; Modified = $_.LastWriteTime }) }
                }
                $lastUse = $null
                if ($p.LastUseTime) { $lastUse = [datetime]$p.LastUseTime }
                $stats += [pscustomobject]@{
                    Path = $root; Total = $total; Downloads = $dlSize; OneDrive = $odSize
                    Loaded = [bool]$p.Loaded; LastUse = $lastUse
                }
            }

            foreach ($s in @($stats | Sort-Object Total -Descending | Select-Object -First 5)) {
                $ProfileLines += "$($s.Path) : $(Format-Size $s.Total) (Downloads: $(Format-Size $s.Downloads), OneDrive local: $(Format-Size $s.OneDrive))"
            }
            foreach ($s in @($stats | Where-Object { $_.OneDrive -ge 5GB } | Sort-Object OneDrive -Descending)) {
                $OneDriveLines += "$($s.Path) : $(Format-Size $s.OneDrive) of OneDrive files stored on this PC"
            }
            foreach ($f in @($big | Sort-Object Size -Descending | Select-Object -First 10)) {
                $BigFileLines += "$(Format-Size $f.Size) : $($f.Path) (modified $($f.Modified.ToString('yyyy-MM-dd')))"
            }
            foreach ($s in @($stats | Where-Object { -not $_.Loaded -and $_.LastUse -and $_.LastUse -lt (Get-Date).AddDays(-$StaleProfileDays) } | Sort-Object Total -Descending)) {
                $StaleLines += "$($s.Path) : $(Format-Size $s.Total), last used $($s.LastUse.ToString('yyyy-MM-dd'))"
            }

            if ($OneDriveLines.Count -gt 0) {
                Add-Finding "INFO" "Large OneDrive folders are stored locally. Ask the user to right-click the OneDrive folder and choose 'Free up space'."
            }
            if ($StaleLines.Count -gt 0) {
                Add-Finding "INFO" "$($StaleLines.Count) profile(s) unused for $StaleProfileDays+ days. Review and remove them through System Properties if no longer needed."
            }
            if ($BigFileLines.Count -gt 0) {
                Add-Finding "INFO" "Large files found in user profiles. Ask the user whether they can be deleted or moved to OneDrive."
            }
        }
    }
}

$Elapsed = [int]((Get-Date) - $StartTime).TotalSeconds

$Lines = @(
"============================================================",
"Disk Space Cleanup ($Drive)",
"============================================================",
"",
"Version : $Version",
"Execution Time : $($StartTime.ToString('yyyy-MM-dd HH:mm:ss'))",
"Execution Context : $Context",
"Dry Run : $DryRun",
"Run Threshold : $ThresholdText",
"Profiles Processed : $(if($Proceed){$Profiles.Count}else{0})",
"Restart Pending : $(if($PendingReboot.Count -gt 0){'Yes (' + ($PendingReboot -join ', ') + ')'}else{'No'})",
"",
"Disk Summary",
"------------",
"Disk Size : $(Format-Size $DiskSize)",
"Free Before : $(Format-Size $FreeBefore) ($PctBefore%)",
"Free After : $(Format-Size $FreeAfter) ($PctAfter%)",
"Space Freed : $(Format-Size $TotalFreed)",
"Files Removed : $FilesTotal ($(Format-Size $FoundTotal))",
"Disk Cleanup Tool : $CleanMgrState",
"",
"Old Windows Installation",
"------------------------"
)

if ($UpgradeFolders.Count -eq 0) { $Lines += "None found." }
foreach ($f in $UpgradeFolders) {
    if ($Proceed) { $Lines += "$($f.Path) : $(Format-Size $f.Size), $($f.AgeDays) days old -> $($f.Result)" }
    else { $Lines += "$($f.Path) : $($f.AgeDays) days old -> $($f.Result)" }
}

$Lines += ""
$Lines += "Cleanup Steps"
$Lines += "-------------"

if (-not $Proceed) { $Lines += "Not run. Free space is above the threshold." }

foreach ($s in $Steps) {
    if ($s.Note -eq "Disabled in settings") {
        $Lines += "$($s.Name) : Disabled"
        continue
    }
    if ($DryRun) { $line = "$($s.Name) : would free $(Format-Size $s.Found)" }
    else { $line = "$($s.Name) : freed $(Format-Size $s.Freed)" }
    if ($s.Files -gt 0) { $line += ", $($s.Files) file(s)" }
    $line += ", $($s.Seconds)s"
    if ($s.Note) { $line += " [$($s.Note)]" }
    $Lines += $line
}

if ($ProfileLines.Count -gt 0) {
    $Lines += ""
    $Lines += "Largest User Profiles (local files only)"
    $Lines += "----------------------------------------"
    $Lines += $ProfileLines
}
if ($OneDriveLines.Count -gt 0) {
    $Lines += ""
    $Lines += "OneDrive Files Stored Locally (5 GB+)"
    $Lines += "-------------------------------------"
    $Lines += $OneDriveLines
}
if ($BigFileLines.Count -gt 0) {
    $Lines += ""
    $Lines += "Largest Files In User Profiles ($BigFileGB GB+, top 10)"
    $Lines += "-------------------------------------------------"
    $Lines += $BigFileLines
}
if ($StaleLines.Count -gt 0) {
    $Lines += ""
    $Lines += "Profiles Unused For $StaleProfileDays+ Days (not deleted)"
    $Lines += "-----------------------------------------------"
    $Lines += $StaleLines
}

$Lines += ""
$Lines += "Findings"
$Lines += "--------"
if ($Findings.Count -eq 0) { $Lines += "None." } else { $Lines += $Findings }

$Lines += ""
$Lines += "Disk Status : $Status"
$Lines += "Duration : $Elapsed seconds"
$Lines += ""
$Lines += "NOTE: User documents, Desktop, Downloads, browser cookies, passwords and history were not touched."
$Lines += "NOTE: 'Space Freed' is measured from real free space before and after each step."
$Lines += "============================================================"

$Output = $Lines -join [Environment]::NewLine

if ($WriteLocalLog) { [void](Write-LocalLog "Disk_Space_Cleanup" $Output) }

# Same ZDX output/result API pattern as the working Employee Experience Health Check.
Set-ZOutput $Output
if (-not $Proceed) {
    Set-ZResult -Status Success -Message "Disk Space Cleanup: no action needed. Free space $(Format-Size $FreeBefore) is above $RunIfFreeAtOrBelowGB GB."
} else {
    Set-ZResult -Status Success -Message "Disk Space Cleanup completed. Freed $(Format-Size $TotalFreed). Free now $(Format-Size $FreeAfter) ($PctAfter%)."
}
