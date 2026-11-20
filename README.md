# deskside

**A safe, repeatable toolkit for looking after friends' and family's Windows PCs.**

When someone's new PC needs setting up, or an old one starts acting up, deskside gives you:

- **A plain-English health check.** One read-only command reports what's wrong, ranked *fix now*, *fix soon* and
  *nice to have*, each in a sentence anyone can understand: unsupported Windows, stuck updates, antivirus or firewall
  off, a failing or full disk, a worn battery, crashes, no backups, junk and trialware, and remote-control tools that
  scammers leave behind.
- **Safe, reversible setup.** Install profiles and a settings baseline live as data in [`catalog/`](catalog). Only
  what's missing is installed (always the latest version, through winget), every change records its before-state and
  ships its undo, and every removal or settings change is offered as one list to mark yes or no.
- **Remote help afterwards.** The [MeshCentral](https://github.com/Ylianst/MeshCentral) agent connects the PC to your
  own MeshCentral server, and an OpenSSH server that listens only on the PC itself lets you run deskside's scripts
  through MeshCentral's port mapping. SSH is never open on their home network. Screen, terminal and file sessions show the
  person a notice; background runs over the port map don't, which the consent wording tells them up front.
- **A Claude Code console.** [`.claude/`](.claude) holds skills (`connect`, `diagnose`, `onboard`, `apply-settings`,
  `undo`, `report`, `enroll`, `remove`) for running all of this from *your* machine. Claude Code never runs on, or
  signs in from, their PC.

Everything is proven end to end in [Windows Sandbox](docs/sandbox-proof.md) before it touches a real PC.

## Ground rules

- **Only with the owner's yes.** Every change script refuses to run until the PC's owner has agreed, in plain words
  on screen, to that kind of change (`diagnose`, `onboard`, `remote`). Using someone's computer without permission is
  a crime.
- **Work and school PCs are report-only.** A PC joined to a domain or Microsoft Entra, or enrolled in device
  management, belongs to its organization. deskside shows a report there and changes nothing.
- **No personal data in this repo.** Reports, app lists and the device list go to a private store you choose. A
  check blocks names, accounts, serial numbers and similar from ever being committed.
- **Nothing that gets around Windows or Office activation or licensing.**

## Start on a PC

In person, or over [Quick Assist](https://learn.microsoft.com/windows/client-management/client-tools/quick-assist),
open **PowerShell as administrator** and run:

```powershell
irm https://raw.githubusercontent.com/coltonbearden/deskside/main/bootstrap.ps1 | iex
```

It checks for a work or school PC before downloading anything, puts deskside in `C:\ProgramData\deskside\app`, asks
the owner to agree to a read-only check, shows the report, then offers to set the PC up (asking again first). It runs
on Windows PowerShell 5.1, which every Windows 10 and 11 PC has, and installs winget itself if it's missing.

## What gets installed

| Profile | Apps | Settings |
|---|---|---|
| [everyone](catalog/profiles/everyone.json) | Winget-AutoUpdate (keeps every app updated), 7-Zip, VLC, Bitwarden, Google Chrome, SumatraPDF | restore points on, block potentially unwanted apps, SmartScreen on, warn before update restarts, show file extensions, Storage Sense on, ads and tips off |
| [power](catalog/profiles/power.json) | everyone, plus PowerShell 7, Windows Terminal, Git and a PowerShell profile | |
| [developer](catalog/profiles/developer.json) | power, plus WSL, chezmoi, ripgrep, fd, fzf, Starship, PSReadLine, Terminal-Icons | |

Each setting in [`catalog/settings.json`](catalog/settings.json) says what it does, why, Microsoft's page for it, and
how it's undone. Windows only lets the person at the PC choose default apps, so setup opens *Settings > Default apps*
for them rather than forcing it.

## Layout

```
bootstrap.ps1         the one-line entry point
scripts/diagnose      read-only health check
scripts/onboard       consent, the yes/no change list, onboarding flows, app removal
scripts/install       winget repair, install profiles, Winget-AutoUpdate
scripts/settings      the settings baseline and undo
scripts/remote        MeshCentral agent, loopback-only SSH, remove-everything
scripts/console       your side: port map, remote runs, device removal (PowerShell 7)
health/               the scheduled health sweep (runs beside your MeshCentral server)
catalog/              profiles, settings, checks, junk and remote-tool lists, Windows support dates
profiles/             PowerShell profile, Windows Terminal settings, WSL additions
.claude/              Claude Code console: CLAUDE.md, skills, a read-only report subagent
sandbox/              the Windows Sandbox end-to-end proof
tests/                Pester tests
docs/                 how it works, safety model, remote access, decisions
```

## Working on deskside

```powershell
pwsh -File Invoke-Check.ps1 -Integration
```

runs PSScriptAnalyzer (with Windows PowerShell 5.1 compatibility rules), Pester, every PC-side script for real under
both Windows PowerShell 5.1 and PowerShell 7, gitleaks, and the personal-data scan. GitHub Actions runs the same check
on every push and pull request. Enable the pre-commit hook with `git config core.hooksPath .githooks`.

More: [how it works](docs/how-it-works.md) · [safety model](docs/safety.md) · [remote access](docs/remote-access.md) ·
[Sandbox proof](docs/sandbox-proof.md) · [decisions](docs/DECISIONS.md) · [status](STATE.md)

## Licence

[MIT](LICENSE). deskside downloads, and doesn't include, [Winget-AutoUpdate](https://github.com/Romanitho/Winget-AutoUpdate)
(MIT) and MeshCentral's agent and MeshCmd (Apache-2.0) from their own sources.
