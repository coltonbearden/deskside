---
name: enroll
description: Enroll a family member's PC for remote help - MeshCentral agent, the "Ask for help" button, loopback-only SSH with the helper's key, and its entry in devices.json - after its owner agrees. Use when the helper sets up remote access on a new PC, usually in person or over Quick Assist.
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
4. Add the help button (`helperName` from `meshcentral.json`; the server and group come from the agent):
   `...\scripts\remote\Install-HelpButton.ps1 -HelperName '<helperName>'`
5. Turn on loopback SSH with his public key (`op read` of `sshPublicKeyRef` in `meshcentral.json`, the `deskside-ssh`
   item's public key):
   `...\scripts\remote\Enable-LoopbackSsh.ps1 -PublicKey '<ssh-ed25519 ...>'`
6. On his machine: add the device to `devices.json` (alias, meshNodeId,
   sshUser = the PC account used, profile, consent dates for each scope the owner agreed to), commit the records repo.
7. Prove it: run the `connect` skill for the alias. Then show the owner, on their desktop, "Ask <helperName> for help"
   (one click sends him a request; his server emails it) and "Remove remote help". Tell them plainly: when he views the
   screen, a terminal or files they see MeshCentral's notice and bar; when he connects to run checks or fixes a message
   says so and another says when he's finished (after they close the first, or 5 minutes); if nobody is signed in nothing appears but the visit is recorded; the
   automatic check every 6 hours only reads and shows nothing.
