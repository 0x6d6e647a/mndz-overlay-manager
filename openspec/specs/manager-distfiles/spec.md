# manager-distfiles Specification

## Purpose

Define the manager’s private Portage distfiles cache: path resolution defaults and overrides, directory mode, preflight usability probe, environment for `ebuild … manifest`, sticky/EPERM operator messaging, and the `eclean` work command that reclaims that cache without touching the system Portage DISTDIR.

## Requirements

### Requirement: Default manager distfiles path follows XDG cache

When neither CLI nor config overrides the distfiles path, the program SHALL resolve the manager distfiles directory to `${XDG_CACHE_HOME}/mndz/overlay-manager/distfiles` when the environment variable `XDG_CACHE_HOME` is set and non-empty, and to `${HOME}/.cache/mndz/overlay-manager/distfiles` when `XDG_CACHE_HOME` is unset or empty. This default SHALL parallel the XDG layout used for the default config file under `…/mndz/overlay-manager.toml`.

#### Scenario: XDG_CACHE_HOME set

- **WHEN** `XDG_CACHE_HOME` is `/tmp/cache` and no distfiles override is set
- **THEN** the resolved manager distfiles path is `/tmp/cache/mndz/overlay-manager/distfiles`

#### Scenario: XDG_CACHE_HOME unset

- **WHEN** `XDG_CACHE_HOME` is unset, `HOME` is `/home/op`, and no distfiles override is set
- **THEN** the resolved manager distfiles path is `/home/op/.cache/mndz/overlay-manager/distfiles`

### Requirement: Distfiles path override order

The program SHALL resolve the effective manager distfiles path in this order: (1) global CLI `--distfiles-path DIR` when provided; (2) else config key `distfiles-path` when set; (3) else the default XDG cache path. The operator MAY deliberately point the path at the system Portage DISTDIR; that choice SHALL NOT by itself be rejected for `update`.

#### Scenario: CLI overrides config and default

- **WHEN** config sets `distfiles-path` to `/cfg/dist` and the user passes `--distfiles-path /cli/dist`
- **THEN** the effective path is `/cli/dist`

#### Scenario: Config overrides default

- **WHEN** config sets `distfiles-path` to `/cfg/dist` and no CLI override is given
- **THEN** the effective path is `/cfg/dist`

### Requirement: Manager distfiles directory mode

When the program creates the manager distfiles directory (because it does not exist), it SHALL create it with mode `0700` (owner read/write/execute only). When the directory already exists, the program SHALL NOT be required to chmod it to `0700` on every use.

#### Scenario: First create uses 0700

- **WHEN** the resolved distfiles path does not exist and the program ensures the directory for `update` or `eclean` setup
- **THEN** the created directory has mode `0700`

### Requirement: Shared distfiles cache across parallel packages

All package units in a single `update` run SHALL share the same effective manager distfiles path. The program SHALL NOT allocate a separate DISTDIR per package solely for isolation.

#### Scenario: Two packages one DISTDIR

- **WHEN** `update` applies two packages that both run `ebuild … manifest`
- **THEN** both invocations use the same effective `DISTDIR` value

### Requirement: Ebuild manifest uses manager DISTDIR and empty GENTOO_MIRRORS

Every Portage `ebuild … manifest` invocation performed by the program SHALL run with an environment that includes `DISTDIR` set to the effective manager distfiles path and `GENTOO_MIRRORS` set to the empty string, merged onto the process environment so that other variables (including agent and `PATH`) remain available. The program SHALL NOT rely on `FEATURES=-mirror` as the mechanism to disable Gentoo mirror URL construction.

#### Scenario: Manifest child sees private DISTDIR

- **WHEN** the program runs `ebuild … manifest` for a package update
- **THEN** that process environment sets `DISTDIR` to the effective manager distfiles path

#### Scenario: Manifest child disables Gentoo mirrors list

- **WHEN** the program runs `ebuild … manifest` for a package update
- **THEN** that process environment sets `GENTOO_MIRRORS` to the empty string

### Requirement: Sticky or EPERM distfiles failures are actionable

When `ebuild … manifest` fails and the captured error text indicates an operation-not-permitted or failed move under distfiles (including Portage atomic `.__download__` rename failures or `.layout.conf` mirror metadata failures), the unit hard-fail message SHALL identify a distfiles ownership or sticky-directory problem, SHALL name the effective DISTDIR in use when known, and SHALL direct the operator toward a user-owned manager distfiles path (default or `distfiles-path` / `--distfiles-path`) rather than an opaque Portage traceback alone.

#### Scenario: EPERM rename maps to guidance

- **WHEN** `ebuild … manifest` fails with stderr containing `Operation not permitted` and a path under distfiles involving `.__download__` or `.layout.conf`
- **THEN** the hard-fail message indicates sticky or ownership problems with DISTDIR and mentions the effective distfiles path or how to configure a private path

### Requirement: eclean work command

The CLI SHALL provide an `eclean` work subcommand that deletes the contents of the effective manager distfiles path (resolved by the same override order as `update`) so the operator can reclaim disk used by manager-driven fetches. The command SHALL load configuration as needed to resolve `distfiles-path` and SHALL NOT require a valid overlay inventory. On success the program SHALL exit with status `0`. If the resolved path does not exist, the command SHALL succeed without error (nothing to clean).

#### Scenario: eclean removes manager cache

- **WHEN** the effective distfiles path exists and contains fetched files and is not the system Portage DISTDIR
- **THEN** `eclean` removes those cache contents and exits `0`

#### Scenario: Missing cache is success

- **WHEN** the effective distfiles path does not exist
- **THEN** `eclean` exits `0` without treating the absence as a hard failure

### Requirement: eclean refuses system Portage DISTDIR

The `eclean` command SHALL refuse to delete when the effective distfiles path is the system Portage DISTDIR. System DISTDIR SHALL include at least `/var/cache/distfiles` after path canonicalization and, when discoverable, the live Portage `DISTDIR` setting. On refuse, the program SHALL log an error, SHALL NOT delete, and SHALL exit with status `1`.

#### Scenario: eclean refuses /var/cache/distfiles

- **WHEN** the user runs `eclean` with `--distfiles-path /var/cache/distfiles` (or equivalent canonical path)
- **THEN** the program logs an error, does not delete the directory, and exits with status `1`

#### Scenario: update may still use system path

- **WHEN** the user sets `distfiles-path` to `/var/cache/distfiles` and runs `update`
- **THEN** the program does not refuse solely because the path is the system DISTDIR (preflight usability still applies)

### Requirement: Manager distfiles free space is a hard feasibility surface for update

The effective manager distfiles path SHALL be included as a hard free-space surface in the `disk-space-preflight` feasibility gate for `update`. Planned `ebuild … manifest` fetches that would place missing distfiles into that path SHALL contribute to estimated need on that filesystem. Distfiles already present under the effective path SHALL NOT require additional free-space reservation for the gate.

#### Scenario: Large missing bin distfiles fail gate when free is low

- **WHEN** `update` will run `ebuild … manifest` for a package whose Manifest (or planned SRC_URI set) implies fetching large missing distfiles into manager distfiles and free space on that path is below the concurrent sum of such needs under `--jobs`
- **THEN** the disk-space feasibility gate hard-fails before package mutation with a message that names the manager distfiles path

#### Scenario: Present distfiles do not inflate need

- **WHEN** all distfiles required for the planned units already exist under the effective manager distfiles path
- **THEN** manager distfiles need for those files is zero for the gate even if the files are large
