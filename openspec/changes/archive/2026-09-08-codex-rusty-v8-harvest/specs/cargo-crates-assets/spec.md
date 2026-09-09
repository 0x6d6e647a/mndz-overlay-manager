## MODIFIED Requirements

### Requirement: rusty_v8 submodule sidecar

When full-path Cargo materialize runs for `dev-util/codex` and that unit’s provenance lock pins a crates.io `v8` package, the program SHALL treat a rusty_v8+recursive-submodules snapshot as a required pin-keyed companion **separate from** the Codex crates release. Full-path SHALL: (1) parse the `v8` name/version/checksum from the provenance lock; (2) if mndz-overlay-assets already has basename `rusty-v8-${ver}-with-submodules.tar.xz` **and** GitHub release tag `rusty-v8-${ver}` provides that asset, and downloaded bytes verify against the assets-worktree checksum sidecars, reuse it without cloning; (3) otherwise clone `https://github.com/denoland/rusty_v8` at tag `v${ver}` with recursive submodules inside the materialize container, pack under the hermetic tar/xz rules, and publish a new assets release whose tag, GitHub release name, and asset basename are keyed by crate version (`rusty-v8-${ver}` / `rusty-v8-${ver}-with-submodules.tar.xz`), not by Codex PV. The program SHALL write overlay `RUSTY_V8_VER` and the rusty-v8 `SRC_URI` download tag from that pin. The program SHALL NOT pack this tree into `{pn}-{pv}-crates.tar.xz`. The program SHALL NOT attach the snapshot to GitHub release tag `codex-${PV}`. Chromium clang and rust-toolchain GCS objects SHALL remain ebuild `SRC_URI` distfiles, not overlay-assets.

A package other than `dev-util/codex` SHALL NOT harvest or require this sidecar, including other Cargo GitTag packages whose lock might pin crates.io `v8`.

Codex crates required-asset lookup for tag `codex-${PV}` SHALL be `{pn}-{pv}-crates.tar.xz` only. Absence of a rusty_v8 snapshot SHALL NOT make an existing crates release partial.

#### Scenario: Same v8 pin reuses the snapshot

- **WHEN** full-path materialize runs for `codex` 0.153.4 and the lock still pins `v8` `150.4.0` and assets already hold `rusty-v8-150.4.0-with-submodules.tar.xz` under tag `rusty-v8-150.4.0` with verifying checksums
- **THEN** apply does not clone `denoland/rusty_v8`
- **AND** it still publishes `{pn}-0.153.4-crates.tar.xz` as a new crates sidecar
- **AND** the written ebuild `RUSTY_V8_VER` is `150.4.0`
- **AND** rusty-v8 `SRC_URI` still downloads from tag `rusty-v8-150.4.0`

#### Scenario: Pin change harvests a new snapshot

- **WHEN** full-path materialize runs for `dev-util/codex` whose lock pins `v8` `150.5.0` and no rusty_v8 snapshot exists for `150.5.0`
- **THEN** the container clones tag `v150.5.0` with recursive submodules
- **AND** it publishes `rusty-v8-150.5.0-with-submodules.tar.xz` on GitHub release tag `rusty-v8-150.5.0` whose release name is `rusty-v8-150.5.0`
- **AND** the written ebuild `RUSTY_V8_VER` is `150.5.0`

#### Scenario: hk is unaffected

- **WHEN** full-path materialize runs for `dev-util/hk`
- **THEN** apply does not harvest or require a rusty_v8 snapshot

#### Scenario: Missing snapshot does not partial the crates tag

- **WHEN** release tag `codex-0.153.4` has `codex-0.153.4-crates.tar.xz` and no rusty-v8 asset
- **THEN** that crates tag is complete for Codex crates reuse/full-path classification
- **AND** rusty-v8 is looked up on tag `rusty-v8-${ver}` instead

### Requirement: Cargo reuse path skips pycargoebuild

When a planned Cargo PV needs work, has a derivable reuse-write floor, is not forced full, and an assets release provides every required asset basename including `{pn}-{pv}-crates.tar.xz`, the program SHALL reuse those assets when downloaded bytes pass expected Manifest/trusted-hash verification. For `dev-util/codex`, the crates tag’s required set SHALL NOT include the rusty_v8 snapshot; that snapshot SHALL be reused or harvested as specified by the rusty_v8 submodule sidecar requirement. Reuse SHALL NOT run pycargoebuild, manager crate packing, rusty_v8 clone, or crates-tag release publication. It MAY rewrite KEYWORDS, `RUST_MIN_VER`, `RUSTY_V8_VER`, GCS filename assignments, and SRC_URI for plan adequacy, SHALL ensure steady-state tarball shape has empty `CRATES`, then SHALL run `ebuild ... manifest` and verify as for other `DepsAndAssets` ecosystems.

If the crates release tag exists but any required **crates-tag** asset is missing, or if the PV is forced full because no reuse-write floor is derivable, the package SHALL hard-fail before mutation because full publication cannot update, replace, or delete an existing release tag. Absence of the crates release tag SHALL permit the full path. A missing rusty_v8 snapshot for a new `v8` pin SHALL NOT by itself force the crates full path when the crates tag is absent; full-path SHALL harvest the snapshot as specified by the rusty_v8 submodule sidecar requirement.

#### Scenario: Clean reuse no pycargoebuild

- **WHEN** all required release assets for `usage-3.5.4` exist, their bytes verify, and its reuse-write floor is derivable
- **THEN** apply does not invoke pycargoebuild for that unit

#### Scenario: Clean reuse no manager crate pack

- **WHEN** all required release assets for `usage-3.5.4` exist, their bytes verify, and its reuse-write floor is derivable
- **THEN** apply does not run manager crate packing for that unit

#### Scenario: Reuse clears list-era CRATES

- **WHEN** reuse applies for a PV whose canonical template still has a non-empty `CRATES` list
- **THEN** the written ebuild has empty `CRATES` suitable for crate-tarball packaging

#### Scenario: Existing release cannot satisfy forced-full Cargo unit

- **WHEN** all required assets exist but the Cargo PV is forced full because it has no derivable reuse-write floor
- **THEN** the package hard-fails with release-tag guidance and does not run pycargoebuild or mutate local/remote assets

#### Scenario: Existing tag missing asset hard-fails

- **WHEN** the crates release tag for a planned Cargo PV exists but `{pn}-{pv}-crates.tar.xz` is missing from that release
- **THEN** the package hard-fails before overlay mutation

## ADDED Requirements

### Requirement: Chromium GCS filenames from v8/DEPS for Codex

When `dev-util/codex` full-path (or overlay write after rusty_v8 harvest/reuse) has a crates.io `v8` pin that **differs** from the donor ebuild `RUSTY_V8_VER`, the program SHALL parse `v8/DEPS` from the rusty_v8 tree (fresh recursive clone, or `v8/DEPS` extracted from the verified snapshot tarball) without executing it as Python. From the GCS blocks `'third_party/llvm-build/Release+Asserts'` and `'third_party/rust-toolchain'` it SHALL take the unique `Linux_x64/` object whose `condition` is exactly `host_os == "linux"`, with basename prefixes `clang-llvmorg-` and `rust-toolchain-` respectively, and SHALL write those basenames as `CLANG_DIST` and `RUST_TC_DIST`. Zero or more than one keep-set match, missing `v8/DEPS`, or a non-GCS dep type SHALL hard-fail the unit. When the lock pin **equals** donor `RUSTY_V8_VER`, the program SHALL copy the donor `CLANG_DIST` and `RUST_TC_DIST` assignments and SHALL NOT clone rusty_v8 solely to re-parse DEPS. Those GCS objects SHALL remain Chromium `SRC_URI` distfiles (`https://commondatastorage.googleapis.com/chromium-browser-clang/Linux_x64/…`), not overlay-assets.

A 150.4.0 `v8/DEPS` SHALL yield `clang-llvmorg-23-init-10931-g20b6ec66-11.tar.xz` and `rust-toolchain-4c4205163abcbd08948b3efab796c543ba1ea687-4-llvmorg-23-init-10931-g20b6ec66.tar.xz`.

#### Scenario: 150.4.0 DEPS round-trips seed filenames

- **WHEN** the parser reads `v8/DEPS` from rusty_v8 tag `v150.4.0`
- **THEN** `CLANG_DIST` is `clang-llvmorg-23-init-10931-g20b6ec66-11.tar.xz`
- **AND** `RUST_TC_DIST` is `rust-toolchain-4c4205163abcbd08948b3efab796c543ba1ea687-4-llvmorg-23-init-10931-g20b6ec66.tar.xz`

#### Scenario: Same pin copies donor GCS lines

- **WHEN** full-path materialize runs for a new Codex PV whose lock still pins `v8` `150.4.0` and the donor ebuild already has that `RUSTY_V8_VER` and matching GCS filenames
- **THEN** apply does not clone rusty_v8 solely to parse DEPS
- **AND** the written ebuild keeps the donor `CLANG_DIST` and `RUST_TC_DIST`

#### Scenario: Pin change without parseable DEPS hard-fails

- **WHEN** Codex full-path harvests rusty_v8 for a new pin and `v8/DEPS` has no unique Linux_x64 `host_os == "linux"` `clang-llvmorg-` object
- **THEN** the unit hard-fails before overlay commit
- **AND** apply does not invent a clang tarball name
