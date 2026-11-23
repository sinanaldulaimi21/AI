Disk Space Cleanup - Tanium Package (v1.0)
Created by: Sinan Aldulaimi

Same cleanup as ZDX Disk Space Cleanup v2.1, adapted for Tanium:
- No 5-minute limit: Windows Disk Cleanup and Windows.old removal finish in the same run
  (waits up to 30 min; script budget 45 min).
- Runs only if C: has 20 GB free or less ($RunIfFreeAtOrBelowGB).
- Never touches Documents, Desktop, Downloads, passwords or browsing history.
- Stops and changes nothing if not running as SYSTEM (Tanium runs packages as SYSTEM).

1. Create the package
   - Package name : EllisDon - Disk Space Cleanup v1.0
   - File         : Disk_Space_Cleanup_Tanium_v1.0.ps1 (signed copy if your policy requires it)
   - Command      : cmd.exe /d /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File Disk_Space_Cleanup_Tanium_v1.0.ps1
   - Timeout      : 60 minutes
   - Platform     : Windows

2. Pilot
   - Deploy to 1-2 of the LowDisk devices first (e.g. WS1V0ZQV3).
   - Check the action log / exit code: 0 = ran (see Status), 1 = not SYSTEM, nothing done.
   - Full report on the device: C:\ProgramData\ZDX_Remediation\Logs\Disk_Space_Cleanup.log
     Step-by-step progress:     C:\ProgramData\ZDX_Remediation\Logs\Disk_Space_Cleanup_progress.log

3. Deploy to the remaining LowDisk devices
   - Target with the Get-WindowsUpdate-Health sensor = LowDisk (or the device list).

4. Report results across devices (Tanium question)
   Use the "Registry Value Data" sensor on HKLM\SOFTWARE\EllisDon\DiskSpaceCleanup:
   - Status       HEALTHY / OK / LOW / CRITICAL / NO ACTION NEEDED / NOT RUN - NEEDS SYSTEM
   - FreeBeforeGB free space before the run
   - FreeAfterGB  free space after the run
   - FreedGB      space freed
   - DiskCleanup  Completed / Still running in background / Not needed
   - LastRun      date and time of the run
   Then re-check Get-WindowsUpdate-Health: devices no longer LowDisk can take the
   Windows Update fix package.

Notes
- To make it run on devices with more free space, set $RunIfFreeAtOrBelowGB higher
  (or 0 = always) before signing.
- $DryRun = $true reports what it would do without changing anything.
- Any edit after signing breaks the signature.
