## MODIFIED Requirements

### Requirement: pycargoebuild crate-tarball materialize

For `DepsAndAssets Cargo` full-path materialization of PV, the program SHALL: (1) clone the package’s GitHub source into a temporary directory and check out the tag formed by the source tag prefix plus that PV; (2) run `pycargoebuild` with crate-tarball mode against the package subdirectory when policy sets one, otherwise against the lock root, inplace-updating the working ebuild, without invoking `pkgdev manifest` (`-M`), with `--no-write-crate-tarball` so pycargoebuild does not create the crates archive, passing a manager-chosen `--crate-tarball-path` whose basename is `{pn}-{pv}-crates.tar.xz` and `--crate-tarball-prefix` `cargo_home/gentoo`, using a temporary distdir for fetched crates; (3) after pycargoebuild succeeds, pack the fetched registry crates into that tarball path as specified by the manager-owned crates tarball pack requirement; (4) not reimplement pycargoebuild’s crate fetch or license logic in Haskell. The program MAY parse `Cargo.lock` for packing and for MSRV. The temporary clone, temp distdir, and pack stage tree SHALL be removed when the PV attempt finishes. The program SHALL NOT require host `rustc` or `cargo` for packing.

#### Scenario: Full path invokes pycargoebuild

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5`
- **THEN** the process runs `pycargoebuild` with `--crate-tarball`, `--no-write-crate-tarball`, and a tarball path whose basename is `mise-2026.7.5-crates.tar.xz`

#### Scenario: Full path pack produces the crates tarball

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5` and pycargoebuild succeeds
- **THEN** the manager writes `mise-2026.7.5-crates.tar.xz` at the planned path and does not rely on pycargoebuild to create that file

#### Scenario: No host rustc gate

- **WHEN** full-path cargo materialize runs on a host without `rustc` on PATH but with `pycargoebuild`, a supported fetcher, and `xz`
- **THEN** packing is not failed solely due to missing `rustc`

### Requirement: Cargo distfile and release naming

For Cargo packages, the program SHALL name the dependency distfile `{pn}-{pv}-crates.tar.xz` using the overlay package name PN and version PV without revision. Release tags SHALL remain `{pn}-{pv}`. The program SHALL pass this basename to pycargoebuild via `--crate-tarball-path` (for tarball mode / empty CRATES metadata) and SHALL write that same basename when packing after pycargoebuild, rather than relying on Cargo.toml package name defaults when they could differ from PN.

#### Scenario: mise crates name

- **WHEN** publishing assets for package `mise` at PV `2026.7.5`
- **THEN** the distfile basename is `mise-2026.7.5-crates.tar.xz` and the release tag is `mise-2026.7.5`

### Requirement: Cargo reuse path skips pycargoebuild

When a planned Cargo PV needs work but an assets release already provides `{pn}-{pv}-crates.tar.xz` and the downloaded bytes’ SHA512 matches the expected Manifest or trusted hash (reuse R2), the program SHALL reuse that asset without running `pycargoebuild`, without running manager crate packing, and without re-publishing. The program MAY still rewrite KEYWORDS, `RUST_MIN_VER`, and SRC_URI for plan adequacy, and SHALL ensure steady-state tarball shape includes empty `CRATES` (so list-era donor bodies are not left with non-empty `CRATES` on reuse), then run `ebuild … manifest` and verify as for other `DepsAndAssets` ecosystems.

#### Scenario: Clean reuse no pycargoebuild

- **WHEN** the crates asset for `usage-3.5.4-crates.tar.xz` exists on the release and SHA512 matches
- **THEN** apply does not invoke `pycargoebuild` for that unit

#### Scenario: Clean reuse no manager crate pack

- **WHEN** the crates asset for `usage-3.5.4-crates.tar.xz` exists on the release and SHA512 matches
- **THEN** apply does not run manager crate packing for that unit

#### Scenario: Reuse clears list-era CRATES

- **WHEN** reuse applies for a PV whose donor ebuild still has a non-empty `CRATES` list
- **THEN** the written ebuild has empty `CRATES` suitable for crate-tarball packaging

## ADDED Requirements

### Requirement: Manager-owned crates tarball pack

For full-path Cargo materialize after successful pycargoebuild with `--no-write-crate-tarball`, the program SHALL create `{pn}-{pv}-crates.tar.xz` by: (1) parsing `Cargo.lock` at the policy lock root for registry packages that declare a checksum; (2) for each such package, extracting the corresponding `{name}-{version}.crate` from the temporary distdir into a stage tree under `cargo_home/gentoo/{name}-{version}/` and writing `.cargo-checksum.json` with `package` set to the lockfile checksum and `files` an empty object; (3) creating the archive with system `tar` such that member paths are prefixed with `cargo_home/gentoo/…`, compressing with environment `XZ_OPT=-T0 -9e`; (4) writing the final file atomically (temp then rename). Pack SHALL hard-fail if a lock-listed registry crate file is missing from the distdir or if archive creation fails, with an error distinct from pycargoebuild failure. Git/path packages that are not registry crates with checksums SHALL NOT be required in the tarball (GIT_CRATES remain pycargoebuild’s ebuild concern).

#### Scenario: Checksum JSON from lock

- **WHEN** the lock lists registry package `serde` version `1.0.200` with checksum `abc123` and the matching `.crate` is in the distdir
- **THEN** the packed tarball contains `cargo_home/gentoo/serde-1.0.200/.cargo-checksum.json` whose `package` field is `abc123`

#### Scenario: Compression uses multi-threaded extreme xz

- **WHEN** the manager packs a crates tarball
- **THEN** the pack process uses system `tar` with `XZ_OPT` containing `-T0` and `-9e` (or equivalent extreme multi-thread settings)

#### Scenario: Missing crate after pycargo hard-fails pack

- **WHEN** `Cargo.lock` lists a registry package whose `.crate` is absent from the temporary distdir after pycargoebuild
- **THEN** pack fails with an error that is not reported solely as a pycargoebuild failure

#### Scenario: Atomic final path

- **WHEN** pack succeeds
- **THEN** the final `{pn}-{pv}-crates.tar.xz` path exists as a complete file (no partial final basename left from a failed mid-write)
