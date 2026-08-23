## MODIFIED Requirements

### Requirement: README documents Docker full-path materialize and config mode

`README.md` SHALL document at operator depth:

1. That `update` of DepsAndAssets packages that need **full-path** materialize requires `docker` on `PATH` and a product Gentoo materialize image (host CPU architecture), and does not require host `go` / `npm` / `bun` / `sbcl` / `pycargoebuild` for that path.
2. That reuse of existing assets releases does not require Docker or those language tools.
3. That GPG-signed commits, SSH `git push`, GitHub token, `ebuild` / `egencache`, and overlay/assets worktrees stay on the host.
4. That `update` **ensures** the default materialize image when full-path work needs it (generate and `docker build` if the current image does not satisfy those floors); that GitMv/reuse may proceed while ensure runs; that Bun in the image comes from overlay `dev-lang/bun-bin::mndz`; that metadata lives under the XDG cache `…/mndz/overlay-manager/materialize/` (`image.json`); that `MNDZ_MATERIALIZE_IMAGE` uses an existing tag and is not built or deleted by the CLI; that a manual `docker build` of an in-repo Dockerfile is **not** a required prerequisite of `update`; that the git tree SHALL NOT ship `docker/materialize/` (recipe or pointer) as operator documentation; that ensure’s generated recipe uses an official Gentoo `stage3` glibc OpenRC flavor for the host CPU architecture; and that a host architecture with no such official flavor hard-fails ensure (no host language-toolchain fallback).
5. That work commands warn when the overlay-manager TOML is not mode `0600`, without changing token resolution.

#### Scenario: Operator finds Docker in the runtime table

- **WHEN** an operator reads `README.md` runtime requirements
- **THEN** the documentation lists `docker` for full-path `update` of vendor/deps/crates packages and does not claim host `go`/`npm`/`bun` are required for that path

#### Scenario: Operator finds config mode warning

- **WHEN** an operator reads `README.md` configuration documentation
- **THEN** the documentation states that a config file not mode `0600` produces a warning

#### Scenario: Operator finds auto-ensure not a manual docker build recipe

- **WHEN** an operator reads `README.md` materialize image documentation
- **THEN** the text describes `update` ensuring the image for full-path work
- **AND** it does not present a manual `docker build -f docker/materialize/Dockerfile` as the required setup step before `update`

#### Scenario: Operator does not find an in-repo materialize recipe directory

- **WHEN** an operator inspects the repository for a materialize Docker recipe
- **THEN** there is no `docker/materialize/` directory (Dockerfile or pointer README)
- **AND** `README.md` is the operator documentation for image ensure

#### Scenario: Operator finds OpenRC stage3 and unsupported-arch hard-fail

- **WHEN** an operator reads `README.md` materialize image documentation
- **THEN** the text states that ensure uses an official Gentoo OpenRC stage3 for the host CPU architecture
- **AND** that a host architecture without such an image hard-fails (host `go`/`npm`/`bun` are not used instead)
