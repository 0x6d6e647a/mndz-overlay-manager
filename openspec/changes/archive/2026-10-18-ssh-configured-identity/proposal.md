# Proposal

## Why

An assets `git push` unlocks every `IdentityFile` in `~/.ssh/config` plus every default `~/.ssh/id_*` key, and it treats any loaded identity as proof that the GitHub key is ready. The push needs one configured private key, and a key this run unlocks must not remain in the desktop agent.

## What Changes

- **BREAKING:** An `update` that will `git push` the assets worktree requires `ssh-identity` in the overlay-manager config: one private-key path. `~` is expanded. Any other relative path, a missing file, or a `.pub` path hard-fails before a prompt. Commands that will not push (`list`, `outdated`, `gencache`, and an `update` with no assets push) accept a config that omits the key.
- The program unlocks only that path. It no longer parses `~/.ssh/config` or adds default identity basenames.
- When a reachable agent already holds that key, the run uses that agent, does not prompt, does not add a key, and does not kill the agent on exit.
- When that key is absent, the agent is empty, or no usable agent exists, the run starts an agent it owns, adds only that path, and points this process's `SSH_AUTH_SOCK` at it. Exit kills that agent. A parent-death supervisor kills it if this process dies, including under `SIGKILL`. The desktop agent is left unchanged.
- The prompt stays before package work. Passphrase entry stays on `/dev/tty`, then `SSH_ASKPASS`. The materialize container still does not receive `SSH_AUTH_SOCK`.
- No CLI flag and no environment variable select the key.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ssh-agent-session`: configured identity instead of key discovery; reuse only when that key is loaded; owned agent and parent-death teardown when it is not.

## Impact

- `src/Config/Types.hs` and config load tests gain optional `ssh-identity`.
- `src/Update/SshAgent.hs` stops discovering keys. `ensureSshAgent` takes the resolved path, matches it against `ssh-add -l`, and either reuses the existing agent or starts an owned one. The assets-push bracket in `src/Update/Spine.hs` supplies the path and the supervisor.
- `test/Test/Ssh.hs` and `test/Test/Config.hs` cover the path rules, reuse, the owned agent, and teardown. No live passphrase prompt in `hk check`.
- `README.md` config table and example document `ssh-identity` at operator depth. No new global option, so `cli-help` is unchanged.
- On archive, the `ssh-agent-session` Purpose line changes from key discovery to the configured identity. A delta cannot carry Purpose.

## Non-goals

- A list of keys, a CLI flag, or an environment variable for the path.
- Loading the key into the desktop agent when it is not already there.
- Starting a private agent when the configured key is already loaded.
- Removing other identities from a reused agent, or hiding them from `git push` while that agent is reused.
- Parsing `Host` blocks or asking `ssh -G` which key OpenSSH would pick.
- Delaying the prompt until the moment of `git push`.
- An `ssh-add -t` lifetime on the desktop agent.
- Passing `SSH_AUTH_SOCK` only to the `git push` child. An owned socket is this process's environment for the run; the materialize container still strips it.
- Changing GPG session unlock, assets remote URLs, or which runs prepare SSH.
