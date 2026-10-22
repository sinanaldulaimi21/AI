# ZDX Disk Space Cleanup (System Drive)
# Version 1.1 - REMEDIATION (makes changes) - ASCII
# Frees as much space as safely possible on the system drive (C:).
# Runs only when free space is at or below $RunIfFreeAtOrBelowGB.
# Never touches user documents, Desktop, Downloads, cookies, passwords or history.
# Run with Elevated Permissions (System Account).

$ErrorActionPreference = "SilentlyContinue"
$Version = "1.1"

# ---------------- Settings ----------------
$DryRun                    = $false  # $true = measure only, delete nothing
$RunIfFreeAtOrBelowGB      = 20      # clean only if C: free space is this many GB or less (0 = always run)
$TempFileAgeHours          = 24      # temp files newer than this are kept (protects running installs)
$CleanSystemTemp           = $true   # Windows\Temp, WER reports, old CBS logs
$CleanUserTemp             = $true   # every profile: Temp, INetCache, CrashDumps, WER
$CleanBrowserCache         = $true   # Edge/Chrome cache only; skipped for a user whose browser is open
$CleanRecycleBin           = $true   # empties the Recycle Bin for ALL users on this drive
$CleanCrashDumps           = $true   # MEMORY.DMP, LiveKernelReports, minidumps older than $MinidumpAgeDays
$MinidumpAgeDays           = 30
$CleanWindowsUpdateCache   = $true   # SoftwareDistribution\Download
$CleanDeliveryOptimization = $true   # Delivery Optimization cache
$RunDiskCleanupTool        = $true   # cleanmgr: update cleanup, setup files, old drivers, etc.
$RemoveOldWindowsInstall   = $true   # Windows.old, only if older than $WindowsOldMinDays (removes rollback)
$WindowsOldMinDays         = 10
$DiskCleanupTimeoutMinutes = 25      # if cleanmgr runs longer, it keeps running in the background
$DisableHibernation        = $false  # frees hiberfil.sys but turns off hibernate and Fast Startup
$ReportLargestProfiles     = $true   # if still low after cleanup, list the biggest user profiles
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
if ($RunIfFreeAtOrBelowGB -le 0) { $ThresholdText = "Always run" }
else { $ThresholdText = "$RunIfFreeAtOrBelowGB GB free or less" }
$Proceed = ($RunIfFreeAtOrBelowGB -le 0) -or ($FreeBefore -le ($RunIfFreeAtOrBelowGB * 1GB))

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

$CleanMgrState = "Not run"
Invoke-CleanupStep "Windows Disk Cleanup (cleanmgr)" $RunDiskCleanupTool {
    $exe = "$env:SystemRoot\System32\cleanmgr.exe"
    if (-not (Test-Path -LiteralPath $exe)) { Set-StepNote "cleanmgr.exe not found"; $script:CleanMgrState = "Not available"; return }

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

    $wo = "$Drive\Windows.old"
    if (Test-Path -LiteralPath $wo) {
        $age = [int]((Get-Date) - (Get-Item -LiteralPath $wo -Force).CreationTime).TotalDays
        if (-not $RemoveOldWindowsInstall) {
            Set-StepNote "Windows.old kept (disabled in settings)"
        } elseif ($age -ge $WindowsOldMinDays) {
            $handlers += "Previous Installations"
            Set-StepNote "Windows.old ($age days old) included"
        } else {
            Set-StepNote "Windows.old kept (only $age days old, rollback still possible)"
        }
    }

    if ($DryRun) { Set-StepNote "Dry run: cleanmgr not started"; $script:CleanMgrState = "Dry run"; return }

    # Clear any old selection under this ID, then select only our handlers.
    Get-ChildItem -LiteralPath $vc | ForEach-Object { Remove-ItemProperty -LiteralPath $_.PSPath -Name $flag -ErrorAction SilentlyContinue }
    foreach ($h in $handlers) {
        $k = Join-Path $vc $h
        if (Test-Path -LiteralPath $k) { New-ItemProperty -LiteralPath $k -Name $flag -Value 2 -PropertyType DWord -Force | Out-Null }
    }

    $proc = Start-Process -FilePath $exe -ArgumentList "/sagerun:777" -WindowStyle Hidden -PassThru
    if ($proc -and $proc.WaitForExit($DiskCleanupTimeoutMinutes * 60 * 1000)) {
        $script:CleanMgrState = "Completed"
        Get-ChildItem -LiteralPath $vc | ForEach-Object { Remove-ItemProperty -LiteralPath $_.PSPath -Name $flag -ErrorAction SilentlyContinue }
    } elseif ($proc) {
        $script:CleanMgrState = "Still running in background"
        Set-StepNote "Still running after $DiskCleanupTimeoutMinutes min; more space will be freed when it finishes"
    } else {
        $script:CleanMgrState = "Failed to start"
        Set-StepNote "cleanmgr failed to start"
    }
}

# ---------------- Results ----------------
$Disk = Get-DiskInfo
$FreeAfter = $Disk.Free
$TotalFreed = [Math]::Max(0, $FreeAfter - $FreeBefore)
$FoundTotal = ($Steps | Measure-Object Found -Sum).Sum
$FilesTotal = ($Steps | Measure-Object Files -Sum).Sum
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

if ($ServicingBusy) { Add-Finding "INFO" "Windows servicing (TiWorker) was running; update-related cleanup was limited. Run again later for more space." }
if ($CleanMgrState -eq "Still running in background") { Add-Finding "INFO" "Disk Cleanup is still running. Re-check free space in 30-60 minutes." }

$LargestLines = @()
if ($Proceed -and $PctAfter -lt 15 -and -not $DryRun) {
    Add-Finding "WARNING" "Free space is still below 15% after cleanup. Remaining space is likely user data or applications."
    if ($ReportLargestProfiles -and $Profiles.Count -gt 0) {
        $sizes = foreach ($p in $Profiles) {
            [pscustomobject]@{
                Path      = $p.LocalPath
                Total     = Get-FolderSize $p.LocalPath
                Downloads = Get-FolderSize (Join-Path $p.LocalPath "Downloads")
            }
        }
        foreach ($s in @($sizes | Sort-Object Total -Descending | Select-Object -First 5)) {
            $LargestLines += "$($s.Path) : $(Format-Size $s.Total) (Downloads: $(Format-Size $s.Downloads))"
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
"Cleanup Steps",
"-------------"
)

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

if ($LargestLines.Count -gt 0) {
    $Lines += ""
    $Lines += "Largest User Profiles (approximate)"
    $Lines += "-----------------------------------"
    $Lines += $LargestLines
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

# Same ZDX output/result API pattern as the working Employee Experience Health Check.
Set-ZOutput $Output
if (-not $Proceed) {
    Set-ZResult -Status Success -Message "Disk Space Cleanup: no action needed. Free space $(Format-Size $FreeBefore) is above $RunIfFreeAtOrBelowGB GB."
    return
}
Set-ZResult -Status Success -Message "Disk Space Cleanup completed. Freed $(Format-Size $TotalFreed). Free now $(Format-Size $FreeAfter) ($PctAfter%)."
