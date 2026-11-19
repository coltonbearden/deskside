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
