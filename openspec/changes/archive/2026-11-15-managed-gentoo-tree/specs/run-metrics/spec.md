# Spec Delta

## MODIFIED Requirements

### Requirement: Remaining subprocesses have wall-clock spans

Subprocesses the program starts outside the shared command execution (GPG commands that build the session key home, and Portage `DISTDIR` and rusty_v8 snapshot reads) SHALL each be recorded as a `proc` span with wall-clock timing and exit status, without a `time` object. Interactive `ssh-add` SHALL be recorded the same way with `interactive: true`.

#### Scenario: Portage DISTDIR lookup is timed

- **WHEN** `eclean` queries Portage for its `DISTDIR`
- **THEN** a `proc` span for `portageq` with its duration and exit status exists in the run
- **AND** the span has no `time` object
