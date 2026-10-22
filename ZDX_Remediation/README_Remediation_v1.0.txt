ZDX Remediation Scripts v1.0

Both scripts:
- MAKE CHANGES on the device (unlike the v1.4 diagnostics, which are read only).
- Use the same ZDX output pattern as v1.4: Set-ZOutput $Output / Set-ZResult -Status Success.
- Must be run with Elevated Permissions (System Account).
- Have a Settings block at the top. Change settings BEFORE signing.
- Set $DryRun = $true to test: the script reports what it would do and changes nothing.
- Must be signed after any edit. Do not edit after signing.

Teams_Cache_Reset_v1.0.ps1
- Finds the logged-on user and their Teams cache (new Teams and classic Teams).
- Does nothing if the user is in a Teams call (mic/camera in use).
- Closes Teams for that user only, renames the cache to MSTeams.bak_<date> (backup kept),
  deletes older backups, and reopens Teams if it was open before.
- User may need to sign in to Teams again.
- Rollback: close Teams, delete the new MSTeams folder, rename the .bak_ folder back.

Disk_Space_Cleanup_v1.0.ps1
- Cleans: Windows temp, WER reports, old CBS logs, all users' temp/INetCache/crash dumps,
  Edge/Chrome cache (not cookies/passwords/history), crash dumps, Recycle Bin (all users),
  Windows Update download cache, Delivery Optimization cache, and Windows Disk Cleanup
  (update cleanup, setup files, old drivers, Windows.old if older than 10 days).
- Never touches Documents, Desktop, Downloads or other user files.
- Reports free space before/after and space freed per step.
- If still below 15% free, lists the 5 largest user profiles and their Downloads size.
- Optional (off by default): $DisableHibernation frees hiberfil.sys but turns off hibernate.

Test first: run both with $DryRun = $true on a pilot device, then with $DryRun = $false.
Check how long Disk Cleanup takes against your ZDX script timeout. If it is too long,
lower $DiskCleanupTimeoutMinutes. Disk Cleanup keeps running in the background after
the timeout and the script still returns its output.
