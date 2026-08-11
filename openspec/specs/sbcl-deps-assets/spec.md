# sbcl-deps-assets Specification

## Purpose

SBCL/Autolith-style `DepsAndAssets` materialize (`.qlot/` + vendored fff), distfile naming, `sbcl.version` floor probe, preflight tools, and ebuild SBCL floor atom ownership.

## Requirements

### Requirement: Sbcl ecosystem under DepsAndAssets

The library SHALL support an update technique `DepsAndAssets` with ecosystem `Sbcl` for packages whose language dependency asset is an Autolith-style offline deps tarball and whose runtime floor is declared in upstream `sbcl.version`. Apply logic SHALL dispatch materialization, requirement probes, SBCL dependency atom rendering, and runtime-lane ceiling sources according to this ecosystem.

#### Scenario: Autolith policy uses Sbcl

- **WHEN** policy for `dev-util/autolith` uses `DepsAndAssets` with ecosystem `Sbcl` and GitHub source `luciusmagn/autolith` with tag prefix `v`
- **THEN** planning and apply use the SBCL floor probe, gentoo `dev-lisp/sbcl` ceilings, and deps tarball materialize/reuse path

### Requirement: sbcl.version floor probe

For each candidate package version under `DepsAndAssets Sbcl`, the library SHALL read the raw file `sbcl.version` at the corresponding upstream tag (repository root). The trimmed content SHALL be parsed as a dotted numeric version floor. Unparseable or missing files SHALL make that candidate ineligible for lane selection (not a package-wide hard-fail by themselves when other candidates remain).

#### Scenario: Floor from tag

- **WHEN** tag `v0.18.0` has `sbcl.version` containing `2.6.4`
- **THEN** the requirement floor for that candidate is `2.6.4`

### Requirement: Distfile and release naming

For package name PN and version PV (without revision), the program SHALL name SBCL/Autolith dependency distfiles `{pn}-{pv}-deps.tar.xz`. Release tags SHALL be `{pn}-{pv}`. Names SHALL use the overlay package name (PN).

#### Scenario: autolith deps name

- **WHEN** publishing assets for package `autolith` at PV `0.18.0`
- **THEN** the distfile basename is `autolith-0.18.0-deps.tar.xz` and the release tag is `autolith-0.18.0`

### Requirement: Deps tarball layout contract

Full-path materialize for `DepsAndAssets Sbcl` SHALL produce a tarball whose contents include a top-level `.qlot/` directory suitable for offline Autolith bootstrap and a top-level `fff/` tree at the commit declared by upstream `native/fff/commit` for that tag, including Cargo vendor output sufficient for `cargo build --offline` of the fff C library package used by Autolith.

#### Scenario: Offline fff inputs present

- **WHEN** a full-path materialize completes for a PV
- **THEN** the packed tarball contains `.qlot/` and `fff/` with vendored crates for offline cargo

### Requirement: Materialize and reuse

Full-path materialize SHALL clone the GitHub tag, build the deps layout (network allowed only during materialize on the manager host), pack `{pn}-{pv}-deps.tar.xz`, and publish via the assets-publish path. When a release already provides that asset with matching trusted checksum (reuse), apply SHALL reuse without rematerializing.

#### Scenario: Reuse skips rematerialize

- **WHEN** `autolith-0.18.0-deps.tar.xz` exists on the assets release with matching hash
- **THEN** apply does not rebuild the qlot/fff tree for that unit solely to obtain the asset

### Requirement: SBCL atom on ebuild rewrite

When rewriting a `DepsAndAssets Sbcl` ebuild for a planned PV, the program SHALL ensure the ebuild declares a dependency atom that requires Gentoo `dev-lisp/sbcl` at least as new as the floor from `sbcl.version` for that PV, with subslot rebuild operator and `source` USE as required by the seed template contract (e.g. `>=dev-lisp/sbcl-<floor>:=[source]`). The program SHALL parameterize the deps assets `SRC_URI` with `${PV}`.

#### Scenario: Floor atom for 0.18.0

- **WHEN** apply writes autolith at PV `0.18.0` with floor `2.6.4`
- **THEN** the ebuild depends on SBCL ≥ 2.6.4 with `:=` and `[source]` consistent with the template
- **AND** the deps assets URL uses `${PV}`

### Requirement: Preflight tools for materialize

When a selected `DepsAndAssets Sbcl` package requires full-path materialize, preflight SHALL require the host tools needed to produce the deps tarball (including at least `git`, `sbcl`, and cargo for vendoring, plus any documented qlot/quicklisp bootstrap) in addition to existing update spine tools. Reuse-only paths SHALL NOT require materialize-only tools solely because the package is Sbcl.

#### Scenario: Reuse without cargo

- **WHEN** apply will only reuse an existing deps asset for autolith
- **THEN** preflight does not fail solely due to missing `cargo` for that package

### Requirement: Sbcl materialize uses product temp workspace

Full-path materialize for `DepsAndAssets Sbcl` SHALL perform clone, qlot/fff build stages, and packing under the unit `work/` and `out/` directories of the product temporary workspace defined by `temp-workspace`. Unit temporary trees SHALL follow the `temp-workspace` lifecycle (delete on success or soft-skip; retain on hard-fail with path in the error).

#### Scenario: Full-path sbcl work is under the run root

- **WHEN** full-path materialize runs for a `DepsAndAssets Sbcl` package PV
- **THEN** heavy temporary clone and stage directories for that unit are nested under the product run root unit tree rather than only as free-floating directories in the effective temp root

### Requirement: Sbcl deps tarball xz compression and verification

When full-path materialize for `DepsAndAssets Sbcl` packs `{pn}-{pv}-deps.tar.xz`, the program SHALL compress with environment `XZ_OPT=-T0 -9e` (multi-threaded extreme xz, or equivalent extreme multi-thread settings) when invoking tar, and SHALL verify that the final deps path is an xz-compressed stream. If the final file is plain tar or otherwise not xz, pack SHALL hard-fail before assets publish treats the file as successful.

#### Scenario: Sbcl deps pack uses extreme multi-thread xz

- **WHEN** the manager packs an Sbcl/Autolith deps tarball
- **THEN** the pack process uses `XZ_OPT` containing `-T0` and `-9e` (or equivalent extreme multi-thread settings)

#### Scenario: Sbcl deps pack rejects non-xz body

- **WHEN** the final `{pn}-{pv}-deps.tar.xz` path is not an xz-compressed stream after pack
- **THEN** materialize hard-fails before assets publish treats the file as successful
