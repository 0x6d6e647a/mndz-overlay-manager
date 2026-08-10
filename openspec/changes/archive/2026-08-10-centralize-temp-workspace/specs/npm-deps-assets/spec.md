## MODIFIED Requirements

### Requirement: Registry-only npm cache tarball

For `DepsAndAssets Npm` full-path materialization of PV, the program SHALL, in the unit directories under the product temporary workspace defined by `temp-workspace` without requiring a git clone of the package source: (1) run `npm pack` for the configured npm package at that version (specifier `{npmPackage}@{pv}`) into the unit work area; (2) populate an `npm-cache/` directory under the unit work area via `npm --cache <npm-cache-path> install` of the produced tarball; (3) create `{pn}-{pv}-deps.tar.xz` under the unit `out/` (or equivalent staged output path for publish) whose top-level entry is `npm-cache/`, using xz compression suitable for large artifacts (including multi-threaded xz settings equivalent to `XZ_OPT=-T0 -9` when invoking tar). The program SHALL implement this in-process/Haskell orchestration and SHALL NOT invoke overlay Python helper scripts. Unit temporary trees SHALL follow the `temp-workspace` lifecycle.

#### Scenario: Tarball layout for openspec

- **WHEN** npm cache construction succeeds for PN `openspec` at PV `1.4.2`
- **THEN** the output file is named `openspec-1.4.2-deps.tar.xz` and unpacking yields a top-level `npm-cache` directory

#### Scenario: Scoped registry package

- **WHEN** the npm source package is `@fission-ai/openspec` and PV is `1.4.2`
- **THEN** `npm pack` uses `@fission-ai/openspec@1.4.2` while the deps distfile basename uses PN `openspec`
