## ADDED Requirements

### Requirement: One container session per full-path unit

When `update` full-path materializes a DepsAndAssets unit, the program SHALL use **one** Docker container session for that unit’s language work (clone, ecosystem toolchain, pack to unit `out/`). The session SHALL be created and started before those commands, each language/`git`/`tar`/`pycargoebuild` (and equivalent) invocation SHALL run as `docker exec` into that session (not a new `docker run` per command), and the session SHALL be removed when that unit’s materialize ends (success or hard-fail). Sequential PVs of the same package SHALL use sequential sessions (a new session per unit). Concurrent package jobs under `--jobs` MAY have one live session each. Reuse-path units SHALL NOT start a materialize session. PID 1 in the session MAY be a long-sleep (or equivalent) so exec can attach; the program SHALL NOT use a restart policy that brings the container back after remove.

The session SHALL be named so an operator can identify it while it runs (name containing a product prefix, the run id, category, package, and PV, with `/` replaced so the name is a legal Docker name). The session SHALL carry product labels including a run id and the host CLI process id so leftovers can be swept. After start, the program SHALL wait until the session is running before the first exec, or hard-fail that unit. If session create/start fails, that unit SHALL hard-fail. If an exec fails because the session is not running, that unit SHALL hard-fail; the program SHALL NOT silently open a replacement session for that unit.

At the start of a mutate that will full-path materialize, the program SHALL best-effort remove leftover product-labeled materialize sessions whose recorded CLI pid is not a live overlay-manager process. Sweep SHALL NOT hard-fail the run. Sweep SHALL NOT remove sessions labeled with a still-live overlay-manager pid (another concurrent run). At unit end the program SHALL `docker rm -f` that session (and `--rm` MAY also be set on create). Failed units keep the host unit directory as specified by `temp-workspace`; the program SHALL NOT keep the container after the unit ends solely for debugging.

#### Scenario: Cargo extract uses one session

- **WHEN** full-path materialize runs for a Cargo unit whose lock lists many registry crates
- **THEN** the program starts one materialize container for that unit
- **AND** crate extract `tar` invocations run as `docker exec` into that container
- **AND** the container is removed when that unit’s materialize ends

#### Scenario: Sequential PVs get sequential sessions

- **WHEN** a package job full-path materializes two PVs in order
- **THEN** the second PV does not reuse the first PV’s container
- **AND** at most one of those two sessions is live at a time for that package job

#### Scenario: Session create failure hard-fails the unit

- **WHEN** full-path materialize cannot create or start the unit session
- **THEN** that unit hard-fails
- **AND** the program does not fall back to host language toolchains

#### Scenario: Exec into a dead session hard-fails the unit

- **WHEN** a language command is issued and the unit session is not running
- **THEN** that unit hard-fails
- **AND** the program does not start a new session for the same unit to retry that command

#### Scenario: Named session is visible while the unit runs

- **WHEN** a full-path unit session is running for category `dev-util`, package `mise`, PV `2026.8.12`
- **THEN** `docker ps` lists a container whose name includes `mndz-mat-`, the run id, `dev-util`, `mise`, and `2026.8.12`

#### Scenario: Leftover session from a dead CLI is swept

- **WHEN** mutate starts and a product-labeled materialize container exists whose labeled CLI pid is not a live overlay-manager process
- **THEN** the program removes that container
- **AND** mutate does not hard-fail solely because that leftover existed

#### Scenario: Live concurrent run is not swept

- **WHEN** mutate starts and a product-labeled materialize container exists whose labeled CLI pid is a live overlay-manager process
- **THEN** the program does not remove that container as a leftover

## MODIFIED Requirements

### Requirement: Container identity and bind-mount ownership

The materialize container SHALL use a generic home directory `HOME=/home/builder` (or an equivalent non-operator path that is not the host user’s home). Language tools inside the container SHALL NOT read the operator’s `~/.npmrc`, `~/quicklisp`, or other host-home config unless those paths are explicitly bind-mounted (they SHALL NOT be). Unit `work/` and `out/` SHALL be bind-mounted at the **same absolute paths** the host allocated. Files the container writes under those mounts SHALL be owned by the operator’s numeric uid and gid (`docker` `--user` matching the host user on the **session**, not by a fixed image uid such as 1000). Forced session environment (`HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`) SHALL be set when the session is created so every exec inherits it. Per-command working directory and extra environment from the language builder SHALL be passed on that exec. Host secrets (`GITHUB_TOKEN`, GPG, SSH agent) SHALL NOT be passed into the session, as already required by host-keeps-publish.

#### Scenario: Operator home is not visible

- **WHEN** full-path npm materialize runs
- **THEN** `npm` inside the container does not load `/home/<operator>/.npmrc`

#### Scenario: Output owned by operator

- **WHEN** the container writes `{pn}-{pv}-vendor.tar.xz` under the unit `out/`
- **THEN** that file is owned by the same uid/gid as the host CLI process

### Requirement: Container does not inherit host SBCL_HOME

When full-path materialize runs a language command in the materialize container, the program SHALL NOT pass the host process environment variables `SBCL_HOME` or `SBCL_SOURCE_ROOT` into the container. SBCL inside the container SHALL use the image-configured `SBCL_HOME` when SBCL is present. The program SHALL NOT bind-mount the operator’s `~/quicklisp` to satisfy this.

#### Scenario: Host SBCL_HOME is not forwarded

- **WHEN** full-path materialize execs a command in the unit session and the host environment has `SBCL_HOME` set
- **THEN** the session and that exec do not include `SBCL_HOME` from the host
- **AND** they do not include host `SBCL_SOURCE_ROOT`
