# deskside: the helper's console

deskside checks, sets up and stays connected to friends' and family's Windows PCs. This `.claude/` folder is the
console the helper uses from **his own machine**: Claude Code runs here, never on their PC, and reaches a PC only
through MeshCentral's port map and the loopback-only SSH server deskside sets up there.

## Rules that are never crossed

- **Only with the owner's yes.** Remote access and every change go only on a PC whose owner has agreed. On the PC,
  scripts refuse to run without the matching consent scope (`diagnose`, `onboard`, `remote`); on this side,
  `devices.json` must hold the date the owner said yes to `remote` before any connection. Using someone's computer
  without permission is a crime (the Computer Fraud and Abuse Act and state laws).
- **Work or school PCs are report-only.** A PC joined to a domain or Microsoft Entra, or enrolled in device
  management, belongs to its organization; its user can't authorize changes. Every script checks this first.
- **No Claude account on their PC.** Claude Code is never installed on, or signed in from, someone else's PC.
- **Nothing personal in this repo.** Names, accounts, serial numbers, reports, app lists and screenshots go only to
  the private records store (`$env:DESKSIDE_RECORDS`, default `~\Projects\deskside-records`). The repo is public.
- **Nothing that gets around Windows or Office activation or licensing**, ever.

## How a session targets a PC

PCs are named by **alias** from `devices.json` in the records store. Every skill takes the alias as its argument.
`scripts/console/Invoke-DesksideRemote.ps1 -Alias <alias> -Script <folder\Script.ps1>` opens the port map, runs the
script with Windows PowerShell on the PC, pulls the run's records back into `devices\<alias>\runs\` and closes the map.

## Output discipline

Sessions are mirrored to the helper's notes. On screen, report **counts and the findings' plain sentences only**:
never names, account names, file paths under a user's profile, or app lists. Read details from the records store
when needed and summarize them without quoting personal data.

## Where things are

- `scripts/diagnose`: the read-only health check. `scripts/onboard`: consent, the change list, onboarding, removals.
  `scripts/install`: winget repair, profiles, Winget-AutoUpdate. `scripts/settings`: the baseline and undo.
  `scripts/remote`: MeshCentral agent, loopback SSH, removal. `scripts/console`: this side only.
- `catalog/`: profiles, settings, checks, junk and remote-tool lists, Windows support dates. Changing what gets
  installed or checked is a data edit there.
- `docs/`: how it works, the safety model, the Sandbox proof. `STATE.md` and `docs/DECISIONS.md`: status and decisions.

## Before changing this repo

Run `pwsh -File Invoke-Check.ps1` (add `-Integration` to run every PC-side script under Windows PowerShell 5.1 and
PowerShell 7). Every script that runs on a family PC must work on Windows PowerShell 5.1 and stay ASCII-only.
