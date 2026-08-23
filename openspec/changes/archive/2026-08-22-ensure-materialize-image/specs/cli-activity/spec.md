## ADDED Requirements

### Requirement: Materialize image ensure is visible in progress

When activity indicators are enabled and `update` ensures the materialize image as specified by `ensure-materialize-image`, the program SHALL show that work so a long `docker build` is not indistinguishable from a hung apply panel. At the first ensure in the run (t0 full-path), a sequential step (or equivalent) SHALL indicate ensuring the materialize image. When ensure runs at overlay wait-edge re-entry, waiting consumer rows in the existing apply panel SHALL update status to indicate ensuring the image (not a second apply panel). Full-path packages waiting on ensure SHALL use waiting presentation, not hard-fail, until ensure succeeds or fails.

#### Scenario: t0 ensure has a step

- **WHEN** indicators are enabled and `update` must `docker build` the materialize image before admitted full-path work
- **THEN** a sequential step (or equivalent) indicates ensuring the materialize image

#### Scenario: Re-entry ensure uses waiting row status

- **WHEN** indicators are enabled, ralph-tui is waiting after bun-bin commit, and ensure runs for ralph-tui full-path
- **THEN** the ralph-tui row in the same apply panel indicates ensuring the materialize image
- **AND** a second apply panel is not opened solely for ensure

## MODIFIED Requirements

### Requirement: One update apply panel for overlay wait admission

When activity indicators are enabled, `update` mutate SHALL use a **single** multi-progress panel for package apply (the existing apply phase label such as `Updating packages`), not a second apply panel per overlay wait-edge wave. Packages withheld on an overlay wait-edge provider SHALL appear in that panel in a **waiting** presentation (not in-flight mutate, not hard-fail, not soft-skip) until they are admitted or hard-fail without admit; the waiting row SHALL name the provider (for example waiting on `dev-lang/bun-bin`). Packages waiting on materialize image ensure SHALL likewise use waiting presentation in that panel until ensure succeeds or fails. Waiting SHALL NOT occupy a package job slot. When a withheld package is admitted, its row SHALL become an ordinary in-flight mutate row in the same panel. The top-level done/total count SHALL include withheld packages that will still need a terminal outcome in this apply panel so the panel is not treated as complete while consumers remain waiting. Independents and providers that are already admitted MAY run concurrently in that same panel under `--jobs`.

#### Scenario: Ralph waits in the same panel as bun-bin

- **WHEN** indicators are enabled, bun-bin needs work, and ralph-tui is withheld
- **THEN** the apply multi-progress panel shows bun-bin as in-flight (or completed) and ralph-tui as waiting on `dev-lang/bun-bin`
- **AND** there is not a second apply panel opened solely because ralph-tui was withheld

#### Scenario: Waiting is not hard-fail presentation

- **WHEN** ralph-tui is waiting on bun-bin
- **THEN** the ralph-tui row does not use hard-fail presentation solely because it has not been admitted yet

#### Scenario: Full-path waits on ensure in the same panel

- **WHEN** indicators are enabled, a full-path Go package is admitted for mutate but ensure has not finished
- **THEN** that package’s row uses waiting presentation rather than in-flight container materialize
- **AND** GitMv packages may appear in-flight in the same panel
