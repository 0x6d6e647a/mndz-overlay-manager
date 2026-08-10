## MODIFIED Requirements

### Requirement: Resolve free-space check roots

The program SHALL resolve at least these paths for free-space evaluation during `update`:

1. **Effective temp root** — the directory used as the filesystem root for free-space measurement for temporary work (environment `TMPDIR` when set and usable; otherwise the process default temporary directory, typically `/tmp`). Product temporary workspace trees defined by `temp-workspace` SHALL reside under this root; free-space evaluation SHALL measure this root’s filesystem (not a separate device solely because of the `mndz/overlay-manager/<run-id>` subdirectory).
2. **Effective manager distfiles path** — as defined by `manager-distfiles` (CLI, config, or XDG default).
3. **Live Portage DISTDIR** — best-effort query of the host Portage `DISTDIR` (or the canonical system fallback when the query is unavailable), solely for optional warning when it differs from the manager path.

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
