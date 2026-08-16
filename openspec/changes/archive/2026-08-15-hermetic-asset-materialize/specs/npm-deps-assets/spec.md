## MODIFIED Requirements

### Requirement: Registry-only npm cache tarball

For `DepsAndAssets Npm` full-path materialization of PV, the program SHALL, in the unit directories under the product temporary workspace defined by `temp-workspace` without requiring a git clone of the package source: (1) run `npm pack` for the configured npm package at that version (specifier `{npmPackage}@{pv}`) into the unit work area; (2) populate an `npm-cache/` directory under the unit work area via `npm --cache <npm-cache-path> install` of the produced tarball using an empty userconfig (not the operator `~/.npmrc`); (3) create `{pn}-{pv}-deps.tar.xz` under the unit `out/` whose top-level entry is `npm-cache/`, omitting `npm-cache/_logs/` and `npm-cache/_update-notifier*` members, packing with the hermetic tar/xz rules specified by `hermetic-asset-materialize`; (4) after writing the final deps tarball path, verify that the file is an xz-compressed stream and hard-fail if it is plain tar or otherwise not xz. Full-path npm pack/install/tar SHALL run in the materialize container. The program SHALL implement this in-process/Haskell orchestration and SHALL NOT invoke overlay Python helper scripts. Unit temporary trees SHALL follow the `temp-workspace` lifecycle.

#### Scenario: Tarball layout for openspec

- **WHEN** npm cache construction succeeds for PN `openspec` at PV `1.4.2`
- **THEN** the output file is named `openspec-1.4.2-deps.tar.xz` and unpacking yields a top-level `npm-cache` directory

#### Scenario: Scoped registry package

- **WHEN** the npm source package is `@fission-ai/openspec` and PV is `1.4.2`
- **THEN** `npm pack` uses `@fission-ai/openspec@1.4.2` while the deps distfile basename uses PN `openspec`

#### Scenario: Npm deps pack uses extreme multi-thread xz

- **WHEN** the manager packs an npm deps tarball
- **THEN** the pack process uses `XZ_OPT` containing `-T1` and `-9e` (single-thread extreme; hermetic-asset-materialize)

#### Scenario: Npm deps pack rejects non-xz body

- **WHEN** the final `{pn}-{pv}-deps.tar.xz` path is not an xz-compressed stream after pack
- **THEN** materialize hard-fails before assets publish treats the file as successful

#### Scenario: Packed cache omits logs

- **WHEN** npm cache construction packs the deps tarball
- **THEN** the archive has no `npm-cache/_logs/` members

### Requirement: Host Node gate on full path

After determining the node requirement for a PV on the full materialize path, the program SHALL compare the materialize-image `node` version to that requirement. If the image is strictly older, the program SHALL hard-fail that PV before `npm pack`/cache population and SHALL NOT publish assets or mutate the overlay for that attempt. The reuse path SHALL NOT apply this gate. The program SHALL NOT require a host `node` binary for this gate.

#### Scenario: Host too old

- **WHEN** engines require `20.19.0` and the materialize image Node is older
- **THEN** full-path materialize hard-fails without publishing assets
