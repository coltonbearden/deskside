---
name: apply-settings
description: Apply settings from deskside's catalog to a family member's PC by alias, one change list marked yes or no, with before-state saved for undo. Use when the helper wants to change specific settings on a PC.
argument-hint: "[alias] [setting ids...]"
disable-model-invocation: true
---

Apply settings on `$0`.

1. Check `devices.json` for `consent.onboard` and `consent.remote`.
2. If setting ids were given (from `catalog/settings.json`), preview with
   `... -Script settings\Set-Baseline.ps1 -Arguments '-ItemId <id1>,<id2> -WhatIf'`, show the helper each item's
   what/why/source, ask yes or no, then run without `-WhatIf` for the yes items.
3. With no ids, build a change list from the newest diagnose record (see `onboard`, step 4) and apply only its yes
   items with `-ChangeList`.
4. Report each item as applied, already set or failed, and the run id (needed for `undo`).

Never add a setting that isn't in `catalog/settings.json`; propose a catalog entry (with its Microsoft source and
undo) in a commit instead.
