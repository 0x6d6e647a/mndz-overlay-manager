# Spec Delta

## ADDED Requirements

### Requirement: Crate staging checks every registry crate before extracting

Before extracting any crate, manager crates pack SHALL check every lock-listed registry crate against the temporary distdir. When one or more are absent, pack SHALL hard-fail without extracting any crate, and SHALL report every absent crate in lock order as specified by the crate staging failure summary and crate staging failure transcript file requirements.

#### Scenario: Missing crates stop pack before extraction

- **WHEN** `Cargo.lock` lists registry crates `a-1.0.0`, `b-2.0.0`, and `c-3.0.0`, and `a-1.0.0.crate` and `c-3.0.0.crate` are absent from the distdir
- **THEN** pack hard-fails
- **AND** no crate is extracted into the stage tree
- **AND** the failure reports both `a-1.0.0.crate` and `c-3.0.0.crate`, with `a-1.0.0.crate` first

#### Scenario: All crates present proceeds to extraction

- **WHEN** every lock-listed registry crate is present in the distdir
- **THEN** pack proceeds to extract the crates

### Requirement: Crate staging uses one builder invocation

Manager crates pack SHALL extract all lock-listed registry crates through a single builder process invocation, which runs in the materialize container on the full path. That invocation SHALL run at most the resolved `--jobs` value of crate extracts concurrently, and SHALL attempt every crate even when some fail.

#### Scenario: Many crates, one invocation

- **WHEN** pack stages 890 registry crates
- **THEN** exactly one builder process invocation performs crate extraction

#### Scenario: Concurrency follows jobs

- **WHEN** pack stages crates with resolved `--jobs` value `4`
- **THEN** the extraction invocation runs at most 4 crate extracts at once

#### Scenario: A failing crate does not stop the others

- **WHEN** the second of five lock-listed crates fails to extract
- **THEN** the other four crates are still extracted

### Requirement: Crate staging reports every extract failure in lock order

When any crate fails to stage, pack SHALL hard-fail and SHALL report every failing crate in `Cargo.lock` order, whatever order the extracts finished in. A crate fails to stage when its extract exits non-zero, or when it exits zero but no `cargo_home/gentoo/{name}-{version}/` directory exists afterward.

#### Scenario: Failures listed in lock order

- **WHEN** lock-listed crates `a-1.0.0`, `b-2.0.0`, and `c-3.0.0` are staged, and `c-3.0.0` fails to extract before `a-1.0.0` fails to extract
- **THEN** pack hard-fails
- **AND** the reported failures list `a-1.0.0.crate` before `c-3.0.0.crate`

#### Scenario: Missing crate directory counts as a failure

- **WHEN** the extract of `b-2.0.0.crate` exits zero but `cargo_home/gentoo/b-2.0.0/` does not exist afterward
- **THEN** pack hard-fails and reports `b-2.0.0.crate` as a staging failure

### Requirement: Crate staging failure summary

A crate staging hard-fail message SHALL begin with `cargo crates pack failed:`. It SHALL state the number of failing crates and SHALL name the first failing crate in lock order. For an extract failure it SHALL include the first line of that crate's extract error output. It SHALL name `crate-staging.log` in the unit directory, including that unit directory's absolute path.

#### Scenario: Extract failures summarized

- **WHEN** two crates fail to extract, the first in lock order being `a-1.0.0.crate` with extract error output whose first line is `gzip: stdin: not in gzip format`
- **THEN** the message begins with `cargo crates pack failed:`
- **AND** the message states 2 failing crates
- **AND** the message names `a-1.0.0.crate` and includes `gzip: stdin: not in gzip format`
- **AND** the message names `crate-staging.log` and the unit directory's absolute path

#### Scenario: Missing crates summarized

- **WHEN** three registry crates are absent from the distdir, the first in lock order being `a-1.0.0.crate`
- **THEN** the message begins with `cargo crates pack failed:`
- **AND** the message states 3 missing crates and names `a-1.0.0.crate`
- **AND** the message names `crate-staging.log` in the unit directory

### Requirement: Crate staging failure transcript file

On a crate staging hard-fail the program SHALL write `crate-staging.log` in the unit directory. It SHALL list every failing crate in lock order with its crate filename, the failure kind (missing, extract, or no directory), and, for an extract failure, its full extract error output. A successful pack SHALL leave no such file. When the log cannot be written, the hard-fail message SHALL say so.

#### Scenario: Log lists every failure

- **WHEN** crates `a-1.0.0` and `c-3.0.0` fail to extract and `b-2.0.0` produces no crate directory
- **THEN** `crate-staging.log` in the unit directory lists `a-1.0.0.crate`, `b-2.0.0.crate`, and `c-3.0.0.crate` in that order, each with its failure kind
- **AND** each extract failure entry contains that crate's full extract error output

#### Scenario: Log lists every missing crate

- **WHEN** pack hard-fails because `a-1.0.0.crate` and `c-3.0.0.crate` are absent from the distdir
- **THEN** `crate-staging.log` lists both crates as missing, `a-1.0.0.crate` first

#### Scenario: Success leaves no log

- **WHEN** crate staging and pack succeed for a full-path Cargo unit
- **THEN** that unit directory does not contain `crate-staging.log`

#### Scenario: Unwritable log still fails clearly

- **WHEN** a crate fails to extract and `crate-staging.log` cannot be created in the unit directory
- **THEN** the hard-fail message reports that the log was not written
- **AND** the message still names the first failing crate

### Requirement: Crates archive independent of extraction order

The bytes of `{pn}-{pv}-crates.tar.xz` SHALL depend only on the staged crate contents and checksum files, not on the order in which concurrent extracts finished.

#### Scenario: Different completion order, same archive

- **WHEN** the same lock and distdir are packed twice and the crate extracts finish in different orders
- **THEN** both runs produce byte-identical `{pn}-{pv}-crates.tar.xz` files

### Requirement: Crate staging progress line

When activity indicators are enabled and pack stages N registry crates with N at least 1, the package's progress row SHALL show `staging N crates` once, before extraction begins, using `staging 1 crate` when N is 1. Pack SHALL then show `crates pack` when archive creation starts. With no registry crates, no staging status SHALL be shown.

#### Scenario: Many crates

- **WHEN** pack stages 890 registry crates
- **THEN** the progress row shows `staging 890 crates` once, followed by `crates pack`

#### Scenario: One crate

- **WHEN** pack stages a single registry crate
- **THEN** the progress row shows `staging 1 crate`, followed by `crates pack`

#### Scenario: No registry crates

- **WHEN** `Cargo.lock` lists no registry crates with checksums
- **THEN** the progress row shows no staging status before `crates pack`
