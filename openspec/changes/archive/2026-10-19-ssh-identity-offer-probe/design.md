# Design

## Context

See proposal.md for why. The behavior contract is `specs/ssh-agent-session/spec.md`.

`prepareSshIdentity` then `ensureSshAgent` run from the `update` spine only when that run will do assets work (`needDeps`), immediately before package mutation. The bracket resolves `ssh-identity`, fingerprints it with `ssh-keygen -lf -E sha256`, and either reuses a reachable agent that already holds that `SHA256:` token or starts an owned agent and `ssh-add`s only that path. `git push` inherits `SSH_AUTH_SOCK`. The program does not pass `-i`. OpenSSH then applies `~/.ssh/config`, including `IdentitiesOnly`.

The assets fetch URL is already `git remote get-url origin` via `usdGitOriginUrl`. `git push` with no remote uses the push URL (`git remote get-url --push origin`). On the current assets worktree those two URLs are the same `git@github.com:…` form. `parseGitHubOrigin` accepts that form, `ssh://git@github.com/…`, `ssh://github.com/…`, and `http`/`https` `github.com` URLs.

## Goals / Non-Goals

**Goals:**

- Run the offer check in the existing `needDeps` bracket, after `prepareSshIdentity` succeeds and before `ensureSshAgent`.
- Classify the push URL with the same host shapes `parseGitHubOrigin` already accepts. Do not add a URL library.
- Reuse `saoFingerprint` and `expandLeadingHome`. Compare `SHA256:` tokens only.
- Keep the check injectable through the command runner so `hk check` never opens an SSH connection or prompts.
- Leave every `SshAgentOps` record literal alone.

**Non-Goals:**

- See proposal.md Non-goals.
- A new exposed module. Classification sits next to `parseGitHubOrigin`. The check sits in `Update.SshAgent`.
- Moving the bracket earlier than the plan or later than pre-mutation.
- Teaching `ensureSshAgent` about `IdentityFile`. It still unlocks exactly `ssh-identity` after the check passes.

## Decisions

### 1. Push URL in, then a pure transport class

Add `gitRemotePushUrl` beside `gitRemoteOriginUrl`: `git -C <assets> remote get-url --push origin`. `UpdateSpineDeps` gains `usdGitPushUrl` with that function in `app/Main.hs` and on the Waves base stub. Record updates that only override another field do not need to repeat it. Fetch-URL owner/repo parsing keeps `usdGitOriginUrl`.

`classifyAssetsPushUrl :: Text -> AssetsPushTransport` is pure:

| Push URL | Class |
|---|---|
| `https://github.com/…`, `http://github.com/…` | `PushWeb` |
| `git@github.com:…`, `ssh://git@github.com/…` | `PushSshGitHub` with user `git` |
| `ssh://github.com/…` | `PushSshGitHub` with no user |
| anything else | `PushUnsupported` carrying the raw URL |

`PushUnsupported` is the pre-prompt failure that quotes the URL. `PushWeb` returns success without `ssh` or `git config`. A port in the authority (`ssh://git@github.com:22/…`) does not match these prefixes and is unsupported. That URL is not a form `parseGitHubOrigin` accepts either.

Alternatives:

- Always query host `github.com` from the fetch URL. A distinct push URL would be checked against the wrong host.
- Reuse `usdGitOriginUrl` for both. The fetch URL and the push URL are allowed to differ; the probe has to follow `git push`.

### 2. One guard before `ensureSshAgent`, no new `SshAgentOps` field

`guardSshIdentityOffered :: CommandRunner -> SshAgentOps -> FilePath -> FilePath -> Text -> IO (Either Text ())` takes the runner, the ops, the assets root, the resolved key path, and the push URL.

The spine calls it only inside the `needDeps` bracket, and only after `prepareSshIdentity` returns a path. `Left` uses the existing `ApplyHardFail` path (`SSH agent setup failed: …`) and does not call `ensureSshAgent`, so no agent is started and teardown is a no-op.

`SshAgentOps` stays as it is. The query uses the runner, as `fingerprintOf` already does. Spine tests that construct `SshAgentOps` by hand do not grow a field. `UpdateSpineDeps` gains `usdCommandRunner`. Production passes `productionCommandRunner`. The Waves base stub passes a runner whose `ssh` and `git config` results are irrelevant when its push URL is `PushWeb` or when the stub's `usdGitPushUrl` is the web fixture those tests already conceptually use. Tests that reach the bracket with an SSH URL must supply a runner; the new `Test/Ssh.hs` cases call `guardSshIdentityOffered` directly with a scripted runner and do not go through the spine.

Order inside the guard:

1. Classify the URL. `PushWeb` returns `Right ()`. `PushUnsupported` returns `Left` with the URL.
2. `lookupEnv "GIT_SSH_COMMAND"` through `saoLookupEnv`. A non-empty value fails naming `GIT_SSH_COMMAND` and not the value.
3. `git -C <root> config --get core.sshCommand`. Exit 0 with non-empty stdout fails naming `core.sshCommand` and not the value. Exit 1 with empty stdout means unset. Any other exit fails with git's stderr.
4. `ssh -G github.com`, plus `-l git` when the class carries user `git`. Stdout is the parse input. Non-zero exit fails with stderr. Success ignores stderr, including the "Pseudo-terminal will not be allocated" line `ssh -G` writes when stdin is not a terminal.
5. If no `identitiesonly yes` line, return `Right ()` without fingerprinting.
6. Otherwise collect `identityfile` values other than `none`. Expand a leading `~` or `~/`. Fingerprint each absolute path with `saoFingerprint`. A path that is still not absolute, a `~user` form, or a fingerprint error does not match. If any token equals the configured key's token, return `Right ()`. If none do, `Left` names the configured path, every offered path, and any fingerprint error that was read.

Alternatives:

- Add `saoSshDashG` to `SshAgentOps`. Every hand-written ops literal in the test suite would change for a query most of those tests never run.
- Parse `~/.ssh/config`. `Include`, `Match`, and `Host *` are why the previous change refused that. `ssh -G` applies them.
- Force `GIT_SSH_COMMAND='ssh -i <key> -o IdentitiesOnly=yes'` around `git push`. That hides a disagreeing `IdentityFile` instead of reporting it.

### 3. `ssh -G` line shape

Each stdout line is a keyword, then whitespace, then the rest of the line. Keywords are compared case-sensitively as OpenSSH prints them (`identitiesonly`, `identityfile`). The value `yes` enables the restricted check. Any other `identitiesonly` value, including a missing line, is unrestricted. `identityfile none` is skipped. Repeated files are kept; the first fingerprint match wins.

`ssh-keygen -lf` already returns the `SHA256:` token without the comment and without a passphrase for an OpenSSH private key. The same call works on a `.pub` file. Comments are not compared.

### 4. README

Add one sentence to the existing `ssh-identity` paragraph: for an SSH assets push, when OpenSSH will offer only configured identity files, `ssh-identity` must be one of those files, and a mismatch fails before the passphrase prompt. The example path stays `~/.ssh/keys/shanty_github_id`. No config-key rename, so the table row stays.

## Risks / Trade-offs

- [The plan still runs before this check, because `needDeps` is known only after the plan] → Accepted. The saved work is the passphrase and the package mutation, which is the failure that shipped a useless unlock.
- [`IdentitiesOnly` off still offers the agent key after other identity files, and a server may disconnect on an earlier key] → Accepted. The spec fails only the restricted case. See proposal non-goals.
- [A relative `identityfile` with no leading `~` is not absolute after expansion, so it cannot match] → Fail closed and name the path. `ssh -G` does not report the cwd `ssh` would use, and the guard does not run inside the assets worktree. Operators already use `~/` or absolute paths.
- [`ssh -G` and `git config` are extra processes on every assets push] → Both are local and run once per `update`, not once per package.
- [`core.sshCommand` from `includeIf` or the system file is visible to `git -C <root> config --get`] → That is the effective value git will use. Treat it as an override.
- [A hand-built `SshAgentOps` in an unrelated test drifts if someone later adds a field anyway] → This change does not add one. The guard takes the runner as an argument.

## Migration Plan

Operators whose `ssh-identity` is not the GitHub identity file get a pre-prompt error naming both paths. Point `ssh-identity` at the offered file. No other config migration. Rollback is reverting the change; the unlock-only behavior returns with the old binary.

On archive, edit the living `ssh-agent-session` Purpose so it names the offer check. The delta does not carry Purpose.
