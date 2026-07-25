## Why

After ProcessOps lands for ecosystems and simple runners, SSH agent and GPG production process edges remain large absolute HPC residual. Domain `SshAgentOps` / `GpgAgentOps` Unit tests already warm orchestration with fakes; production process helpers (agent start, list identities, kill, gpg process edges) stay cold. Wave 4 finishes process-adapter testmaxxing for agents using captured I/O first—not full interactive TTY/askpass (T2-A).

## What Changes

- Route **production SSH** process helpers that are safe under captured I/O through CommandRunner / existing Ops injectability (agent run/parse, list identities, kill, non-interactive add paths as product allows)
- Route residual **GPG production process** edges not already heated through the same process seam or existing `GpgAgentOps` fakes where production bodies remain dark
- Unit tests with scripted process fakes for captured SSH session lifecycle and GPG process failure/success edges
- **Defer** full `runInherited` / `/dev/tty` / askpass interactive matrix to a later optional follow-up (explicit non-goal of this change)
- Floor-free gate; no live pinentry required

### Non-goals

- Full interactive SSH TTY/askpass matrix
- Ecosystem builders / ebuild/egencache (prior process wave)
- Fake-HTTP registry clients
- Apply Integration residual
- Floors; cold Main

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `test-coverage`: Require Unit coverage of residual SSH/GPG production process edges via fakes (captured I/O); floor-free

## Impact

- **Library:** `Update.SshAgent`, `Update.GpgAgent`; depends on Process seam from `process-command-runner` when applicable
- **Tests:** extend `Test.Ssh`, `Test.Gpg`
- **Program order:** after `process-command-runner`
