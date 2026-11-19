---
name: report
description: Summarize a family member's PC from the private records store - latest health, trends across runs, changes made and what's still open - without connecting to it. Use when the helper asks how a PC is doing or wants a status write-up.
argument-hint: "[alias]"
---

Summarize `$ARGUMENTS` from the records store, without connecting.

1. Read `devices.json` for the device (profile, consent dates, last seen) and the run folders in
   `devices\<alias>\runs\`, newest first. The health sweep's records (`devices\<alias>\health\`) count too.
2. Delegate the reading to the `report-reader` subagent when there are many runs.
3. Report: the latest fix-now and fix-soon items, what improved or got worse since the previous diagnose, changes
   made (and their run ids for `undo`), and anything the health sweep alerted on.
4. No names, accounts or app lists in the reply.
