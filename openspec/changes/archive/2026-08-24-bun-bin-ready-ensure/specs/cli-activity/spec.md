## ADDED Requirements

### Requirement: bun-bin Manifest wait and post-ensure commit are visible

When activity indicators are enabled and `update` will `docker build` a recipe that emerges overlay bun-bin, the program SHALL show bun-bin file work (`ebuild … manifest` / egencache) so that wait is not indistinguishable from a hung ensure. When bun-bin’s signed overlay commit is delayed until ensure finishes, the sequential commit progress (or bun-bin’s apply row) SHALL indicate that commit after the ensure attempt. Full-path packages waiting on ensure SHALL keep waiting presentation as already specified.

#### Scenario: bun-bin manifest is a visible status

- **WHEN** indicators are enabled, bun-bin needs GitMv work, and ensure will emerge overlay bun-bin
- **THEN** bun-bin’s apply row (or a sequential step) indicates Manifest regeneration before `docker build` starts

#### Scenario: bun-bin commit after ensure is visible

- **WHEN** indicators are enabled, ensure has finished, and bun-bin still needs its signed overlay commit
- **THEN** progress indicates bun-bin is being committed
- **AND** withheld ralph-tui remains in waiting presentation until that commit exists

## MODIFIED Requirements

### Requirement: Materialize image ensure is visible in progress

When activity indicators are enabled and `update` ensures the materialize image as specified by `ensure-materialize-image`, the program SHALL show that work so a long `docker build` is not indistinguishable from a hung apply panel. At the first ensure in the run (t0 full-path), a sequential step (or equivalent) SHALL indicate ensuring the materialize image. When consumers remain withheld until bun-bin’s signed commit after that ensure, their rows SHALL stay in waiting presentation naming the provider; the program SHALL NOT open a second apply panel solely for that admit. Full-path packages waiting on ensure SHALL use waiting presentation, not hard-fail, until ensure succeeds or fails.

#### Scenario: t0 ensure has a step

- **WHEN** indicators are enabled and `update` must `docker build` the materialize image before admitted full-path work
- **THEN** a sequential step (or equivalent) indicates ensuring the materialize image

#### Scenario: Ralph stays waiting through ensure until bun-bin commit

- **WHEN** indicators are enabled, bun-bin needs work, ralph-tui is withheld, and t0 ensure runs for hypo bun floors
- **THEN** the ralph-tui row in the same apply panel remains waiting on `dev-lang/bun-bin`
- **AND** a second apply panel is not opened solely for ensure

#### Scenario: Re-entry ensure uses waiting row status

- **WHEN** indicators are enabled, ralph-tui is waiting after bun-bin file work, and t0 ensure runs for hypo bun floors
- **THEN** the ralph-tui row in the same apply panel remains waiting on `dev-lang/bun-bin` (or indicates ensuring the image)
- **AND** a second apply panel is not opened solely for ensure
