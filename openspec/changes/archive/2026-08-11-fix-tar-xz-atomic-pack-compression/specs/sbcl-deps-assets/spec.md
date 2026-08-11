## ADDED Requirements

### Requirement: Sbcl deps tarball xz compression and verification

When full-path materialize for `DepsAndAssets Sbcl` packs `{pn}-{pv}-deps.tar.xz`, the program SHALL compress with environment `XZ_OPT=-T0 -9e` (multi-threaded extreme xz, or equivalent extreme multi-thread settings) when invoking tar, and SHALL verify that the final deps path is an xz-compressed stream. If the final file is plain tar or otherwise not xz, pack SHALL hard-fail before assets publish treats the file as successful.

#### Scenario: Sbcl deps pack uses extreme multi-thread xz

- **WHEN** the manager packs an Sbcl/Autolith deps tarball
- **THEN** the pack process uses `XZ_OPT` containing `-T0` and `-9e` (or equivalent extreme multi-thread settings)

#### Scenario: Sbcl deps pack rejects non-xz body

- **WHEN** the final `{pn}-{pv}-deps.tar.xz` path is not an xz-compressed stream after pack
- **THEN** materialize hard-fails before assets publish treats the file as successful
