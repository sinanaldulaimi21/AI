ZDX Remediation Scripts v2.0

Both scripts:
- MAKE CHANGES on the device (unlike the v1.4 diagnostics, which are read only).
- Use the same ZDX output pattern as v1.4: Set-ZOutput $Output / Set-ZResult -Status Success.
- Must be run with Elevated Permissions (System Account).
- Have a Settings block at the top. Change settings BEFORE signing.
- Set $DryRun = $true to test: the script reports what it would do and changes nothing.
- Save a copy of every run's output on the device: C:\ProgramData\ZDX\Logs\<script>.log
- Must be signed after any edit. Do not edit after signing.
- The signing certificate must be in Local Machine > Trusted Publishers on every device.

Teams_Cache_Reset_v2.0.ps1
- Finds the logged-on user and their Teams cache (new Teams and classic Teams).
- Does nothing to Teams if the user is in a Teams call (mic/camera in use).
- Closes Teams for that user only, renames the cache to MSTeams.bak_<date> (backup kept),
  deletes older backups, reopens Teams if it was open, and confirms the cache was rebuilt.
- NEW: Repairs the Outlook "Teams Meeting" add-in (re-enables it and stops Outlook from
  auto-disabling it). Takes effect the next time Outlook starts.
- NEW: Teams health report: app version and package status, WebView2 runtime,
  crashes/hangs in the last 7 days.
- User may need to sign in to Teams again.
- Rollback: close Teams, delete the new MSTeams folder, rename the .bak_ folder back.

Disk_Space_Cleanup_v2.0.ps1
- Runs only if C: has 20 GB free or less ($RunIfFreeAtOrBelowGB, 0 = always run).
  Above that, it changes nothing and reports "NO ACTION NEEDED".
- Cleans: Windows temp, WER reports, old CBS logs, all users' temp/INetCache/crash dumps,
  Edge/Chrome cache (not cookies/passwords/history), crash dumps, Recycle Bin (all users),
  Windows Update download cache, Delivery Optimization cache, and Windows Disk Cleanup
  (update cleanup, setup files, old drivers, Windows.old if older than 10 days).
- Never touches Documents, Desktop, Downloads or other user files.
- Reports free space before/after and space freed per step.
- NEW: Time budget ($MaxRuntimeMinutes, default 40). Disk Cleanup is shortened or skipped
  so the script always returns its output to ZDX.
- NEW: Uses DISM component cleanup if cleanmgr is not available on the device.
- NEW: Old Windows installation: measures Windows.old and upgrade leftovers
  ($WINDOWS.~BT, $Windows.~WS, $GetCurrent) and shows their size. If Disk Cleanup did not
  remove them, deletes them directly (links inside are removed first so nothing outside
  the folder is touched). Kept if newer than $WindowsOldMinDays (default 10) or while a
  Windows upgrade is running. Set $WindowsOldMinDays = 0 to always remove.
- NEW: Reports a pending restart (a restart can free more space).
- NEW: If still below 15% free, a deeper report lists (nothing is deleted):
    - 5 largest profiles, with Downloads and locally stored OneDrive size
    - OneDrive folders with 5 GB+ stored locally (user can "Free up space")
    - top 10 files of 1 GB+ in user profiles
    - profiles unused for 90+ days
- Optional (off by default): $DisableHibernation frees hiberfil.sys but turns off hibernate.
- Optional (off by default): $RestorePointMaxPercent caps System Restore storage (e.g. 5).

Test first: run both with $DryRun = $true on a pilot device, then with $DryRun = $false.
Check total run time against your ZDX script timeout and set $MaxRuntimeMinutes below it.
