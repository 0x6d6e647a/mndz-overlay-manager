# Spec Delta

## ADDED Requirements

### Requirement: pycargoebuild failure summary
When `pycargoebuild` exits non-zero on a full-path Cargo unit, the hard-fail message SHALL begin with `pycargoebuild failed` and the process exit code. Each captured stdout or stderr line that contains `error` in any letter case SHALL follow, stderr lines before stdout lines, indented four spaces. The message SHALL name `pycargoebuild.log` in that unit directory. Captured lines that lack that substring SHALL be absent from the message.

#### Scenario: Download failure quotes error lines
- **WHEN** full-path Cargo materialize runs `pycargoebuild` and the process exits `1`, and stderr contains, in order, a `!!! Section` line, aria2 `NOTICE` lines, `[ERROR] CUID#31 - Download aborted.`, a `URI=` line, `Failed to resolve the hostname github.com, cause: Temporary failure in name resolution`, and a `CalledProcessError` line that reports status `19`
- **THEN** the hard-fail message begins with `pycargoebuild failed` and exit code `1`
- **AND** the `[ERROR]` line and the `CalledProcessError` line appear in the message, each indented four spaces, with the `[ERROR]` line first
- **AND** the message names `pycargoebuild.log` in the unit directory and includes that unit directory's absolute path
- **AND** the message contains neither `NOTICE`, nor `!!! Section`, nor `Failed to resolve`

#### Scenario: Checksum failure quotes the exception line
- **WHEN** `pycargoebuild` exits non-zero and stderr is aria2 `NOTICE` lines, then `ChecksumMismatchError: Checksum mismatch for /work/distdir/serde-1.0.200.crate`, then a `current:` line, then an `expected:` line
- **THEN** the message includes that `ChecksumMismatchError` line indented four spaces
- **AND** the message contains neither `NOTICE`, nor `current:`, nor `expected:`

#### Scenario: Stdout matches follow stderr matches
- **WHEN** `pycargoebuild` exits non-zero, stderr contains `[ERROR] Download aborted.`, and stdout contains `tool error on stdout`
- **THEN** the indented `[ERROR]` line appears before the indented stdout line

#### Scenario: No error substring leaves no quote
- **WHEN** `pycargoebuild` exits non-zero and the captured output is only `materialize session is not running`
- **THEN** the message begins with `pycargoebuild failed` and the process exit code
- **AND** the message contains no four-space indented transcript line
- **AND** the message names `pycargoebuild.log` in the unit directory

### Requirement: pycargoebuild failure transcript file
On that non-zero exit the program SHALL write `pycargoebuild.log` in the unit directory with the full stdout and stderr. A successful `pycargoebuild` SHALL leave no such file. When the log cannot be written, the hard-fail message SHALL say so and SHALL still omit captured lines that lack the `error` substring.

#### Scenario: Log keeps lines the message omits
- **WHEN** `pycargoebuild` exits non-zero and stderr contains a `NOTICE` line, a `Failed to resolve the hostname github.com` line, and a `CalledProcessError` line
- **THEN** `pycargoebuild.log` in the unit directory contains all three lines

#### Scenario: Success leaves no log
- **WHEN** `pycargoebuild` exits zero for a full-path Cargo unit
- **THEN** that unit directory does not contain `pycargoebuild.log`

#### Scenario: Unwritable log stays a short message
- **WHEN** `pycargoebuild` exits non-zero, stderr contains a `NOTICE` line and an `[ERROR]` line, and `pycargoebuild.log` cannot be created in the unit directory
- **THEN** the hard-fail message reports that the log was not written
- **AND** the `[ERROR]` line appears indented four spaces
- **AND** the message does not contain the `NOTICE` line
