## MODIFIED Requirements

### Requirement: README documents update free-space behavior and TMPDIR

When the product performs free-space feasibility checks for `update`, `README.md` SHALL document at operator depth:

1. That `update` checks free space on the effective temp root (`TMPDIR` or system default) and the manager distfiles path before heavy concurrent mutation.
2. That free-space estimates cover only packages that **need work** and heavy units, using prior Manifest/GitHub asset sizes with **reuse vs full-path** classification, ecosystem factors for full path, and a fixed safety margin—not a full-path estimate for every inventory package on bare `update`.
3. That `update` plans which packages need work (using the check cache when enabled) before the free-space gate and conditional assets/language tool requirements that depend on needs-work.
4. Remediation: free space, set `TMPDIR` to roomier storage (for example under `$HOME`), lower `--jobs`, and that system Portage DISTDIR low space may only warn when distinct from the manager path.
5. That mid-materialize ENOSPC is a failure mode the gate is intended to prevent when free space is already insufficient for the planned concurrent work.
6. That heavy product temporary work is nested under `$TMPDIR/mndz/overlay-manager/<run-id>/` (or the process default temp root when `TMPDIR` is unset), with per-unit trees; successful units are cleaned immediately; hard-fail retains the failing unit tree and names its path in the error; a fully successful run removes the run root and empty parent brand directories; residuals after crashes or hard-fails may be removed manually by the operator.

#### Scenario: Operator finds TMPDIR guidance in README

- **WHEN** an operator reads `README.md` after this capability ships
- **THEN** the documentation describes `TMPDIR`, free-space remediation, needs-work-scoped estimates, and the product temporary workspace layout and retention behavior for `update` without requiring OpenSpec as the primary path

#### Scenario: README mentions plan before free-space gate

- **WHEN** an operator reads the `update` free-space documentation
- **THEN** the text indicates that free-space checks apply to packages that need work after planning, not every package in the overlay inventory
