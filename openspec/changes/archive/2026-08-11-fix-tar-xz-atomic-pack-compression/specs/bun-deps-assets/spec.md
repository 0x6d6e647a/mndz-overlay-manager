## MODIFIED Requirements

### Requirement: Bun cache tarball from GitHub tag

For `DepsAndAssets Bun` full-path materialization of PV for packages that use **BunCache** packaging (including `dev-util/ralph-tui`), the program SHALL: (1) clone the package’s GitHub source into the unit `work/` directory under the product temporary workspace defined by `temp-workspace` and check out the tag formed by the source tag prefix plus that PV; (2) require a `bun.lock` at the repository root and hard-fail if missing; (3) run `bun install --frozen-lockfile --cache-dir <bun-cache-path>` with the cache directory under the unit workspace so the cache can be packaged; (4) create `{pn}-{pv}-deps.tar.xz` under the unit `out/` (or equivalent staged output path for publish) whose top-level entry is `bun-cache/`, using xz compression with environment `XZ_OPT=-T0 -9e` (multi-threaded extreme) when invoking tar, or equivalent extreme multi-thread xz settings; (5) after writing the final deps tarball path, verify that the file is an xz-compressed stream and hard-fail if it is plain tar or otherwise not xz. The program SHALL implement this in Haskell orchestration and SHALL NOT invoke overlay Python helper scripts. Unit temporary trees SHALL follow the `temp-workspace` lifecycle (delete on success or soft-skip; retain on hard-fail with path in the error).

#### Scenario: Tarball layout for ralph-tui

- **WHEN** bun cache construction succeeds for PN `ralph-tui` at PV `0.12.0`
- **THEN** the output file is named `ralph-tui-0.12.0-deps.tar.xz` and unpacking yields a top-level `bun-cache` directory

#### Scenario: Missing lockfile hard-fails

- **WHEN** the checked-out tag has no `bun.lock` at the repository root
- **THEN** materialization hard-fails before assets publish

#### Scenario: Bun deps pack uses extreme multi-thread xz

- **WHEN** the manager packs a BunCache deps tarball
- **THEN** the pack process uses `XZ_OPT` containing `-T0` and `-9e` (or equivalent extreme multi-thread settings)

#### Scenario: Bun deps pack rejects non-xz body

- **WHEN** the final `{pn}-{pv}-deps.tar.xz` path is not an xz-compressed stream after pack
- **THEN** materialize hard-fails before assets publish treats the file as successful

### Requirement: InstallTree packaging for opencode deps distfile

For `dev-util/opencode` full-path materialization of PV, after a successful host Bun gate and clone of the GitHub tag, the program SHALL run `bun install --frozen-lockfile` (network allowed on the manager host) in the clone, then create `{pn}-{pv}-deps.tar.xz` whose members are the **install tree** rooted at the repository root: all `node_modules` directories (and any additional workspace install artifacts required to build with `build.ts --skip-install`) with paths relative to that root. The tarball SHALL NOT be defined solely as a top-level `bun-cache/` directory. Packaging SHALL use xz compression with environment `XZ_OPT=-T0 -9e` (or equivalent extreme multi-thread settings) and SHALL verify the final deps path is an xz-compressed stream (hard-fail if not). Failure of install or packaging SHALL hard-fail the PV before assets publish. The program SHALL still publish models JSON multi-asset rules for opencode.

#### Scenario: Deps basename unchanged

- **WHEN** InstallTree packaging succeeds for PN `opencode` at PV `1.18.5`
- **THEN** the output file is still named `opencode-1.18.5-deps.tar.xz`

#### Scenario: Install tree has node_modules

- **WHEN** the deps tarball is listed after InstallTree packaging for opencode
- **THEN** members include a `node_modules` path under the repository root layout

#### Scenario: Install failure hard-fails

- **WHEN** `bun install` fails during full materialize for opencode
- **THEN** the PV hard-fails without publishing a partial deps release

#### Scenario: InstallTree deps pack uses extreme multi-thread xz

- **WHEN** the manager packs an InstallTree deps tarball for opencode
- **THEN** the pack process uses `XZ_OPT` containing `-T0` and `-9e` (or equivalent extreme multi-thread settings)
