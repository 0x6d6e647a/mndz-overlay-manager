## MODIFIED Requirements

### Requirement: pycargoebuild crate-tarball materialize

For `DepsAndAssets Cargo` full-path materialization of PV, the program SHALL: (1) clone the package’s GitHub source into the unit `work/` directory under the product temporary workspace defined by `temp-workspace` and check out the tag formed by the source tag prefix plus that PV; (2) run `pycargoebuild` with crate-tarball mode against the package subdirectory when policy sets one, otherwise against the lock root, inplace-updating the working ebuild, without invoking `pkgdev manifest` (`-M`), with `--no-write-crate-tarball` so pycargoebuild does not create the crates archive, passing a manager-chosen `--crate-tarball-path` whose basename is `{pn}-{pv}-crates.tar.xz` and `--crate-tarball-prefix` `cargo_home/gentoo`, using a temporary distdir under the unit work area for fetched crates; (3) after pycargoebuild succeeds, pack the fetched registry crates into that tarball path under the unit `out/` as specified by the manager-owned crates tarball pack requirement; (4) not reimplement pycargoebuild’s crate fetch or license logic in Haskell. The program MAY parse `Cargo.lock` for packing and for MSRV. The temporary clone, temp distdir, and pack stage tree SHALL follow the `temp-workspace` unit lifecycle (delete the unit tree on success or soft-skip; retain on hard-fail with path in the error). Full-path clone, `pycargoebuild`, fetch, and pack SHALL run in the materialize container. The program SHALL NOT require host `rustc`, `cargo`, `pycargoebuild`, or `xz` for packing.

#### Scenario: Full path invokes pycargoebuild

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5`
- **THEN** the process runs `pycargoebuild` with `--crate-tarball`, `--no-write-crate-tarball`, and a tarball path whose basename is `mise-2026.7.5-crates.tar.xz`

#### Scenario: Full path pack produces the crates tarball

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5` and pycargoebuild succeeds
- **THEN** the manager writes `mise-2026.7.5-crates.tar.xz` at the planned path and does not rely on pycargoebuild to create that file

#### Scenario: No host rustc gate

- **WHEN** full-path cargo materialize runs without `rustc` on the host PATH
- **THEN** packing is not failed solely due to missing host `rustc`

### Requirement: Manager-owned crates tarball pack

For full-path Cargo materialize after successful pycargoebuild with `--no-write-crate-tarball`, the program SHALL create `{pn}-{pv}-crates.tar.xz` by: (1) parsing `Cargo.lock` at the policy lock root for registry packages that declare a checksum; (2) for each such package, extracting the corresponding `{name}-{version}.crate` from the temporary distdir into a stage tree under `cargo_home/gentoo/{name}-{version}/` and writing `.cargo-checksum.json` with `package` set to the lockfile checksum and `files` an empty object; (3) creating the archive with system `tar` such that member paths are prefixed with `cargo_home/gentoo/…`, packing with the hermetic tar/xz rules specified by `hermetic-asset-materialize` (`XZ_OPT=-T1 -9e`, numeric owner `0/0`); (4) writing the final file atomically (temp then rename) such that the path presented to `tar` for compression **always selects xz** (the program SHALL NOT use a temporary basename whose suffix causes `tar -a` / auto-compress to skip compression—for example a bare `.tmp` suffix on an otherwise `.tar.xz` product name—unless xz is forced by an explicit xz filter flag equivalent to `-J` / `--xz`); (5) after a successful archive write and rename to the final `{pn}-{pv}-crates.tar.xz` path, verifying that the final file is an xz-compressed stream (hard-fail with an error distinct from pycargoebuild failure if the body is plain tar or otherwise not xz). Pack SHALL hard-fail if a lock-listed registry crate file is missing from the distdir or if archive creation fails, with an error distinct from pycargoebuild failure. Git/path packages that are not registry crates with checksums SHALL NOT be required in the tarball (GIT_CRATES remain pycargoebuild’s ebuild concern).

#### Scenario: Checksum JSON from lock

- **WHEN** the lock lists registry package `serde` version `1.0.200` with checksum `abc123` and the matching `.crate` is in the distdir
- **THEN** the packed tarball contains `cargo_home/gentoo/serde-1.0.200/.cargo-checksum.json` whose `package` field is `abc123`

#### Scenario: Compression uses multi-threaded extreme xz

- **WHEN** the manager packs a crates tarball
- **THEN** the pack process uses system `tar` with `XZ_OPT` containing `-T1` and `-9e` (single-thread extreme; hermetic-asset-materialize)

#### Scenario: Atomic temp still compresses as xz

- **WHEN** pack writes via a temporary path before renaming to `{pn}-{pv}-crates.tar.xz`
- **THEN** the produced final file is xz-compressed data (not a plain POSIX tar archive)

#### Scenario: Plain tar final path hard-fails

- **WHEN** archive creation leaves a final `*.tar.xz` path whose content is not an xz stream
- **THEN** pack hard-fails before assets publish treats the file as a successful crates distfile

#### Scenario: Missing crate after pycargo hard-fails pack

- **WHEN** `Cargo.lock` lists a registry package whose `.crate` is absent from the temporary distdir after pycargoebuild
- **THEN** pack fails with an error that is not reported solely as a pycargoebuild failure

#### Scenario: Atomic final path

- **WHEN** pack succeeds
- **THEN** the final `{pn}-{pv}-crates.tar.xz` path exists as a complete file (no partial final basename left from a failed mid-write)

### Requirement: Cargo preflight tools

When any classified **full-path** unit uses `DepsAndAssets Cargo`, preflight SHALL require `docker` and a usable materialize image as specified by `hermetic-asset-materialize`. The image SHALL provide `pycargoebuild` and at least one fetcher among `wget` and `aria2c`. Preflight SHALL NOT require host `pycargoebuild`, `wget`, `aria2c`, `xz`, or `rustc` solely because a cargo package needs work. Reuse-only cargo units SHALL NOT fail preflight solely because those host tools or `docker` are missing.

#### Scenario: Missing pycargoebuild

- **WHEN** `update` selects `dev-util/mise`, a cargo unit is classified full path, and `docker` is not available
- **THEN** preflight fails before apply (image provides `pycargoebuild`; host binary is not a substitute)

#### Scenario: Missing both wget and aria2c

- **WHEN** a cargo unit is classified full path and the materialize image is unusable
- **THEN** preflight fails before package mutation (fetchers live in the image, not on the host PATH)

#### Scenario: aria2 alone does not satisfy fetcher preflight

- **WHEN** a cargo unit is classified full path and only a host binary named `aria2` (without `c`) exists
- **THEN** that host binary does not satisfy full-path cargo preflight; `docker` and the image are required

#### Scenario: Reuse-only cargo skips host pycargoebuild

- **WHEN** a cargo package needs work and every cargo unit is classified reuse
- **THEN** preflight does not fail solely because host `pycargoebuild` or a fetcher is missing

### Requirement: Soft advisory when cargo full path will use wget

The host wget/aria2 speed advisory specified previously for host-PATH `pycargoebuild` SHALL NOT be emitted solely because `aria2c` is absent from the **host** `PATH`. The materialize image SHOULD provide `aria2c`; image-internal fetcher choice is not an operator host preflight.

#### Scenario: Full-path cargo with wget only warns once

- **WHEN** `update` will full-path materialize a cargo package and `aria2c` is not on the **host** `PATH`
- **THEN** the program does not emit `pycargoebuild is using wget; install aria2 for faster crate fetches` solely for that host PATH

#### Scenario: aria2c present no advisory

- **WHEN** `update` will full-path materialize a cargo package and `aria2c` is on the host `PATH`
- **THEN** the program does not emit the wget/aria2 speed advisory solely for that package set

#### Scenario: Reuse-only cargo no advisory

- **WHEN** a cargo package needs work but every cargo unit is classified reuse (no full-path cargo materialize)
- **THEN** the program does not emit the wget/aria2 speed advisory solely for missing host `aria2c`
