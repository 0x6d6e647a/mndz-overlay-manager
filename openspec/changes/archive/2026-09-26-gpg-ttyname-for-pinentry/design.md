# Design

## Context

See proposal.md for why. The behavior contract is the modified requirement in `specs/gpg-sign-readiness/spec.md`.

`controllingTtyPath` opens `/dev/tty` and, on success, returns that string. `pinentryChildEnv` strips any parent `GPG_TTY` and publishes the returned string for the warm-up `gpg` and for `git commit -S`. Both children have pipes on stdin, stdout, and stderr, so GnuPG cannot discover a terminal from those fds. The session agent is started earlier by `gpg --homedir` during session-home setup. That agent daemonizes, so its `pinentry-tty` has no controlling terminal. `fopen("/dev/tty")` in that pinentry fails, and pinentry maps the failure to `GPG_ERR_CANCELED`.

`ssh-add` and the github-token wrap prompt open `/dev/tty` inside this process, which still has a controlling terminal. Their prompts appear. The session `gpg-agent.conf` stays `pinentry-program /usr/bin/pinentry-tty`.

## Goals / Non-Goals

**Goals:**

- One discovery result for the warm-up and for `git commit -S`: the terminal device node.
- A regression check that calls the production discovery function against a pty this test allocated, with no pinentry and no `forkProcess`.
- Keep the missing-terminal unlock error the program already returns.

**Non-Goals:**

- See proposal.md Non-goals.
- A new package dependency. `unix` 2.8 is already a direct dependency and exports the pty and `ttyname` helpers.
- Exporting a new library symbol. Production discovery stays behind `gaoControllingTty` on `productionGpgAgentOps`.
- Sharing that discovery with `Update.Auth` or `Update.SshAgent`. Those open `/dev/tty` in this process.

## Decisions

### 1. `ttyname` of the controlling terminal's device node

`controllingTtyPath` opens `/dev/tty`. `getTerminalName` (`ttyname`) on that fd is not the device node: glibc `ttyname` uses `readlink` of `/proc/self/fd/N`, and that link is the path that was opened, `/dev/tty`. Publishing that string is the bug.

`getControllingTerminalName` is the wrong helper. It is `ctermid`, and on Linux `ctermid` returns the string `/dev/tty`.

When `ttyname` of the `/dev/tty` fd is empty or `/dev/tty`, the fd's `TIOCGDEV` value is the underlying device (major 136, minor N for a devpts slave). The candidate path is `/dev/pts/N`. It is accepted only when that node's device id matches `TIOCGDEV`. The returned path is `ttyname` of an fd opened from that node, which is `/dev/pts/N`.

An open failure, an empty name, a device-id mismatch, or a final name of exactly `/dev/tty` is "no controlling terminal". Unlock then takes the existing hard-fail path. The error text stays as it is.

`pinentryChildEnv` already deletes a parent `GPG_TTY` and inserts the discovered path, and it still clears `DISPLAY` on those children only. No second env builder.

Alternatives:

- Leave discovery as `/dev/tty` and switch `pinentry-program` to `pinentry-curses`. That pinentry also opens the name it is given. The alias still fails from the agent.
- Unset `GPG_TTY` and let `gpg` call `ttyname` itself. The warm-up stdio fds are pipes, so `gpg` has nothing to name.
- Honor a parent `GPG_TTY` when set. An operator export cannot fix a binary that overwrites it, and a stale parent value would point pinentry at the wrong terminal.

### 2. Regression test execs a new session

The suite is threaded. `forkProcess` duplicates one thread and is the wrong tool here.

The test allocates a pty with `openPseudoTerminal`, reads the slave path with `getSlaveTerminalName`, and keeps the master fd open until the child exits. It runs the test executable (`getExecutablePath`) with `new_session = True` and an env var holding the slave path. Stdout is a pipe.

At the start of `test/Main.hs`, next to the existing session-supervisor check, that env var means: open the slave without `O_NOCTTY` so the new session acquires it as the controlling terminal, print `gaoControllingTty` from `productionGpgAgentOps`, and exit before tasty. The parent asserts the printed path equals the slave path.

The child does not run `gpg` or pinentry. A host with no `/dev/pts` fails the test. There is no skip.

Injected-path tests that pass `Just "/dev/tty"` into `pinentryChildEnv` only show that the env copier copies its argument. Point those fixtures at a device-node path so they do not document the alias as the production value. The pty test is what locks discovery.

## Risks / Trade-offs

- [The slave is opened in the parent before the child, and a Linux pty rejects a slave open while the master is closed] → The parent holds the master until the child exits.
- [`new_session` plus a duplicated slave fd does not set the controlling terminal] → The child opens the slave path itself after `setsid`. `dup` does not acquire a controlling terminal; `open` without `O_NOCTTY` does.
- [A pts mode blocks the agent from opening the node] → The operator owns the pts. The same-uid agent opened `/dev/pts/N` in the reproduction. No permission change in this design.
- [Discovery returns Nothing when `TIOCGDEV` does not match a `/dev/pts/N` node] → Unlock hard-fails with the existing missing-TTY error, which is the safe outcome. Linux pty sessions resolve to `/dev/pts/N`.

## Migration Plan

No config migration and no desktop `gpg-agent.conf` edit. Rollback is reverting the change. The next signing `update` or `gencache` prompts on the terminal device node instead of exiting with `Operation cancelled`.
