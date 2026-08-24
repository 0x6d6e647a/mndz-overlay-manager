## ADDED Requirements

### Requirement: qlot Manifest wait is visible

When activity indicators are enabled and `update` will `docker build` a recipe that emerges overlay qlot, and overlay qlot needs `GitMvAndManifest` file work, the program SHALL show qlot Manifest / egencache work so that wait is not indistinguishable from a hung ensure. The program SHALL NOT show Autolith (or other packages) as waiting on `dev-lisp/qlot`.

#### Scenario: qlot manifest is a visible status

- **WHEN** indicators are enabled, qlot needs GitMv work, and ensure will emerge overlay qlot
- **THEN** qlot’s apply row (or a sequential step) indicates Manifest regeneration before `docker build` starts
- **AND** Autolith is not shown as waiting on `dev-lisp/qlot`
