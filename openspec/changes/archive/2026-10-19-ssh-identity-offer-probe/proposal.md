# Proposal

## Why

An assets `git push` unlocks `ssh-identity` and inherits that agent, then OpenSSH may refuse to offer the key. With `IdentitiesOnly yes`, `ssh` offers only the `IdentityFile` entries for `github.com`. A configured hostel key still produces a successful `ssh-add`, and the push later fails with no terminal passphrase for the GitHub key. The mismatch is knowable before the prompt.

## What Changes

- When `update` will `git push` the assets worktree over SSH to `github.com`, the program asks OpenSSH which identities that host will offer (`ssh -G`, no connection) before any passphrase prompt.
- The push URL is the assets worktree `origin` push URL. An `http` or `https` push URL skips this comparison. SSH setup is otherwise unchanged.
- When that query reports `IdentitiesOnly yes` and no offered identity file has the same SHA256 fingerprint as `ssh-identity`, the run hard-fails before a passphrase prompt, on the same path as a missing `ssh-identity`. The error names the configured path and each offered identity path. A leading `~` in an offered path is expanded before fingerprinting. Several offered files pass when any one fingerprint matches.
- When `IdentitiesOnly` is not set, the check does not fail. OpenSSH still offers the agent key.
- When that push URL is SSH and `GIT_SSH_COMMAND` is set, or the assets worktree's effective `core.sshCommand` is set, the run hard-fails before the prompt. Those overrides select a client the query does not describe. The error names the override and does not echo the command.
- An SSH push URL whose host is not `github.com` hard-fails before the prompt. The error names the URL.
- A failed `ssh -G` or a fingerprint that cannot be read hard-fails before the prompt. An offered path that cannot be fingerprinted does not count as a match.
- `README.md` states that, for an SSH assets push, `ssh-identity` must be a key OpenSSH will offer for that host when `IdentitiesOnly` is set.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ssh-agent-session`: before unlocking `ssh-identity` for an SSH assets push, require that OpenSSH will offer that key when `IdentitiesOnly` is set. Fail closed when git's SSH command is overridden or the push host is not `github.com`.

## Impact

- `src/Update/SshAgent.hs` gains the offer query and fingerprint comparison. `src/Update/Spine.hs` runs it in the existing assets-push bracket, after the plan has decided a push will run and before `ensureSshAgent`.
- The assets `origin` push URL is the transport input. Owner/repo parsing for the GitHub API stays on the fetch URL already used today.
- `test/Test/Ssh.hs` covers the query with fakes: matching fingerprint, mismatched `IdentitiesOnly`, `IdentitiesOnly` off, HTTPS skip, SSH-command override, non-`github.com` host, and `ssh -G` failure. No live `ssh` connection and no passphrase prompt in `hk check`.
- `README.md` gains the operator constraint next to the existing `ssh-identity` paragraph. No new config key and no CLI flag, so `cli-help` is unchanged.
- On archive, the `ssh-agent-session` Purpose line names this offer check. A delta cannot carry Purpose.

## Non-goals

- Passing `-i` or `IdentitiesOnly` on the `git push` so `ssh-identity` overrides `~/.ssh/config`.
- Parsing `Host` blocks, `Include`, or `Match` in `~/.ssh/config` directly. `ssh -G` is the query.
- Ranking multiple matching identity files, or failing because a non-matching file is offered first.
- Running the check before the plan. Only the plan knows whether this run will push.
- Skipping SSH unlock for an HTTPS push URL.
- `CertificateFile`, PKCS#11, or security-key identities.
- Changing which key is unlocked, agent reuse, owned-agent teardown, GPG unlock, or the materialize environment scrub.
