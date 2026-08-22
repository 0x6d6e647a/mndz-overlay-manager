## ADDED Requirements

### Requirement: One update apply panel for overlay wait admission

When activity indicators are enabled, `update` mutate SHALL use a **single** multi-progress panel for package apply (the existing apply phase label such as `Updating packages`), not a second apply panel per overlay wait-edge wave. Packages withheld on an overlay wait-edge provider SHALL appear in that panel in a **waiting** presentation (not in-flight mutate, not hard-fail, not soft-skip) until they are admitted or hard-fail without admit; the waiting row SHALL name the provider (for example waiting on `dev-lang/bun-bin`). Waiting SHALL NOT occupy a package job slot. When a withheld package is admitted, its row SHALL become an ordinary in-flight mutate row in the same panel. The top-level done/total count SHALL include withheld packages that will still need a terminal outcome in this apply panel so the panel is not treated as complete while consumers remain waiting. Independents and providers that are already admitted MAY run concurrently in that same panel under `--jobs`.

#### Scenario: Ralph waits in the same panel as bun-bin

- **WHEN** indicators are enabled, bun-bin needs work, and ralph-tui is withheld
- **THEN** the apply multi-progress panel shows bun-bin as in-flight (or completed) and ralph-tui as waiting on `dev-lang/bun-bin`
- **AND** there is not a second apply panel opened solely because ralph-tui was withheld

#### Scenario: Waiting is not hard-fail presentation

- **WHEN** ralph-tui is waiting on bun-bin
- **THEN** the ralph-tui row does not use hard-fail presentation solely because it has not been admitted yet
