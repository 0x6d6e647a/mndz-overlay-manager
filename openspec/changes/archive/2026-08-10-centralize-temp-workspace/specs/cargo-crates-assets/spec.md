## MODIFIED Requirements

### Requirement: pycargoebuild crate-tarball materialize

For `DepsAndAssets Cargo` full-path materialization of PV, the program SHALL: (1) clone the package’s GitHub source into the unit `work/` directory under the product temporary workspace defined by `temp-workspace` and check out the tag formed by the source tag prefix plus that PV; (2) run `pycargoebuild` with crate-tarball mode against the package subdirectory when policy sets one, otherwise against the lock root, inplace-updating the working ebuild, without invoking `pkgdev manifest` (`-M`), with `--no-write-crate-tarball` so pycargoebuild does not create the crates archive, passing a manager-chosen `--crate-tarball-path` whose basename is `{pn}-{pv}-crates.tar.xz` and `--crate-tarball-prefix` `cargo_home/gentoo`, using a temporary distdir under the unit work area for fetched crates; (3) after pycargoebuild succeeds, pack the fetched registry crates into that tarball path under the unit `out/` (or equivalent staged output) as specified by the manager-owned crates tarball pack requirement; (4) not reimplement pycargoebuild’s crate fetch or license logic in Haskell. The program MAY parse `Cargo.lock` for packing and for MSRV. The temporary clone, temp distdir, and pack stage tree SHALL follow the `temp-workspace` unit lifecycle (delete the unit tree on success or soft-skip; retain on hard-fail with path in the error). The program SHALL NOT require host `rustc` or `cargo` for packing.

#### Scenario: Full path invokes pycargoebuild

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5`
- **THEN** the process runs `pycargoebuild` with `--crate-tarball`, `--no-write-crate-tarball`, and a tarball path whose basename is `mise-2026.7.5-crates.tar.xz`

#### Scenario: Full path pack produces the crates tarball

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5` and pycargoebuild succeeds
- **THEN** the manager writes `mise-2026.7.5-crates.tar.xz` at the planned path and does not rely on pycargoebuild to create that file

#### Scenario: No host rustc gate

- **WHEN** full-path cargo materialize runs on a host without `rustc` on PATH but with `pycargoebuild`, a supported fetcher, and `xz`
- **THEN** packing is not failed solely due to missing `rustc`
