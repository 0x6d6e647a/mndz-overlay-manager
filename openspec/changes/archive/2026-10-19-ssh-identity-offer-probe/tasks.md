# Tasks

## 1. Push URL classification

- [x] 1.1 Add `classifyAssetsPushUrl` beside `parseGitHubOrigin` with `PushWeb`, `PushSshGitHub` (optional user), and `PushUnsupported`, using the host prefixes `parseGitHubOrigin` already accepts. Verify `just test classifyAssetsPushUrl` covers `git@github.com:`, `ssh://git@github.com/`, `ssh://github.com/`, `https://` and `http://` github URLs, a non-github SSH URL, and an `ssh://git@github.com:22/` port URL as unsupported.

## 2. Offer guard

- [x] 2.1 Add `gitRemotePushUrl` (`git remote get-url --push origin`) beside `gitRemoteOriginUrl`, and add `guardSshIdentityOffered` per design.md: web URL skips, SSH command override fails without echoing the command, `git config --get` exit 1 means unset, `ssh -G` parses `identitiesonly` and `identityfile`, `none` is skipped, `~` expands, fingerprints use `saoFingerprint`, and a restricted set with no matching token fails naming both paths. Do not add an `SshAgentOps` field. Verify `just test guardSshIdentityOffered` covers the spec scenarios: user `git`, URL without a user, `IdentitiesOnly` mismatch, tilde match, any-one-of-several match, `IdentitiesOnly` off, `GIT_SSH_COMMAND`, `core.sshCommand`, https ignoring `GIT_SSH_COMMAND`, non-github host, `ssh -G` failure, and an unreadable offered path.

## 3. Spine bracket

- [x] 3.1 Add `usdGitPushUrl` and `usdCommandRunner` to `UpdateSpineDeps`. Production wires `gitRemotePushUrl` and `productionCommandRunner`. The Waves base stub uses an `https://github.com/…` push URL so the guard does not call `ssh`. In the `needDeps` bracket, after `prepareSshIdentity` succeeds and before `ensureSshAgent`, call `guardSshIdentityOffered`. A `Left` uses the existing `SSH agent setup failed` hard-fail and does not start an agent. Verify `just test` for the spine SSH cases still passes, including a new case whose push URL is SSH, whose scripted `ssh -G` reports `IdentitiesOnly yes` for a different fingerprint, and whose outcome is that hard-fail without `ssh-add`.

## 4. Operator docs

- [x] 4.1 Add the README sentence from design.md to the existing `ssh-identity` paragraph. Leave the example path `~/.ssh/keys/shanty_github_id` and the config table row unchanged. Verify the paragraph states that a restricted offer set must include `ssh-identity` and that a mismatch fails before the passphrase prompt.

## 5. Gate

- [x] 5.1 Verify `openspec validate --change ssh-identity-offer-probe --strict` and `just check` both pass.

## Workflow follow-up

- On archive, edit the living `ssh-agent-session` Purpose so it names the offer check. The delta does not carry Purpose.
