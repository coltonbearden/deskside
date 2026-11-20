---
name: enroll
description: Enroll a family member's PC for remote help - MeshCentral agent, loopback-only SSH with the helper's key, and its entry in devices.json - after its owner agrees. Use when the helper sets up remote access on a new PC, usually in person or over Quick Assist.
argument-hint: "[alias]"
disable-model-invocation: true
---

Enroll a PC as `$ARGUMENTS`. This happens with the helper at the PC (in person or over Quick Assist), because
nothing can reach it yet. Walk him through it; he types the commands on the PC.

1. On the PC, in an administrator PowerShell: the one line from the README (bootstrap) if deskside isn't there yet.
2. The owner agrees to remote help, in their own words, at the prompt:
   `powershell -ExecutionPolicy Bypass -File C:\ProgramData\deskside\app\scripts\onboard\Grant-Consent.ps1 -Scope remote`
3. Install the agent (`serverUrl` from `meshcentral.json` in the records store; the group id is in 1Password at its
   `groupRef`, read with `op read`):
   `...\scripts\remote\Install-MeshAgent.ps1 -ServerUrl <url> -GroupId <group id>`
   The run prints only counts; its record (`C:\ProgramData\deskside\data\runs\*-mesh-install\record.json`, `data.meshNodeId`)
   holds the device's node id. He reads it there on the PC, or from the device's page in MeshCentral.
4. Turn on loopback SSH with his public key (from 1Password item `deskside-ssh`, public key field):
   `...\scripts\remote\Enable-LoopbackSsh.ps1 -PublicKey '<ssh-ed25519 ...>'`
5. On his machine: add the device to `devices.json` (alias, meshNodeId,
   sshUser = the PC account used, profile, consent dates for each scope the owner agreed to), commit the records repo.
6. Prove it: run the `connect` skill for the alias. Then show the owner the "Remove remote help" shortcut on their
   desktop. Tell them plainly: a notice and privacy bar appear when he views the screen, a terminal or files; checks run
   over the SSH route show nothing on screen, but each run is recorded on the PC.
