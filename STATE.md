# STATE

> Live status of the project. A brand-new session should be able to resume from this file alone.
> Decisions: docs/DECISIONS.md. How it works: docs/how-it-works.md. Safety: docs/safety.md.

## Now

- **Status:** v0.1.0. Diagnostics, onboarding (everyone, power, developer profiles), the settings baseline with undo,
  the yes/no change list, the MeshCentral agent install and removal, loopback-only SSH, the console scripts and the
  `.claude/` console are built. `Invoke-Check.ps1 -Integration` passes locally under Windows PowerShell 5.1 and
  PowerShell 7, and in GitHub Actions.
- **Proven end to end:** the README's one-liner through remote help, against the live MeshCentral server, in Windows
  Sandbox: 23 of 23 steps at d0fb4a5 with the console at 6910365 (docs/sandbox-proof.md, 2026-11-19). The agent
  joins the Proofs group, the console's MeshCmd port map and SSH reach the PC, Claude Code on the helper's machine runs
  the diagnose skill and the record comes back, and removal leaves nothing on the PC or the server. Not yet run
  anywhere: the developer profile (WSL needs nested virtualization), `Remove-DesksideDevice` against a real device,
  the console's `onboard`/`undo` skills remotely.
- **Waiting on the owner:** the `deskside-ssh` SSH Key item in 1Password (Personal vault), whose public key the
  `enroll` skill installs on each PC; Dependabot's PR #1 (actions/checkout 4 to 7, checks green); scheduling the
  health sweep beside the server.
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
- Request Help needs MeshCentral Assistant on the PC; deskside doesn't install it.
- Only 64-bit Intel/AMD PCs get the agent for now; ARM64 needs MeshCentral's ARM64 agent id.
- Diagnostics over MeshCentral's run-command run as SYSTEM, so per-user sections (OneDrive folders, the account) read
  SYSTEM's profile there; the console's SSH runs read the person's.

## Key facts for a fresh session

- Run checks: `pwsh -File Invoke-Check.ps1 -Integration`. Prove on a clean Windows: `pwsh -File sandbox/Invoke-SandboxProof.ps1`.
- PC-side scripts must run on Windows PowerShell 5.1 and be ASCII-only; the analyzer and tests enforce both.
- Every change script: `Assert-NotManaged`, `Assert-Consent`, `SupportsShouldProcess`, before-state via
  `Save-BeforeState`, record via `New-DesksideRun` / `Complete-DesksideRun`.
- Records go to the private store (`DESKSIDE_RECORDS`, default `~\Projects\deskside-records`), never here.
