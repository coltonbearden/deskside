---
name: diagnose
description: Run deskside's read-only health check on a family member's PC by alias and summarize it in plain English, ranked fix now, fix soon, nice to have. Use when the helper asks what's wrong with someone's PC or wants a fresh report.
argument-hint: "[alias]"
---

Run the read-only health check on `$ARGUMENTS` and report it.

1. `pwsh -File scripts/console/Invoke-DesksideRemote.ps1 -Alias <alias> -Script diagnose\Invoke-Diagnose.ps1`
   (add `-Arguments '-Quick'` to skip the slow Windows Update search).
2. Open the newest `devices\<alias>\runs\*-diagnose\summary.md` in the records store, and `record.json` beside it
   for details.
3. Tell the helper, in this order: the fix-now items, then fix-soon, then nice-to-have, one plain sentence each,
   with the count of good-to-know items at the end. Compare with the previous diagnose run if there is one and say
   what changed.
4. Keep names, accounts, user paths and app lists out of the reply (the session is mirrored to his notes). Say
   "2 junk apps" rather than naming them unless he asks.

This changes nothing on the PC. Suggest `onboard` or `apply-settings` for fixes; don't run them unasked.
