## Purpose

Project-wide temporary workspace under the process effective temp root: one run-scoped tree, per-unit `out`/`work` layout, clean-on-success and retain-on-hard-fail lifecycle so operators can investigate failures without scattering anonymous temp dirs.

## Requirements

### Requirement: Effective temp root and product workspace brand

The program SHALL resolve an **effective temp root** as the environment `TMPDIR` when set and usable, otherwise the process default temporary directory. Product-owned heavy scratch SHALL be placed under:

`<temp-root>/mndz/overlay-manager/<run-id>/`

and SHALL NOT place such scratch as free-floating siblings of that brand directory under the temp root. Durable manager distfiles under XDG cache, overlay-path, and assets-path SHALL remain outside this temporary workspace.

#### Scenario: TMPDIR hosts the workspace brand

- **WHEN** `TMPDIR` is set to a usable directory and the program opens a product temp workspace for heavy work
- **THEN** the run root is created under that directory as `mndz/overlay-manager/<run-id>/`

#### Scenario: Distfiles stay on XDG path

- **WHEN** the program fetches manager distfiles for `ebuild … manifest`
- **THEN** those files are written under the effective manager distfiles path, not under the temporary run root

### Requirement: Run root identity

Each process that opens a product temporary workspace for a command run SHALL create **one** run root for that run. The run id SHALL use a local-timezone **ISO 8601 basic** timestamp with seconds precision and a numeric UTC offset in `±HHMM` form (no colon in the offset), followed by a separator, the process id, a dot, and a random suffix sufficient to avoid same-second collisions (for example `20260810T154207-0700-4242.a8f3`). The run-id path segment SHALL NOT contain `:` (the POSIX `PATH` separator). Extended ISO 8601 with colons (for example `2026-08-10T15:42:07-07:00`) SHALL NOT be used as the directory name.

#### Scenario: Concurrent processes do not share a run root

- **WHEN** two manager processes open a temp workspace in the same local second
- **THEN** each creates a distinct run root directory under `mndz/overlay-manager/`

#### Scenario: Run id is PATH-safe

- **WHEN** the program opens a product temp workspace and creates a run root
- **THEN** the run-id directory name contains no `:` and matches ISO 8601 basic local time with numeric offset, pid, and random suffix (for example a name of the form `20260810T154207-0700-4242.a8f3`)

### Requirement: Unit tree layout

When a planned apply unit is admitted to heavy temporary work (full-path materialize or reuse download/verify that needs local files), the program SHALL ensure a unit directory exists at:

`<run-root>/<category>/<package>/<pv>-<kind>/`

where `<kind>` is `full` for full-path materialize work and `reuse` for reuse-path download/verify work, and SHALL ensure subdirectories `out/` and `work/` under that unit directory. Heavy product scratch for that unit SHALL use those directories (`out` for staged distfiles or downloaded assets; `work` for clones, language caches, fetch dist dirs, and pack stages). The program SHALL NOT open a unit directory for failures that occur before any unit is admitted to heavy temporary work.

#### Scenario: Full-path unit path shape

- **WHEN** full-path materialize runs for category `dev-util`, package `crush`, PV `0.77.0`
- **THEN** temporary work for that unit is under `<run-root>/dev-util/crush/0.77.0-full/` with `out/` and `work/` present

#### Scenario: Reuse unit path shape

- **WHEN** reuse-path asset download runs for category `dev-util`, package `crush`, PV `0.77.0`
- **THEN** temporary work for that unit is under `<run-root>/dev-util/crush/0.77.0-reuse/` with `out/` and `work/` present

#### Scenario: Pre-unit failure has no unit tree

- **WHEN** a hard-fail occurs before any unit is admitted to heavy temporary work (for example disk-space preflight)
- **THEN** the program does not create a unit directory solely for retention of that failure

### Requirement: Unit success and soft-skip cleanup

When a unit that opened a unit directory completes with success or soft-skip, the program SHALL delete that unit directory **immediately** (before or as that unit’s job finishes) and SHALL remove empty parent package and category directories under the run root when they no longer contain entries.

#### Scenario: Successful unit frees space under concurrent jobs

- **WHEN** package job A finishes a unit successfully while package job B is still running
- **THEN** unit A’s directory under the run root is removed without waiting for the whole command to finish

#### Scenario: Soft-skip cleans like success

- **WHEN** a unit that opened temporary directories ends in soft-skip
- **THEN** that unit’s directory is deleted the same way as a successful unit

### Requirement: Unit hard-fail retention and path in error

When a unit that opened a unit directory hard-fails, the program SHALL retain that unit’s directory contents for operator investigation and SHALL include the absolute path of that unit directory in the hard-fail error message presented to the operator. Sibling units under the same package that already succeeded or soft-skipped SHALL already have been cleaned and SHALL NOT be recreated for retention. Units that never opened a directory SHALL NOT invent a retained path.

#### Scenario: Hard-fail names the unit path

- **WHEN** full-path materialize for `dev-util/crush` at PV `0.77.0` hard-fails after opening its unit directory
- **THEN** the error message contains the absolute path to `…/dev-util/crush/0.77.0-full` (or that unit directory under the run root)

#### Scenario: Only the failing unit remains for a multi-PV package

- **WHEN** multi-PV apply succeeds for PV `0.77.0` and hard-fails for PV `0.78.0` after both opened unit directories
- **THEN** the `0.77.0-*` unit directory is absent and the `0.78.0-*` unit directory is retained under the package path

### Requirement: Full-run success upward prune

When a command run that opened a product temporary workspace completes with **no** hard-fail for that run, the program SHALL delete the entire run root directory. After that deletion, if `<temp-root>/mndz/overlay-manager` is empty, the program SHALL remove it; if `<temp-root>/mndz` is then empty, the program SHALL remove it. When any hard-fail occurred in the run, the program SHALL leave the run root in place (with retained failing unit trees) and SHALL NOT delete the run root solely because some units succeeded.

#### Scenario: Clean update removes brand dirs when empty

- **WHEN** `update` opens a temp workspace, all units succeed or soft-skip, and no hard-fail occurs
- **THEN** the run root is gone and empty `mndz/overlay-manager` and empty `mndz` under the temp root are removed

#### Scenario: Mixed run keeps the run root

- **WHEN** at least one unit hard-fails after opening a unit directory and other units succeed
- **THEN** the run root remains and successful unit directories are not present under it

### Requirement: Project-wide scratch convention

New product features that need heavy temporary files or directories SHALL allocate them under the product temporary workspace (run root and unit layout as applicable) rather than creating anonymous free-floating directories directly under the effective temp root. Test-only harness paths are not required to use the product workspace.

#### Scenario: No free-floating product temp prefixes under temp root

- **WHEN** product full-path or reuse temporary work runs
- **THEN** that work is nested under `mndz/overlay-manager/<run-id>/` rather than only under a random name directly in the effective temp root
