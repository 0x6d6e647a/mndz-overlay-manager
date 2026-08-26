## MODIFIED Requirements

### Requirement: Container identity and bind-mount ownership

The materialize container SHALL use a generic home directory `HOME=/home/builder` (or an equivalent non-operator path that is not the host user’s home). Language tools inside the container SHALL NOT read the operator’s `~/.npmrc`, `~/quicklisp`, or other host-home config unless those paths are explicitly bind-mounted (they SHALL NOT be). Unit `work/` and `out/` SHALL be bind-mounted at the **same absolute paths** the host allocated. Files the container writes under those mounts SHALL be owned by the operator’s numeric uid and gid (`docker` `--user` matching the host user on the **session**, not by a fixed image uid such as 1000). Forced session environment (`HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `npm_config_nodedir=/usr`, `npm_config_python=/usr/bin/python3`, `PYTHON=/usr/bin/python3`) SHALL be set when the session is created so every exec inherits it. The session SHALL NOT set `npm_config_offline`. Per-command working directory and extra environment from the language builder SHALL be passed on that exec. Host secrets (`GITHUB_TOKEN`, GPG, SSH agent) SHALL NOT be passed into the session, as already required by host-keeps-publish.

#### Scenario: Operator home is not visible

- **WHEN** full-path npm materialize runs
- **THEN** `npm` inside the container does not load `/home/<operator>/.npmrc`

#### Scenario: Output owned by operator

- **WHEN** the container writes `{pn}-{pv}-vendor.tar.xz` under the unit `out/`
- **THEN** that file is owned by the same uid/gid as the host CLI process

#### Scenario: node-gyp sees image Node headers

- **WHEN** full-path Bun materialize runs `bun install` in the container
- **THEN** the session environment includes `npm_config_nodedir=/usr`
- **AND** it includes `npm_config_python=/usr/bin/python3`
- **AND** it does not set `npm_config_offline`
