# Tasks

## 1. Terminal device node

- [x] 1.1 Change `controllingTtyPath` so an open of `/dev/tty` is followed by `getTerminalName` on that fd, and the returned path is that device node. Treat an open failure, an empty name, and the string `/dev/tty` as no controlling terminal, and keep the existing missing-TTY unlock error. Do not use `getControllingTerminalName`. Leave `pinentryChildEnv` stripping any parent `GPG_TTY` and clearing `DISPLAY` on the warm-up and `git commit -S` children only. Do not change `Update.Auth` or `Update.SshAgent`, and do not add a library export or a package dependency. Point existing `GPG_TTY` fixtures that inject a path at a device node such as `/dev/pts/7` rather than `/dev/tty`.
- [x] 1.2 Add a regression test that allocates a pty with `openPseudoTerminal`, keeps the master open, and runs this test executable in a new session (`new_session`) with the slave path in an env var. Before tasty, that env var opens the slave without `O_NOCTTY`, prints `gaoControllingTty` from `productionGpgAgentOps`, and exits. The parent asserts the printed path equals the slave path. The test does not run `gpg` or pinentry, and it does not use `forkProcess`. Verify the new test and the updated `GPG_TTY` fixture tests pass.

## 2. Gate

- [x] 2.1 Leave living `openspec/specs/` unchanged until archive. This delta does not change the `gpg-sign-readiness` Purpose line. Verify `openspec validate --change gpg-ttyname-for-pinentry --strict` and `hk check` both exit 0.
