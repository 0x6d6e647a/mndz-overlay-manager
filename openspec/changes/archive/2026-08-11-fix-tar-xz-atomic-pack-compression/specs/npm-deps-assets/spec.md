## MODIFIED Requirements

### Requirement: Registry-only npm cache tarball

For `DepsAndAssets Npm` full-path materialization of PV, the program SHALL, in the unit directories under the product temporary workspace defined by `temp-workspace` without requiring a git clone of the package source: (1) run `npm pack` for the configured npm package at that version (specifier `{npmPackage}@{pv}`) into the unit work area; (2) populate an `npm-cache/` directory under the unit work area via `npm --cache <npm-cache-path> install` of the produced tarball; (3) create `{pn}-{pv}-deps.tar.xz` under the unit `out/` (or equivalent staged output path for publish) whose top-level entry is `npm-cache/`, using xz compression with environment `XZ_OPT=-T0 -9e` (multi-threaded extreme) when invoking tar, or equivalent extreme multi-thread xz settings; (4) after writing the final deps tarball path, verify that the file is an xz-compressed stream and hard-fail if it is plain tar or otherwise not xz. The program SHALL implement this in-process/Haskell orchestration and SHALL NOT invoke overlay Python helper scripts. Unit temporary trees SHALL follow the `temp-workspace` lifecycle.

#### Scenario: Tarball layout for openspec

- **WHEN** npm cache construction succeeds for PN `openspec` at PV `1.4.2`
- **THEN** the output file is named `openspec-1.4.2-deps.tar.xz` and unpacking yields a top-level `npm-cache` directory

#### Scenario: Scoped registry package

- **WHEN** the npm source package is `@fission-ai/openspec` and PV is `1.4.2`
- **THEN** `npm pack` uses `@fission-ai/openspec@1.4.2` while the deps distfile basename uses PN `openspec`

#### Scenario: Npm deps pack uses extreme multi-thread xz

- **WHEN** the manager packs an npm deps tarball
- **THEN** the pack process uses `XZ_OPT` containing `-T0` and `-9e` (or equivalent extreme multi-thread settings)

#### Scenario: Npm deps pack rejects non-xz body

- **WHEN** the final `{pn}-{pv}-deps.tar.xz` path is not an xz-compressed stream after pack
- **THEN** materialize hard-fails before assets publish treats the file as successful
