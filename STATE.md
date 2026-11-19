# STATE

> Live status of the project. A brand-new session should be able to resume from this file alone.
> Decisions: docs/DECISIONS.md. How it works: docs/how-it-works.md. Safety: docs/safety.md.

## Now

- **Status:** v0.1.0. Diagnostics, onboarding (everyone, power, developer profiles), the settings baseline with undo,
  the yes/no change list, the MeshCentral agent install and removal, loopback-only SSH, the console scripts and the
  `.claude/` console are built. `Invoke-Check.ps1 -Integration` passes locally under Windows PowerShell 5.1 and
  PowerShell 7, and in GitHub Actions.
- **In flight:** the end-to-end proof's remote half (agent online on the server, SSH through MeshCentral's port map,
  Claude Code running the diagnostics remotely, device removed from the server) waits for the MeshCentral server.
  Everything up to and including loopback SSH and removal is proven in Windows Sandbox from the README's one-liner,
  14 of 14 steps (docs/sandbox-proof.md, 2026-11-19).
- **Waiting on the owner:** the `deskside-ssh` SSH Key item in 1Password (Personal vault), whose public key the
  `enroll` skill installs on each PC; Dependabot's PR #1 (actions/checkout 4 to 7, checks green).
- **How a failure reaches the owner:** CI failures show on GitHub. The health sweep (health/Invoke-HealthSweep.ps1)
  pushes to an uptime monitor whose downs become tasks; it's scheduled by the homelab's stack repo beside the
  MeshCentral server, not from here.
- **Next:** when the server exists, fill `meshcentral.json` in the records store, run
  `sandbox/Invoke-SandboxProof.ps1 -Source github -ServerUrl ... -GroupId ... -HostCheck {...}`, then remove the
  Sandbox's device from the server.

## Proved on the first real PC, not in Windows Sandbox

Windows Sandbox can't show these, so they're covered by mocked tests until the first real PC (with its owner's yes):
Defender status and PUA blocking, BitLocker or device encryption and its recovery key, battery wear, Windows Update
history on a long-lived PC, OneDrive folder backup, Microsoft-account detection, the Store app list, WSL (no nested
virtualization), restarts, Windows' own OpenSSH optional feature (Sandbox uses the winget fallback), and the
work-or-school stop on a real Entra-joined or MDM-enrolled PC.

## Open issues

- MeshCentral details (server URL, group id, server id and certificate hash for MeshCmd, the automation login's
  password-manager references, where meshctrl.js lives on the helper's machine) aren't known until the server exists.
- Only 64-bit Intel/AMD PCs get the agent for now; ARM64 needs MeshCentral's ARM64 agent id.
- Diagnostics over MeshCentral's run-command run as SYSTEM, so per-user sections (OneDrive folders, the account) read
  SYSTEM's profile there; the console's SSH runs read the person's.

## Key facts for a fresh session

- Run checks: `pwsh -File Invoke-Check.ps1 -Integration`. Prove on a clean Windows: `pwsh -File sandbox/Invoke-SandboxProof.ps1`.
- PC-side scripts must run on Windows PowerShell 5.1 and be ASCII-only; the analyzer and tests enforce both.
- Every change script: `Assert-NotManaged`, `Assert-Consent`, `SupportsShouldProcess`, before-state via
  `Save-BeforeState`, record via `New-DesksideRun` / `Complete-DesksideRun`.
- Records go to the private store (`DESKSIDE_RECORDS`, default `~\Projects\deskside-records`), never here.
