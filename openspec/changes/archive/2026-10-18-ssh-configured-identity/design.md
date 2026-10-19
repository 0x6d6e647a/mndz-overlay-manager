# Design

## Context

See proposal.md for why. The behavior contract is `specs/ssh-agent-session/spec.md`.

`Update.SshAgent.ensureSshAgent` runs from the `update` spine only when that run will do assets work (`needDeps`), immediately before package mutation. It reuses any reachable agent that has at least one identity. Otherwise `runSshAddInteractive` collects every `IdentityFile` in `~/.ssh/config` and every existing `~/.ssh/id_*` default, then `ssh-add`s that list on `/dev/tty` or via `SSH_ASKPASS`. An agent this process starts is killed on the normal exit path. `ssh-agent` double-forks, so that kill does not run if this process is `SIGKILL`ed. `Update.GpgAgent` already covers that gap for the session gpg-agent: re-exec this binary, `PR_SET_PDEATHSIG`, recheck the parent, then kill.

`OverlayConfig` has no SSH field. `list`, `outdated`, and `gencache` never call `ensureSshAgent`. The materialize container already drops `SSH_AUTH_SOCK`.

## Goals / Non-Goals

**Goals:**

- One config path, resolved at the existing assets-push bracket, passed into `ensureSshAgent`.
- Reuse if and only if that key's SHA256 fingerprint is loaded. Otherwise an owned agent, one `ssh-add`, and a parent-death supervisor started before the prompt.
- Keep passphrase entry, askpass fallback, and the materialize scrub as they are.
- Delete key discovery. Do not leave it exported for weeder to trip over.

**Non-Goals:**

- See proposal.md Non-goals.
- A second supervisor implementation with a different lifetime rule. Copy the GPG sequence. Do not refactor the GPG supervisor in this change.
- A new exposed library module. Helpers stay in `Update.SshAgent` and `Config.Types`.
- Moving the SSH bracket earlier or later than the current pre-mutation site.

## Decisions

### 1. `ssh-identity` is an optional string, resolved only when a push will run

Add `sshIdentity :: Maybe FilePath` to `OverlayConfig` via `optKey "ssh-identity"`. TOML parse does not expand `~` and does not touch the disk. An omitted key stays `Nothing`.

`UpdateSpineDeps` gains the raw `Maybe FilePath`. `app/Main.hs` passes the config field. The spine consults it only inside the existing `needDeps` bracket. `list`, `outdated`, `gencache`, and an `update` that never enters that bracket ignore it.

Resolution is a pure function plus one existence check, both behind `SshAgentOps` so apply tests do not need a real key file:

- Expand a leading `~` or `~/` with the operator home. Do not expand `~user`.
- Require `System.FilePath.isAbsolute`.
- Reject a path whose final component ends in `.pub`.
- `doesFileExist`. A directory fails that check.
- Omitted or empty: error names `ssh-identity` and does not include a path. Any other failure includes the configured text.

Alternatives:

- Resolve at config load. `list` would fail because a key file moved. The spec requires failure only when a push will run.
- A TOML array. Rejected with the single-path decision. `ssh-add` still receives a one-element list.

### 2. Fingerprint match, then either reuse or a new agent

Production listing is `ssh-add -E sha256 -l`. Production fingerprint is `ssh-keygen -lf <path> -E sha256`. Compare the `SHA256:` token only. Comments differ between the file and the agent, so they are not the match.

`ssh-keygen -lf` reads the public half of an OpenSSH private key without the passphrase. If it fails, hard-fail with its stderr before choosing a socket. Do not fall through to `ssh-add` on the desktop agent.

Outcomes:

| Agent state | Action |
|---|---|
| Reachable, token present | `SshSessionReused`. No `ssh-add`, no `setEnv`, no supervisor. |
| Reachable, token absent, including an empty agent | Start an agent. Do not `ssh-add` into the one that is already up. |
| Missing or unreachable socket | Start an agent, as today. |

The owned path sets `SSH_AUTH_SOCK` and `SSH_AGENT_PID` on this process so `git push` inherits them. Teardown unsets both. It does not restore the previous socket; the bracket ends after the push. The container scrub is unchanged, so a replaced parent variable still does not enter the container.

After `ssh-add`, list again and require the token. Success with the token absent is a hard fail, and the owned agent is killed.

`SshAgentOps` grows the path, the fingerprint read, the loaded-token list, and supervisor start/reap. `saoSshAdd` takes the one path. `AgentIdentities` (`HasIdentities` / `NoIdentities`) cannot express "other keys are loaded," so the list returns the tokens (unreachable stays a distinct error). Apply-test stubs report a match for the path they were given, which preserves today's "do not `ssh-add`" behavior for tests that are not about selection.

Alternatives:

- `ssh-add` the path and rely on OpenSSH to skip a key that is present. That writes into whichever agent is current, including the desktop agent, which is the lifetime this change rejects.
- Match the comment or the path string from `ssh-add -l`. The listing does not include the path.

### 3. Parent-death supervisor, same sequence as GPG

`ssh-agent` double-forks. Normal-exit `kill <pid>` stays. Before `ssh-add`, re-exec this binary with `MNDZ_OVERLAY_MANAGER_SSH_SUPERVISOR` set to that pid. The child unsets the variable, sets `PR_SET_PDEATHSIG` to `SIGTERM`, rechecks the parent pid, writes `ready` on stdout, and on the signal runs `kill <pid>`. `app/Main.hs` and `test/Main.hs` call this take-over next to `takeGpgSessionSupervisor` and skip the program when either one claims the process.

If the supervisor does not become ready, kill the agent, unset the socket variables, and return the error. No prompt.

`SshSessionOwned` carries the pid and a reap action. It cannot keep `Eq`. Tests match the pid. Teardown kills the pid, then reaps (the supervisor's `SIGTERM` kills a pid that may already be dead). Reuse carries no supervisor.

The GPG env var and kill command stay as they are. A second copy of the short prctl sequence lives in `Update.SshAgent`. Lifting a shared waiter would churn the signing supervisor for no operator-visible change.

Alternatives:

- `ssh-add -t`. The lifetime has to outlast an unknown-length pack, and it would evict a key the operator had loaded on purpose.
- Kill only on the exit bracket. That is today's owned path, and it loses to `SIGKILL`.

### 4. Discovery goes away

Remove `discoverIdentityFiles`, `parseIdentityFiles`, and `defaultIdentityCandidates`, their exports, and the tests that only exist for them. Fix the imports. `ssh-add` is called with the resolved path and no other arguments.

## Risks / Trade-offs

- [A reused desktop agent also holds other keys, and `git push` can offer those first] → Accepted. The push still uses this process's inherited socket. One extra refusal fits in `MaxAuthTries`. We do not strip the desktop agent.
- [An empty desktop agent stays empty, so a later shell push does not see the key this run unlocked] → That is the lifetime decision. The owned agent dies with the process.
- [Supervisor and parent die in the same blow, or `prctl` is unavailable] → Same residual as GPG. `prctl` failure fails the child, which fails the run before the prompt. No desktop fallback.
- [Same-uid process that finds the owned socket can use the key until the agent dies] → Same ceiling as `SSH_AUTH_SOCK` and the GPG session socket. No proxy.
- [`ssh-keygen -lf` cannot read a legacy PEM key without a passphrase] → Fail closed with the tool error. Do not prompt against the desktop agent to discover the fingerprint.
- [`SshAgentOps` field changes break the two record literals and the discovery imports] → Update those sites in the same change. Do not keep a compatibility shim.

## Migration Plan

Operators add one line before the next assets `update`:

```toml
ssh-identity = "~/.ssh/keys/shanty_github_id"
```

Runs that do not push keep working with the line absent. Rollback is reverting this change; discovery returns with the old binary. No on-disk migration beyond that line.

On archive, edit the living `ssh-agent-session` Purpose so it names the configured identity and owned-agent teardown. The delta does not carry Purpose.

## Open Questions

None. Path versus list, and reuse versus a private agent, are decided in the proposal.
