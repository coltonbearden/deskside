# The Windows Sandbox proof

Windows Sandbox is a clean Windows that is thrown away when it closes: a stand-in for a family PC nobody has touched.

```powershell
pwsh -File sandbox/Invoke-SandboxProof.ps1                 # the working tree, before a push
pwsh -File sandbox/Invoke-SandboxProof.ps1 -Source github  # the README's exact one-liner, from GitHub
```

`Invoke-SandboxProof.ps1` packs the repo the way GitHub serves it, makes a throwaway SSH key pair, writes a `.wsb`
(networking on, inputs read-only, a results folder writable) and waits for `sandbox/proof-inner.ps1`, which runs as
the Sandbox's logon command and writes one JSON line per step.

## Steps

| Step | What it proves |
|---|---|
| managed-stop | with an MDM enrollment planted, the one-liner shows a report on screen and writes nothing (no `C:\ProgramData\deskside`) |
| bootstrap | the one-liner: work-or-school check, deskside in place, consent, diagnose, onboarding with the everyone profile (proof mode answers the prompts; it only works as the Sandbox's own account) |
| records | every run left a `deskside.record/v1` record |
| winget | winget, missing in a fresh Sandbox, was installed by Microsoft's documented repair |
| everyone-apps | all six everyone apps are installed |
| everyone-settings | every everyone setting is in place (Defender's PUA setting excepted: Defender doesn't run in Sandbox) |
| install-undo-file | the install run's undo.json lists every app it installed |
| wau-task | Winget-AutoUpdate's scheduled task exists |
| undo-settings | a setting is applied, undone, undone again harmlessly, and re-applied |
| idempotent | running the baseline a second time changes nothing |
| remove-marked-app | an app marked yes on a change list is removed |
| problem-flow | `Start-Onboarding -Flow Problem` runs end to end |
| power-profile | the power profile adds PowerShell 7, Windows Terminal, Git and the PowerShell profile |
| consent-remote | the owner's yes to remote help is recorded |
| loopback-ssh | sshd listens on 127.0.0.1 only |
| ssh-login | the helper's key signs in; a password sign-in is refused |
| ssh-not-on-network | port 22 doesn't answer on the PC's network address |
| mesh-agent | the MeshCentral agent installs and runs (needs `-ServerUrl` and `-GroupId`) |
| help-button | the help button installs from the server's monitor-only Assistant (server and group read from the agent), runs in the signed-in session, and its weekly refresh, run as SYSTEM, finds it current |
| help-request | the button's script sends a two-line request as one line; Assistant's own log shows `requesthelp` going to the agent (the mail is checked at inbox@) |
| notice-seen | the console's "is connected" message appeared in the signed-in session, `notice.json` says the closing message was sent, and it appeared once the first closed itself (Windows shows one message at a time) |
| sweep-silent | the diagnostics run as SYSTEM with no SSH, as the scheduled check runs them: no message, no notice in the record |
| remove-remote-help | agent, help button (program, shortcuts, task, setting), sshd, key, shortcut and remote consent are all gone |

With a server (`-Remote`), the Sandbox waits after `mesh-agent` while the host check runs on the helper's machine:
`host:route-ssh` (the port map and SSH through it), `host:real-key` (the console's own deskside-ssh key from
1Password's agent, named by its public key), `host:claude-diagnose` (Claude Code running the diagnostics remotely)
and `host:ssh-notice` (that run's record says the notice reached the one signed-in session). The Proofs group removes the device from the server when the agent is uninstalled.

## Results

- 2026-11-19, `-Source local`: 13 of 14 passed. `undo-settings` assumed file extensions start hidden; in Windows Sandbox
  they're shown, so the step now sets its own starting state.
- 2026-11-19, `-Source github` (`irm https://raw.githubusercontent.com/coltonbearden/deskside/main/bootstrap.ps1 | iex`):
  **14 of 14 passed.** The first health check found 3 fix-now, 3 fix-soon and 3 nice-to-have items (Windows 11 24H2
  out of support, no antivirus running, no backups, no restore points, nothing updating apps); after onboarding, the
  restore-point and app-update items were gone. Installing the six apps took about 12 minutes.
- 2026-11-19, -Source github again after two fixes (settings before apps; recheck winget's list after an install):
  14 of 14 passed, a restore point was made before the installs and all six apps were logged installed. Its records
  showed the install's undo.json nested under Windows PowerShell 5.1 (ConvertFrom-Json returns an array as one
  object), which a 5.1 integration test now covers and the install-undo-file step checks.
- 2026-11-19, -Source github at 401f197: **15 of 15 passed**, including install-undo-file (all six apps in undo.json).
- 2026-11-19, `-Source github` at a40e3d2, with the new steps: **19 of 19 passed**: managed-stop (an MDM enrollment
  planted: report on screen, nothing written), remove-marked-app, problem-flow and power-profile included.
- 2026-11-19, `-Source github -Remote` at fb800bd against the live server (Proofs group): **23 of 23 passed**, but
  the nested Claude Code session found that its remote run failed on the PC's default script policy and fixed the
  console itself mid-run (d0fb4a5: `powershell.exe -ExecutionPolicy Bypass -File` for that run only). The host check
  now forbids edits, so a proof can't patch what it proves.
- 2026-11-19 (second run), `-Source github -Remote` at d0fb4a5 (console at 6910365, which also checks the server certificate when
  the route starts): **23 of 23 passed, no edits** (the nested session's reply and ``git status`` afterwards showed none; the host check now fails on any change to the tree). mesh-agent (agent running, node id handed over), host:route-ssh
  (MeshCmd port map over the private relay, SSH with the proof key, Windows PowerShell 5.1), host:claude-diagnose
  (Claude Code on the helper's machine ran the `diagnose` skill; the record came back to the throwaway store),
  remove-remote-help (nothing left behind). The server's admin side confirmed the Proofs group held no device after
  the first run's agent left.

- 2026-11-20, `-Source local -Remote` (working tree on d6fbafe, before the push): **29 of 29 passed** in the fourth run of
  the day. help-button (Assistant from the server's monitor-only download, signature Valid, running in session 1; the
  weekly refresh as SYSTEM read the server and group from the agent and found it current; no update dialog), help-request
  (two lines sent as one; Assistant's log shows `requesthelp` to the agent; the server's mail reached inbox@ once the
  Proofs group's help-request email was on, seen by the owner for the 16:42 request), host:real-key (deskside-ssh from
  1Password's agent, named by its public key with IdentitiesOnly; elevated login), host:claude-diagnose and
  host:ssh-notice (the record says sentBy console, signedIn 1, shown 1), notice-seen ("is connected" at 17:49:37; the
  closing message at 17:54:37, once the first had closed itself: Windows shows a session's messages one at a time),
  sweep-silent (diagnose as SYSTEM: no message, no notice), remove-remote-help (nothing left, help button included); no
  `deskside-route-*` folder left on the helper's machine. Earlier runs that day: the first two failed only notice-seen
  (the closing message queued behind an open first one, found by that step), the third only on a 1Password prompt
  nobody approved.
`-Remote` takes the server and the Proofs group from the private records store. The host half is
`sandbox/Invoke-HostCheck.ps1`: a throwaway records store with only the Sandbox in it, the proof's throwaway key
(`DESKSIDE_SSH_IDENTITY`), and Claude Code allowed only the console's runner and reading.

## What Sandbox can't prove

See STATE.md, "Proved on the first real PC". Windows' own OpenSSH optional feature can't install in Sandbox
(0x80072ee6), so the proof always exercises the winget fallback.
