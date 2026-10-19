# Tasks

## 1. Config key and path resolution

- [x] 1.1 Add optional `ssh-identity` to `OverlayConfig` (`optKey`, `Maybe FilePath`, no disk I/O and no `~` expansion at parse). Verify `test/Test/Config.hs` loads a file that omits it, loads one that sets an absolute path, and loads one that sets a `~/` path as the raw string.
- [x] 1.2 Add the pure resolver in `Update.SshAgent`: expand a leading `~` or `~/` with the given home, reject `~user`, require an absolute path, and reject a final component that ends in `.pub`. Empty and omitted inputs are a distinct error that names `ssh-identity` and does not quote a path. Every other error includes the configured text. Verify unit cases for `~/.ssh/keys/shanty_github_id`, `keys/github`, an absolute `.pub` path, `~other/key`, empty, and omitted.
- [x] 1.3 Document `ssh-identity` in the README config table and example (one path, leading `~` allowed, required only when an assets push will run). Verify the table names `ssh-identity` and the example is a single string, not an array.

## 2. Unlock only that key

- [x] 2.1 Change `ensureSshAgent` so the assets bracket passes the resolved path. Production fingerprint is `ssh-keygen -lf <path> -E sha256`. Production listing is `ssh-add -E sha256 -l`. Match the `SHA256:` token only. A reachable agent that has the token is reused: no `ssh-add`, no `setEnv`, no kill on exit. Any other reachable, empty, missing, or unreachable agent starts an agent this process owns, `ssh-add`s only that path, and exports the new socket for this process. Do not `ssh-add` into an agent this process did not start. `ssh-keygen` failure hard-fails before a socket choice. An add that does not leave the token loaded hard-fails and kills the owned agent. Delete `discoverIdentityFiles`, `parseIdentityFiles`, and `defaultIdentityCandidates` and fix every import. Verify `test/Test/Ssh.hs`: reuse when the token is present (add not called); other loaded tokens start an owned agent and add only the configured path; an empty reachable agent is not the add target; an unreachable socket starts an owned agent; `ssh-keygen` failure does not call `ssh-add`; a successful add whose follow-up list lacks the token kills the owned agent and unsets `SSH_AUTH_SOCK`.
- [x] 2.2 Pass the raw config value on `UpdateSpineDeps` from `app/Main.hs`. Resolve and existence-check it only in the existing `needDeps` bracket, before `ensureSshAgent`. A missing file fails before a prompt and the error includes the path. Apply-test stubs report a fingerprint match for the path they are given so they still do not `ssh-add`. Verify a spine or bracket test that an omitted key with assets work returns a hard fail naming `ssh-identity` and does not call `ssh-add`, and that the existing assets stub still reuses without `ssh-add`.
- [x] 2.3 Extend the README `ssh-identity` paragraph: a reachable agent that already has the key is reused and does not prompt; otherwise the run prompts once for that key and does not leave it in the desktop agent. Verify the paragraph states both outcomes and does not tell the operator to list `IdentityFile` entries for this program.

## 3. Parent-death supervisor

- [x] 3.1 Before `ssh-add` on an owned agent, re-exec this binary with `MNDZ_OVERLAY_MANAGER_SSH_SUPERVISOR` set to the agent pid. The child unsets it, sets `PR_SET_PDEATHSIG` to `SIGTERM`, rechecks the parent, signals ready, and on the signal runs `kill <pid>`. `app/Main.hs` and `test/Main.hs` take this over beside `takeGpgSessionSupervisor` and do not run the program when either supervisor claims the process. If the supervisor does not become ready, kill the agent, unset the socket variables, and return before `ssh-add`. Normal teardown still kills the pid, then reaps. A reused session has no supervisor. Do not change the GPG supervisor. Verify a test that starts the supervisor against a `kill` on `PATH` which records its arguments, reaps, and sees that pid, and a test that a supervisor start failure names the supervisor, does not call `ssh-add`, and does not leave `SSH_AUTH_SOCK` set.
- [x] 3.2 Keep the owned-agent teardown kill on success and on add failure, and do not kill a reused agent. Verify the reuse test from 2.1 still records no kill, and the add-failure test records a kill of the owned pid only.

## 4. Gate

- [x] 4.1 Run `openspec validate --change ssh-configured-identity --strict` and `just check`. Verify both exit 0. Leave living `openspec/specs/` unchanged.

## Workflow follow-up

- Archive only after the tasks above are done. Sync the delta into `openspec/specs/ssh-agent-session/spec.md`, then edit that file's Purpose so it describes the configured identity and owned-agent teardown instead of key discovery. A delta cannot carry Purpose.
- Move the change to `openspec/changes/archive/YYYY-MM-DD-ssh-configured-identity/` in that archive step.
