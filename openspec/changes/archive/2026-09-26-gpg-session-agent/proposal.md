# Proposal

## Why

A cold desktop gpg-agent asks for pinentry while the materialize image is building, and that unlock then sits in the operator's desktop agent for the rest of the run. Signing should unlock once, before package work, into an agent this process owns, and that agent should die with the process.

## What Changes

- A signing `update` or `gencache` creates a private GnuPG home and its own gpg-agent, with cache lifetimes set in that home's `gpg-agent.conf`. The desktop agent is left cold: its configuration is not edited and it is not reloaded.
- The run unlocks each distinct signing key once, on the controlling terminal, before signed work. Later signed commits in that run, including commits that overlap the image build, use the session cache and do not prompt again.
- `GNUPGHOME` is passed only to the warm-up `gpg` and to `git commit -S`. `ebuild`, `egencache`, `ssh`, and the materialize container keep the desktop home.
- Process exit kills the session agent. A supervisor also kills it if the parent dies, including under `SIGKILL`. Teardown does not clear passphrases in the desktop agent.
- Overlay commit points stay where they are: bun-bin still commits after an ensure attempt, qlot and node-gyp still commit before the build when they are on the file gate, and other admitted packages still commit when their unit succeeds.
- The operator README stops describing bun-bin's GPG prompt as happening after the image build.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `gpg-sign-readiness`: session agent, one unlock before signed work, signing children only, kill the session agent on exit instead of clearing the desktop agent.
- `update-command`: update teardown kills the owned session agent and does not clear keygrips on the desktop agent.

## Impact

- `src/Update/GpgAgent.hs`, the signed-commit path in `src/Update/Git.hs`, and the `update` / `gencache` brackets in `app/Main.hs`.
- Tests in `test/Test/Gpg.hs` (and apply tests that fake readiness) gain a session agent and an early unlock. No live pinentry and no live `docker build` in `hk check`.
- `README.md` prompt-timing sentence. No new CLI flag, config key, or package-target rule.
- A parent-death supervisor is new process machinery. The passphrase stays in the session agent; the program does not read or store it.

## Non-goals

- Holding overlay commits until the image build finishes, or until every selected package has finished apply.
- Moving bun-bin's commit back to immediately after `egencache` on a run that ensures.
- Treating qlot or node-gyp as overlay wait-edge providers, or withholding other packages on them.
- Passing the private home to `ebuild` so Portage can sign Manifests. Manifests are not signed. Adding that later means those Portage children must receive the private home.
- A socket proxy that admits only child processes. Same-uid processes that find the session socket can sign until the agent dies.
- Editing or reloading the desktop gpg-agent, copying a cached passphrase out of it, or skipping the session prompt because the desktop agent is already warm.
- Changing SSH agent reuse, image-build inputs, or the materialize container's secret scrubbing.
