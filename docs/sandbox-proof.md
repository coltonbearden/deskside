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
| bootstrap | the one-liner: work-or-school check, deskside in place, consent, diagnose, onboarding with the everyone profile (proof mode answers the prompts; it only works as the Sandbox's own account) |
| records | every run left a `deskside.record/v1` record |
| winget | winget, missing in a fresh Sandbox, was installed by Microsoft's documented repair |
| everyone-apps | all six everyone apps are installed |
| everyone-settings | every everyone setting is in place (Defender's PUA setting excepted: Defender doesn't run in Sandbox) |
| wau-task | Winget-AutoUpdate's scheduled task exists |
| undo-settings | a setting is applied, undone, undone again harmlessly, and re-applied |
| idempotent | running the baseline a second time changes nothing |
| consent-remote | the owner's yes to remote help is recorded |
| loopback-ssh | sshd listens on 127.0.0.1 only |
| ssh-login | the helper's key signs in; a password sign-in is refused |
| ssh-not-on-network | port 22 doesn't answer on the PC's network address |
| mesh-agent | the MeshCentral agent installs and runs (needs `-ServerUrl` and `-GroupId`) |
| remove-remote-help | agent, sshd, key, shortcut and remote consent are all gone |

With a server, the Sandbox waits after `mesh-agent` while `-HostCheck` runs on the helper's machine: the port map,
SSH through it, Claude Code running the diagnostics remotely. Then the device is removed from the server.

## Results

- 2026-11-19, `-Source local`: 13 of 14 passed. `undo-settings` assumed file extensions start hidden; in Windows Sandbox
  they're shown, so the step now sets its own starting state.
- 2026-11-19, `-Source github` (`irm https://raw.githubusercontent.com/coltonbearden/deskside/main/bootstrap.ps1 | iex`):
  **14 of 14 passed.** The first health check found 3 fix-now, 3 fix-soon and 3 nice-to-have items (Windows 11 24H2
  out of support, no antivirus running, no backups, no restore points, nothing updating apps); after onboarding, the
  restore-point and app-update items were gone. Installing the six apps took about 12 minutes.
- The mesh-agent step and the host-side checks wait for the MeshCentral server.

## What Sandbox can't prove

See STATE.md, "Proved on the first real PC". Windows' own OpenSSH optional feature can't install in Sandbox
(0x80072ee6), so the proof always exercises the winget fallback.
