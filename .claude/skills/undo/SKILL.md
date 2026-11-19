---
name: undo
description: Reverse a deskside change run on a family member's PC by alias and run id, from the before-state it saved. Use when a change needs to be rolled back.
argument-hint: "[alias] [run id]"
disable-model-invocation: true
---

Undo run `$1` on `$0`.

1. Find the run in `devices\<alias>\runs\` in the records store and show the helper what it changed (`record.json`
   `changes`). If no run id was given, list the change runs (anything not `-diagnose`) newest first and ask which.
2. Preview: `... -Script settings\Undo-DesksideRun.ps1 -Arguments '-Run <run id> -WhatIf'`.
   The run folder must still be on the PC (`-KeepOnPc` was used) or be copied back first with scp; say which.
3. After his yes, run it without `-WhatIf` and report each entry as undone or failed.

App removals can't be undone this way (trialware isn't reinstalled); the restore point made before them is the way
back, from System Restore on the PC.
