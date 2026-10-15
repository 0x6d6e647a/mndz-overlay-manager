# Spec Delta

## MODIFIED Requirements

### Requirement: Hardcoded cargo packages enabled

The hardcoded policy map SHALL set `DepsAndAssets` with ecosystem `Cargo` for `dev-util/hk`, `dev-util/mise`, and `dev-util/usage` with their existing GitHub sources (`jdx` / respective repos / tag prefix `v`) and provenance `CargoGitTag`, for `dev-util/biodiff` with GitHub source `8051enthusiast`/`biodiff` (tag prefix `v`) and provenance `CargoCratesIo`, and for `dev-util/codex` with GitHub source `openai`/`codex` (tag prefix `rust-v`), lock subdirectory `codex-rs`, package subdirectory `codex-rs/cli`, and provenance `CargoGitTag`. Those packages SHALL NOT remain `Unsupported` solely for cargo CRATES regeneration. Policy for `usage` SHALL use package subdirectory `cli` when required for package metadata. Policy for `codex` SHALL restrict runtime-lane arches to amd64 as specified by `runtime-lanes`. Policy for `media-gfx/photocraft` SHALL use GitHub source `storytold`/`photocraft` (tag prefix `v`), provenance `CargoGitTag`, no lock subdirectory, package subdirectory `apps/photocraft`, and SHALL restrict runtime-lane arches to `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`.
Policy for `app-office/deckcraft`, `app-office/designcraft`, `app-office/gridcraft`, `app-office/wordcraft`, `app-text/pdfcraft`, `media-gfx/cadcraft`, `media-gfx/figcraft`, `media-gfx/lightcraft`, `media-gfx/vectorcraft`, `media-sound/soundcraft`, `media-video/effectcraft`, and `media-video/filmcraft` SHALL each use GitHub source `storytold`/`<package-name>` (tag prefix `v`), provenance `CargoGitTag`, no lock subdirectory, package subdirectory `apps/<package-name>`, and SHALL restrict runtime-lane arches to `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`.

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

- **WHEN** policy is resolved for `app-office/deckcraft`, `app-office/designcraft`, `app-office/gridcraft`, `app-office/wordcraft`, `app-text/pdfcraft`, `media-gfx/cadcraft`, `media-gfx/figcraft`, `media-gfx/lightcraft`, `media-gfx/vectorcraft`, `media-sound/soundcraft`, `media-video/effectcraft`, or `media-video/filmcraft`
- **THEN** the technique is `DepsAndAssets Cargo` with provenance `CargoGitTag`, no lock subdirectory, and package subdirectory `apps/<package-name>`
- **AND** the source is GitHub `storytold/<package-name>` with tag prefix `v`
- **AND** the runtime-lane allowlist is `amd64`, `x86`, `arm`, `arm64`, `ppc64`, `loong`, `riscv`, `sparc`, and `s390`
