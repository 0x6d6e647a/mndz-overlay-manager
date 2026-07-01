## ADDED Requirements

### Requirement: Rich logger is initialized before any other work
The program SHALL initialize a rich `co-log` logger (timestamps, colored levels, stderr output) as the very first action in `main`, before argument parsing or config loading. The default level SHALL be `warn`. The logger SHALL be usable for all subsequent error and diagnostic messages.

#### Scenario: Error message uses the rich logger
- **WHEN** the program encounters a fatal error (e.g., config file missing)
- **THEN** the error is emitted via the rich logger (with timestamp and level) to stderr

#### Scenario: Verbosity flags affect early messages
- **WHEN** the user supplies `-vv` or `--log-level debug`
- **THEN** debug-level messages are emitted from the first log statement onward
