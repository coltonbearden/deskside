---
name: connect
description: Open an SSH session to a family member's PC through MeshCentral's port map, or check that the route works. Use when the helper wants to reach a PC by its alias from devices.json.
argument-hint: "[alias]"
disable-model-invocation: true
---

Connect to the PC with alias `$ARGUMENTS`.

1. Read `devices.json` in the records store (`$env:DESKSIDE_RECORDS`, default `~\Projects\deskside-records`) and find
   the alias. Stop if it has no `consent.remote` date: the owner has to agree first (see the `enroll` skill).
2. Check the route without changing anything:
   `pwsh -File scripts/console/Invoke-DesksideRemote.ps1 -Alias <alias> -Script diagnose\Invoke-Diagnose.ps1 -Arguments '-Quick'`
   is the usual first call; it also refreshes the PC's report.
3. For an interactive session the helper types into, tell him to run
   `pwsh -File scripts/console/Invoke-DesksideRemote.ps1 -Alias <alias> -Shell` himself (it needs his terminal).

If the port map fails, say whether MeshCentral sees the PC online (the error names it) and stop. 1Password may ask
him to approve the login and the SSH key: that is expected.
