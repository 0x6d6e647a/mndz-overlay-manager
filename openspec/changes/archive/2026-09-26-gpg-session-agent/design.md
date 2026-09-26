# Design

## Context

See proposal.md for why. The behavior contract is `specs/gpg-sign-readiness/spec.md` and `specs/update-command/spec.md`.

`update` and `gencache` already share `Update.GpgAgent`: resolve `user.signingkey`, KEYINFO, a TTY ready-prompt, a dummy clearsign, then `CLEAR_PASSPHRASE` on exit for keygrips this process warmed. `git commit -S` calls that path while holding the overlay git lock. The desktop agent is the one at `~/.gnupg` (here, GnuPG 2.5 with `use-keyboxd`, socket `/run/user/1000/gnupg/S.gpg-agent`). Its `default-cache-ttl` and `max-cache-ttl` are startup settings. A second `gpg-agent --daemon` against that home exits with "already running" and does not apply new lifetimes. `gpg-agent --daemon` double-forks, so killing overlay-manager does not kill it.

Commit points stay in `Update.Spine` / `Update.Apply`. This design does not move `delayCommit`, the file gate, or `overlapReady`.

## Goals / Non-Goals

**Goals:**

- One session agent per signing `update` or `gencache`, unlocked before that command's signed work, dead when the process is gone.
- Reuse the existing ready-prompt, TTY pinentry environment, and per-commit KEYINFO check. Point them at the session agent.
- Keep `GNUPGHOME` off the parent environment and off `ebuild`, `egencache`, `ssh`, and the materialize container.
- Keep the passphrase out of this process.

**Non-Goals:**

- See proposal.md Non-goals.
- Do not add a CLI flag, a config key, or a new exposed library module.
- Do not pass `--default-cache-ttl` / `--max-cache-ttl` on the `gpg-agent` command line. The session home's `gpg-agent.conf` is the setting that a newly started agent will read.
- Do not share the desktop keyboxd database with a second keyboxd.

## Decisions

### 1. Session home under the product temp tree

Create `<run-root>/gpg-home` mode 700 when a signing command opens its run root. `gencache` opens a run root for this home even though it has no unit directories. Remove `gpg-home` on every teardown, including a hard failure that keeps the rest of the run root. Removal deletes the symlink or the copied key file inside the home. It must not follow a symlink into `~/.gnupg/private-keys-v1.d`.

The agent's socket directory is GnuPG's, under `/run/user/<uid>/gnupg/d.<hash>/` for a non-default home. The program does not choose that path and does not put `GNUPGHOME` in the parent environment, so other children do not inherit it. Same-uid processes can still find the socket. That ceiling is accepted.

Alternatives:

- Put the home only in `/run/user`. It vanishes on logout, but it bypasses the product temp-workspace rule for scratch this command owns.
- `setEnv` the parent. Every child, including `ebuild`, would see the home. Manifests are not signed; a later Manifest-signing change has to widen this on purpose. The widen is: pass the session home to the Portage children that sign, not a silent inheritance from the parent.

### 2. What the home contains

`gpg-agent.conf` in the session home:

- `default-cache-ttl 28800` and `max-cache-ttl 28800`, so a long image build does not expire the cache while the process is alive. This number is only the bound for the residual in Risks.
- `pinentry-program /usr/bin/pinentry-tty`. Do not copy the desktop `pinentry-gnome3` setting.
- No `enable-ssh-support`.

No `use-keyboxd` in the session `common.conf`. Export the public half of each signing key into the home. Give the agent only the sign-capable secret key file for each distinct keygrip this run will use: symlink the one file from `private-keys-v1.d` first. If that GnuPG refuses to use a symlink, copy that file into the session home instead. Do not link or copy the rest of the secret ring.

Every session `gpg`, `gpg-connect-agent`, and `gpgconf` invocation receives this home (`--homedir` or a child `GNUPGHOME`). KEYINFO against the desktop socket is the wrong check.

### 3. Unlock before signed work, then the existing per-commit check

`update`, after plan, when any selected unit may sign: start the home and the supervisor, resolve the overlay key and, when this run may publish assets, the assets key, and run the existing ready-prompt plus clearsign once per distinct keygrip. This is before workers start and before `docker build`, so a commit in `overlapReady` finds the session cache warm and does not take the overlay git lock to wait on pinentry.

`gencache` does the same immediately before its one commit, and skips it when there is nothing to commit.

Per-commit KEYINFO stays. A cold session cache (the 28800s ceiling, or a failed early unlock) still prompts. A warm desktop cache never suppresses the session prompt.

The activity panel pause already used around the ready-prompt stays. No new panel.

### 4. Parent-death supervisor

Before unlock, spawn a child whose job is to run `gpgconf --homedir <session> --kill gpg-agent` when its parent dies. The child sets the Linux parent-death signal to SIGTERM, then checks the parent pid is still this process (the set-then-recheck race), then waits. Normal teardown also runs that kill, removes the home, and reaps the child.

If the supervisor cannot be started, hard-fail before unlock and do not fall back to the desktop agent.

`gpgconf --kill` is enough when the agent was auto-started by the first `gpg`. The program does not need a second daemon start, and it does not pass TTL flags to one.

Alternatives:

- `CLEAR_PASSPHRASE` on the desktop agent. That is the current teardown. It leaves the key usable by every same-uid client for the whole run, and it cannot set a lifetime without reloading the desktop agent.
- Kill only on the normal exit bracket. A double-forked `gpg-agent` survives `SIGKILL` of overlay-manager.

### 5. Child environment, not a new signing stack

`gitAddAndSignedCommit` and the clearsign warm already take a child environment (`GPG_TTY`, `DISPLAY` cleared). Add the session `GNUPGHOME` there only. `ebuild`, `egencache`, and `ssh` keep the parent environment. The materialize container already drops `GNUPGHOME`; keep that scrub.

Extend `GpgAgentOps` (or the handle next to it) so tests inject the home, the kill, and the supervisor. Do not add a parallel GPG implementation.

## Risks / Trade-offs

- [SIGKILL of the whole process group kills the supervisor before it can run `gpgconf --kill`] → The session `max-cache-ttl` is 28800 seconds. The socket is not the desktop socket. Normal `SIGKILL` of overlay-manager alone still delivers the parent's death signal to the supervisor.
- [GnuPG 2.5 rejects a symlinked secret key file, or rejects the public-key export without keyboxd] → The implementation spike copies the one key file if the symlink fails, and adjusts the home recipe before the rest of the wiring. The operator contract does not change.
- [A same-uid process finds `/run/user/<uid>/gnupg/d.<hash>/`] → Accepted. The desktop agent stays cold, so a normal `git commit -S` in another terminal still uses that cold agent.
- [Early unlock prompts even when every unit later fails before a commit] → The prompt happens only when the plan says some unit may sign. A run that will not sign does not prompt.
- [A run longer than 8 hours finds a cold session cache] → The existing per-commit cold path prompts again. The commit point does not move.

## Migration Plan

No data migration and no desktop `gpg-agent.conf` edit. Rollback is reverting the change; the desktop agent was not modified. Operators see one prompt before signed `update` work instead of a prompt at the first cold commit. Update the README sentence that places bun-bin's GPG prompt after the image build. Replace the `gpg-sign-readiness` Purpose line when this change is archived; a delta cannot carry a new Purpose for an existing capability. Until archive, leave `openspec/specs/` unchanged.
