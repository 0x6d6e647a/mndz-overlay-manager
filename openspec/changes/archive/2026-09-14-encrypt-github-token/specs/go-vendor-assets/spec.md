## MODIFIED Requirements

### Requirement: Preserve non-assets companion SRC_URI on Go rewrite

When rewriting a Go package ebuild for assets parameterization, BDEPEND alignment, KEYWORDS, or PV filename update, the program SHALL preserve non-assets `SRC_URI` entries that do not use the assets-repository release download marker (`{repo}/releases/download/` for `{owner}/{repo}` from `assets-path` `origin`). This includes USE-conditional blocks such as a fixed jemalloc upstream tarball. The program SHALL NOT drop, freeze-rewrite, or re-home those companion URIs when parameterizing vendor assets URLs to `${PV}`.

#### Scenario: jemalloc companion survives parameterization

- **WHEN** the template ebuild contains a vendor assets URL with a frozen version and a `jemalloc? ( https://github.com/jemalloc/jemalloc/releases/download/5.3.0/jemalloc-5.3.0.tar.bz2 )` (or equivalent) companion URI
- **THEN** after Go assets parameterization the companion jemalloc URI is still present unchanged
- **AND** the vendor assets URL uses `${PV}` in the assets-repo path

#### Scenario: Only assets URL is parameterized

- **WHEN** the ebuild has both a GitHub source archive URI and an assets vendor URI and a jemalloc companion URI
- **THEN** parameterization changes only the assets vendor URI components that encode the package version under the assets repository

### Requirement: Assets SRC_URI uses full path with ${PV}

When rewriting or writing a Go package ebuild’s vendor assets `SRC_URI`, the program SHALL produce a URL of the form:

`https://github.com/{owner}/{repo}/releases/download/{pn}-${PV}/{pn}-${PV}-vendor.tar.xz`

where `{owner}` and `{repo}` are parsed from `assets-path` `origin` as specified by `assets-publish`. Both the release tag path segment and the asset filename SHALL use the literal Portage variable `${PV}` (not a frozen version digit string). When Portage expands `${PV}` for package version `2.1.11` and package name `dolt`, the fetch URL SHALL be:

`https://github.com/{owner}/{repo}/releases/download/dolt-2.1.11/dolt-2.1.11-vendor.tar.xz`

Rewriting frozen versions to `${PV}` SHALL preserve the `{repo}/releases/download/` path segment for that origin repo. The program SHALL NOT produce bare host paths such as `https://github.com/{owner}/{pn}-${PV}/…` that omit the assets repository and release download prefix. Non-Go ecosystems use their own distfile suffixes (`-deps.tar.xz`, `-crates.tar.xz`) as specified by `deps-assets` and the ecosystem capabilities; this requirement covers Go vendor SRC_URI form.

#### Scenario: Frozen dolt URL becomes fully parameterized

- **WHEN** the ebuild contains  
  `…/{repo}/releases/download/dolt-2.1.6/dolt-2.1.6-vendor.tar.xz` for the origin `{repo}`
- **THEN** after parameterization it contains  
  `…/{repo}/releases/download/dolt-${PV}/dolt-${PV}-vendor.tar.xz`
- **AND** it still contains the substring `{repo}/releases/download/`

#### Scenario: Already parameterized beads URL is unchanged

- **WHEN** the ebuild already contains  
  `…/{repo}/releases/download/beads-${PV}/beads-${PV}-vendor.tar.xz` for the origin `{repo}`
- **THEN** parameterization leaves that full assets download path and `${PV}` form intact

#### Scenario: Written URL uses origin owner and repo

- **WHEN** `assets-path` `origin` is `git@github.com:alice/overlay-assets.git` and the program writes a Go vendor assets `SRC_URI`
- **THEN** the URL host path is `github.com/alice/overlay-assets/releases/download/`
