# Spec Delta

## ADDED Requirements

### Requirement: Passphrase prompt does not time out

The session agent SHALL be configured so the terminal pinentry waits for the operator without expiring. The configuration SHALL set the pinentry timeout to 2147483647 seconds, the largest value the terminal pinentry accepts. It SHALL NOT use `0`, because the agent then sends no timeout and the pinentry falls back to a 60 second default. The session agent configuration SHALL NOT change the desktop agent.

#### Scenario: Prompt outlasts the pinentry default

- **WHEN** the session-agent cache is cold, the pinentry prompt is showing, and the operator does not answer for longer than 60 seconds
- **THEN** the prompt is still open and unlock has not failed

#### Scenario: Operator answers late

- **WHEN** the operator enters the passphrase after being away for several minutes
- **THEN** the unlock succeeds and the key is cached in the session agent

## RENAMED Requirements

- FROM: `### Requirement: Ready prompt and unlock when cache is cold`
- TO: `### Requirement: Unlock when cache is cold`

## MODIFIED Requirements

### Requirement: Detect agent cache warmth before each signed commit

Immediately before every GPG-signed git commit (overlay or assets), the program SHALL query the session agent for whether the worktree’s signing keygrip has a cached passphrase (KEYINFO cached field warm vs cold). The program SHALL NOT treat warmth detection as an unlock operation. A cached passphrase in the desktop agent SHALL NOT count as warm.

#### Scenario: Warm cache skips unlock

- **WHEN** KEYINFO on the session agent reports the signing keygrip is cached
- **THEN** the program proceeds to `git commit -S` without a passphrase prompt or additional unlock for that commit

#### Scenario: Cold cache requires unlock

- **WHEN** KEYINFO on the session agent reports the signing keygrip is not cached
- **THEN** the program unlocks the key through the terminal pinentry before `git commit -S`

#### Scenario: Desktop warmth is ignored

- **WHEN** the desktop agent has the signing key cached and the session agent does not
- **THEN** the program treats the key as cold

### Requirement: No optional flag for GPG readiness

GPG readiness behavior SHALL always apply when `update` or `gencache` performs signed commits. The program SHALL NOT require a CLI flag to enable the session agent, warmth checks, TTY pinentry environment, or session-agent teardown.

#### Scenario: Always on for signed update commits

- **WHEN** the user runs `update` and a package reaches a signed commit
- **THEN** readiness rules apply without an extra enable flag

#### Scenario: Always on for gencache

- **WHEN** the user runs `gencache` and a signed cache commit is created
- **THEN** readiness rules apply without an extra enable flag

### Requirement: Unlock each signing key before signed work

Before `update` starts concurrent package work that may sign, the program SHALL unlock each distinct signing key that work may use (overlay, and assets when this run may publish assets) into the session agent, using the terminal pinentry. One keygrip shared by both worktrees SHALL be unlocked once. A `gencache` run SHALL unlock the overlay signing key into the session agent before its signed commit. After that unlock, a later signed commit in the same process whose session-agent cache is still warm SHALL NOT prompt again, including a commit that runs while the materialize image is building.

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

### Requirement: Unlock when cache is cold

When the session agent's cache for the signing keygrip is cold, the program SHALL require a controlling terminal and SHALL unlock the key via the terminal pinentry so the passphrase is cached in the session agent. The pinentry prompt SHALL appear immediately, with no separate operator confirmation step before it. The program SHALL NOT read or store the GPG passphrase in the process. If no controlling terminal is available when unlock is required, the program SHALL hard-fail with an error explaining that interactive GPG unlock is required. Fully unattended unlock without a TTY is out of scope.

#### Scenario: Unlock on TTY

- **WHEN** the session-agent cache is cold and a controlling TTY is available
- **THEN** the program triggers pinentry unlock for the signing key without first waiting for the operator to confirm on that TTY

#### Scenario: No TTY when unlock required

- **WHEN** the session-agent cache is cold and no controlling TTY is available
- **THEN** the program hard-fails without attempting GUI-only unlock as the success path
