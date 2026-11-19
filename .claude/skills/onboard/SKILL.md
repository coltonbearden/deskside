---
name: onboard
description: Set up a family member's PC with a deskside profile (everyone, power or developer) - install only the missing apps and apply the agreed settings - by alias. Use when the helper asks to set up, onboard or install a profile on a PC.
argument-hint: "[alias] [everyone|power|developer]"
disable-model-invocation: true
---

Onboard `$0` with the `$1` profile (default `everyone`).

1. Check `devices.json`: the device needs `consent.onboard` and `consent.remote` dates. If not, stop and tell the
   helper the owner has to agree first.
2. Run `diagnose` first if the newest diagnose record is older than a day.
3. Show what the profile would do, without changing anything:
   `... -Script install\Install-Profile.ps1 -Arguments '-ProfileName <profile> -WhatIf'`
4. Build the change list: copy the newest `record.json` path on the PC and run
   `... -Script onboard\New-ChangeList.ps1 -Arguments '-Record <pc path to record.json> -ProfileName <profile>'`.
   Show the helper the items (title, why, verdict) and ask him yes or no for each with AskUserQuestion. Write his
   answers into the PC's changelist.json over SSH.
5. Apply in this order: `install\Install-Profile.ps1 -ProfileName <profile>`, then
   `settings\Set-Baseline.ps1 -ChangeList <path>`, then `onboard\Remove-Apps.ps1 -ChangeList <path>`.
6. Run `diagnose` again and report what changed. Remind him of hands-only steps the run reports (default apps can
   only be chosen by the person at the PC; WSL needs a restart).

Every change script records its before-state; `undo` reverses a run.
