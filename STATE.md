# STATE

> Live status of the project. A brand-new session should be able to resume from this file alone.
> Decisions: docs/DECISIONS.md. How it works: docs/how-it-works.md. Safety: docs/safety.md.

## Now

- **Status:** v0.1.0. Diagnostics, onboarding (everyone, power, developer profiles), the settings baseline with undo,
  the yes/no change list, the MeshCentral agent install and removal, the help button (MeshCentral Assistant beside the
  agent, D-011), loopback-only SSH, the on-screen message whenever the helper works over SSH (D-012), the console scripts
  (naming the deskside-ssh key, D-013) and the `.claude/` console are built. `Invoke-Check.ps1 -Integration` passes locally under Windows PowerShell 5.1 and
  PowerShell 7, and in GitHub Actions.
- **Proven end to end:** the README's one-liner through remote help, against the live MeshCentral server, in Windows
  Sandbox: 29 of 29 steps on 2026-11-20 (working tree on d6fbafe, before faef957; docs/sandbox-proof.md). The agent
  joins the Proofs group, the help button installs and its request reaches the agent and then inbox@, the console's
  port map and SSH reach the PC with the real deskside-ssh key, Claude Code runs the diagnose skill and the record comes
  back, the "connected" and "finished" messages show in the signed-in session, and removal leaves nothing. Stand-ins:
  the scheduled check's silence was shown with diagnose run as SYSTEM by a task, not a real MeshCentral run-command;
  the help button ran its script elevated with `-Text -Quiet`, not the shortcut, its form, or an ordinary user's
  Assistant; "nobody signed in" and the fix for long announced runs (D-012, after the proof) are covered by tests
  only. Not yet run anywhere: the developer profile (WSL needs nested virtualization), `Remove-DesksideDevice` against
  a real device, the console's `onboard`/`undo` skills remotely.
- **Waiting on the owner:** scheduling the health sweep beside the server (the server's stack repo); the homelab
  records' handoff kickoffs.
- **How a failure reaches the owner:** CI failures show on GitHub. The health sweep (health/Invoke-HealthSweep.ps1)
  pushes to an uptime monitor whose downs become tasks; it's scheduled by the homelab's stack repo beside the
  MeshCentral server, not from here.
- **Next:** the first real PC, with its owner's yes (`enroll` skill); the health sweep on the server's node.

## Proved on the first real PC, not in Windows Sandbox

Windows Sandbox can't show these, so they're covered by mocked tests until the first real PC (with its owner's yes):
Defender status and PUA blocking, BitLocker or device encryption and its recovery key, battery wear, Windows Update
history on a long-lived PC, OneDrive folder backup, Microsoft-account detection, the Store app list, WSL (no nested
virtualization), restarts, Windows' own OpenSSH optional feature (Sandbox uses the winget fallback), and the
work-or-school stop on a real Entra-joined or domain-joined PC (the Sandbox proof covers an MDM enrollment).

## Open issues

- The console's MeshCentral login is relay-only, so it can't delete devices: removing a real PC from the server is a
  web-page step (`Remove-DesksideDevice.ps1` prints it). A login allowed to delete devices plus meshctrl.js would
  automate it.
- Behind the server's proxy `serverId` doesn't work, so MeshCmd checks `serverHttpsHash`, which matches any
  certificate in the chain with no host-name check. deskside pins the server's own key and maps ports only over a relay
  that resolves to VPN addresses; when the certificate is renewed the route reads the new key over that relay and warns
  (docs/remote-access.md).
- Help requests reach inbox@ by MeshCentral's email; n8n's mail job isn't designed to turn them into Home items.
- Assistant runs one copy per PC, so with two people signed in at once (fast user switching) only the first has the
  button working; and the SSH message's "nobody signed in" path and an SSH account different from the signed-in
  person are proven by tests only, not on a real PC yet.
- Only 64-bit Intel/AMD PCs get the agent for now; ARM64 needs MeshCentral's ARM64 agent id.
- Diagnostics over MeshCentral's run-command run as SYSTEM, so per-user sections (OneDrive folders, the account) read
  SYSTEM's profile there; the console's SSH runs read the person's.

## Key facts for a fresh session

- Run checks: `pwsh -File Invoke-Check.ps1 -Integration`. Prove on a clean Windows: `pwsh -File sandbox/Invoke-SandboxProof.ps1`.
- PC-side scripts must run on Windows PowerShell 5.1 and be ASCII-only; the analyzer and tests enforce both.
- Every change script: `Assert-NotManaged`, `Assert-Consent`, `SupportsShouldProcess`, before-state via
  `Save-BeforeState`, record via `New-DesksideRun` / `Complete-DesksideRun`.
- Records go to the private store (`DESKSIDE_RECORDS`, default `~\Projects\deskside-records`), never here.
