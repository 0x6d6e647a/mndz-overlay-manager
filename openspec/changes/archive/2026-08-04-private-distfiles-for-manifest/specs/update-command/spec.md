## ADDED Requirements

### Requirement: Update preflight requires usable manager distfiles directory

Before any package mutation, `update` SHALL resolve the effective manager distfiles path (CLI `--distfiles-path`, else config `distfiles-path`, else the default XDG cache path defined by `manager-distfiles`), ensure the directory exists, and verify that the process can create a file in that directory and rename it to another name in the same directory (modeling Portage atomic distfile placement). If ensure or probe fails, the program SHALL log an error that names the distfiles path and explains that a sticky or non-writable DISTDIR prevents safe `ebuild … manifest` fetches, and SHALL exit with status `1` without applying package updates. Commands that do not run `ebuild … manifest` SHALL NOT be required to run this probe.

#### Scenario: Probe failure blocks update before mutation

- **WHEN** the user runs `update` and the effective distfiles directory cannot support create-then-rename (for example sticky directory with foreign-owned names, or not writable)
- **THEN** the program logs an error naming the distfiles path and exits with status `1` before renaming ebuilds, regenerating Manifests, publishing assets, or creating commits

#### Scenario: Successful probe allows package work

- **WHEN** the user runs `update` against a valid overlay with tools present and the distfiles probe succeeds
- **THEN** the program proceeds to per-package update work using that distfiles path for manifests
