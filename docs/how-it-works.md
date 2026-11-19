# How it works

## Two flows

**A brand-new PC** (`Start-Onboarding.ps1 -Flow NewPC`, the default the bootstrap offers):

1. Health check (read-only).
2. The owner agrees to set-up (`onboard`).
3. One change list: junk and trialware found, plus the profile's settings the PC doesn't have yet. Each is asked yes
   or no.
4. The profile's missing apps are installed through winget (winget is repaired first if it's missing).
5. The yes settings are applied, the yes removals are done, each with its before-state saved.
6. Health check again, so the difference is visible.

**A PC with a problem** (`-Flow Problem`): the health check's *fix now* items are shown first, then the same change
list; no new apps unless a profile is named.

## Run records

Every run writes to `C:\ProgramData\deskside\data\runs\<UTC time>-<kind>\`:

- `record.json`: schema `deskside.record/v1`: `kind`, `runId`, times, tool and PowerShell versions, `counts` by rank,
  `findings` (`id`, `rank`, `text`), `changes`, `errors` (sections that couldn't be read) and `data` (raw values per
  section). Agents read these.
- `summary.md`: the findings as plain sentences, grouped *Fix now*, *Fix soon*, *Nice to have*, *Good to know*.
- `transcript.txt`, and `undo.json` for change runs.

The console pulls run folders into the private records store and deletes them from the PC.

## The catalog

| File | What it holds |
|---|---|
| `checks.json` | every finding: its rank and the sentence shown, with `{0}` slots for counts and dates only |
| `lifecycle.json` | Windows 11 Home and Pro support end dates and Windows 10's consumer ESU end, copied from Microsoft with the date read; the check flags itself when that date is over 180 days old |
| `settings.json` | the settings baseline: what, why, Microsoft source, how it's applied and undone |
| `profiles/*.json` | install profiles: winget ids, PowerShell modules, files, WSL |
| `junk.json` | name patterns for junk and trialware, each *recommended* or *questionable* |
| `remote-tools.json` | remote-control tools scammers use, and the MeshCentral agent as expected |

Changing what gets installed or checked is a data edit; the tests check every entry's shape.

## Updates after set-up

Winget-AutoUpdate (installed by the everyone profile) updates every winget app daily, notifies the person only when
an update fails, and keeps itself updated. Its scheduled task `\WAU\Winget-AutoUpdate` is what the health check reads
to say whether app updates are working. Windows Update stays Windows' own job; the health check reports when it
stalls.
