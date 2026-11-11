# Spec Delta

## MODIFIED Requirements

### Requirement: Sbcl deps tarball xz compression and verification

When full-path materialize for `DepsAndAssets Sbcl` packs `{pn}-{pv}-deps.tar.xz`, the program SHALL pack with the hermetic tar/xz rules specified by `hermetic-asset-materialize` (`XZ_OPT=-T{N} -9e`, where `N` is the resolved `--jobs` value, numeric owner `0/0`), SHALL ensure packed `.qlot/qlot.conf` and `.qlot/source-registry.conf` contain no `/home/` pathnames, SHALL omit `:qlot-source-directory`, `:setup-file`, and a source-registry `:directory` entry that names a builder qlot checkout, and SHALL verify that the final deps path is an xz-compressed stream. If the final file is plain tar or otherwise not xz, pack SHALL hard-fail before assets publish treats the file as successful. The program SHALL NOT rewrite those builder paths to `/home/builder` or any other home directory.

#### Scenario: Sbcl deps pack uses extreme multi-thread xz

- **WHEN** the manager packs an Sbcl/Autolith deps tarball
- **THEN** the pack process uses `XZ_OPT` containing `-T` equal to the resolved `--jobs` value and `-9e` (hermetic-asset-materialize)

#### Scenario: Sbcl deps pack rejects non-xz body

- **WHEN** the final `{pn}-{pv}-deps.tar.xz` path is not an xz-compressed stream after pack
- **THEN** materialize hard-fails before assets publish treats the file as successful

#### Scenario: Packed qlot has no operator home

- **WHEN** the manager packs an Autolith deps tarball
- **THEN** `.qlot/qlot.conf` and `.qlot/source-registry.conf` do not contain `/home/`
- **AND** those files do not contain `:qlot-source-directory` or `:setup-file`
- **AND** `source-registry.conf` has no `:directory` entry
