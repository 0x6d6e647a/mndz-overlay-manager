# Spec Delta

## MODIFIED Requirements

### Requirement: Prefer terminal pinentry for warm and signed commits

For GPG unlock and for `git commit -S` child processes, the program SHALL set `GPG_TTY` to the device node of the controlling terminal when that node can be resolved. The device node is the path of the terminal itself, such as `/dev/pts/N`, and it is a path a process with no controlling terminal can open. The program SHALL NOT set `GPG_TTY` to `/dev/tty`. The program SHALL replace a `GPG_TTY` value inherited from the parent environment with that device node. The program SHALL arrange that pinentry does not depend on a graphical pinentry dialog (for example by clearing `DISPLAY` in those child environments so a TTY pinentry is used). The program SHALL NOT leave the parent process’s environment permanently without `DISPLAY` solely for this purpose. If the device node cannot be resolved when unlock is required, including when the only available name is `/dev/tty`, the program SHALL hard-fail rather than relying on a GUI pinentry timeout.

#### Scenario: Child sign environment uses GPG_TTY

- **WHEN** the program runs a signed commit or unlock operation and the controlling terminal's device node is `/dev/pts/N`
- **THEN** the child process environment includes `GPG_TTY` set to `/dev/pts/N`

#### Scenario: Alias path is not used

- **WHEN** the program runs a signed commit or unlock operation with a controlling terminal
- **THEN** the child `GPG_TTY` is not `/dev/tty`

#### Scenario: Inherited GPG_TTY is replaced

- **WHEN** the parent environment sets `GPG_TTY` to a different path and the controlling terminal's device node can be resolved
- **THEN** the unlock and `git commit -S` children receive that device node as `GPG_TTY`

#### Scenario: GUI pinentry not the required path

- **WHEN** unlock is required and a controlling terminal device node can be resolved
- **THEN** the program does not require a successful graphical pinentry dialog to complete unlock

#### Scenario: Unresolved device node fails unlock

- **WHEN** unlock is required and the controlling terminal's device node cannot be resolved
- **THEN** the program hard-fails without a graphical pinentry dialog and without publishing `GPG_TTY` as `/dev/tty`
