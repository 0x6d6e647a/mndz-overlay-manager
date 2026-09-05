## MODIFIED Requirements

### Requirement: Exact-set package directory for DepsAndAssets

When applying a runtime-lane plan, after all planned target PVs for that apply attempt have been successfully materialized, the program SHALL retain every non-live versioned ebuild whose PV is in the planned unique set. The program SHALL remove other non-live versioned ebuilds **except** those `overlay-atom-closure` reverse-dep keep requires. Live ebuilds, if present, SHALL be left untouched. The program SHALL NOT prune when a planned target failed to materialize if pruning would drop a tip without its replacement. Reverse-dep keep SHALL NOT change which PVs the runtime-lane planner selects.

#### Scenario: Converge deletes extras

- **WHEN** the package dir has two non-live ebuilds and the plan is a single successful PV and no remaining consumer ebuild requires the extra PV
- **THEN** after apply only that planned non-live ebuild remains

#### Scenario: Reverse-dep keep retains an unplanned PV

- **WHEN** the package dir has `6.6.1` and `6.8.0`, the plan unique set is `{6.8.0}`, and a remaining overlay consumer ebuild requires `=dev-util/usage-6.6.1`
- **THEN** after apply both `6.6.1` and `6.8.0` remain
