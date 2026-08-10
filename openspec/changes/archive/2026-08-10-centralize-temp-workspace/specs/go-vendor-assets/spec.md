## MODIFIED Requirements

### Requirement: Temp clone at release tag

For `DepsAndAssets` Go apply of a given target PV (including each runtime-lane planned PV), the program SHALL clone the package’s GitHub source into the unit `work/` directory under the product temporary workspace defined by `temp-workspace`, check out the tag formed by the source tag prefix plus that target PV (for example prefix `v` and PV `0.76.0` → tag `v0.76.0`), and apply the `temp-workspace` lifecycle to that unit (delete the unit tree on success or soft-skip; retain on hard-fail with path in the error). The program SHALL NOT require a pre-existing long-lived checkout of the upstream project.

#### Scenario: Clone uses version tag

- **WHEN** updating `dev-util/crush` to PV `0.77.0` with tag prefix `v`
- **THEN** the clone targets tag `v0.77.0` under the unit `work/` tree for that PV full-path unit

#### Scenario: Clone uses target PV tag

- **WHEN** the planned target PV is `0.82.0` and the tag prefix is `v`
- **THEN** the temporary clone checks out tag `v0.82.0`
