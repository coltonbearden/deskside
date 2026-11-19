# Remote access

```
 helper's machine                         MeshCentral server                    family PC
 ----------------                         ------------------                    ---------
 Claude Code / pwsh                                                            Mesh Agent (service + tray)
   Invoke-DesksideRemote.ps1                                                     |
     MeshCmd route  -- wss://<server>/meshrelay.ashx -->  relay  <-- agent --->  127.0.0.1:22  sshd
     127.0.0.1:<free port>                                                         keys only, no firewall rule
     ssh / scp  (key from the helper's SSH agent)
```

- **First contact** is in person or over Quick Assist (the helper needs a Microsoft account; the person sharing
  doesn't sign in). Nothing is installed before then.
- **The agent** comes from the helper's own MeshCentral server and device group:
  `scripts/remote/Install-MeshAgent.ps1 -ServerUrl https://<server> -GroupId <mesh id>`. It downloads the group's
  64-bit agent (`/meshagents?id=4&meshid=...&installflags=0`), runs `-fullinstall` and leaves a *Remove remote help*
  shortcut on the desktop. The device group's notify setting shows the person when a session is active.
- **SSH** is Windows' own OpenSSH Server, `ListenAddress 127.0.0.1`, `PasswordAuthentication no`,
  `AuthenticationMethods publickey`, the helper's key in `administrators_authorized_keys` with Microsoft's ACL, the
  installers' inbound firewall rules turned off. Where Windows can't add the optional feature (Windows Sandbox, a
  broken feature store), winget's `Microsoft.OpenSSH.Preview` (Microsoft's Win32-OpenSSH MSI) is used instead.
  Sources: Microsoft Learn's OpenSSH install, configuration and key-management pages.
- **The route**: MeshCmd's `route` action maps a free local port to port 22 on the PC, through the server (MeshCentral
  docs, *MeshCmd*). MeshCmd itself is downloaded from the server (`/meshagents?meshcmd=4`), so its version always
  matches. The action file carrying the login is deleted as soon as MeshCmd has read it.
- **The login** for MeshCmd and for removing devices is a MeshCentral login token kept in a password manager and read
  by reference (`meshcentral.json` in the private records store); nothing about the server lives in this repo.
- **Removal**: `scripts/remote/Remove-RemoteHelp.ps1` (the person can run it from the desktop shortcut) uninstalls the
  agent, the SSH setup and the key, and checks nothing is left. Uninstalling an agent doesn't delete the device on the
  server, so the helper also runs `scripts/console/Remove-DesksideDevice.ps1`.

## The private records store

A separate private repo (default `~\Projects\deskside-records`, override with `DESKSIDE_RECORDS`):

```
devices.json          [{ alias, meshNodeId, sshUser, profile, consent: { diagnose, onboard, remote } }]
meshcentral.json      { serverUrl, groupId, serverId, serverHttpsHash, meshctrl, login: { userRef, passwordRef } }
devices/<alias>/runs  run folders pulled back from the PC (records, summaries, transcripts)
devices/<alias>/health  the health sweep's records
```

## The health sweep

`health/Invoke-HealthSweep.ps1` runs beside the MeshCentral server on a schedule. For each device in the group it asks
the agent (MeshCentral's run-command, with the automation login) to run the installed read-only diagnostics and return
the record, writes one record per PC per run into the records store, and pushes a status to an uptime monitor: up when
the sweep ran and nothing needs attention, down with a reason when a disk is failing or full, protection is off,
Windows or app updates have stopped for three weeks, no restore point has been made for a month, an unexpected
remote-control app appears, or a PC hasn't been seen for a month. The agent runs the check as SYSTEM, so per-user state
(OneDrive folder backup, File History) is left to the console's own diagnose runs.
