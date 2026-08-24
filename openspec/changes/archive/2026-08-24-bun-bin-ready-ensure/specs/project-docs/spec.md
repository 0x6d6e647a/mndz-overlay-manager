## ADDED Requirements

### Requirement: README documents overlay dirty preflight and bun-bin-before-ensure

`README.md` SHALL document at operator depth that:

1. `update` hard-fails when selected overlay package directories, or overlay atoms the materialize image will emerge (`dev-lang/bun-bin` when the image installs overlay bun-bin), are dirty vs git HEAD (including untracked and deleted ebuilds), and that the operator must restore or finish that tree.
2. Untargeted `update` plans Bun consumers against the selected bun-bin remote when bun-bin needs work, and applies those consumers after bun-bin’s signed overlay commit without a disk re-plan.
3. When the materialize image will emerge overlay bun-bin, `update` regenerates bun-bin Manifest (and package cache) before `docker build`; bun-bin’s signed commit happens after that ensure attempt when ensure ran.
4. `update PACKAGE` while bun-bin is unselected still refuses on plan-delta / fail-closed as already specified.

#### Scenario: Operator finds dirty overlay refuse

- **WHEN** an operator reads `README.md` `update` documentation
- **THEN** the text states that a dirty overlay bun-bin (or selected package dir) causes `update` to exit `1` before mutate or image build

#### Scenario: Operator finds bun-bin Manifest before docker

- **WHEN** an operator reads `README.md` materialize / `update` documentation
- **THEN** the text states that overlay bun-bin Manifest regeneration happens before a bun-layer image build
- **AND** it does not claim Bun consumers are re-planned from disk after bun-bin commits in the same run
