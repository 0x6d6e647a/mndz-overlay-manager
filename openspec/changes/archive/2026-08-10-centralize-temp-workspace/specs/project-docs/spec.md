## MODIFIED Requirements

### Requirement: README documents update free-space behavior and TMPDIR

When the product performs free-space feasibility checks for `update`, `README.md` SHALL document at operator depth:

1. That `update` checks free space on the effective temp root (`TMPDIR` or system default) and the manager distfiles path before heavy concurrent work.
2. That estimates use prior Manifest/GitHub asset sizes and ecosystem factors, with a fixed safety margin.
3. Remediation: free space, set `TMPDIR` to roomier storage (for example under `$HOME`), lower `--jobs`, and that system Portage DISTDIR low space may only warn when distinct from the manager path.
4. That mid-materialize ENOSPC is a failure mode the gate is intended to prevent when free space is already insufficient for the planned concurrent work.
5. That heavy product temporary work is nested under `$TMPDIR/mndz/overlay-manager/<run-id>/` (or the process default temp root when `TMPDIR` is unset), with per-unit trees; successful units are cleaned immediately; hard-fail retains the failing unit tree and names its path in the error; a fully successful run removes the run root and empty parent brand directories; residuals after crashes or hard-fails may be removed manually by the operator.

#### Scenario: Operator finds TMPDIR guidance in README

- **WHEN** an operator reads `README.md` after this capability ships
- **THEN** the documentation describes `TMPDIR`, free-space remediation, and the product temporary workspace layout and retention behavior for `update` without requiring OpenSpec as the primary path
