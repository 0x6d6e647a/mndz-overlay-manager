# Spec Delta

## Purpose

Lets the operator set one CPU and I/O scheduling priority for the manager process and every workload it starts, including work inside Docker containers.

## ADDED Requirements

### Requirement: Priority options

The CLI SHALL accept the global options `--nice N` with N an integer from 0 to 19, `--ionice-class` with value `idle` or `best-effort`, and `--ionice-level N` with N an integer from 0 to 7. Each value SHALL be an absolute target, never an increment on the inherited value.

#### Scenario: Absolute nice target

- **WHEN** the operator runs `update --nice 10` from a shell at nice 5
- **THEN** the manager runs at nice 10, not 15

#### Scenario: Idle I/O class

- **WHEN** the operator runs `smoke --ionice-class idle`
- **THEN** the manager runs in the idle I/O class

### Requirement: Out-of-range priority values are rejected

A `--nice` value outside 0–19 or an `--ionice-level` value outside 0–7 SHALL be a usage error that exits non-zero before any command work. Values SHALL NOT be clamped.

#### Scenario: Nice above range

- **WHEN** the operator runs `--nice 25 update`
- **THEN** the program reports that `--nice` must be between 0 and 19
- **AND** exits non-zero without starting the command

#### Scenario: Negative nice

- **WHEN** the operator runs `--nice -5 update`
- **THEN** the program reports a usage error and exits non-zero

### Requirement: I/O priority option combinations

`--ionice-level` without `--ionice-class` SHALL select the best-effort class at that level. `--ionice-class best-effort` without a level SHALL use the level the kernel derives from the effective nice value. `--ionice-class idle` together with `--ionice-level` SHALL be a usage error. No realtime class SHALL be accepted.

#### Scenario: Level implies best-effort

- **WHEN** the operator runs `--ionice-level 7 update`
- **THEN** the manager runs in the best-effort I/O class at level 7

#### Scenario: Idle with a level

- **WHEN** the operator runs `--ionice-class idle --ionice-level 3 update`
- **THEN** the program reports that idle takes no level and exits non-zero

#### Scenario: Realtime is not offered

- **WHEN** the operator runs `--ionice-class realtime update`
- **THEN** the program reports a usage error and exits non-zero

### Requirement: Priority config keys

The config file SHALL accept the top-level keys `nice` (integer 0–19), `ionice-class` (`"idle"` or `"best-effort"`) and `ionice-level` (integer 0–7). Validation and combination rules SHALL match the options. An invalid value SHALL be a config error that names the key.

#### Scenario: Config sets nice

- **WHEN** the config contains `nice = 10` and the operator runs `update` with no priority options
- **THEN** the manager runs at nice 10

#### Scenario: Invalid config value

- **WHEN** the config contains `nice = 25`
- **THEN** loading the config fails with an error naming `nice`

### Requirement: Command line overrides config priority

A `--nice` option SHALL replace the config `nice` value. Any `--ionice-class` or `--ionice-level` option SHALL replace the entire config I/O priority setting, so the I/O priority is what the command-line options alone describe.

#### Scenario: Nice override

- **WHEN** the config contains `nice = 10` and the operator runs `--nice 15 update`
- **THEN** the manager runs at nice 15

#### Scenario: I/O setting replaced as a unit

- **WHEN** the config contains `ionice-class = "idle"` and the operator runs `--ionice-level 4 update`
- **THEN** the manager runs in the best-effort I/O class at level 4

### Requirement: Unset priority leaves the manager unchanged

When neither an option nor a config key sets the nice value, the manager SHALL keep its inherited nice value. When neither sets the I/O priority, the manager SHALL keep its inherited I/O priority. Because of the floor, `--nice 0` SHALL leave an inherited non-negative nice value unchanged.

#### Scenario: No settings

- **WHEN** the operator runs `nice -n 7 mndz-overlay-manager update` with no priority options or keys
- **THEN** the manager runs at nice 7

#### Scenario: Overriding config back to inherited

- **WHEN** the config contains `nice = 10` and the operator runs `--nice 0 update` from a shell at nice 0
- **THEN** the manager runs at nice 0

### Requirement: Priority targets never raise priority

The effective nice value SHALL be the higher of the target and the inherited value. The effective I/O priority SHALL be the lower of the target and the inherited one. The ranking from highest to lowest is best-effort 0 through best-effort 7, then idle. With no explicit inherited I/O priority, the inherited level is the one the kernel derives from nice.

#### Scenario: Nice floor

- **WHEN** the operator runs `--nice 10 update` from a shell at nice 15
- **THEN** the manager runs at nice 15

#### Scenario: I/O floor

- **WHEN** the operator runs `--ionice-level 4 update` under `ionice -c 3`
- **THEN** the manager stays in the idle I/O class

### Requirement: Floor warning

When the floor keeps an inherited value instead of a target, the manager SHALL log one warning per run for nice and one for I/O priority, naming the inherited and requested values. It SHALL continue the run.

#### Scenario: Warning names both values

- **WHEN** the operator runs `--nice 10 update` from a shell at nice 15
- **THEN** one warning states that the inherited nice 15 is kept instead of the requested 10
- **AND** the update continues

### Requirement: Every manager thread runs at the effective priority

Every command SHALL apply the effective nice and I/O priority to every thread of the manager process before it starts any workload process, so every child process inherits them. Settings from the config SHALL apply once the command has loaded its config.

#### Scenario: All threads updated

- **WHEN** the operator runs `--nice 12 --ionice-class idle update`
- **THEN** every thread of the manager process reports nice 12 and the idle I/O class

#### Scenario: Child processes inherit

- **WHEN** the operator runs `--nice 12 update` and the update runs `git`
- **THEN** that `git` process runs at nice 12

#### Scenario: Supervisors inherit

- **WHEN** an update with `--nice 12` starts its GPG or SSH session supervisor
- **THEN** the supervisor runs at nice 12

### Requirement: Priority failure stops the run

If the manager cannot apply the effective priority to one of its threads, it SHALL report the failure and exit non-zero before starting any workload. A thread that exits while priority is being applied SHALL NOT count as a failure.

#### Scenario: Apply failure

- **WHEN** setting the priority of a live manager thread fails
- **THEN** the run exits non-zero with an error naming the priority setting
- **AND** no workload process is started

### Requirement: Container workloads run at the manager's priority

Each workload command run in a smoke, materialize or Portage tools container SHALL run at the manager's effective nice and I/O priority, including values the manager only inherited. Container setup commands run by the manager itself SHALL NOT be required to.

#### Scenario: Option reaches the emerge

- **WHEN** the operator runs `--nice 15 smoke crush`
- **THEN** the emerge in the smoke container runs at nice 15

#### Scenario: Inherited priority reaches containers

- **WHEN** the operator runs `nice -n 19 ionice -c 3 mndz-overlay-manager update` with no priority options or keys
- **THEN** materialize and Portage tools workload commands run at nice 19 in the idle I/O class

#### Scenario: Floored value reaches containers

- **WHEN** the operator runs `--nice 10 update` from a shell at nice 15
- **THEN** container workload commands run at nice 15

### Requirement: Container floor

When a container workload command starts at a lower priority than the manager's effective priority, the command SHALL keep the lower priority. It SHALL write one line to standard error naming the kept and requested values, and continue.

#### Scenario: Daemon already niced

- **WHEN** the Docker daemon starts container processes at nice 10 and the manager's effective nice is 5
- **THEN** the workload command runs at nice 10
- **AND** its output contains a line naming nice 10 kept instead of 5

### Requirement: Default priority needs no container tools

When the effective nice is 0 and the manager has no explicit I/O priority, container workload commands SHALL run without any priority change, and images SHALL NOT need priority tools.

#### Scenario: Image without priority tools

- **WHEN** an operator-supplied materialize image lacks `ionice` and the run has the default priority
- **THEN** the materialize session runs normally

### Requirement: Missing priority tools fail session setup

When a priority change applies and the container lacks the tools to apply it, session setup SHALL fail with an error naming the missing tool. That session's workload SHALL NOT start.

#### Scenario: Operator image lacks ionice

- **WHEN** the operator runs `--ionice-class idle update` with an `MNDZ_MATERIALIZE_IMAGE` that has no `ionice`
- **THEN** materialize session setup fails with an error naming `ionice`
- **AND** no materialize workload runs in that container

### Requirement: Image builds are unaffected

Priority settings SHALL NOT change smoke or materialize image builds, their recipes, or their build cache eligibility.

#### Scenario: Recipe unchanged

- **WHEN** the operator runs `--nice 19 update` and a materialize image build is needed
- **THEN** the rendered recipe is identical to the one rendered without `--nice`
