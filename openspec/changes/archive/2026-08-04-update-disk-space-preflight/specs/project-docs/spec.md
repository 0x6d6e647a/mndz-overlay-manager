## ADDED Requirements

### Requirement: README documents update free-space behavior and TMPDIR

When the product performs free-space feasibility checks for `update`, `README.md` SHALL document at operator depth:

1. That `update` checks free space on the effective temp root (`TMPDIR` or system default) and the manager distfiles path before heavy concurrent work.
2. That estimates use prior Manifest/GitHub asset sizes and ecosystem factors, with a fixed safety margin.
3. Remediation: free space, set `TMPDIR` to roomier storage (for example under `$HOME`), lower `--jobs`, and that system Portage DISTDIR low space may only warn when distinct from the manager path.
4. That mid-materialize ENOSPC is a failure mode the gate is intended to prevent when free space is already insufficient for the planned concurrent work.

#### Scenario: Operator finds TMPDIR guidance in README

- **WHEN** an operator reads `README.md` after this capability ships
- **THEN** the documentation describes `TMPDIR` and free-space remediation for `update` without requiring OpenSpec as the primary path
