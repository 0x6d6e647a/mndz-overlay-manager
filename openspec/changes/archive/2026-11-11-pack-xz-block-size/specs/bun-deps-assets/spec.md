# Spec Delta

## MODIFIED Requirements

### Requirement: InstallTree packaging for opencode deps distfile

For `dev-util/opencode` full-path materialization of PV, after a successful image Bun gate and clone of the GitHub tag, the program SHALL run `bun install --frozen-lockfile` (network allowed during materialize) in the clone **inside the materialize container**, then create `{pn}-{pv}-deps.tar.xz` whose members are the **install tree** rooted at the repository root: all `node_modules` directories (and any additional workspace install artifacts required to build with `build.ts --skip-install`) with paths relative to that root. The tarball SHALL NOT be defined solely as a top-level `bun-cache/` directory. Packaging SHALL use the hermetic tar/xz rules specified by `hermetic-asset-materialize` (`XZ_OPT` from its pack xz threads requirement) and SHALL verify the final deps path is an xz-compressed stream (hard-fail if not). Failure of install or packaging SHALL hard-fail the PV before assets publish.

#### Scenario: Deps basename unchanged

- **WHEN** InstallTree packaging succeeds for PN `opencode` at PV `2.0.3`
- **THEN** the output file is still named `opencode-2.0.3-deps.tar.xz`

#### Scenario: Install tree has node_modules

- **WHEN** the deps tarball is listed after InstallTree packaging for opencode
- **THEN** members include a `node_modules` path under the repository root layout

#### Scenario: Install failure hard-fails

- **WHEN** `bun install` fails during full materialize for opencode
- **THEN** the PV hard-fails without publishing a partial deps release

#### Scenario: InstallTree deps pack uses extreme multi-thread xz

- **WHEN** the manager packs an InstallTree deps tarball for opencode
- **THEN** the pack process uses `XZ_OPT` containing `-T` equal to the resolved `--jobs` value and `-9e` (hermetic-asset-materialize)
