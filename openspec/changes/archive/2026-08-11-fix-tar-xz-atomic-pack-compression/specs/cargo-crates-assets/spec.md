## MODIFIED Requirements

### Requirement: Manager-owned crates tarball pack

For full-path Cargo materialize after successful pycargoebuild with `--no-write-crate-tarball`, the program SHALL create `{pn}-{pv}-crates.tar.xz` by: (1) parsing `Cargo.lock` at the policy lock root for registry packages that declare a checksum; (2) for each such package, extracting the corresponding `{name}-{version}.crate` from the temporary distdir into a stage tree under `cargo_home/gentoo/{name}-{version}/` and writing `.cargo-checksum.json` with `package` set to the lockfile checksum and `files` an empty object; (3) creating the archive with system `tar` such that member paths are prefixed with `cargo_home/gentoo/…`, compressing with environment `XZ_OPT=-T0 -9e` (multi-threaded extreme xz); (4) writing the final file atomically (temp then rename) such that the path presented to `tar` for compression **always selects xz** (the program SHALL NOT use a temporary basename whose suffix causes `tar -a` / auto-compress to skip compression—for example a bare `.tmp` suffix on an otherwise `.tar.xz` product name—unless xz is forced by an explicit xz filter flag equivalent to `-J` / `--xz`); (5) after a successful archive write and rename to the final `{pn}-{pv}-crates.tar.xz` path, verifying that the final file is an xz-compressed stream (hard-fail with an error distinct from pycargoebuild failure if the body is plain tar or otherwise not xz). Pack SHALL hard-fail if a lock-listed registry crate file is missing from the distdir or if archive creation fails, with an error distinct from pycargoebuild failure. Git/path packages that are not registry crates with checksums SHALL NOT be required in the tarball (GIT_CRATES remain pycargoebuild’s ebuild concern).

#### Scenario: Checksum JSON from lock

- **WHEN** the lock lists registry package `serde` version `1.0.200` with checksum `abc123` and the matching `.crate` is in the distdir
- **THEN** the packed tarball contains `cargo_home/gentoo/serde-1.0.200/.cargo-checksum.json` whose `package` field is `abc123`

#### Scenario: Compression uses multi-threaded extreme xz

- **WHEN** the manager packs a crates tarball
- **THEN** the pack process uses system `tar` with `XZ_OPT` containing `-T0` and `-9e` (or equivalent extreme multi-thread settings)

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
