## MODIFIED Requirements

### Requirement: Deps tarball layout contract

Full-path materialize for `DepsAndAssets Sbcl` SHALL produce a tarball whose contents include a top-level `.qlot/` directory suitable for offline Autolith bootstrap and a top-level `fff/` tree at the commit declared by upstream `native/fff/commit` for that tag. The `fff/` tree SHALL include the Cargo workspace members and `vendor/` output sufficient for `cargo build --offline --locked -p fff-c` of the fff C library package used by Autolith. The packed `fff/` tree SHALL NOT include neovim plugin, lua, tests, GitHub workflow, flake, or node `packages/` trees that that cargo build does not require.

#### Scenario: Offline fff inputs present

- **WHEN** a full-path materialize completes for a PV
- **THEN** the packed tarball contains `.qlot/` and `fff/` with vendored crates for offline cargo

#### Scenario: Packed fff omits unused plugin trees

- **WHEN** a full-path materialize completes for a PV
- **THEN** the packed `fff/` tree does not contain `plugin/`, `lua/`, `tests/`, `.github/`, or `packages/`

### Requirement: Sbcl deps tarball xz compression and verification

When full-path materialize for `DepsAndAssets Sbcl` packs `{pn}-{pv}-deps.tar.xz`, the program SHALL pack with the hermetic tar/xz rules specified by `hermetic-asset-materialize` (`XZ_OPT=-T1 -9e`, numeric owner `0/0`), SHALL ensure packed `.qlot/qlot.conf` and `.qlot/source-registry.conf` contain no `/home/` pathnames, SHALL omit `:qlot-source-directory`, `:setup-file`, and a source-registry `:directory` entry that names a builder qlot checkout, and SHALL verify that the final deps path is an xz-compressed stream. If the final file is plain tar or otherwise not xz, pack SHALL hard-fail before assets publish treats the file as successful. The program SHALL NOT rewrite those builder paths to `/home/builder` or any other home directory.

#### Scenario: Sbcl deps pack uses extreme multi-thread xz

- **WHEN** the manager packs an Sbcl/Autolith deps tarball
- **THEN** the pack process uses `XZ_OPT` containing `-T1` and `-9e` (single-thread extreme; hermetic-asset-materialize)

#### Scenario: Sbcl deps pack rejects non-xz body

- **WHEN** the final `{pn}-{pv}-deps.tar.xz` path is not an xz-compressed stream after pack
- **THEN** materialize hard-fails before assets publish treats the file as successful

#### Scenario: Packed qlot has no operator home

- **WHEN** the manager packs an Autolith deps tarball
- **THEN** `.qlot/qlot.conf` and `.qlot/source-registry.conf` do not contain `/home/`
- **AND** those files do not contain `:qlot-source-directory` or `:setup-file`
- **AND** `source-registry.conf` has no `:directory` entry
