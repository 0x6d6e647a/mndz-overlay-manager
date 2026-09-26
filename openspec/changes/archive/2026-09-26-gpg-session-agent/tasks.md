# Tasks

## 1. Session home

- [x] 1.1 Add a session-home builder on `Update.GpgAgent` (no new exposed module). It creates a mode-700 directory, writes `gpg-agent.conf` with `default-cache-ttl 28800`, `max-cache-ttl 28800`, and `pinentry-program /usr/bin/pinentry-tty`, leaves `use-keyboxd` off, exports only the public half of the requested signing keys, and links only those sign-capable secret key files. If the host GnuPG will not sign through a symlink, copy that one key file instead. Verify with a non-interactive test that sets its own `GNUPGHOME` under a temp directory, generates a no-passphrase key there, builds a session home, and produces a signature with `gpg --homedir` on that session home. The test must not contact the desktop socket. Assert the session home does not contain any other secret key file, and that deleting the home removes a symlink without deleting the source key file.

## 2. Session agent lifetime

- [x] 2.1 Extend the existing `GpgAgentOps` / handle so KEYINFO, the clearsign warm, and teardown target the session home. Teardown runs `gpgconf --homedir <session> --kill gpg-agent`, removes the session home, and does not send `CLEAR_PASSPHRASE` to the desktop agent. Verify unit tests: a warm desktop KEYINFO still takes the ready-prompt path; teardown records a session kill and no desktop `CLEAR_PASSPHRASE`; a second keygrip in the same process is unlocked once when the grips match and twice when they differ.
- [x] 2.2 Start a supervisor child before unlock. It sets the Linux parent-death signal to SIGTERM, rechecks that its parent is still this process, and on that signal runs the session kill. If the supervisor cannot start, fail before any unlock and do not use the desktop agent. Normal exit kills the agent, removes the home, and reaps the child. Verify a test that signals the supervisor and observes the session kill, and a test that a supervisor start failure returns the hard-fail error without a warm-up call.

## 3. Signing children only

- [x] 3.1 Pass the session `GNUPGHOME` only on the warm-up `gpg` child and on `git commit -S`. Leave it out of the parent environment, `ebuild`, `egencache`, and `ssh`. Keep the materialize container's existing `GNUPGHOME` scrub. Verify a test that the commit and warm-up child environments contain the session home and `GPG_TTY`, that the parent environment does not gain `GNUPGHOME`, and that an `ebuild` / `egencache` invocation in that run does not receive it.

## 4. Unlock before signed work

- [x] 4.1 On `update`, after plan, when any selected unit may sign, build the session home, start the supervisor, and unlock each distinct overlay and (when this run may publish assets) assets signing key before workers and before `docker build`. Skip the session entirely when the run will not sign. Verify an apply test with a fake ensure: an overlap GitMv commit runs during the fake build and does not call the ready-prompt; bun-bin's commit is still after that build; a run with nothing to sign does not prompt and does not start a supervisor.
- [x] 4.2 On `gencache`, use the same session agent immediately before the signed cache commit, and skip it when there is nothing to commit. `gencache` may open a product run root just for `gpg-home`. Remove `gpg-home` on every exit, including a hard failure that retains the rest of a run root. Verify a gencache test that a cache commit is signed through the session home, that an unchanged tree does not prompt, and that a failed run's retained scratch does not contain `gpg-home`.
- [x] 4.3 Update the README sentence that places bun-bin's GPG prompt after the image-build attempt, so it describes one prompt before signed work and commits that still overlap the build. Verify the old timing sentence is gone and the replacement matches the spec scenarios for the early prompt and the unchanged bun-bin commit point.

## 5. Gate

- [x] 5.1 Leave living `openspec/specs/` unchanged until archive. On archive, replace the `gpg-sign-readiness` Purpose line so it describes the session agent and its teardown; a delta cannot carry that Purpose. Verify `openspec validate --change gpg-session-agent --strict` and `hk check` both exit 0.
