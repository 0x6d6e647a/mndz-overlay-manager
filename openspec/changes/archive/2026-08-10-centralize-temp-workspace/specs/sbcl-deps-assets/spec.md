## ADDED Requirements

### Requirement: Sbcl materialize uses product temp workspace

Full-path materialize for `DepsAndAssets Sbcl` SHALL perform clone, qlot/fff build stages, and packing under the unit `work/` and `out/` directories of the product temporary workspace defined by `temp-workspace`. Unit temporary trees SHALL follow the `temp-workspace` lifecycle (delete on success or soft-skip; retain on hard-fail with path in the error).

#### Scenario: Full-path sbcl work is under the run root

- **WHEN** full-path materialize runs for a `DepsAndAssets Sbcl` package PV
- **THEN** heavy temporary clone and stage directories for that unit are nested under the product run root unit tree rather than only as free-floating directories in the effective temp root
