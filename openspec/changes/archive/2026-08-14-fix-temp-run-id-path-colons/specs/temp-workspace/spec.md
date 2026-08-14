## MODIFIED Requirements

### Requirement: Run root identity

Each process that opens a product temporary workspace for a command run SHALL create **one** run root for that run. The run id SHALL use a local-timezone **ISO 8601 basic** timestamp with seconds precision and a numeric UTC offset in `±HHMM` form (no colon in the offset), followed by a separator, the process id, a dot, and a random suffix sufficient to avoid same-second collisions (for example `20260810T154207-0700-4242.a8f3`). The run-id path segment SHALL NOT contain `:` (the POSIX `PATH` separator). Extended ISO 8601 with colons (for example `2026-08-10T15:42:07-07:00`) SHALL NOT be used as the directory name.

#### Scenario: Concurrent processes do not share a run root

- **WHEN** two manager processes open a temp workspace in the same local second
- **THEN** each creates a distinct run root directory under `mndz/overlay-manager/`

#### Scenario: Run id is PATH-safe

- **WHEN** the program opens a product temp workspace and creates a run root
- **THEN** the run-id directory name contains no `:` and matches ISO 8601 basic local time with numeric offset, pid, and random suffix (for example a name of the form `20260810T154207-0700-4242.a8f3`)
