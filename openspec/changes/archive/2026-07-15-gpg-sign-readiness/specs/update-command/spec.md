## ADDED Requirements

### Requirement: GPG readiness teardown on update exit

When `update` runs package work that may create GPG-signed commits, the program SHALL retain process-lifetime state for any signing keygrips this run warmed and SHALL clear those keygrips from gpg-agent on process exit (success or failure), as specified by gpg-sign-readiness. Teardown SHALL run even when some packages hard-failed after an unlock. The program SHALL NOT clear keygrips that this process did not warm.

#### Scenario: Clear warmed key after update finishes

- **WHEN** `update` unlocked a cold signing keygrip during signed commits and then finishes
- **THEN** the program clears that keygrip’s agent cache on exit

#### Scenario: Exit after failure still clears what we warmed

- **WHEN** `update` unlocked GPG then a later package hard-fails
- **THEN** process exit still clears keygrips this process warmed
