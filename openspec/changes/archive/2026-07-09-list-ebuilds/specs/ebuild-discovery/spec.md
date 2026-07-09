## ADDED Requirements

### Requirement: Ebuild type and atom formatting

The library SHALL provide an `Ebuild` value with category, package name, version, and filesystem path fields, and a pure function that formats an `Ebuild` as the atom string `category/package-version`.

#### Scenario: Atom from ebuild fields

- **WHEN** an `Ebuild` has category `app-editors`, package `vim`, and version `9.0.1234`
- **THEN** the atom formatting function returns `app-editors/vim-9.0.1234`

### Requirement: Collect ebuilds via structural category heuristic

The library SHALL provide a discovery function that, given a validated overlay root path, walks the tree and returns all ebuilds found under category/package directories. A top-level directory SHALL be treated as a category if and only if it has at least one immediate child directory that contains one or more files ending in `.ebuild`.

#### Scenario: Non-category top-level directories are skipped

- **WHEN** the overlay root contains `profiles/`, `metadata/`, and `dev-lang/haskell/haskell-9.4.5.ebuild`
- **THEN** discovery yields only the ebuild under `dev-lang`
- **AND** no entries are produced from `profiles` or `metadata`

#### Scenario: Category with multiple package versions

- **WHEN** a package directory contains `haskell-9.4.5.ebuild` and `haskell-9.6.1.ebuild`
- **THEN** discovery returns two ebuilds for that package with the respective versions

### Requirement: Malformed ebuild filenames fail discovery

If any file ending in `.ebuild` is found in a package directory and cannot be parsed as `package-version.ebuild` where the package portion matches the parent directory name, discovery SHALL fail with an error identifying the path.

#### Scenario: Ebuild name missing version

- **WHEN** a package directory contains a file such as `haskell.ebuild` that cannot be split into package and version
- **THEN** discovery returns an error naming that file path

#### Scenario: Package name mismatches parent directory

- **WHEN** a package directory named `haskell` contains `foo-1.0.ebuild`
- **THEN** discovery returns an error naming that file path

### Requirement: Non-ebuild files do not populate inventory

Files in package directories that do not end in `.ebuild` (for example `Manifest`, `metadata.xml`) SHALL be ignored for inventory purposes and SHALL NOT cause discovery to fail.

#### Scenario: Package directory with Manifest

- **WHEN** a package directory contains valid `*.ebuild` files and a `Manifest`
- **THEN** discovery returns only the ebuilds
- **AND** does not report an error for `Manifest`
