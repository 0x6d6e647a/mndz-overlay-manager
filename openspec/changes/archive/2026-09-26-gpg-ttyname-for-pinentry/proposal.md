# Proposal

## Why

A signing `update` or `gencache` unlocks through `pinentry-tty` on a session gpg-agent that has no controlling terminal. The warm-up sets `GPG_TTY` to the string `/dev/tty`. That pinentry opens the path from the agent, the open fails, and GnuPG reports `Operation cancelled` with no passphrase prompt. `git commit -S` would send the same string.

## What Changes

- Resolve the controlling terminal to its device node, the path `ttyname` returns (for example `/dev/pts/N`), and set `GPG_TTY` to that path on the warm-up `gpg` and on `git commit -S`.
- When unlock is required and that device node cannot be resolved, hard-fail with the existing missing-TTY error. The string `/dev/tty` is not a value of `GPG_TTY`.
- `ssh-add` and the github-token wrap prompt keep opening `/dev/tty` in this process.
- A regression test allocates its own pty, makes that pty the controlling terminal, and checks the discovered path. The coverage gate still does not run pinentry.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `gpg-sign-readiness`: `GPG_TTY` for unlock and signed commits is the controlling terminal's device node, a path the session agent's pinentry can open.

## Impact

- `controllingTtyPath` in `src/Update/GpgAgent.hs`, and the tests in `test/Test/Gpg.hs` that describe the path placed in `GPG_TTY`.
- No CLI flag, config key, README change, or `pinentry-program` change. The session home stays on `/usr/bin/pinentry-tty`.
- The passphrase stays in the session agent. The program does not read or store it.

## Non-goals

- Switching the session agent to `pinentry-curses` or `pinentry-gnome3`.
- Honoring a `GPG_TTY` already set in the parent environment.
- Loopback pinentry, or reading the passphrase into this process.
- Changing `ssh-add` or the github-token wrap prompt, which open `/dev/tty` in this process.
- Passing the session `GNUPGHOME` to any child other than the warm-up `gpg` and `git commit -S`.
