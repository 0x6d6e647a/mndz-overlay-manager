# gpg-sign-readiness Specification

## Purpose

Per-worktree GPG signing key resolution, agent cache warmth detection, ready-prompt and warm-up before signed commits, TTY pinentry environment, and clear-on-exit only for keygrips this process warmed.

## Requirements

### Requirement: Resolve signing keygrip from git user.signingkey per worktree

Before ensuring GPG readiness for a signed commit in a git worktree, the program SHALL resolve the signing key by reading `user.signingkey` from git configuration for that worktree (including repository-local overrides). The program SHALL map that identifier to a sign-capable secret keygrip via gpg. The program SHALL NOT fall back to gpg’s default secret key when `user.signingkey` is unset or empty. Missing, unresolvable, or non-sign-capable configuration SHALL be a hard failure for that signing attempt with an error that names the worktree and the problem.

The program SHALL track resolved keygrip and warm-up ownership per worktree (overlay and assets independently). When both worktrees resolve to the same keygrip, teardown SHALL clear that keygrip at most once.

#### Scenario: user.signingkey required

- **WHEN** a signed commit is about to run in a worktree and `git config user.signingkey` is unset for that worktree
- **THEN** the program hard-fails that signing attempt without guessing a default gpg key

#### Scenario: Sign-capable keygrip from configured key

- **WHEN** `user.signingkey` identifies a secret key with a sign-capable keygrip
- **THEN** readiness uses that keygrip for cache checks and optional clear

#### Scenario: Per-worktree resolution

- **WHEN** overlay and assets worktrees have different `user.signingkey` values
- **THEN** each signed commit uses the keygrip resolved for its own worktree

### Requirement: Detect agent cache warmth before each signed commit

Immediately before every GPG-signed git commit (overlay or assets), the program SHALL query gpg-agent for whether the worktree’s signing keygrip has a cached passphrase (KEYINFO cached field warm vs cold). The program SHALL NOT treat warmth detection as an unlock operation.

#### Scenario: Warm cache skips ready prompt

- **WHEN** KEYINFO reports the signing keygrip is cached
- **THEN** the program proceeds to `git commit -S` without a ready-prompt or additional unlock for that commit

#### Scenario: Cold cache requires readiness

- **WHEN** KEYINFO reports the signing keygrip is not cached
- **THEN** the program performs the ready-prompt and unlock sequence before `git commit -S`

### Requirement: Ready prompt and unlock when cache is cold

When the signing keygrip cache is cold, the program SHALL require a controlling terminal. It SHALL prompt the operator on that terminal to confirm they are ready (for example, press Enter), then unlock the key via pinentry so the passphrase is cached in gpg-agent. The program SHALL NOT read or store the GPG passphrase in the process. If no controlling terminal is available when unlock is required, the program SHALL hard-fail with an error explaining that interactive GPG unlock is required. Fully unattended unlock without a TTY is out of scope.

#### Scenario: Ready then unlock on TTY

- **WHEN** the cache is cold and a controlling TTY is available
- **THEN** the program waits for operator confirmation on that TTY and then triggers pinentry unlock for the signing key

#### Scenario: No TTY when unlock required

- **WHEN** the cache is cold and no controlling TTY is available
- **THEN** the program hard-fails without attempting GUI-only unlock as the success path

### Requirement: Prefer terminal pinentry for warm and signed commits

For GPG unlock and for `git commit -S` child processes, the program SHALL set `GPG_TTY` to the controlling terminal when available and SHALL arrange that pinentry does not depend on a graphical pinentry dialog (for example by clearing `DISPLAY` in those child environments so a TTY pinentry is used). The program SHALL NOT leave the parent process’s environment permanently without `DISPLAY` solely for this purpose. If terminal pinentry cannot be arranged when unlock is required, the program SHALL hard-fail rather than relying on a GUI pinentry timeout.

#### Scenario: Child sign environment uses GPG_TTY

- **WHEN** the program runs a signed commit or unlock operation with a controlling TTY
- **THEN** the child process environment includes `GPG_TTY` set to that terminal

#### Scenario: GUI pinentry not the required path

- **WHEN** unlock is required and a controlling TTY is available
- **THEN** the program does not require a successful graphical pinentry dialog to complete unlock

### Requirement: Clear only keygrips this process warmed

If this process caused an unlock that cached a passphrase for a keygrip, the program SHALL clear that passphrase from gpg-agent on process exit (success or failure). The program SHALL NOT clear keygrips that were already warm without this process unlocking them. When multiple worktrees share one warmed keygrip, the program SHALL clear it once.

#### Scenario: Clear after we unlocked

- **WHEN** the process unlocked a cold keygrip during the run
- **THEN** process exit clears that keygrip’s cached passphrase via gpg-agent

#### Scenario: Do not clear pre-warmed agent

- **WHEN** the signing keygrip was already cached before any unlock by this process and this process never unlocked it
- **THEN** process exit does not clear that keygrip’s cache because of this run

### Requirement: No optional flag for GPG readiness

GPG readiness behavior SHALL always apply when `update` performs signed commits. The program SHALL NOT require a CLI flag to enable ready-prompt, warmth checks, TTY pinentry environment, or clear-on-exit for warmed keygrips.

#### Scenario: Always on for signed update commits

- **WHEN** the user runs `update` and a package reaches a signed commit
- **THEN** readiness rules apply without an extra enable flag
