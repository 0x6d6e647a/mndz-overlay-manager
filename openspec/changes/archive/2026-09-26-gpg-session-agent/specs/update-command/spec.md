## ADDED Requirements

### Requirement: Session-agent teardown on update exit

When `update` runs package work that may create GPG-signed commits, the program SHALL use the session agent specified by `gpg-sign-readiness` and SHALL terminate that agent on process exit (success or failure) when this run started one. Teardown SHALL run even when some packages hard-failed after an unlock. Teardown SHALL also terminate the session agent if the `update` process is killed after the agent has started. The program SHALL NOT clear passphrases in the desktop agent and SHALL NOT reload the desktop agent.

#### Scenario: Exit stops the session agent

- **WHEN** `update` unlocked the session agent and then finishes
- **THEN** the program terminates that agent on exit
- **AND** the desktop agent's cached passphrases are unchanged by this run

#### Scenario: Exit after failure still stops the session agent

- **WHEN** `update` unlocked the session agent and a later package hard-fails
- **THEN** process exit still terminates the session agent

#### Scenario: Killed update does not leave the session agent

- **WHEN** `update` has started the session agent and the `update` process is then killed
- **THEN** the session agent is terminated

## REMOVED Requirements

### Requirement: GPG readiness teardown on update exit

**Reason**: Teardown no longer clears a passphrase in the desktop agent. The signing cache lives in the session agent, which has to be killed.
**Migration**: Terminate the session agent on exit and on parent death, as specified by `gpg-sign-readiness` and by Session-agent teardown on update exit.
