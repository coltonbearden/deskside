# Remote access

```
 helper's machine                         MeshCentral server                    family PC
 ----------------                         ------------------                    ---------
 Claude Code / pwsh                                                            Mesh Agent (service + tray)
   Invoke-DesksideRemote.ps1                                                     |
     MeshCmd route  -- wss://<server>/meshrelay.ashx -->  relay  <-- agent --->  127.0.0.1:22  sshd
     127.0.0.1:<free port>                                                         keys only, no firewall rule
     ssh / scp  (deskside-ssh from the helper's SSH agent, named by its public key with IdentitiesOnly)
```

- **First contact** is in person or over Quick Assist (the helper needs a Microsoft account; the person sharing
  doesn't sign in). Nothing is installed before then.
- **The USB kit** (`usb-kit/`) does the whole enrollment from a drive with nothing typed. The values are a 64-character
  group id, a server address and a key, and typing them by hand failed in practice.
  - `scripts/console/New-DesksideUsbKit.ps1 -Drive E:` writes:
    - `START HERE.cmd`;
    - deskside at the committed HEAD (a zip, plus the bootstrap, the common module and the kit script from that commit);
    - `deskside/kit.json` (the commit);
    - `deskside/values.json`: the server, group id, `deskside-ssh` public key and helper's name, read from
      `meshcentral.json` and 1Password each time and printed nowhere.

    It refuses a drive that isn't removable, one that still holds a kit's values or an older single-script kit, and
    results not yet read back.
  - On the PC the kit elevates, then checks, in this order, before it changes anything:
    1. Work or school: it stops.
    2. Smart App Control (Defender's `SmartAppControlState`, then the code-integrity policy value): when it is on and
       the downloaded agent's Authenticode status isn't `Valid`, the kit stops, says why and changes nothing.

    After that it puts deskside on the PC from the drive: the usual first visit with the owner's prompts, or a refresh
    of the scripts when deskside is there already. Then it removes an earlier attempt's leftovers:
    - `deskside-mesh-*` and `deskside-check-*` temp folders;
    - PowerShell history lines that ran `Install-MeshAgent` or hold the group id;
    - Defender's allow for detection 489403, unless deskside placed it.

    Then it runs the remote consent, the agent, the help button and SSH. It writes `readback.txt` and `log.txt` on the
    drive and deletes `values.json`. No value is ever on a command line. The kit's own command line holds none, so
    none reaches the transcript header. It runs `Install-MeshAgent.ps1` in its own process, because Windows PowerShell's
    event log keeps a child `powershell.exe`'s whole command line (`HostApplication` in events 400 and 403, seen on the
    T14 on 2026-11-21).
  - `scripts/console/Read-DesksideUsbKit.ps1 -Drive E: -Alias <alias>`:
    - saves both files to the records store (`devices/<alias>/enroll/<stamp>/`);
    - overwrites and deletes `values.json` if the run left it;
    - checks every file of the kit for the group id, and fails if one still holds it;
    - shows only the plain findings, never the node id or account.

    On flash media a deleted file's old blocks can survive wear-levelling, so a lost drive is handled by replacing the
    group's enroll id. The agent's own `MeshAgent.msh` holds its group by design; *Remove remote help* removes it.
  - `Install-MeshAgent.ps1` makes the same Smart App Control check after the download and before running it, and
    always removes its download (try/finally).
- **The agent** comes from the helper's own MeshCentral server and device group:
  `scripts/remote/Install-MeshAgent.ps1 -ServerUrl https://<server> -GroupId <mesh id>`. It downloads the group's
  64-bit agent (`/meshagents?id=4&meshid=...&installflags=0`), runs `-fullinstall` and leaves a *Remove remote help*
  shortcut on the desktop. The device group's notify setting shows the person a notice and a privacy bar for desktop,
  terminal and file sessions. **A TCP port map (the SSH route below) shows nothing on the PC by itself**, so deskside
  shows its own message (*The notice over SSH* below), and every run it makes over it is recorded on the PC in
  `C:\ProgramData\deskside\data\runs`.
- **SSH** is Windows' own OpenSSH Server, `ListenAddress 127.0.0.1`, `PasswordAuthentication no`,
  `AuthenticationMethods publickey`, the helper's key in `administrators_authorized_keys` with Microsoft's ACL, the
  installers' inbound firewall rules turned off. Where Windows can't add the optional feature (Windows Sandbox, a
  broken feature store), winget's `Microsoft.OpenSSH.Preview` (Microsoft's Win32-OpenSSH MSI) is used instead.
  Sources: Microsoft Learn's OpenSSH install, configuration and key-management pages.
- **The route**: MeshCmd's `route` action maps a free local port to port 22 on the PC, through the server (MeshCentral
  docs, *MeshCmd*). MeshCmd itself is downloaded from the server (`/meshagents?meshcmd=4`), so its version always
  matches. The action file carrying the login is deleted as soon as MeshCmd has read it. MeshCmd checks the server by
  `serverId` (the MeshCentral server's own key, which the server proves by signing) or, when that's absent, by
  `serverHttpsHash`. Behind a proxy that presents its own certificate only `serverHttpsHash` works, and it is weaker
  than it looks: it's a SHA-384 of a certificate's public key, accepted when it matches *any* certificate the server
  sends, CA and root certificates included, with no host-name check. Pinning a root's key would accept any site that
  sends that root. So deskside pins the server's own key (`Get-MeshServerKeyHash`), and with `serverHttpsHash` alone
  it maps ports only over a relay whose name resolves to VPN overlay addresses, where the VPN authenticates the server.
  When the server's certificate is renewed and MeshCmd rejects the pin, the route reads the new key over that relay,
  records it in `meshcentral.json` and warns. `relayUrl` in `meshcentral.json` points MeshCmd at a relay address other than the agents' one (for example, agents
  on a public address and the console on a private one). deskside never sets MeshCmd's `debugLevel`: above 0 it prints
  the login.
- **The notice over SSH**: the console runs `scripts/remote/Send-HelperNotice.ps1 -Phase Start` over SSH before a script
  or `-Shell`, and `-Phase End` afterwards. It shows a message box in every signed-in session (WTSSendMessage from the
  elevated session-0 SSH login). Windows shows a session's messages one at a time (measured: a second box waited until
  the first closed), so each closes itself after 5 minutes and the End message follows once the Start one is closed.
  The message names the helper (`helperName` in
  `meshcentral.json`, never this repo) and what he is doing, and writes `data\notice.json` (phase, time, counts).
  sshd sets `SSH_CONNECTION` for the run and the console also sets `DESKSIDE_VIA=ssh`; with either, `New-DesksideRun`
  stamps `data.notice` into the run's record, sends the Start message itself (and the End one when the run completes)
  if the console's is missing or older than 10 minutes, and records "No one was signed in" when nobody was. A link that
  drops can lose the End message; the consent wording says so. The health sweep's run-command runs as SYSTEM with no
  SSH and shows nothing.
- **The help button**: `scripts/remote/Install-HelpButton.ps1 -HelperName <name>` (after the agent) downloads
  [MeshCentral Assistant](https://github.com/Ylianst/MeshCentralAssistant) (Apache-2.0, Intel) from the server's
  *System tray, monitor only* link, `/meshagents?id=10006&meshid=<group>&ac=4` (read in MeshCentral 1.3.1's
  `webserver.js`: `ac=4` adds no server details). It finds the installed agent through
  `HKLM\SOFTWARE\Open Source\Mesh Agent` and its named pipe, so the agent's patched relay code stays the only one;
  any other `ac` would make Assistant its own agent. The server and group come from the agent's own `MeshAgent.msh`.
  It goes in `%ProgramFiles%\deskside\Help`, starts at every sign-in with `-noupdate` (an all-users Startup shortcut),
  and *Ask &lt;name&gt; for help* on the public desktop and in the Start menu runs `Ask-ForHelp.ps1` as the person: it
  asks what's wrong (optional), checks the agent is connected to the server, makes the text one line (a line break
  loses the request, Assistant issue #50), closes their copy (one runs per PC) and starts it again with
  `-help:"<text>"`. Assistant sends `requesthelp` to the agent; the server emails every user linked to the group who
  ticked *Email for help requests*. **Updates:** Assistant's own update needs the person's OK and can't write to
  Program Files, so a weekly SYSTEM task `\deskside\help-refresh` (`Update-HelpButton.ps1`) downloads it again from the
  server and swaps the file when it changed; diagnose reports `help.refresh-failing` after 3 weeks without a good
  refresh, and the sweep alerts on it. The server is its source; the server's own update job keeps the server current.
- **The device id**: `Install-MeshAgent.ps1` records the agent's MeshCentral node id (`MeshAgent.exe -nodeid`, turned
  into `node//...`) in its run record; the helper copies it into `devices.json` when enrolling (the `enroll` skill).
- **The helper's SSH key** is `deskside-ssh` in 1Password (its private half never leaves it). 1Password's agent offers
  every key it holds and an OpenSSH server refuses after `MaxAuthTries` (6), so the console writes the public key
  (`sshPublicKeyRef`) to `%LOCALAPPDATA%\deskside\deskside-ssh.pub` and passes it with `IdentitiesOnly=yes`
  (1Password's documented fix); the agent then signs with that key only and 1Password asks to approve it.
- **The login** for MeshCmd and for removing devices is a MeshCentral login token kept in a password manager and read
  by reference (`meshcentral.json` in the private records store); nothing about the server lives in this repo.
- **Removal**: `scripts/remote/Remove-RemoteHelp.ps1` (the person can run it from the desktop shortcut) removes the
  help button (its program, shortcuts, refresh task and each profile's Assistant setting, loading an unloaded profile's
  hive for a moment), uninstalls the agent, the SSH setup and the key, and checks nothing is left. Uninstalling an agent doesn't delete the device on the
  server, so the helper also runs `scripts/console/Remove-DesksideDevice.ps1`. A relay-only console login can't delete
  devices: by default the script prints the web page's steps (*Actions > Delete Device*) and `-RemovedInWebUi` then marks
  the device removed; with `meshctrl` and a `removeLogin` allowed to delete devices set, it removes it itself.

## The private records store

A separate private repo (default `~\Projects\deskside-records`, override with `DESKSIDE_RECORDS`):

```
devices.json          [{ alias, meshNodeId, sshUser, profile, consent: { diagnose, onboard, remote } }]
meshcentral.json      { serverUrl, relayUrl, groupRef, proofGroupRef, serverId | serverHttpsHash, meshctrl,
                        login: { userRef, passwordRef }, removeLogin,
                        helperName, sshPublicKeyRef }   (refs are 1Password op:// references)
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
