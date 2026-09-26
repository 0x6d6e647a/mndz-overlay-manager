# gpg-sign-readiness Specification

## Purpose

Per-worktree GPG signing key resolution, a process-owned session agent unlocked before signed work, session-agent cache checks, ready-prompt and TTY pinentry, and teardown that kills that session agent.

## Requirements

### Requirement: Resolve signing keygrip from git user.signingkey per worktree

Before ensuring GPG readiness for a signed commit in a git worktree, the program SHALL resolve the signing key by reading `user.signingkey` from git configuration for that worktree (including repository-local overrides). The program SHALL map that identifier to a sign-capable secret keygrip via gpg. The program SHALL NOT fall back to gpg’s default secret key when `user.signingkey` is unset or empty. Missing, unresolvable, or non-sign-capable configuration SHALL be a hard failure for that signing attempt with an error that names the worktree and the problem.

The program SHALL track the resolved keygrip per worktree (overlay and assets independently). Both worktrees SHALL be served by the one session agent for that process. When both worktrees resolve to the same keygrip, that keygrip SHALL be unlocked once.

#### Scenario: user.signingkey required

- **WHEN** a signed commit is about to run in a worktree and `git config user.signingkey` is unset for that worktree
- **THEN** the program hard-fails that signing attempt without guessing a default gpg key

#### Scenario: Sign-capable keygrip from configured key

- **WHEN** `user.signingkey` identifies a secret key with a sign-capable keygrip
- **THEN** readiness uses that keygrip for session-agent cache checks and unlock

#### Scenario: Per-worktree resolution

- **WHEN** overlay and assets worktrees have different `user.signingkey` values
- **THEN** each signed commit uses the keygrip resolved for its own worktree

### Requirement: Detect agent cache warmth before each signed commit

Immediately before every GPG-signed git commit (overlay or assets), the program SHALL query the session agent for whether the worktree’s signing keygrip has a cached passphrase (KEYINFO cached field warm vs cold). The program SHALL NOT treat warmth detection as an unlock operation. A cached passphrase in the desktop agent SHALL NOT count as warm.

#### Scenario: Warm cache skips ready prompt

- **WHEN** KEYINFO on the session agent reports the signing keygrip is cached
- **THEN** the program proceeds to `git commit -S` without a ready-prompt or additional unlock for that commit

#### Scenario: Cold cache requires readiness

- **WHEN** KEYINFO on the session agent reports the signing keygrip is not cached
- **THEN** the program performs the ready-prompt and unlock sequence before `git commit -S`

#### Scenario: Desktop warmth is ignored

- **WHEN** the desktop agent has the signing key cached and the session agent does not
- **THEN** the program treats the key as cold

### Requirement: Ready prompt and unlock when cache is cold

When the session agent's cache for the signing keygrip is cold, the program SHALL require a controlling terminal. It SHALL prompt the operator on that terminal to confirm they are ready (for example, press Enter), then unlock the key via pinentry so the passphrase is cached in the session agent. The program SHALL NOT read or store the GPG passphrase in the process. If no controlling terminal is available when unlock is required, the program SHALL hard-fail with an error explaining that interactive GPG unlock is required. Fully unattended unlock without a TTY is out of scope.

#### Scenario: Ready then unlock on TTY

- **WHEN** the session-agent cache is cold and a controlling TTY is available
- **THEN** the program waits for operator confirmation on that TTY and then triggers pinentry unlock for the signing key

#### Scenario: No TTY when unlock required

- **WHEN** the session-agent cache is cold and no controlling TTY is available
- **THEN** the program hard-fails without attempting GUI-only unlock as the success path

### Requirement: Prefer terminal pinentry for warm and signed commits

For GPG unlock and for `git commit -S` child processes, the program SHALL set `GPG_TTY` to the device node of the controlling terminal when that node can be resolved. The device node is the path of the terminal itself, such as `/dev/pts/N`, and it is a path a process with no controlling terminal can open. The program SHALL NOT set `GPG_TTY` to `/dev/tty`. The program SHALL replace a `GPG_TTY` value inherited from the parent environment with that device node. The program SHALL arrange that pinentry does not depend on a graphical pinentry dialog (for example by clearing `DISPLAY` in those child environments so a TTY pinentry is used). The program SHALL NOT leave the parent process’s environment permanently without `DISPLAY` solely for this purpose. If the device node cannot be resolved when unlock is required, including when the only available name is `/dev/tty`, the program SHALL hard-fail rather than relying on a GUI pinentry timeout.

#### Scenario: Child sign environment uses GPG_TTY

- **WHEN** the program runs a signed commit or unlock operation and the controlling terminal's device node is `/dev/pts/N`
- **THEN** the child process environment includes `GPG_TTY` set to `/dev/pts/N`

#### Scenario: Alias path is not used

- **WHEN** the program runs a signed commit or unlock operation with a controlling terminal
- **THEN** the child `GPG_TTY` is not `/dev/tty`

#### Scenario: Inherited GPG_TTY is replaced

- **WHEN** the parent environment sets `GPG_TTY` to a different path and the controlling terminal's device node can be resolved
- **THEN** the unlock and `git commit -S` children receive that device node as `GPG_TTY`

#### Scenario: GUI pinentry not the required path

- **WHEN** unlock is required and a controlling terminal device node can be resolved
- **THEN** the program does not require a successful graphical pinentry dialog to complete unlock

#### Scenario: Unresolved device node fails unlock

- **WHEN** unlock is required and the controlling terminal's device node cannot be resolved
- **THEN** the program hard-fails without a graphical pinentry dialog and without publishing `GPG_TTY` as `/dev/tty`

### Requirement: No optional flag for GPG readiness

GPG readiness behavior SHALL always apply when `update` or `gencache` performs signed commits. The program SHALL NOT require a CLI flag to enable the session agent, ready-prompt, warmth checks, TTY pinentry environment, or session-agent teardown.

#### Scenario: Always on for signed update commits

- **WHEN** the user runs `update` and a package reaches a signed commit
- **THEN** readiness rules apply without an extra enable flag

#### Scenario: Always on for gencache

- **WHEN** the user runs `gencache` and a signed cache commit is created
- **THEN** readiness rules apply without an extra enable flag

### Requirement: Signing runs use a session agent

When `update` or `gencache` will create a GPG-signed commit, the program SHALL sign through a GnuPG home and gpg-agent created for that process. Cache lifetimes for that agent SHALL be set in that home. The desktop agent SHALL stay unused for those signatures: the program SHALL NOT edit the desktop agent configuration, SHALL NOT reload the desktop agent, and SHALL NOT treat a passphrase cached in the desktop agent as warmth for this run. The session agent SHALL be able to sign with each distinct `user.signingkey` this run will use, and SHALL NOT be given the operator's other secret keys. If the session home or its agent cannot be started, or if a terminal pinentry cannot be arranged for it, the program SHALL hard-fail before any signed commit and, on `update`, before the materialize image build. The program SHALL NOT read or store the GPG passphrase.

#### Scenario: Desktop cache does not skip the session prompt

- **WHEN** `update` will create a signed commit and the desktop agent already has the signing key's passphrase cached
- **THEN** the program still unlocks that key into the session agent
- **AND** the desktop agent configuration is unchanged

#### Scenario: Session setup failure blocks signing and the image build

- **WHEN** `update` would sign and would build the materialize image, and the session agent cannot be started
- **THEN** the program hard-fails before that image build and before any signed commit

#### Scenario: No signed work means no session agent

- **WHEN** `update` or `gencache` finishes without creating a signed commit
- **THEN** the program does not leave a session agent running and does not prompt for GPG solely to create one

### Requirement: Unlock each signing key before signed work

Before `update` starts concurrent package work that may sign, the program SHALL unlock each distinct signing key that work may use (overlay, and assets when this run may publish assets) into the session agent, using the ready-prompt and terminal pinentry sequence. One keygrip shared by both worktrees SHALL be unlocked once. A `gencache` run SHALL unlock the overlay signing key into the session agent before its signed commit. After that unlock, a later signed commit in the same process whose session-agent cache is still warm SHALL NOT prompt again, including a commit that runs while the materialize image is building.

#### Scenario: One prompt before the image build

- **WHEN** `update` will build the materialize image and will sign with one keygrip
- **THEN** the operator is prompted once before that image build
- **AND** a signed commit that finishes while that build is still running does not prompt again

#### Scenario: Two signing keys unlock before package work

- **WHEN** `update` may sign the overlay and the assets worktree with different signing keys
- **THEN** the program unlocks both keys into the session agent before concurrent package work
- **AND** each key is prompted once

#### Scenario: gencache unlocks before its commit

- **WHEN** `gencache` is about to create its signed overlay commit
- **THEN** that commit is signed by the session agent
- **AND** the desktop agent is not the agent that caches the passphrase

### Requirement: Session home is limited to signing children

The program SHALL pass the session GnuPG home to the warm-up unlock and to `git commit -S` children. It SHALL leave `ebuild`, `egencache`, `ssh`, and the materialize container on the desktop home. The parent process environment SHALL stay without a session `GNUPGHOME`.

#### Scenario: Manifest generation does not see the session home

- **WHEN** `update` runs `ebuild … manifest` or package `egencache` in a signing run
- **THEN** those children do not receive the session GnuPG home

#### Scenario: Signed commit uses the session home

- **WHEN** a unit creates a signed overlay or assets commit in a signing run
- **THEN** that `git commit -S` uses the session agent

### Requirement: Session agent dies with the signing process

On process exit after a session agent was started, success or failure, the program SHALL terminate that agent so its cached passphrases are gone. If the signing process is killed after the agent has started, the agent SHALL still be terminated. Teardown SHALL NOT clear a passphrase in the desktop agent and SHALL NOT reload the desktop agent. The session home SHALL be removed on every exit, including a failure that retains other scratch for inspection, and that removal SHALL NOT delete the operator's real secret-key files.

#### Scenario: Normal exit stops the session agent

- **WHEN** `update` unlocked the session agent and then exits 0
- **THEN** the session agent is not left running
- **AND** the desktop agent's cached passphrases are unchanged by this run

#### Scenario: Failure still stops the session agent

- **WHEN** `update` unlocked the session agent and a later package hard-fails
- **THEN** process exit still terminates the session agent and removes the session home

#### Scenario: Killed parent does not leave the agent

- **WHEN** the signing process is killed after the session agent has started
- **THEN** the session agent is terminated

### Requirement: Session signing does not move commit points

Using the session agent SHALL NOT change when a unit's signed commit is created. Those points remain as specified by `update-apply` and `md5-cache`: commit-on-unit-success, bun-bin's commit after an ensure attempt when ensure ran, qlot and node-gyp commits not delayed solely because ensure ran, and `gencache`'s single commit after cache regeneration when paths changed.

#### Scenario: Overlap commit still happens during the image build

- **WHEN** `update` builds the materialize image and an admitted package other than `dev-lang/bun-bin` is ready to sign during that build
- **THEN** that package's signed commit is still created during the build
- **AND** the commit uses the session agent

#### Scenario: bun-bin still commits after ensure

- **WHEN** `update` ensures the materialize image and `dev-lang/bun-bin` needs GitMv work
- **THEN** bun-bin's signed overlay commit is still created after that ensure attempt finishes
