## MODIFIED Requirements

### Requirement: Overlay dirty preflight before update mutate

After the plan phase and before any overlay mutation or materialize `docker build`, `update` SHALL hard-fail with status `1` and SHALL NOT mutate overlay packages or start ensure `docker build` when `git status --porcelain` reports dirty, staged, untracked, or deleted paths under:

1. each **selected** package’s overlay directory, and
2. the overlay directory of each package atom this run’s materialize recipe will emerge from the overlay (`dev-lang/bun-bin` when the recipe emerges `dev-lang/bun-bin::mndz`, `dev-lisp/qlot` when the recipe emerges `dev-lisp/qlot::mndz`), even if that package is not in the `update` selection.

Unrelated overlay paths outside those directories SHALL NOT fail this preflight. Commands other than `update` SHALL NOT be required to run this preflight. The error SHALL name at least one dirty path or package directory and SHALL tell the operator to restore or finish that tree relative to git HEAD.

#### Scenario: Leftover bun-bin rename fails update dolt

- **WHEN** the operator runs `update dev-db/dolt`, overlay bun-bin has `bun-bin-1.3.14.ebuild` deleted and untracked `bun-bin-1.4.0.ebuild`, and ensure will emerge overlay bun-bin
- **THEN** the command exits `1` without mutating dolt and without `docker build`
- **AND** the error names `dev-lang/bun-bin` or a path under that directory

#### Scenario: Leftover qlot rename fails when recipe emerges qlot

- **WHEN** the operator runs `update` that will full-path Autolith (recipe emerges overlay qlot) and overlay qlot has `qlot-1.8.4.ebuild` deleted and untracked `qlot-1.8.5.ebuild`
- **THEN** the command exits `1` without mutating Autolith and without `docker build`
- **AND** the error names `dev-lisp/qlot` or a path under that directory

#### Scenario: Unrelated overlay file does not fail

- **WHEN** only `README.md` at the overlay root is dirty and selected package dirs and ensure-emerge overlay atoms are clean
- **THEN** this preflight does not fail solely because of that README

#### Scenario: Clean tree proceeds

- **WHEN** selected package dirs and ensure-emerge overlay atoms are clean vs HEAD
- **THEN** mutate and ensure are not blocked solely by this preflight
