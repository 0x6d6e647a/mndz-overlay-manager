# Spec Delta

## MODIFIED Requirements

### Requirement: bundled-codex revision of the live PV

The live ebuild for installed PV `2.1.1` SHALL be `codex-acp-2.1.1-r1.ebuild`. The unrevised `codex-acp-2.1.1.ebuild` SHALL NOT remain the live file. `IUSE` SHALL include `bundled-codex` and `external-codex`, each without a default-on `+` prefix. `REQUIRED_USE` SHALL be `?? ( bundled-codex external-codex )`. `metadata.xml` SHALL describe `bundled-codex` as installing the Codex CLI bundled in the npm package, and SHALL describe `external-codex` as using a Codex executable supplied outside Portage via `CODEX_PATH`.

#### Scenario: Revision path

- **WHEN** the external harness flag is published
- **THEN** the live ebuild path is `dev-util/codex-acp/codex-acp-2.1.1-r1.ebuild`
- **AND** `codex-acp-2.1.1.ebuild` is not a live ebuild

#### Scenario: Flag defaults off

- **WHEN** the ebuild `IUSE` is inspected
- **THEN** `bundled-codex` is present and is not prefixed with `+`
- **AND** `external-codex` is present and is not prefixed with `+`

#### Scenario: At most one harness flag

- **WHEN** the ebuild `REQUIRED_USE` is inspected
- **THEN** it is `?? ( bundled-codex external-codex )`

#### Scenario: Both harness flags are rejected

- **WHEN** the package is emerged with `bundled-codex` and `external-codex` both enabled
- **THEN** Portage rejects the USE combination

### Requirement: Installed command name

`src_install` SHALL install `/usr/bin/codex-acp` via an offline global npm install from the deps cache into `${ED}/usr`. The installed image SHALL NOT contain `/usr/bin/codex`.

When `bundled-codex` and `external-codex` are both disabled, that install SHALL pass `--omit=optional`, SHALL replace the npm bin with a wrapper that exports `CODEX_PATH=/usr/bin/codex` when the variable is unset and then executes the adapter entrypoint, and the ebuild SHALL declare an unversioned `dev-util/codex` atom on `RDEPEND` inside `!bundled-codex? ( !external-codex? ( dev-util/codex ) )`.

When `bundled-codex` is enabled, that install SHALL NOT pass `--omit=optional`, SHALL leave the npm bin in place, and SHALL NOT declare a dependency on `dev-util/codex`.

When `external-codex` is enabled, that install SHALL pass `--omit=optional`, SHALL leave the npm bin in place, SHALL NOT install a wrapper, SHALL NOT export `CODEX_PATH`, and SHALL NOT declare a dependency on `dev-util/codex`. The installed image SHALL NOT contain the nested Codex CLI.

#### Scenario: Bin name

- **WHEN** the package is emerged
- **THEN** `/usr/bin/codex-acp` exists
- **AND** this package's installed image does not contain `/usr/bin/codex`

#### Scenario: Default install uses the system Codex

- **WHEN** the package is emerged with `bundled-codex` and `external-codex` both disabled
- **THEN** `/usr/bin/codex-acp` is a wrapper that defaults `CODEX_PATH` to `/usr/bin/codex`
- **AND** the installed image does not contain `/usr/bin/codex` from this package
- **AND** `RDEPEND` includes `dev-util/codex` only inside `!bundled-codex? ( !external-codex? ( dev-util/codex ) )`

#### Scenario: Flag on keeps the npm bin

- **WHEN** the package is emerged with `bundled-codex` enabled
- **THEN** `/usr/bin/codex-acp` is the npm-installed bin
- **AND** the ebuild does not depend on `dev-util/codex`

#### Scenario: External flag keeps the npm bin and drops the harness

- **WHEN** the package is emerged with `external-codex` enabled and `bundled-codex` disabled
- **THEN** `/usr/bin/codex-acp` is the npm-installed bin
- **AND** that bin does not export `CODEX_PATH`
- **AND** the installed image does not contain the nested Codex CLI
- **AND** the ebuild does not depend on `dev-util/codex`

### Requirement: No completions surface

The ebuild SHALL NOT inherit `shell-completion` and SHALL NOT declare bash, zsh, or fish completion USE flags.

#### Scenario: No completion USE flags

- **WHEN** the ebuild is inspected
- **THEN** it does not declare `bash-completion`, `zsh-completion`, or `fish-completion` USE flags
- **AND** it does not inherit `shell-completion`
- **AND** `IUSE` contains `bundled-codex`, `external-codex`, and `test` and no completion flag

### Requirement: Offline src_test version smoke

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT` to include `!test? ( test )`. `src_test` SHALL install the package into a temporary prefix from the offline deps cache, passing `--omit=optional` when `bundled-codex` is disabled, and SHALL run `codex-acp --version` there. The phase SHALL fail unless that command exits 0 and its stdout is `@agentclientprotocol/codex-acp` followed by a space and the package PV. The test phase SHALL NOT require network access and SHALL NOT treat `--help` or `-v` as the smoke command. The version check SHALL pass with `bundled-codex` disabled, and SHALL pass with `external-codex` enabled and `CODEX_PATH` unset.

#### Scenario: Offline version smoke

- **WHEN** Portage runs `src_test` with network isolation for a live PV
- **THEN** the phase installs from the deps cache offline
- **AND** `codex-acp --version` exits 0 with stdout `@agentclientprotocol/codex-acp` plus that PV

#### Scenario: Default USE omits the optional CLI in src_test

- **WHEN** `src_test` runs with `bundled-codex` disabled
- **THEN** the temporary npm install passes `--omit=optional`
- **AND** `codex-acp --version` still exits 0 with the expected stdout

#### Scenario: External USE omits the optional CLI in src_test

- **WHEN** `src_test` runs with `external-codex` enabled, `bundled-codex` disabled, and `CODEX_PATH` unset
- **THEN** the temporary npm install passes `--omit=optional`
- **AND** `codex-acp --version` exits 0 with stdout `@agentclientprotocol/codex-acp` plus the PV
