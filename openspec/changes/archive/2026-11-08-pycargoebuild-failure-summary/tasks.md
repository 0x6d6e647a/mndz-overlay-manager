# Tasks

## 1. Failure summary

- [x] 1.1 In `runPycargoebuild`, on a non-zero exit write `<unit>/pycargoebuild.log` from the host (unit directory = parent of `work/`, and `distdir` is `work/distdir`) with the exit code and the full stderr then stdout. Return `Left` beginning `pycargoebuild failed (exit N)`, then each captured line containing `error` in any letter case, stderr lines before stdout lines, indented four spaces, then `log: <path>`. On `IOException`, say the log was not written and still omit non-matching lines. Exit zero writes no file. Leave `coPycargoebuild`'s type, `productionCommandRunner`, `emitOutcome`, and `retainUnitError` as they are. Add `pycargoFailureSummary` in `test/Test/Ecosystems.hs` through `mkCargoOps`: a scripted runner whose stderr has a `!!! Section` line, `NOTICE` lines, `[ERROR] CUID#31 - Download aborted.`, a `URI=` line, `Failed to resolve the hostname github.com`, and a `CalledProcessError` with status `19`, with process exit `1`. Assert the `Left` contains exit `1`, the indented `[ERROR]` and `CalledProcessError` lines, and the log path; assert it contains neither `NOTICE`, nor `!!! Section`, nor `Failed to resolve`; assert the log file contains those omitted lines and the quoted lines. Cover a checksum stderr (indented `ChecksumMismatchError`, no `expected:` in the `Left`), a stdout `error` line after a stderr `[ERROR]` line, a stderr of only `materialize session is not running` (no indented quote), exit zero (no log file), and a unit directory that cannot accept the log (message says it was not written, `NOTICE` stays out of the `Left`, restore permissions so the temp directory can be removed). Verify with `just test pycargoFailureSummary`.

- [x] 1.2 In the README temp-workspace lifecycle, state that a `pycargoebuild` hard-fail leaves `pycargoebuild.log` in the retained unit directory and names that path in the error. Verify the lifecycle section contains `pycargoebuild.log` and still says a hard-fail retains the unit and includes its absolute path.

## 2. Gate

- [x] 2.1 Validate with `openspec validate pycargoebuild-failure-summary --type change --strict` and run `just check`. Do not run `sudo`, `emerge`, `docker build`, or a filmcraft `update`.

## Workflow follow-up

- Archive this change after implementation and review. Sync the delta into `openspec/specs/cargo-crates-assets/spec.md` at archive time. Do not edit that living spec by hand before archive.
- `temp-workspace` and `project-docs` stay unchanged. The retained-unit path and the README accuracy rule already cover those surfaces.
