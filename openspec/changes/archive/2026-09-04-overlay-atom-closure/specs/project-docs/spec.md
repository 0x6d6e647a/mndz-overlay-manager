## ADDED Requirements

### Requirement: README documents overlay atom closure

`README.md` SHALL document at operator depth that:

1. After each `update` overlay commit, retained overlay ebuilds’ dependencies on other overlay packages remain satisfiable (no consumer ebuild naming a provider PV the tree no longer has).
2. `DepsAndAssets` prune of a provider will not drop a PV that a remaining consumer ebuild still requires.
3. GitMv will not rename away the only PV that still satisfies a remaining consumer pin.
4. `update PACKAGE` of a consumer whose to-be-written ebuild is unsatisfied, while that overlay provider is unselected, hard-fails the consumer and names the provider; it does not pull the provider into the selection.

This is distinct from overlay wait-edges (`overlay-apply-waves`): Bun consumers still wait on bun-bin for ceilings; Cargo packages do not gain a ceiling wait-edge on `dev-util/usage`.

#### Scenario: Operator finds atom-closed overlay commits in README

- **WHEN** an operator reads `README.md` `update` documentation
- **THEN** the text states that overlay commits stay closed under overlay-internal dependency atoms and that prune will not drop a provider PV a remaining consumer ebuild still names
- **AND** it does not claim hk or mise are withheld on usage as a runtime-lane wait-edge
