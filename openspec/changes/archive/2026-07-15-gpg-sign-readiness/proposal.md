## Why

Long `update` runs finish phase-1 work (or mid-phase assets publishes) while the operator is away; pinentry then appears with a short GUI timeout and signed `git commit -S` fails. The tool already warms SSH early for assets push, but GPG still unlocks lazily at the first sign with no ready-gate, no TTY pinentry preference, and no cleanup of passphrases this process unlocked.

## What Changes

- Before every GPG-signed git commit (overlay and assets worktrees), ensure the signing key’s passphrase is available in gpg-agent when needed: poll agent cache warmth; if cold, require a controlling TTY, prompt “ready?”, then unlock via terminal pinentry.
- Resolve the signing key only from that worktree’s `git config user.signingkey` (no gpg default-key fallback); map to a sign-capable keygrip for cache checks and clear.
- Prefer TTY pinentry for warm/sign child processes (`GPG_TTY` set; avoid relying on GUI pinentry such as pinentry-gnome3).
- On process exit, clear gpg-agent cached passphrases only for keygrips this run warmed; leave already-warm agent state from other tools alone.
- Fail early when signing is required but `user.signingkey` is missing, no controlling TTY is available for a needed unlock, or TTY pinentry cannot be arranged.
- No new CLI flags; behavior is always on for `update` signing paths. Fully unattended / no-TTY automation remains out of scope.

## Capabilities

### New Capabilities

- `gpg-sign-readiness`: Per-worktree GPG signing key resolution, agent cache warmth detection, ready-prompt and warm-up before signed commits, TTY pinentry environment, and clear-on-exit only for keys this process warmed.

### Modified Capabilities

- `update-apply`: Signed commit path MUST go through GPG readiness (not only “rely on pinentry at first commit”); still no in-process passphrase storage and no unsigned fallback.
- `update-command`: Spine/lifecycle owns GPG readiness teardown bracket analogous to SSH agent session teardown when applicable.

## Impact

- New module parallel to `Update.SshAgent` (e.g. `Update.GpgAgent`) with injectable ops for tests.
- `Update.Git` / apply signed-commit call sites (overlay phase-2 and assets publish) call ensure-ready before `git commit -S`.
- `app/Main.hs` brackets clear-on-exit for keygrips warmed during the run.
- Specs under `openspec/specs/` for the new capability plus deltas on update apply/command.
- Tests with fake KEYINFO / config / tty availability; no live pinentry in default `cabal test`.
- Operator requirement: `user.signingkey` must be set for each git worktree that will create signed commits (overlay and assets as used).
