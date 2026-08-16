## MODIFIED Requirements

### Requirement: Preflight tools for materialize

When a selected `DepsAndAssets Sbcl` package requires full-path materialize, preflight SHALL require `docker` and a usable materialize image as specified by `hermetic-asset-materialize`. The image SHALL provide the tools needed to produce the deps tarball (including `git`, `sbcl`, cargo for vendoring, and a Quicklisp/qlot bootstrap that is **not** the operator `~/quicklisp/setup.lisp`). Reuse-only paths SHALL NOT require `docker` or those materialize-only tools solely because the package is Sbcl. The program SHALL NOT require Quicklisp at the operator home.

#### Scenario: Reuse without cargo

- **WHEN** apply will only reuse an existing deps asset for autolith
- **THEN** preflight does not fail solely due to missing `docker` or host `cargo` for that package

#### Scenario: Full path does not require operator Quicklisp

- **WHEN** full-path Autolith materialize runs and `~/quicklisp/setup.lisp` is absent on the host
- **THEN** preflight does not fail solely for that missing host file

### Requirement: Sbcl deps tarball xz compression and verification

When full-path materialize for `DepsAndAssets Sbcl` packs `{pn}-{pv}-deps.tar.xz`, the program SHALL pack with the hermetic tar/xz rules specified by `hermetic-asset-materialize` (`XZ_OPT=-T1 -9e`, numeric owner `0/0`), SHALL ensure packed `.qlot` files contain no operator-home pathnames, and SHALL verify that the final deps path is an xz-compressed stream. If the final file is plain tar or otherwise not xz, pack SHALL hard-fail before assets publish treats the file as successful.

#### Scenario: Sbcl deps pack uses extreme multi-thread xz

- **WHEN** the manager packs an Sbcl/Autolith deps tarball
- **THEN** the pack process uses `XZ_OPT` containing `-T1` and `-9e` (single-thread extreme; hermetic-asset-materialize)

#### Scenario: Sbcl deps pack rejects non-xz body

- **WHEN** the final `{pn}-{pv}-deps.tar.xz` path is not an xz-compressed stream after pack
- **THEN** materialize hard-fails before assets publish treats the file as successful

#### Scenario: Packed qlot has no operator home

- **WHEN** the manager packs an Autolith deps tarball
- **THEN** `.qlot/qlot.conf` and `.qlot/source-registry.conf` do not contain the operator home directory
