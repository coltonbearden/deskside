# DECISIONS

Format: `D-NNN (date) — decision — rationale — consequences`.

## D-001 (2026-11-19) — A public repo, MIT, named deskside

The owner chose the repo's visibility ("Public (Recommended)"), its name ("deskside", offered with housecall and
fieldkit) and its licence ("MIT", offered with Apache-2.0 and GPL-3.0, none marked recommended because it's a legal
choice). Consequence: nothing personal or about the owner's network may enter the repo or its history; a
personal-data scan and gitleaks run in the pre-commit hook and in CI.

## D-002 (2026-11-19) — Remote access is MeshCentral; Claude Code runs on the helper's machine over SSH

The owner chose "MeshCentral on your homelab" (over Tailscale + RustDesk + SSH and Quick Assist only) and "From your
machine, over SSH (Recommended)" for where Claude Code runs. Consequence: OpenSSH Server on the PC listens on
127.0.0.1 only and takes keys only; it's reached through MeshCmd's `route` action, so SSH is never open on anyone's
home network. Claude Code is in no install profile, and is never signed in on someone else's PC (Anthropic's consumer
terms forbid sharing an account).

## D-003 (2026-11-19) — Safety lives in the scripts, not in Claude Code settings

Every change script runs `Assert-NotManaged` and `Assert-Consent` first, supports `-WhatIf`, saves before-state and
ships its undo. The console's `.claude/settings.json` holds only `$schema`. Consequence: the scripts are safe whoever
runs them; the tests check every change script has both gates and `SupportsShouldProcess`.

## D-004 (2026-11-19) — Windows' built-in local enrollments don't count as device management

Every PC carries enrollments under `HKLM:\SOFTWARE\Microsoft\Enrollments` from providers "Local Authority", "Deploy
Authority" and "Cloud Authority" (found on the development machine, which no organization manages). Counting them
made every PC look like a work PC. Consequence: those providers (and `WMI_Bridge_Server`) are skipped; any other
active provider, or any row with a UPN, still stops deskside.

## D-005 (2026-11-19) — The everyone profile, as the owner marked it

[Colton's choice, 2026-11-19] Apps: "Winget-AutoUpdate, 7-Zip, VLC, Bitwarden" and "Google Chrome, Sumatra PDF for the
PDF reader app. Chrome is the default browser." Settings: restore points on, block unwanted apps, SmartScreen on,
restart notice, show file extensions, Storage Sense on, ads and tips off. Not chosen: Adobe Acrobat Reader, the
OneDrive folder-backup offer. Consequence: `catalog/profiles/everyone.json` holds exactly these (a test pins the
list). Windows 11 protects default-app choices from scripts, so set-up opens Settings > Default apps for the person to
pick Chrome and SumatraPDF rather than working around that protection.

## D-006 (2026-11-19) — App updates on family PCs belong to Winget-AutoUpdate

Nothing installed is pinned; Winget-AutoUpdate (MIT) updates winget apps daily, notifies only on errors, runs in user
and system context and updates itself. Consequence: the health check reads its task's last result, and a failure
reaches the helper through the health sweep.

## D-007 (2026-11-19) — Windows Sandbox's limits, and the fallbacks they forced

Proven in a capability spike: winget is absent in Sandbox and Microsoft's documented repair (NuGet provider,
Microsoft.WinGet.Client, `Repair-WinGetPackageManager`) installs it in about 40 s; winget's `msstore` source fails
there, so every winget call names `--source winget`; Windows' OpenSSH Server optional feature can't install
(0x80072ee6, no feature source), so `Enable-LoopbackSsh.ps1` falls back to winget's `Microsoft.OpenSSH.Preview`
(Microsoft's Win32-OpenSSH MSI); Defender, BitLocker and battery data aren't available. Consequence: those sections
are covered by mocked tests and named in STATE.md as proved on the first real PC.

## D-008 (2026-11-19) — Records and the device list live in a private repo

[Colton's choice, 2026-11-19] "Private GitHub repo (Recommended)". Consequence: `coltonbearden/deskside-records`
(private) holds `devices.json`, `meshcentral.json` and every run pulled back from a PC; the console and the health
sweep both write to it.

## D-009 (2026-11-19) — The health sweep runs beside the MeshCentral server

[Colton's choice, 2026-11-19] "Server's node (Recommended)". The sweep uses MeshCentral's run-command with the
automation login, not SSH, because the helper's SSH key lives in an interactive password-manager agent that an
unattended job can't use. Consequence: `health/Invoke-HealthSweep.ps1` and `catalog/alerts.json` ship here; the server
side (schedule, secrets, monitor) is set up by the homelab's own stack repo.

## D-010 (2026-11-19) — Windows support dates are data with a read date

Copied from Microsoft's Windows 11 Home and Pro lifecycle page and the Windows 10 ESU page on 2026-11-19 into
`catalog/lifecycle.json` (`readOn`). Consequence: the check reports its own table as possibly out of date after 180
days, so stale dates can't silently mislead.

## D-011 (2026-11-20) — One-click help is MeshCentral Assistant, monitor-only, refreshed by deskside

[Colton's choice, 2026-11-20] "Write a deskside follow-up" (one-click Request Help, a notice over SSH). Assistant has
no release of its own and no installer; its binary ships inside MeshCentral (agent id 10006), Apache-2.0, Intel. Only
the server's *System tray, monitor only* download (`ac=4`, read in MeshCentral 1.3.1's `webserver.js`) carries no
server settings and attaches to the installed agent; any other kind runs its own agent with its own, unpatched relay
code. [Claude's call] Its own update asks the person and can't write to Program Files, so it runs with `-noupdate` and
a weekly SYSTEM task re-downloads it from the server (the server is its source; the stack's update job keeps the server
current). Consequence: `Install-HelpButton.ps1`, `Ask-ForHelp.ps1`, `Update-HelpButton.ps1`; diagnose's
`help.refresh-failing` and the sweep's `help-button-stale`; removal takes every piece, each profile's setting included.

## D-012 (2026-11-20) — A message on the PC's screen whenever the helper works over SSH

MeshCentral's port map shows nothing on the PC. [Claude's call] `WTSSendMessage` (wtsapi32, every Windows edition,
callable from Windows PowerShell 5.1; `msg.exe` is the same call but documented for no edition) from the elevated
session-0 SSH login reaches every signed-in session; the Sandbox spike showed sshd sets `SSH_CONNECTION` and a SYSTEM
task sees none. Windows queues a session's messages (a second box waited for the first to close, measured on the
T14 2026-11-20), so both close themselves after 5 minutes and the End message follows the Start one. The console sends
Start before a run or shell and End after; the PC enforces it too, since
`New-DesksideRun` sends Start itself for an SSH run the console didn't announce and records `data.notice`. The
consent wording promises only that: nothing appears when nobody is signed in (the record says so), a dropped link can
lose the End message, and the scheduled check (SYSTEM, run-command) shows nothing. Consequence: `Send-HelperNotice.ps1`,
the console's `Send-RemoteNotice`; the helper's name is `helperName` in the private store, never this repo.

## D-013 (2026-11-20) — The console names its key: deskside-ssh with IdentitiesOnly

1Password's agent holds eleven keys here and an OpenSSH server stops after `MaxAuthTries` 6. The console writes the
`deskside-ssh` public key (`sshPublicKeyRef` in the private store) to `%LOCALAPPDATA%\deskside\deskside-ssh.pub` and
passes it with `IdentitiesOnly=yes`, 1Password's documented way to pick a key. The Sandbox proof's throwaway key path
(`DESKSIDE_SSH_IDENTITY`) stays, and one host step uses the real key.
