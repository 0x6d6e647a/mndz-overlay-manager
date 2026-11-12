# Spec Delta

## ADDED Requirements

### Requirement: Git operations are measured subprocesses

When recording, every `git` subprocess the program starts for overlay or assets-worktree work (work-tree detection, dirty-path checks, staging, signed commits, `HEAD` lookup, push, and remote URL lookup) SHALL be a `proc` span with a `time` object, recorded like any other subprocess run through the product's shared command execution.

#### Scenario: Git status is measured

- **WHEN** `update` checks whether overlay paths are dirty
- **THEN** a `proc` span for `git` exists with its exit status and a `time` object
- **AND** the span does not include `interactive`

#### Scenario: Remote URL lookup is measured

- **WHEN** `update` reads the assets worktree's `origin` URL
- **THEN** a `proc` span for `git` with a `time` object records the lookup

#### Scenario: Missing git keeps its failure

- **WHEN** the `git` executable cannot be found on `PATH`
- **THEN** the program reports the same missing-tool failure it reports with `--no-metrics`

### Requirement: Signed commit and push spans are interactive

The `proc` spans for `git commit -S` and `git push` SHALL include `interactive: true`, because they can wait on the operator. Their stdout, stderr, stdin, signing environment, and exit status as seen by the program SHALL be unchanged by recording.

#### Scenario: Push and signed commit are marked interactive

- **WHEN** `update` creates a signed assets commit and pushes it
- **THEN** the `git commit` span and the `git push` span each include `interactive: true` and a `time` object

#### Scenario: Signed commit CPU use is not the signing cost

- **WHEN** a signed commit's `proc` span is read
- **THEN** its `time` object describes only the `git` process and its children
- **AND** the signing work done by the GPG agent is not attributed to it

#### Scenario: Signing environment is not recorded

- **WHEN** a signed commit runs with a signing-specific child environment
- **THEN** the recorded span contains the command arguments after redaction
- **AND** it contains no environment variable values

### Requirement: Interrupted measured subprocesses do not outlive the run

When a measured subprocess is cancelled, for example by an interrupt, the program SHALL terminate the processes that subprocess started, so recording does not leave a command running that would have stopped without it. A subprocess that completes SHALL NOT have its background processes terminated.

#### Scenario: Interrupt stops the command

- **WHEN** a measured subprocess is interrupted while its command is running
- **THEN** its `proc` span ends `fail`
- **AND** the command it started is no longer running afterwards

#### Scenario: Completed subprocess keeps its background processes

- **WHEN** a measured subprocess exits normally after starting a background process
- **THEN** that background process is left running

## REMOVED Requirements

### Requirement: Other subprocesses have wall-clock spans

**Reason**: Git operations no longer belong to the group of subprocesses without a `time` object, so the requirement and its git scenario no longer hold. The remaining subprocesses move to a requirement that names only them.
**Migration**: See "Git operations are measured subprocesses" and "Signed commit and push spans are interactive" for git, and "Remaining subprocesses have wall-clock spans" for the others.

## ADDED Requirements

### Requirement: Remaining subprocesses have wall-clock spans

Subprocesses the program starts outside the shared command execution (GPG commands that build the session key home, and Portage `DISTDIR` and rusty_v8 snapshot reads) SHALL each be recorded as a `proc` span with wall-clock timing and exit status, without a `time` object. Interactive `ssh-add` SHALL be recorded the same way with `interactive: true`.

#### Scenario: Portage DISTDIR lookup is timed

- **WHEN** `update` queries Portage for its `DISTDIR`
- **THEN** a `proc` span for `portageq` with its duration and exit status exists in the run
- **AND** the span has no `time` object
