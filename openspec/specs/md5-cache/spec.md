# md5-cache Specification

## Purpose

Portage md5-dict cache consistency checks, `egencache` orchestration (including repositories-configuration injection), layout.conf gate, `gencache` command behavior, and rules for co-committing cache paths with apply units.

## Requirements

### Requirement: md5-dict cache only

The program SHALL generate and validate only the Portage **md5-dict** cache format stored under `metadata/md5-cache/` relative to the overlay root. The program SHALL NOT write the deprecated `pms` format under `metadata/cache/`, and SHALL NOT generate `pkg_desc_index`, `use.local.desc`, or `timestamp.chk` as part of this capability.

#### Scenario: Cache files land under md5-cache

- **WHEN** the program successfully regenerates cache for a package
- **THEN** cache entries are written under `metadata/md5-cache/` in the effective overlay root
- **AND** the program does not create `metadata/cache/` solely for this capability

### Requirement: layout.conf cache-formats gate

Before any `egencache` invocation or md5-cache consistency gate that assumes distributed md5-dict cache, the program SHALL verify that the overlay’s `metadata/layout.conf` lists `md5-dict` among its `cache-formats` values (whitespace-separated tokens, case-insensitive token match). If `md5-dict` is absent, the program SHALL log an error directing the operator to add `cache-formats = md5-dict` (or include `md5-dict` in an existing `cache-formats` line) and commit that change, and SHALL hard-fail without running `egencache` or applying package updates that require cache work. The program SHALL NOT automatically edit `layout.conf`.

#### Scenario: Missing md5-dict in layout.conf fails

- **WHEN** `layout.conf` has no `cache-formats` line or the line does not include `md5-dict`
- **THEN** `gencache` and `update` hard-fail with an error naming `cache-formats` / `md5-dict`
- **AND** the program does not modify `layout.conf`

#### Scenario: Explicit md5-dict allows work

- **WHEN** `layout.conf` contains `cache-formats = md5-dict`
- **THEN** the layout gate passes for cache work

### Requirement: Cache consistency definition

For a package `category/package`, the program SHALL treat cache as **complete and matching** only when every non-live ebuild file `category/package/package-<ver>.ebuild` has a corresponding file `metadata/md5-cache/category/package-<ver>` whose `_md5_` field equals the MD5 hex digest of that ebuild file’s contents. Live ebuilds whose version is `9999` SHALL be ignored for this consistency check. **Missing** means no cache file for a required ebuild. **Mismatch** means the cache file exists but `_md5_` does not equal the ebuild MD5.

#### Scenario: Matching _md5_ is consistent

- **WHEN** ebuild `dev-util/crush/crush-0.82.0.ebuild` exists and `metadata/md5-cache/dev-util/crush-0.82.0` has `_md5_` equal to the ebuild file MD5
- **THEN** that version is treated as matching

#### Scenario: Sibling version missing fails package completeness

- **WHEN** a package has two non-live ebuilds and only one has a matching cache file
- **THEN** the package is not complete and matching

### Requirement: egencache runner and repositories-configuration

Production cache generation SHALL invoke the `egencache` executable on `PATH` with action `--update`, repository name `mndz`, and a `--repositories-configuration` value that defines the `mndz` repository with `location` set to the absolute effective overlay path so writes target that tree regardless of ambient `repos.conf`. When package atoms are specified, they SHALL be `category/package` form. The runner SHALL be injectable for tests. Failure of `egencache` (non-zero exit) SHALL be a hard failure for the calling unit or command.

#### Scenario: Injected location matches overlay-path

- **WHEN** the effective overlay path is `/tmp/work/mndz-overlay` and the program regenerates cache for `dev-util/crush`
- **THEN** the `egencache` invocation includes `--repo mndz` and `--repositories-configuration` that sets `mndz` location to that absolute path
- **AND** includes `--update` with atom `dev-util/crush` (or full-repo update when no atoms apply)

#### Scenario: egencache failure is hard failure

- **WHEN** `egencache` exits non-zero during `gencache` or an `update` unit
- **THEN** the operation is recorded as a hard failure and is not treated as success

### Requirement: gencache subcommand spine

The CLI SHALL provide a `gencache` subcommand that loads configuration, resolves the overlay path, validates the overlay, requires the overlay to be a git work tree, passes layout and tool preflight (`git`, `egencache`, `gpg`), then regenerates md5-cache for selected packages and creates exactly one GPG-signed overlay commit when any cache paths change (or when `--force` caused regeneration that dirties the tree). Hard spine failures SHALL log an error and exit with status `1`. Empty inventory SHALL be an error with exit status `1`.

#### Scenario: Successful full-tree gencache

- **WHEN** the user runs `gencache` against a valid overlay with ebuilds, layout gate passes, tools are present, and generation succeeds
- **THEN** the program regenerates cache for the selection and creates at most one signed overlay commit for cache paths

#### Scenario: Non-git overlay fails gencache

- **WHEN** the overlay path is not a git work tree
- **THEN** `gencache` hard-fails without writing a success commit

### Requirement: gencache package targets

`gencache` SHALL accept zero or more package arguments in the same form as `update` (`category/package` or unambiguous package name). With no arguments, every package that has at least one discovered ebuild SHALL be selected. Explicit targets that cannot be resolved SHALL hard-fail the command (or soft-skip only if consistent with existing update target policy—prefer hard-fail for unknown names). Selected packages are the only packages whose cache is generated in that run.

#### Scenario: No args selects all packages

- **WHEN** the user runs `gencache` with no package arguments
- **THEN** every inventoried package is selected for cache generation

#### Scenario: Explicit package only

- **WHEN** the user runs `gencache dev-util/crush`
- **THEN** only `dev-util/crush` is passed to egencache update (not unrelated packages)

### Requirement: gencache strict missing mismatch and force

Without `--force`, for each selected package: if any required version is **missing** cache, the program SHALL generate cache for that package; if any required version has a **mismatch**, the program SHALL hard-fail with an error recommending `gencache --force` for that package (or the same invocation with `--force`) and SHALL NOT overwrite mismatched entries; if all versions **match**, the program SHALL skip regeneration for that package. With `--force`, the program SHALL regenerate cache for every selected package regardless of missing, match, or mismatch. After processing, if the worktree has cache path changes relative to HEAD, the program SHALL stage only paths under `metadata/md5-cache/` (for the run’s effects) and create one signed commit with a message that identifies md5-cache regeneration (for example `metadata: regenerate md5-cache`). If nothing changed, the program SHALL NOT create an empty commit.

#### Scenario: Mismatch without force errors

- **WHEN** `dev-util/crush` has an `_md5_` mismatch and the user runs `gencache dev-util/crush` without `--force`
- **THEN** the program hard-fails with a message recommending `--force`
- **AND** does not leave a successful signed commit that overwrote the mismatch as success without force

#### Scenario: Force regenerates mismatch

- **WHEN** the user runs `gencache --force dev-util/crush` and the package had a mismatch
- **THEN** the program runs egencache for that package and may create a signed commit including updated cache paths

#### Scenario: Missing without force generates

- **WHEN** a package has no md5-cache entries and the user runs `gencache` for that package without `--force`
- **THEN** the program generates cache for that package (bootstrap)

#### Scenario: All match without force no empty commit

- **WHEN** every selected package already matches and the user runs `gencache` without `--force`
- **THEN** the program does not create an empty git commit

### Requirement: gencache preflight tools

Before cache mutation, `gencache` SHALL verify that `git`, `egencache`, and `gpg` are available on `PATH`. Missing tools SHALL log an error naming them and exit with status `1`. Signing SHALL NOT be optional for the gencache commit path.

#### Scenario: Missing egencache on gencache

- **WHEN** the user runs `gencache` and `egencache` is not on `PATH`
- **THEN** the program exits with status `1` before generation

### Requirement: Update unit requires complete matching cache

Before mutating an `update` apply unit for a package, after policy/outdated selection has chosen that package for work, the program SHALL verify that package’s non-live ebuilds are complete and matching per the consistency definition. If any version is **missing** cache, the unit SHALL hard-fail without mutating and the error SHALL recommend running `gencache category/package` to bootstrap. If any version has a **mismatch**, the unit SHALL hard-fail without mutating and the error SHALL recommend running `gencache --force category/package`. Soft-skipped packages that are not applied SHALL NOT require this gate.

#### Scenario: Missing cache blocks update unit

- **WHEN** `dev-lang/deno-bin` needs a version bump but has no md5-cache entry for its ebuild
- **THEN** the update unit hard-fails before rename
- **AND** the error mentions `gencache` for that package

#### Scenario: Mismatch blocks update unit

- **WHEN** a package’s ebuild `_md5_` does not match the cache file and the package is selected for update
- **THEN** the unit hard-fails before mutation
- **AND** the error mentions `gencache --force`

### Requirement: Update unit regenerates and co-commits cache

After a successful `ebuild … manifest` (or equivalent manifest step) for an apply unit and before the unit’s signed overlay commit, the program SHALL run package-scoped `egencache --update category/package` against the effective overlay. The unit’s staged paths SHALL include the ebuild/Manifest paths required by the technique **and** the affected `metadata/md5-cache/` paths for that package (adds, updates, and deletions). Success SHALL mean the signed commit includes those cache paths together with the ebuild changes for that unit. The same regeneration and path inclusion SHALL apply to prune units after obsolete ebuilds are removed and Manifest is updated.

#### Scenario: GitMv commit includes cache paths

- **WHEN** a GitMv unit renames an ebuild, regenerates Manifest, and regenerates md5-cache successfully
- **THEN** the signed commit stages the ebuild path changes, `Manifest`, and the package’s updated md5-cache paths

#### Scenario: Go PV unit co-commits cache

- **WHEN** a Go planned PV unit materializes successfully
- **THEN** package-scoped egencache runs after manifest and before that PV’s signed commit
- **AND** that commit includes the md5-cache paths for the package

#### Scenario: Prune commit includes cache cleanup

- **WHEN** prune removes obsolete ebuilds and regenerates Manifest and md5-cache
- **THEN** the prune signed commit includes ebuild deletions, Manifest, and md5-cache path updates/deletions

### Requirement: Update egencache under overlay lock

On `update`, package-scoped `egencache` for a unit SHALL run inside the same overlay critical section as that unit’s `git add` / signed `git commit` (serialized with other overlay index mutations). The program SHALL NOT run concurrent `egencache` invocations for different packages outside that lock as part of this change.

#### Scenario: egencache serialized with commit

- **WHEN** two packages finish manifest concurrently and both need overlay commits
- **THEN** each package’s egencache and git commit pair still runs under mutual exclusion of the overlay critical section
