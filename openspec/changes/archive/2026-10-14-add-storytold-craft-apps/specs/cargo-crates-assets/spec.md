# cargo-crates-assets Delta

## MODIFIED Requirements

### Requirement: Hardcoded cargo packages enabled

The hardcoded policy map SHALL set `DepsAndAssets` with ecosystem `Cargo` for `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` with their existing GitHub sources (`jdx` / respective repos / tag prefix `v`) and provenance `CargoGitTag`, for `dev-util/biodiff` with GitHub source `8051enthusiast`/`biodiff` (tag prefix `v`) and provenance `CargoCratesIo`, and for `dev-util/codex` with GitHub source `openai`/`codex` (tag prefix `rust-v`), lock subdirectory `codex-rs`, package subdirectory `codex-rs/cli`, and provenance `CargoGitTag`. Those packages SHALL NOT remain `Unsupported` solely for cargo CRATES regeneration. Policy for `usage` SHALL use package subdirectory `cli` when required for package metadata. Policy for `codex` SHALL restrict runtime-lane arches to amd64 as specified by `runtime-lanes`. Policy for `media-gfx/photocraft` SHALL use GitHub source `storytold`/`photocraft` (tag prefix `v`), provenance `CargoGitTag`, no lock subdirectory, package subdirectory `apps/photocraft`, and SHALL restrict runtime-lane arches to `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`.
Policy for `app-office/deckcraft`, `app-office/designcraft`, `app-office/gridcraft`, `app-office/wordcraft`, `app-text/pdfcraft`, `media-gfx/cadcraft`, `media-gfx/lightcraft`, `media-gfx/vectorcraft`, `media-sound/soundcraft`, `media-video/effectcraft`, and `media-video/filmcraft` SHALL each use GitHub source `storytold`/`<package-name>` (tag prefix `v`), provenance `CargoGitTag`, no lock subdirectory, package subdirectory `apps/<package-name>`, and SHALL restrict runtime-lane arches to `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`.

#### Scenario: mise technique

- **WHEN** policy is resolved for `dev-util/mise`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoGitTag` and the source is GitHub `jdx/mise` with tag prefix `v`

#### Scenario: usage not Unsupported

- **WHEN** policy is resolved for `dev-util/usage`
- **THEN** the technique is not `Unsupported`

#### Scenario: biodiff technique

- **WHEN** policy is resolved for `dev-util/biodiff`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoCratesIo` and the source is GitHub `8051enthusiast`/`biodiff` with tag prefix `v`

#### Scenario: codex technique

- **WHEN** policy is resolved for `dev-util/codex`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoGitTag`, lock subdirectory `codex-rs`, package subdirectory `codex-rs/cli`, and the source is GitHub `openai/codex` with tag prefix `rust-v`

#### Scenario: photocraft technique

- **WHEN** policy is resolved for `media-gfx/photocraft`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoGitTag`, no lock subdirectory, and package subdirectory `apps/photocraft`
- **AND** the source is GitHub `storytold/photocraft` with tag prefix `v`
- **AND** the runtime-lane allowlist is `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`

#### Scenario: Storytold craft app technique

- **WHEN** policy is resolved for `app-office/deckcraft`, `app-office/designcraft`, `app-office/gridcraft`, `app-office/wordcraft`, `app-text/pdfcraft`, `media-gfx/cadcraft`, `media-gfx/lightcraft`, `media-gfx/vectorcraft`, `media-sound/soundcraft`, `media-video/effectcraft`, or `media-video/filmcraft`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoGitTag`, no lock subdirectory, and package subdirectory `apps/<package-name>`
- **AND** the source is GitHub `storytold/<package-name>` with tag prefix `v`
- **AND** the runtime-lane allowlist is `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`

## ADDED Requirements

### Requirement: Storytold craft donor body survives Cargo rewrite

A Cargo rewrite of a Storytold craft app SHALL preserve `IUSE`, `REQUIRED_USE`, conditional dependencies, `src_compile`, `src_install`, `src_test`, desktop integration, a donor `CRAFT_FONTS_DIR` export, and every `LICENSE` term outside the generated crate-license block.

#### Scenario: USE contract survives a newer PV

- **WHEN** apply rewrites a craft-app donor into a newer numeric PV
- **THEN** the new ebuild still declares the donor `IUSE` and `REQUIRED_USE`, including any per-app flag
- **AND** `src_test` still runs workspace tests excluding `<name>-web` and `xtask`
- **AND** when the donor exported `CRAFT_FONTS_DIR=/usr/share/craft-fonts`, that export remains

#### Scenario: Generated crate block may change

- **WHEN** the newer tag's lock changes the generated crate-license block
- **THEN** that generated block, `CRATES`, `RUST_MIN_VER`, `KEYWORDS`, and the assets `SRC_URI` are updated
- **AND** `LICENSE` terms outside the generated block remain

### Requirement: Cargo win7 target_vendor classification

The Cargo tag-floor walk and the source-tree harvest SHALL evaluate `cfg` atoms named `target_vendor` whose value is `win7`. That value SHALL NOT hold for Linux, macOS, BSD, Windows, or wasm. A target table that matches no modeled family because of that atom SHALL be ignored and SHALL NOT make the candidate incomplete. Any other `target_vendor` value SHALL make the candidate incomplete.

#### Scenario: Windows table that excludes win7 is ignored

- **WHEN** the policy package declares `rust-version = "1.91"` and a path crate declaring `1.99` is reachable only through `cfg(all(windows, not(target_vendor = "win7")))`
- **THEN** the candidate is complete
- **AND** the planned tag floor is `1.91.0`

#### Scenario: A table for every non-win7 target stays active

- **WHEN** the policy package declares `rust-version = "1.91"` and a path crate declaring `1.94` is reachable only through `cfg(not(target_vendor = "win7"))`
- **THEN** the planned tag floor is `1.94.0`

#### Scenario: Other target_vendor values stay incomplete

- **WHEN** a target table uses `cfg(target_vendor = "unknown")`
- **THEN** the candidate is incomplete and is not selected as requirement `0.0.0`

### Requirement: Git crate fetch line

When a Cargo rewrite writes an ebuild with empty `CRATES` and a `GIT_CRATES` declaration, the ebuild SHALL contain `SRC_URI+=" ${CARGO_CRATE_URIS}"` after the assets crates tarball line. An ebuild with empty `CRATES` and no `GIT_CRATES` declaration SHALL NOT gain that line.

#### Scenario: Empty CRATES and GIT_CRATES gains the fetch line

- **WHEN** a Cargo rewrite receives an ebuild with empty `CRATES`, a `GIT_CRATES` map, a GitHub source archive line, and an assets crates tarball line, and the ebuild does not contain `CARGO_CRATE_URIS`
- **THEN** the result contains `SRC_URI+=" ${CARGO_CRATE_URIS}"` after the assets crates tarball line
- **AND** the assets crates tarball line remains

#### Scenario: Empty CRATES without GIT_CRATES omits the fetch line

- **WHEN** a Cargo rewrite receives an ebuild with empty `CRATES`, a GitHub source archive line, and an assets crates tarball line, and the ebuild does not declare `GIT_CRATES`
- **THEN** the result does not contain `CARGO_CRATE_URIS`
- **AND** the assets crates tarball line remains
