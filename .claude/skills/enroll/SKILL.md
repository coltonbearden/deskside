---
name: enroll
description: Enroll a family member's PC for remote help - MeshCentral agent, the "Ask for help" button, loopback-only SSH with the helper's key, and its entry in devices.json - after its owner agrees. Use when the helper sets up remote access on a new PC, usually in person with a USB drive.
argument-hint: "[alias]"
disable-model-invocation: true
---

Enroll a PC as `$ARGUMENTS` with the USB kit: nothing is typed by hand. The helper takes a USB drive to the PC; nothing
can reach the PC before this.

1. **Build the drive** on his machine, with a spare USB drive plugged in (never a drive that still holds the older
   single-script kit; the builder refuses one anyway). He approves 1Password's prompt:
   `pwsh -File scripts\console\New-DesksideUsbKit.ps1 -Drive E:`
   It reads the server from `meshcentral.json`, and the group id (`groupRef`) and the `deskside-ssh` public key
   (`sshPublicKeyRef`) from 1Password, and writes them to the drive's `deskside\values.json`. It prints no value.
2. **At the PC**: plug the drive in and double-click `START HERE.cmd`, then answer Windows' administrator prompt. The kit
   stops on a work or school PC, and when Smart App Control is on and the agent isn't signed with a certificate Windows
   trusts. Either way it changes nothing and says why on screen. Otherwise:
   - It puts deskside on the PC from the drive. If deskside isn't there yet, this is the usual first visit (health check,
     then setup, each asked first). If it is there, the kit refreshes deskside's scripts.
   - It removes what an earlier attempt left behind.
   - The owner agrees to remote help, in their own words, at the prompt.
   - It installs the agent, the help button and loopback SSH.

   It writes `readback.txt` and `log.txt` to the drive and deletes `values.json`.
3. **Back at his machine**, approve 1Password's prompt if values.json was already deleted:
   `pwsh -File scripts\console\Read-DesksideUsbKit.ps1 -Drive E: -Alias $ARGUMENTS`
   It saves both files to `devices\<alias>\enroll\<stamp>\` in the records store, wipes the kit's values, checks that no
   file on the drive still holds the group id, and shows only the plain findings. If it says the kit stopped, tell him why
   in plain words and stop here. A Smart App Control stop clears once the server serves agents signed with a certificate
   Windows trusts; then build a drive and run it again.
4. Add the device to `devices.json` from the saved `readback.txt` (read it, don't echo it): alias, `meshNodeId` (its
   `node:` line), `sshUser` (its `account:` line), profile, and the consent dates for each scope (its `consent:` lines).
   The owner's name goes only in the private owner field. Commit the records repo.
5. Prove it: run the `connect` skill for the alias. Then show the owner, on their desktop, "Ask <helperName> for help"
   (one click sends him a request; his server emails it) and "Remove remote help". Tell them plainly:
   - When he views the screen, a terminal or files, they see MeshCentral's notice and bar.
   - When he connects to run checks or fixes, a message says so, and another says when he's finished (after they close
     the first, or 5 minutes).
   - If nobody is signed in, nothing appears, but the visit is recorded.
   - The automatic check every 6 hours only reads and shows nothing.

Without a drive (only if the kit can't be used): build the kit into any folder with `-Path` and copy it to the PC by
Quick Assist's file transfer, then read it back from that folder the same way. Never read a group id aloud or type it.
