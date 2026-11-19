---
name: remove
description: Remove remote help from a family member's PC by alias - uninstall the MeshCentral agent and the loopback SSH setup, then delete the device from the server - leaving nothing behind. Use when the owner wants remote access gone or the PC is retired.
argument-hint: "[alias]"
disable-model-invocation: true
---

Remove remote help from `$ARGUMENTS`.

1. Over the route: `... -Script remote\Remove-RemoteHelp.ps1 -Arguments '-Confirmed'`. The connection drops part way
   (the agent carrying it is removed); that is expected. The person can also run "Remove remote help" from their
   desktop themselves.
2. Remove the device from the server: `pwsh -File scripts/console/Remove-DesksideDevice.ps1 -Alias <alias>`.
3. Confirm in MeshCentral that the device is gone, mark the consent `remote` as withdrawn in `devices.json`, and
   commit the records repo.
