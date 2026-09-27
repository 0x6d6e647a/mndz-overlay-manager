# Spec Delta

## ADDED Requirements

### Requirement: bundled-codex revision of the live PV

The live ebuild for installed PV `1.13.1` SHALL be `codex-acp-1.13.1-r1.ebuild`. The unrevised `codex-acp-1.13.1.ebuild` SHALL NOT remain the live file. `IUSE` SHALL include `bundled-codex` without a default-on `+` prefix. `metadata.xml` SHALL describe `bundled-codex` as installing the Codex CLI bundled in the npm package.

#### Scenario: Revision path

- **WHEN** the harness flag is published
- **THEN** the live ebuild path is `dev-util/codex-acp/codex-acp-1.13.1-r1.ebuild`
- **AND** `codex-acp-1.13.1.ebuild` is not a live ebuild

#### Scenario: Flag defaults off

- **WHEN** the ebuild `IUSE` is inspected
- **THEN** `bundled-codex` is present and is not prefixed with `+`

## MODIFIED Requirements

### Requirement: Installed command name

`src_install` SHALL install `/usr/bin/codex-acp` via an offline global npm install from the deps cache into `${ED}/usr`. The installed image SHALL NOT contain `/usr/bin/codex`.

When `bundled-codex` is disabled, that install SHALL pass `--omit=optional`, SHALL replace the npm bin with a wrapper that exports `CODEX_PATH=/usr/bin/codex` when the variable is unset and then executes the adapter entrypoint, and the ebuild SHALL declare an unversioned `dev-util/codex` atom on `RDEPEND` inside `!bundled-codex? ( )`.

When `bundled-codex` is enabled, that install SHALL NOT pass `--omit=optional`, SHALL leave the npm bin in place, and SHALL NOT declare a dependency on `dev-util/codex`.

#### Scenario: Bin name

- **WHEN** the package is emerged
- **THEN** `/usr/bin/codex-acp` exists
- **AND** this package's installed image does not contain `/usr/bin/codex`

#### Scenario: Default install uses the system Codex

- **WHEN** the package is emerged with `bundled-codex` disabled
- **THEN** `/usr/bin/codex-acp` is a wrapper that defaults `CODEX_PATH` to `/usr/bin/codex`
- **AND** the installed image does not contain `/usr/bin/codex` from this package
- **AND** `RDEPEND` includes `dev-util/codex` only in the `!bundled-codex?` group

#### Scenario: Flag on keeps the npm bin

- **WHEN** the package is emerged with `bundled-codex` enabled
- **THEN** `/usr/bin/codex-acp` is the npm-installed bin
- **AND** the ebuild does not depend on `dev-util/codex`

### Requirement: Prebuilt Codex CLI is not stripped

The ebuild SHALL set `QA_PREBUILT` on the nested prebuilt Codex ELF from the linux-x64 optional package of `@openai/codex`. The pattern SHALL match that ELF under `usr/lib*/node_modules/@agentclientprotocol/codex-acp/node_modules/` and SHALL NOT embed a Codex version. `QA_PREBUILT` SHALL remain set whether or not `bundled-codex` is enabled.

When `bundled-codex` is enabled, `src_install` SHALL call `dostrip -x` on that installed path and SHALL fail when the ELF is absent. When `bundled-codex` is disabled, `src_install` SHALL succeed without that ELF and SHALL NOT call `dostrip -x` on a missing path.

#### Scenario: QA_PREBUILT pattern

- **WHEN** the ebuild is inspected
- **THEN** `QA_PREBUILT` names the nested Codex ELF under `usr/lib*/node_modules/@agentclientprotocol/codex-acp/node_modules/`

#### Scenario: Missing ELF fails install

- **WHEN** `bundled-codex` is enabled and the offline install does not place the nested Codex ELF
- **THEN** `src_install` fails

#### Scenario: Flag on requires the ELF

- **WHEN** `bundled-codex` is enabled and the offline install does not place the nested Codex ELF
- **THEN** `src_install` fails

#### Scenario: Flag off allows a missing ELF

- **WHEN** `bundled-codex` is disabled and the offline install omits the nested Codex ELF
- **THEN** `src_install` succeeds

### Requirement: No completions surface

The ebuild SHALL NOT inherit `shell-completion` and SHALL NOT declare bash, zsh, or fish completion USE flags.

#### Scenario: No completion USE flags

- **WHEN** the ebuild is inspected
- **THEN** it does not declare `bash-completion`, `zsh-completion`, or `fish-completion` USE flags
- **AND** it does not inherit `shell-completion`
- **AND** `IUSE` contains `bundled-codex` and `test` and no completion flag

### Requirement: Offline src_test version smoke

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT` to include `!test? ( test )`. `src_test` SHALL install the package into a temporary prefix from the offline deps cache, passing `--omit=optional` when `bundled-codex` is disabled, and SHALL run `codex-acp --version` there. The phase SHALL fail unless that command exits 0 and its stdout is `@agentclientprotocol/codex-acp` followed by a space and the package PV. The test phase SHALL NOT require network access and SHALL NOT treat `--help` or `-v` as the smoke command. The version check SHALL pass with `bundled-codex` disabled.

#### Scenario: Offline version smoke

- **WHEN** Portage runs `src_test` with network isolation for a live PV
- **THEN** the phase installs from the deps cache offline
- **AND** `codex-acp --version` exits 0 with stdout `@agentclientprotocol/codex-acp` plus that PV

#### Scenario: Default USE omits the optional CLI in src_test

- **WHEN** `src_test` runs with `bundled-codex` disabled
- **THEN** the temporary npm install passes `--omit=optional`
- **AND** `codex-acp --version` still exits 0 with the expected stdout
