# cargo-crates-assets Delta

## MODIFIED Requirements

### Requirement: pycargoebuild crate-tarball materialize

For `DepsAndAssets Cargo` with provenance `CargoGitTag`, full-path materialization of PV, the program SHALL: (1) clone the package’s GitHub source into the unit `work/` directory under the product temporary workspace defined by `temp-workspace` and check out the tag formed by the source tag prefix plus that PV; (2) run `pycargoebuild` with `--use-crate-tarball` against the package subdirectory when policy sets one, otherwise against the lock root, inplace-updating the working ebuild, without invoking `pkgdev manifest` (`-M`), so pycargoebuild does not create the crates archive, passing a manager-chosen `--crate-tarball-path` whose basename is `{pn}-{pv}-crates.tar.xz` and `--crate-tarball-prefix` `cargo_home/gentoo`, using a temporary distdir under the unit work area for fetched crates, and passing neither `-c`, `--crate-tarball`, `--no-write-crate-tarball`, `-u`, `-w`, `--write-crate-tarball`, `-C`, nor `--fill-crates`; (3) after pycargoebuild succeeds, pack the fetched registry crates into that tarball path under the unit `out/` as specified by the manager-owned crates tarball pack requirement; (4) not reimplement pycargoebuild’s crate fetch or license logic in Haskell. The program MAY parse `Cargo.lock` for packing and for MSRV. The temporary clone, temp distdir, and pack stage tree SHALL follow the `temp-workspace` unit lifecycle (delete the unit tree on success or soft-skip; retain on hard-fail with path in the error). Full-path clone, `pycargoebuild`, fetch, and pack SHALL run in the materialize container. The program SHALL NOT require host `rustc`, `cargo`, `pycargoebuild`, or `xz` for packing.

#### Scenario: Full path invokes pycargoebuild

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5`
- **THEN** the process runs `pycargoebuild` with `--use-crate-tarball` and a tarball path whose basename is `mise-2026.7.5-crates.tar.xz`
- **AND** that argv does not include `-c`, `--crate-tarball`, `--no-write-crate-tarball`, `-u`, `-w`, `--write-crate-tarball`, `-C`, or `--fill-crates`
- **AND** pycargoebuild stderr does not warn that the mode argument will be required

#### Scenario: Full path pack produces the crates tarball

- **WHEN** full-path materialize runs for `mise` at PV `2026.7.5` and pycargoebuild succeeds
- **THEN** the manager writes `mise-2026.7.5-crates.tar.xz` at the planned path and does not rely on pycargoebuild to create that file

#### Scenario: No host rustc gate

- **WHEN** full-path cargo materialize runs without `rustc` on the host PATH
- **THEN** packing is not failed solely due to missing host `rustc`

### Requirement: Manager-owned crates tarball pack

For full-path Cargo materialize after successful pycargoebuild with `--use-crate-tarball`, the program SHALL create `{pn}-{pv}-crates.tar.xz` by: (1) parsing the provenance-appropriate `Cargo.lock` — provenance `CargoGitTag`: the clone’s lock at the policy lock root; provenance `CargoCratesIo`: the unpacked published crate’s `Cargo.lock` — for registry packages that declare a checksum; (2) for each such package, extracting the corresponding `{name}-{version}.crate` from the temporary distdir into a stage tree under `cargo_home/gentoo/{name}-{version}/` and writing `.cargo-checksum.json` with `package` set to the lockfile checksum and `files` an empty object; (3) creating the archive with system `tar` such that member paths are prefixed with `cargo_home/gentoo/…`, packing with the hermetic tar/xz rules specified by `hermetic-asset-materialize` (`XZ_OPT=-T1 -9e`, numeric owner `0/0`); (4) writing the final file atomically (temp then rename) such that the path presented to `tar` for compression **always selects xz** (the program SHALL NOT use a temporary basename whose suffix causes `tar -a` / auto-compress to skip compression—for example a bare `.tmp` suffix on an otherwise `.tar.xz` product name—unless xz is forced by an explicit xz filter flag equivalent to `-J` / `--xz`); (5) after a successful archive write and rename to the final `{pn}-{pv}-crates.tar.xz` path, verifying that the final file is an xz-compressed stream (hard-fail with an error distinct from pycargoebuild failure if the body is plain tar or otherwise not xz). Pack SHALL hard-fail if a lock-listed registry crate file is missing from the distdir or if archive creation fails, with an error distinct from pycargoebuild failure. Git/path packages that are not registry crates with checksums SHALL NOT be required in the tarball (GIT_CRATES remain pycargoebuild’s ebuild concern).

#### Scenario: Checksum JSON from lock

- **WHEN** the lock lists registry package `serde` version `1.0.200` with checksum `abc123` and the matching `.crate` is in the distdir
- **THEN** the packed tarball contains `cargo_home/gentoo/serde-1.0.200/.cargo-checksum.json` whose `package` field is `abc123`

#### Scenario: CratesIo pack includes published workspace members

- **WHEN** pack runs for a `CargoCratesIo` unit of `biodiff` at PV `1.2.1`
- **THEN** the packed tarball includes `cargo_home/gentoo/hexagex-0.2.3/` and `cargo_home/gentoo/biodiff-wfa2-sys-2.3.5/`
- **AND** the `-sys` crate directory contains the bundled WFA2-lib C sources

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

### Requirement: CratesIo materialize from the published crate

For `DepsAndAssets Cargo` with provenance `CargoCratesIo`, full-path materialization of PV SHALL, inside the materialize container: (1) download the published crate for the policy crate name at that PV from the canonical crates.io download endpoint into the unit distdir using `aria2c` with its default User-Agent (the image-provided fetcher posture shared with pycargoebuild’s own crate fetches); (2) unpack the `.crate` into the unit `work/` source area such that the unpacked directory name matches `{p}`; (3) run `pycargoebuild` with `--use-crate-tarball` against the unpacked crate root with the same inplace, `-M`, `--crate-tarball-path` (`{pn}-{pv}-crates.tar.xz`), and `--crate-tarball-prefix` (`cargo_home/gentoo`) arguments as the GitTag lane, passing neither `-c`, `--crate-tarball`, `--no-write-crate-tarball`, `-u`, `-w`, `--write-crate-tarball`, `-C`, nor `--fill-crates`, using a temporary distdir under the unit work area; (4) pack the fetched registry crates from the unpacked crate’s `Cargo.lock` per the manager-owned crates tarball pack requirement. The program SHALL hard-fail the unit when the published crate for the PV cannot be fetched (naming the endpoint and PV), when the published crate’s package name differs from the overlay package name (naming both), or when the unpacked crate lacks `Cargo.lock`. The program SHALL NOT silently fall back to GitTag provenance or to the GitHub tag archive. The unit workspace and lifecycle SHALL follow `temp-workspace` exactly as for the GitTag lane. Full-path download, unpack, `pycargoebuild`, fetch, and pack SHALL run in the materialize container.

#### Scenario: Crate distfile fetch and unpack

- **WHEN** CratesIo materialize runs for `biodiff` at PV `1.2.1`
- **THEN** `aria2c` downloads `biodiff-1.2.1.crate` from the crates.io download endpoint with its default User-Agent
- **AND** the unpacked work source is the directory `biodiff-1.2.1/` containing `Cargo.toml` and `Cargo.lock`

#### Scenario: Missing published crate hard-fails

- **WHEN** crates.io has no published crate for the target PV
- **THEN** the unit hard-fails naming the endpoint and PV
- **AND** the program does not fall back to GitTag provenance or the GitHub tag archive

#### Scenario: Published lock drives the pack set

- **WHEN** pycargoebuild succeeds for a CratesIo unit of `biodiff` at PV `1.2.1`
- **THEN** the pack parses `biodiff-1.2.1/Cargo.lock`
- **AND** the packed tarball includes the published workspace-member crates `hexagex-0.2.3` and `biodiff-wfa2-sys-2.3.5`

#### Scenario: Name divergence hard-fails

- **WHEN** the published crate’s package name differs from the overlay package name PN
- **THEN** the unit hard-fails naming both names before ebuild or Manifest mutation

#### Scenario: pycargoebuild runs against the unpacked crate

- **WHEN** CratesIo materialize runs for `biodiff` at PV `1.2.1` and pycargoebuild succeeds
- **THEN** pycargoebuild ran against the unpacked `biodiff-1.2.1/` directory (a published crate, which carries `[package]` and no `[workspace]` table)
- **AND** that invocation included `--use-crate-tarball` and did not include `-c`, `--crate-tarball`, `--no-write-crate-tarball`, `-u`, `-w`, `--write-crate-tarball`, `-C`, or `--fill-crates`
