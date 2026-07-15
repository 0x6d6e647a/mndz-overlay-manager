# go-vendor-assets Specification

## Purpose

Go package update technique: vendor tarball build, assets publish, ebuild SRC_URI, and Manifest verification.

## Requirements

### Requirement: GoVendorAndAssets technique

The library SHALL support an update technique `GoVendorAndAssets` that binds a package to an optional `go.mod` subdirectory relative to the upstream repository root (`Nothing` means repository root). Apply logic SHALL use this subdirectory when running Go module download after clone.

#### Scenario: Root go.mod package

- **WHEN** policy for `dev-util/beads` uses `GoVendorAndAssets` with no subdirectory
- **THEN** vendor construction runs in the cloned repository root where `go.mod` is present

#### Scenario: Subdirectory go.mod package

- **WHEN** policy for `dev-db/dolt` uses `GoVendorAndAssets` with subdirectory `go`
- **THEN** vendor construction runs in the `go/` directory of the clone

### Requirement: Hardcoded Go packages use GoVendorAndAssets

The hardcoded policy map SHALL set `GoVendorAndAssets` for `dev-db/dolt` (subdir `go`), `dev-util/beads` (root), and `dev-util/crush` (root), each with their existing GitHub update sources. Those packages SHALL NOT remain `Unsupported` solely for vendor assets.

#### Scenario: dolt technique

- **WHEN** policy is resolved for `dev-db/dolt`
- **THEN** the technique is `GoVendorAndAssets` with go.mod subdirectory `go`

#### Scenario: crush technique

- **WHEN** policy is resolved for `dev-util/crush`
- **THEN** the technique is `GoVendorAndAssets` with go.mod at repository root

### Requirement: Temp clone at release tag

For `GoVendorAndAssets` apply, the program SHALL clone the package’s GitHub source into a system temporary directory, check out the tag formed by the source tag prefix plus the target PV (for example prefix `v` and PV `0.76.0` → tag `v0.76.0`), and remove the temporary clone when the package apply attempt finishes (success or failure). The program SHALL NOT require a pre-existing long-lived checkout of the upstream project.

#### Scenario: Clone uses version tag

- **WHEN** updating `dev-util/crush` to PV `0.77.0` with tag prefix `v`
- **THEN** the clone targets tag `v0.77.0` in a temporary directory

### Requirement: Vendor tarball matches go-module.eclass

From the go.mod directory the program SHALL: (1) populate a `go-mod` directory via `GOMODCACHE` pointing at that directory and `go mod download -modcacherw`; (2) create a tarball named `{pn}-{pv}-vendor.tar.xz` whose top-level entry is `go-mod/`; (3) use xz compression suitable for large artifacts (including multi-threaded xz settings equivalent to `XZ_OPT=-T0 -9` when invoking tar). The tarball filename SHALL use package name PN and PV without a leading `v`.

#### Scenario: Tarball name and layout

- **WHEN** vendor construction succeeds for package name `beads` at PV `1.0.5`
- **THEN** the output file is named `beads-1.0.5-vendor.tar.xz` and unpacking it yields a top-level `go-mod` directory

### Requirement: Assets publish before overlay mutation

For `GoVendorAndAssets`, the program SHALL complete assets-repo checksum commit, assets remote push, and GitHub release asset upload for the vendor tarball **before** renaming or rewriting the overlay ebuild or running `ebuild … manifest`. If assets publish fails, the package SHALL hard-fail and the overlay package tree SHALL NOT be mutated for that attempt.

#### Scenario: Push failure leaves overlay untouched

- **WHEN** assets `git push` fails after a local assets commit
- **THEN** the package is a hard failure and the overlay ebuild is not renamed or rewritten

#### Scenario: Successful publish then overlay apply

- **WHEN** assets commit, push, and release upload succeed
- **THEN** the program proceeds to overlay ebuild update and `ebuild … manifest` for that package

### Requirement: Overlay apply after assets publish

After successful assets publish for a Go package, the program SHALL: ensure the ebuild’s assets `SRC_URI` uses `${PV}` parameterization while preserving the full mndz-overlay-assets download path (see assets SRC_URI requirement); place the ebuild at the target version filename (new PV, or same PV with increased `-rN` when only content/revision bump is required); run `ebuild … manifest` from the package directory so Portage fetches distfiles including the new vendor URL; verify integrity; then include overlay paths in the phase-2 signed commit set using message `category/package: version` (version string without leading `v`, including `-rN` when the filename carries a revision).

#### Scenario: Version bump filename

- **WHEN** local newest is `crush-0.76.0.ebuild` and remote PV is `0.77.0`
- **THEN** the overlay ebuild path becomes `crush-0.77.0.ebuild` with assets SRC_URI using `${PV}`

#### Scenario: Same PV SRC_URI fix bumps revision

- **WHEN** local newest is `dolt-2.1.6.ebuild` with a frozen non-`${PV}` assets URL and remote PV is still `2.1.6`
- **THEN** the program produces `dolt-2.1.6-r1.ebuild` (or higher `-rN` if a revision already exists) with parameterized assets SRC_URI

### Requirement: Assets SRC_URI uses full path with ${PV}

When rewriting or writing a Go package ebuild’s vendor/deps assets `SRC_URI`, the program SHALL produce a URL of the form:

`https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/{pn}-${PV}/{pn}-${PV}-vendor.tar.xz`

(or the equivalent `-deps.tar.xz` suffix for future non-Go techniques). Both the release tag path segment and the asset filename SHALL use the literal Portage variable `${PV}` (not a frozen version digit string). When Portage expands `${PV}` for package version `2.1.11` and package name `dolt`, the fetch URL SHALL be:

`https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/dolt-2.1.11/dolt-2.1.11-vendor.tar.xz`

Rewriting frozen versions to `${PV}` SHALL preserve the `mndz-overlay-assets/releases/download/` path segment. The program SHALL NOT produce bare host paths such as `https://github.com/0x6d6e647a/{pn}-${PV}/…` that omit the assets repository and release download prefix.

#### Scenario: Frozen dolt URL becomes fully parameterized

- **WHEN** the ebuild contains  
  `…/mndz-overlay-assets/releases/download/dolt-2.1.6/dolt-2.1.6-vendor.tar.xz`
- **THEN** after parameterization it contains  
  `…/mndz-overlay-assets/releases/download/dolt-${PV}/dolt-${PV}-vendor.tar.xz`
- **AND** it still contains the substring `mndz-overlay-assets/releases/download/`

#### Scenario: Already parameterized beads URL is unchanged

- **WHEN** the ebuild already contains  
  `…/mndz-overlay-assets/releases/download/beads-${PV}/beads-${PV}-vendor.tar.xz`
- **THEN** parameterization leaves that full assets download path and `${PV}` form intact

### Requirement: Manifest SHA512 matches generated vendor hash

After a successful `ebuild … manifest` for a Go package, the program SHALL parse the package `Manifest` for the vendor distfile `{pn}-{pv}-vendor.tar.xz` and compare its SHA512 digest to the SHA512 computed for the tarball that was published. On mismatch the package SHALL hard-fail and the program SHALL warn that assets may already have been published.

#### Scenario: Matching digests succeed

- **WHEN** Manifest SHA512 for the vendor distfile equals the published tarball’s SHA512
- **THEN** the package apply may proceed to overlay commit success path

#### Scenario: Mismatch hard-fails with assets warning

- **WHEN** Manifest SHA512 differs from the generated tarball SHA512
- **THEN** the package is a hard failure and a warning indicates assets were published while overlay update did not complete successfully

### Requirement: Orphan assets warning on late overlay failure

When assets publish has succeeded and a later overlay step fails (dirty check, ebuild write, `ebuild manifest`, or hash verify), the program SHALL hard-fail the package and emit a warning that the assets repository release may exist without a corresponding completed overlay update.

#### Scenario: Manifest command fails after release

- **WHEN** release upload succeeded and `ebuild … manifest` fails
- **THEN** the program logs an error for the manifest failure and a warning about published assets without completed overlay update
