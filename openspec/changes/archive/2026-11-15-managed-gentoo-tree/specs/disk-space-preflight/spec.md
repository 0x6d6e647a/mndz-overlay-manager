# Spec Delta

## MODIFIED Requirements

### Requirement: Resolve free-space check roots

The program SHALL resolve at least these paths for free-space evaluation during `update`:

1. **Effective temp root** — the directory used as the filesystem root for free-space measurement for temporary work (environment `TMPDIR` when set and usable; otherwise the process default temporary directory, typically `/tmp`). Product temporary workspace trees defined by `temp-workspace` SHALL reside under this root; free-space evaluation SHALL measure this root’s filesystem (not a separate device solely because of the `mndz/overlay-manager/<run-id>` subdirectory).
2. **Effective manager distfiles path** — as defined by `manager-distfiles` (CLI, config, or XDG default).

The program SHALL NOT query or measure the host Portage `DISTDIR` for the disk-space gate.

Free-space measurements SHALL use the free bytes available on the filesystem that backs each resolved path.

#### Scenario: TMPDIR overrides temp root

- **WHEN** `TMPDIR` is set to a usable directory on a distinct filesystem from `/tmp`
- **THEN** temp free-space evaluation uses that directory’s filesystem

#### Scenario: Manager distfiles path is always evaluated

- **WHEN** `update` runs a disk-space feasibility gate
- **THEN** free space on the effective manager distfiles path is included in hard feasibility checks

#### Scenario: Workspace subdirectory does not change the measured filesystem

- **WHEN** product temporary work will write under `<temp-root>/mndz/overlay-manager/<run-id>/` on the same filesystem as the effective temp root
- **THEN** the disk-space gate’s temp free-space check still uses the effective temp root’s filesystem free bytes

#### Scenario: Host Portage DISTDIR not measured

- **WHEN** `update` runs the disk-space feasibility gate on a host whose Portage `DISTDIR` filesystem is nearly full
- **THEN** the gate neither warns nor fails because of that filesystem

## REMOVED Requirements

### Requirement: Portage DISTDIR warn-only when distinct

**Reason**: The program no longer runs host Portage tools, so nothing it does writes to the host Portage `DISTDIR`; a free-space warning about that filesystem has no bearing on the run.

**Migration**: None. Manager distfiles free space remains a hard feasibility surface; `eclean` still refuses the system Portage `DISTDIR` as specified by `manager-distfiles`.
