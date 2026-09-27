# Spec Delta

## ADDED Requirements

### Requirement: bundled-claude revision of the live PV

The live ebuild for installed PV `0.81.2` SHALL be `claude-agent-acp-0.81.2-r1.ebuild`. The unrevised `claude-agent-acp-0.81.2.ebuild` SHALL NOT remain the live file. `IUSE` SHALL include `bundled-claude` without a default-on `+` prefix. `metadata.xml` SHALL describe `bundled-claude` as installing the Claude CLI bundled in the npm package.

#### Scenario: Revision path

- **WHEN** the harness flag is published
- **THEN** the live ebuild path is `dev-util/claude-agent-acp/claude-agent-acp-0.81.2-r1.ebuild`
- **AND** `claude-agent-acp-0.81.2.ebuild` is not a live ebuild

#### Scenario: Flag defaults off

- **WHEN** the ebuild `IUSE` is inspected
- **THEN** `bundled-claude` is present and is not prefixed with `+`

## MODIFIED Requirements

### Requirement: Installed command name

`src_install` SHALL install `/usr/bin/claude-agent-acp` via an offline global npm install from the deps cache into `${ED}/usr`. This package's installed image SHALL NOT contain `/usr/bin/claude` or `/opt/bin/claude`.

When `bundled-claude` is disabled, that install SHALL pass `--omit=optional`, SHALL replace the npm bin with a wrapper that exports `CLAUDE_CODE_EXECUTABLE=/opt/bin/claude` when the variable is unset and then executes the adapter entrypoint, and the ebuild SHALL declare an unversioned `dev-util/claude-code` atom on `RDEPEND` inside `!bundled-claude? ( )`.

When `bundled-claude` is enabled, that install SHALL NOT pass `--omit=optional`, SHALL leave the npm bin in place, and SHALL NOT declare a dependency on `dev-util/claude-code`.

#### Scenario: Bin name

- **WHEN** the package is emerged
- **THEN** `/usr/bin/claude-agent-acp` exists
- **AND** this package's installed image does not contain `/usr/bin/claude`

#### Scenario: Default install uses gentoo Claude Code

- **WHEN** the package is emerged with `bundled-claude` disabled
- **THEN** `/usr/bin/claude-agent-acp` is a wrapper that defaults `CLAUDE_CODE_EXECUTABLE` to `/opt/bin/claude`
- **AND** this package's installed image does not contain `/usr/bin/claude`
- **AND** `RDEPEND` includes `dev-util/claude-code` only in the `!bundled-claude?` group

#### Scenario: Flag on keeps the npm bin

- **WHEN** the package is emerged with `bundled-claude` enabled
- **THEN** `/usr/bin/claude-agent-acp` is the npm-installed bin
- **AND** the ebuild does not depend on `dev-util/claude-code`

### Requirement: Prebuilt Claude CLI is not stripped

The ebuild SHALL set `QA_PREBUILT` so Portage does not strip the nested glibc x86-64 Claude CLI installed by the optional dependency `@anthropic-ai/claude-agent-sdk-linux-x64`. The pattern SHALL cover `usr/lib*/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude`. `QA_PREBUILT` SHALL remain set whether or not `bundled-claude` is enabled.

When `bundled-claude` is enabled, `src_install` SHALL call `dostrip -x` on that installed path and SHALL fail when the ELF is absent. When `bundled-claude` is disabled, `src_install` SHALL succeed without that ELF and SHALL NOT call `dostrip -x` on a missing path.

#### Scenario: QA_PREBUILT pattern

- **WHEN** the ebuild is inspected
- **THEN** `QA_PREBUILT` includes `usr/lib*/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude`

#### Scenario: Flag on requires the ELF

- **WHEN** `bundled-claude` is enabled and the offline install does not place the nested Claude ELF
- **THEN** `src_install` fails

#### Scenario: Flag off allows a missing ELF

- **WHEN** `bundled-claude` is disabled and the offline install omits the nested Claude ELF
- **THEN** `src_install` succeeds

### Requirement: No completions surface

The ebuild SHALL NOT inherit `shell-completion` and SHALL NOT declare bash, zsh, or fish completion USE flags.

#### Scenario: No completion USE flags

- **WHEN** the ebuild is inspected
- **THEN** it does not declare `bash-completion`, `zsh-completion`, or `fish-completion` USE flags
- **AND** it does not inherit `shell-completion`
- **AND** `IUSE` contains `bundled-claude` and `test` and no completion flag

### Requirement: Offline src_test version smoke

The ebuild SHALL include `test` in `IUSE` and set `RESTRICT` to include `!test? ( test )`. `src_test` SHALL install the package into a temporary prefix from the offline deps cache, passing `--omit=optional` when `bundled-claude` is disabled, and SHALL run `claude-agent-acp --version` there. The phase SHALL fail unless that command exits 0 and its stdout is the package PV. The test phase SHALL NOT require network access and SHALL NOT treat `--help` as the smoke command. The version check SHALL pass with `bundled-claude` disabled.

#### Scenario: Offline version smoke

- **WHEN** Portage runs `src_test` with network isolation for a live PV
- **THEN** the phase installs from the deps cache offline
- **AND** `claude-agent-acp --version` exits 0 with stdout equal to that PV

#### Scenario: Default USE omits the optional CLI in src_test

- **WHEN** `src_test` runs with `bundled-claude` disabled
- **THEN** the temporary npm install passes `--omit=optional`
- **AND** `claude-agent-acp --version` still exits 0 with stdout equal to the PV
