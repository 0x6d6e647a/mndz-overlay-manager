## ADDED Requirements

### Requirement: Dumped cores relocate Lisp paths to the live share dest

After emerge, recovery and active cores SHALL NOT resolve Autolith or vendored `.qlot` Lisp sources, the private fff helper script, or ASDF compile outputs via Portage `${S}` or `${T}`. Image entry SHALL translate dump-time source-root pathnames to the launcher source-root argument (the share dest). The dumped Lisp SHALL NOT hardcode `/usr/share/autolith`. Debug source namestrings recorded for files compiled from `${S}` SHALL name the corresponding paths under the live share dest. Architecture-specific dests (ELF, `libexec`, cores) SHALL remain under `/usr/$(get_libdir)/autolith`.

#### Scenario: Session start does not use the Portage workdir

- **WHEN** the package is emerged and `FEATURES` does not include `noclean`
- **AND** a user starts Autolith from `PATH` without `--version` or `--help`
- **THEN** the process does not report the private fff helper missing at a path under `/var/tmp/portage`
- **AND** `bin/autolith-search-worker` is resolved under `/usr/share/autolith`

#### Scenario: Lisp dest stays share

- **WHEN** the package is emerged
- **THEN** session-start Lisp source resolution for Autolith uses `/usr/share/autolith`
- **AND** it does not use `/usr/$(get_libdir)/autolith` as the Autolith source-root

### Requirement: Quicklisp local-projects index is user cache

The packaged share `.qlot` tree SHALL remain read-only for an unprivileged user. Quicklisp’s local-projects system index SHALL be written under the user’s XDG cache directory, not under `/usr/share/autolith/.qlot/local-projects`. Dumped cores and `--from-source` SHALL both use that cache directory for the index. Share SHALL NOT be made writable to satisfy Quicklisp.

#### Scenario: Share index is not rewritten

- **WHEN** a user starts packaged Autolith or `autolith --from-source` without write access to `/usr/share/autolith`
- **THEN** the process does not fail because `/usr/share/autolith/.qlot/local-projects/system-index.txt` is not writable

## MODIFIED Requirements

### Requirement: Operator smoke acceptance

After overlay and assets are published, the operator SHALL verify install by emerging `=dev-util/autolith-0.17.2` (or the revised `-rN` atom if used) and confirming both `autolith --version` and a session start that builds the default tool registry. `autolith --version` alone SHALL NOT be treated as proof that the private fff helper or relocated Lisp paths work. Session start SHALL NOT mention `/var/tmp/portage` or a missing fff helper at a Portage workdir.

#### Scenario: smoke commands

- **WHEN** seed publish is complete
- **THEN** emerge of that atom succeeds
- **AND** `autolith --version` exits successfully and reports version 0.17.2
- **AND** starting Autolith without `--version` or `--help` (for example `timeout 5 autolith </dev/null`) does not report a missing fff helper under `/var/tmp/portage`
