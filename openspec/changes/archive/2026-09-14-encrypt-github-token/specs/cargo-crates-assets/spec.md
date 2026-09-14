## MODIFIED Requirements

### Requirement: Manager-owned SRC_URI for cargo

After pycargoebuild inplace update on full path (or on content repair), the program SHALL rewrite the ebuild `SRC_URI` to the provenance-appropriate primary source line plus the assets-repository crates tarball URL for `{pn}-${PV}-crates.tar.xz` (`https://github.com/{owner}/{repo}/releases/download/` using `{owner}/{repo}` from `assets-path` `origin`), and SHALL NOT rely on `${CARGO_CRATE_URIS}` as the **registry** dependency distfile source for steady-state tarball-shaped ebuilds. Provenance `CargoGitTag`: the primary source line is the upstream GitHub source archive for the tag. Provenance `CargoCratesIo`: the primary source line is the canonical crates.io download distfile for the policy crate name and PV, `https://crates.io/api/v1/crates/<crate>/<pv>/download -> <p>.crate`.

The program SHALL treat `${CARGO_CRATE_URIS}` as list-era registry URIs **only when `CRATES` is non-empty**. When `CRATES` is empty, the rewrite SHALL preserve `GIT_CRATES` URI expansion (`${CARGO_CRATE_URIS}` as used for git crates) and SHALL preserve extra `SRC_URI` lines that are neither the GitHub/crates.io primary source nor the crates tarball (including rusty_v8 snapshot and Chromium GCS clang/rust-toolchain distfiles). The program SHALL NOT collapse those ebuilds to a two-line github-archive-plus-crates form.

#### Scenario: Assets crates URL present

- **WHEN** the manager rewrites SRC_URI for `dev-util/hk` at PV `1.50.0`
- **THEN** SRC_URI references `hk-1.50.0-crates.tar.xz` under the origin assets-repo release for `hk-1.50.0`
- **AND** the primary source line is the upstream GitHub source archive

#### Scenario: CratesIo source distfile form

- **WHEN** the manager rewrites SRC_URI for `dev-util/biodiff` at any PV
- **THEN** the primary source line is `https://crates.io/api/v1/crates/biodiff/${PV}/download -> biodiff-${PV}.crate`
- **AND** the secondary line references `biodiff-${PV}-crates.tar.xz` under the origin assets-repo release for `biodiff-${PV}`

#### Scenario: Empty CRATES keeps GIT_CRATES and V8 extras

- **WHEN** the manager rewrites SRC_URI for `dev-util/codex` whose ebuild has empty `CRATES`, a `GIT_CRATES` map, `${CARGO_CRATE_URIS}`, a rusty_v8 snapshot line, and Chromium GCS clang/rust-toolchain lines
- **THEN** `GIT_CRATES` URIs and the extra V8/clang/rust-toolchain lines remain
- **AND** SRC_URI is not reduced to only the GitHub archive plus `{pn}-${PV}-crates.tar.xz`

#### Scenario: Crates URL uses origin owner and repo

- **WHEN** `assets-path` `origin` is `https://github.com/alice/overlay-assets.git` and the program writes a crates assets `SRC_URI`
- **THEN** the URL host path is `github.com/alice/overlay-assets/releases/download/`
