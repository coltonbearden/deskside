# Safety model

The rules live in the scripts, not in anyone's memory. Claude Code's settings add nothing on top: the console's
`settings.json` has no extra permission rules or hooks, because a PC-side script refuses unsafe work on its own.

## Every script

| Rule | Where it's enforced |
|---|---|
| Diagnostics only read | `scripts/diagnose/Invoke-Diagnose.ps1` makes no change; tests run it on the test machine itself |
| Work or school PCs change nothing | `Assert-NotManaged` (domain join, Microsoft Entra join, MDM enrollment other than Windows' built-in local enrollments) runs first in every change script; `bootstrap.ps1` runs the same check in memory before downloading or writing anything |
| Only with the owner's yes | `Assert-Consent -Scope onboard` or `-Scope remote` in every change script; `Grant-Consent.ps1` shows the exact wording and needs a typed YES |
| `-WhatIf` everywhere | every change script is `SupportsShouldProcess`; the tests check it |
| Before-state and undo | each change writes its old value to the run's `undo.json` before changing it; `Undo-DesksideRun.ps1` puts it back |
| Safe to run twice | each item is checked first and skipped when already in place; the Sandbox proof runs the baseline twice and asserts the second run changes nothing |
| Restore point first | `New-DesksideRestorePoint` before every change run when System Protection is on; turning System Protection on is its own catalog item |
| Transcript and record | every run writes `transcript.txt`, `record.json` (schema `deskside.record/v1`) and `summary.md` to `C:\ProgramData\deskside\data\runs\<run>`, readable by administrators only |
| Counts only on screen | the console prints counts and plain sentences, never names, accounts or app lists |
| Nothing pinned | apps always install at winget's latest; Winget-AutoUpdate keeps them current afterwards |
| The person sees the helper arrive | `Invoke-DesksideRemote.ps1` sends a Start message to every signed-in session (`Send-HelperNotice.ps1`, WTSSendMessage) before a script or shell runs, and stops if it can't; an End message in `finally`. On the PC, `New-DesksideRun` sends the Start message itself for any run under SSH that the console didn't announce, and every SSH run's record holds `data.notice` (signed in, shown), with "No one was signed in" when nobody was. The scheduled check runs as SYSTEM without SSH and sends nothing (a test checks the sweep never does) |
| One list, yes or no | `New-ChangeList.ps1` lists only recommended or questionable removals and settings the PC doesn't already have; apply scripts act only on `"decision": "yes"` |

## What "consent" records

`C:\ProgramData\deskside\data\consent.json` holds each scope the owner agreed to, the time and the exact words they
were shown. No name. On the helper's side, `devices.json` in the private records store records who the PC belongs to
and when they said yes, and the console refuses to connect without a `remote` date there.

`-Confirmed` skips the on-screen prompt. It exists for tests, the Sandbox proof, and the case where the owner has
agreed in person or on the phone and the helper is typing for them.

## What can't be undone by deskside

- Removing an app: trialware isn't reinstalled. The restore point made just before is the way back.
- Windows' own default-app choice: only the person at the PC can set it, through Settings.

## The public repo

`tools/Test-PersonalData.ps1` blocks email addresses, account SIDs, MAC addresses, BitLocker recovery keys, serial
numbers, private IP addresses and real user-profile paths, plus a local deny list of exact words kept outside the
repo. gitleaks scans for secrets. Both run in the pre-commit hook and in CI.
