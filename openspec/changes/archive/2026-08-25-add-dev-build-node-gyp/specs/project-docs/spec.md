## MODIFIED Requirements

### Requirement: README documents Docker full-path materialize and config mode

`README.md` SHALL document at operator depth:

1. That `update` of DepsAndAssets packages that need **full-path** materialize requires `docker` on `PATH` and a product Gentoo materialize image (host CPU architecture), and does not require host `go` / `npm` / `bun` / `sbcl` / `pycargoebuild` for that path.
2. That reuse of existing assets releases does not require Docker or those language tools.
3. That GPG-signed commits, SSH `git push`, GitHub token, `ebuild` / `egencache`, and overlay/assets worktrees stay on the host.
4. That `update` **ensures** the default materialize image when full-path work needs it (generate and `docker build` if the current image does not satisfy those floors); that GitMv/reuse may proceed while ensure runs; that Bun in the image comes from overlay `dev-lang/bun-bin::mndz`; that qlot in the image (when SBCL is installed) comes from overlay `dev-lisp/qlot::mndz` rather than a live Quicklisp installer fetch; that `node-gyp` in the image (when bun or node is installed) comes from overlay `dev-build/node-gyp::mndz`; that metadata lives under the XDG cache `…/mndz/overlay-manager/materialize/` (`image.json`); that `MNDZ_MATERIALIZE_IMAGE` uses an existing tag and is not built or deleted by the CLI; that a manual `docker build` of an in-repo Dockerfile is **not** a required prerequisite of `update`; that the git tree SHALL NOT ship `docker/materialize/` (recipe or pointer) as operator documentation; that ensure’s generated recipe uses an official Gentoo `stage3` glibc OpenRC flavor for the host CPU architecture; and that a host architecture with no such official flavor hard-fails ensure (no host language-toolchain fallback).
5. That work commands warn when the overlay-manager TOML is not mode `0600`, without changing token resolution.
6. That the generated image installs language toolchains via Portage: prefers a Gentoo `-bin` package when one can meet the floor, accepts testing KEYWORDS per atom (`~arch`, `::gentoo` or `::mndz`) when the floor is not stable-visible, does not set whole-image `ACCEPT_KEYWORDS` to `~arch`, and reuses local binpkgs across image rebuilds.

#### Scenario: Operator finds Docker in the runtime table

- **WHEN** an operator reads `README.md` runtime requirements
- **THEN** the documentation lists `docker` for full-path `update` of vendor/deps/crates packages and does not claim host `go`/`npm`/`bun` are required for that path
- **AND** the image tool list names overlay qlot (not a wget of Quicklisp) when describing SBCL/Autolith materialize tools
- **AND** the image tool list names overlay `node-gyp` when describing Bun or npm materialize tools

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

#### Scenario: Operator finds Portage -bin and per-atom testing keywords

- **WHEN** an operator reads `README.md` materialize image documentation
- **THEN** the text states that toolchains come from Portage `-bin` when available
- **AND** that testing toolchain versions are accepted per package, not by setting the whole image to `~arch`
- **AND** that image rebuilds reuse locally built binpkgs

### Requirement: README documents overlay dirty preflight and bun-bin-before-ensure

`README.md` SHALL document at operator depth that:

1. `update` hard-fails when selected overlay package directories, or overlay atoms the materialize image will emerge (`dev-lang/bun-bin` when the image installs overlay bun-bin, `dev-lisp/qlot` when the image installs overlay qlot, `dev-build/node-gyp` when the image installs overlay node-gyp), are dirty vs git HEAD (including untracked and deleted ebuilds), and that the operator must restore or finish that tree.
2. Untargeted `update` plans Bun consumers against the selected bun-bin remote when bun-bin needs work, and applies those consumers after bun-bin’s signed overlay commit without a disk re-plan.
3. When the materialize image will emerge overlay bun-bin, `update` regenerates bun-bin Manifest (and package cache) before `docker build`; bun-bin’s signed commit happens after that ensure attempt when ensure ran.
4. When the materialize image will emerge overlay qlot, `update` regenerates qlot Manifest (and package cache) before that `docker build` if qlot needs GitMv work; qlot’s signed overlay commit is not delayed for ensure; Autolith is not withheld on qlot.
5. When the materialize image will emerge overlay node-gyp, `update` regenerates node-gyp Manifest (and package cache) before that `docker build` if node-gyp needs overlay file work; node-gyp’s signed overlay commit is not delayed for ensure; opencode and ralph-tui are not withheld on node-gyp.
6. `update PACKAGE` while bun-bin is unselected still refuses on plan-delta / fail-closed as already specified.

#### Scenario: Operator finds dirty overlay refuse

- **WHEN** an operator reads `README.md` `update` documentation
- **THEN** the text states that a dirty overlay bun-bin, qlot, or node-gyp (when the image will emerge that atom) or selected package dir causes `update` to exit `1` before mutate or image build

#### Scenario: Operator finds bun-bin Manifest before docker

- **WHEN** an operator reads `README.md` materialize / `update` documentation
- **THEN** the text states that overlay bun-bin Manifest regeneration happens before a bun-layer image build
- **AND** it does not claim Bun consumers are re-planned from disk after bun-bin commits in the same run
