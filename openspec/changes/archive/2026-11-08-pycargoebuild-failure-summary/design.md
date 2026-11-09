# Design

## Context

See proposal.md for why the headline is wrong. `runPycargoebuild` in `src/Update/Cargo/Crates.hs` turns any non-zero `ProcessResult` into one `Left` of `pycargoebuild failed:` plus the whole stderr and, when present, the whole stdout. `emitOutcome` logs that string with `logError`. `fmtMessageColored` prefixes the string once, so `[Error]` sticks to line 1.

Full-path Cargo runs that command through `docker exec`. The manager process already holds `prExitCode`, `prStdout`, and `prStderr` when `runPycargoebuild` returns. `pycargoebuild` 0.17.1 and 0.17.2 send aria2's stdout to the child's stderr (`stdout=sys.stderr`). An uncaught `CalledProcessError` makes the Python process exit `1`. Aria2's status `19` is text inside that exception.

`buildCargoCratesTarball` always sets `distDir` to `<workDir>/distdir`, and materialize passes `workDir` as `udWork`, which is `<udPath>/work`. `retainUnitError` appends `retained temp unit: <udPath>` to whatever `Left` the unit returns. The container bind-mounts `work/` and `out/` only, and `docker rm` runs when the unit ends.

## Goals / Non-Goals

**Goals:**

- Build the short `Left` inside `runPycargoebuild` from the captured result.
- Quote every captured line that contains `error` in any letter case, indented four spaces.
- Write the full transcript on the host, into the unit directory, and name that file in the message.
- Leave `coPycargoebuild`'s four-path type, `productionCommandRunner`, and `emitOutcome` as they are.

**Non-Goals:**

- A parser for aria2 blocks, `errorCode=`, or `Failed to resolve`.
- A cap on quoted lines, or reflow so a wrapped quote keeps its indent.
- Preserving stderr that `sessionExecRunner` has already replaced with `materialize session is not running`.
- A new `CargoOps` argument for the unit path.

## Decisions

### Quote by substring, both streams

Split `prStderr` and `prStdout` on newlines. A line matches when its case-folded text contains `error`. Emit stderr matches first, then stdout matches. Indent each match with four spaces. Blank lines and lines without that substring stay out of the message.

The first line of the `Left` is `pycargoebuild failed (exit N)` for `ExitFailure N`. That line is ours, so it stays flush and receives the `[Error]` stamp. The log line is flush too: `log: <absolute path>`.

Alternatives considered: take the first `[ERROR]` line, or the first `CalledProcessError` line, or the last exception header. Each one is a contract with one tool's layout. The substring keeps every line that already says error, including a long `CalledProcessError` argv line, and it leaves a `Failed to resolve` sentence in the file when that sentence lacks the substring.

### Host write next to `work/` and `out/`

On failure, write `<unit>/pycargoebuild.log` from the manager process with `Data.Text.IO`, after `docker exec` has returned. Derive the unit directory as `takeDirectory (takeDirectory distDir)`. The file body is the exit code, then the full stderr, then the full stdout, with a one-line label before each stream so the two captures stay distinguishable. Success returns `Right ()` without creating the file. `deleteUnit` also removes the unit tree on success.

The write stays on the host because `udPath` is not a bind mount. A file created inside the container outside `work/` and `out/` would disappear with `docker rm`.

Alternative considered: add a unit-root argument to `coPycargoebuild`. That touches every test stub for a path the existing `distDir` argument already determines.

### Log-write failure stays short

If creating or writing the log throws `IOException`, the `Left` gains one flush line that the log could not be written, including the path and the IO error. The unquoted transcript is not appended. Quoted `error` lines are still included. Those lines are the part of the transcript the operator still has if the unit directory cannot take the file.

### Retention suffix stays downstream

`runPycargoebuild` does not print the unit path. `retainUnitError` still appends it, so the operator message ends with `retained temp unit: <udPath>` as it does for every other retained unit. The log path is a sibling of `work/` and `out/`, inside that directory.

### Tests drive the real function

`coPycargoebuild` stubs that return `Left "pycargoebuild failed: boom"` never see a transcript and stay as they are. The new case uses `mkCargoOps` with a scripted `CommandRunner`, the same seam as `testCargoMkCommandRunner`: clone succeeds, `pycargoebuild` returns exit `1` and the filmcraft-shaped stderr, and the `Left` is asserted. The work directory is `<unit>/work` so the log lands at `<unit>/pycargoebuild.log`. A second scripted run exits `0` and asserts the log is absent. The pure line split can stay unexported; production calls it, and the test reaches it through `mkCargoOps`.

## Risks / Trade-offs

- [Risk] A multi-file aria2 failure prints one `[ERROR]` line per file, plus a long `CalledProcessError` line. → Mitigation: that volume is the accepted quote. Notices stay in the log. There is no cap.
- [Risk] A terminal wrap of the `CalledProcessError` line returns to column 0, so only the start of the line shows the indent. → Mitigation: accepted. The summarizer does not reflow tool text.
- [Risk] A URL or crate name that contains `error` is quoted too. → Mitigation: accepted. The filter is a substring, not a token parser.
- [Risk] The DNS sentence from the 2026-11-06 run has no `error` substring, so the headline will not show `github.com`. → Mitigation: the log file contains that line, and the message names the file.
- [Risk] `takeDirectory (takeDirectory distDir)` is wrong if a caller passes a `distdir` that is not `<unit>/work/distdir`. → Mitigation: `buildCargoCratesTarball` is the only production caller and always uses that layout. The new test builds the same layout and checks the log path.
- [Risk] A dead materialize session replaces stderr before this code runs, so the log holds only `materialize session is not running`. → Mitigation: left as it is. The message then has no indented quote, which matches the no-substring scenario.
- [Risk] The log write fails and the unquoted transcript exists only in memory. → Mitigation: quoted lines remain on the terminal, and the message says the log was not written. The transcript is not copied into the `[Error]` line.

## Migration Plan

No data migration. The next full-path Cargo failure writes the log and the short message. Units retained by older runs have no `pycargoebuild.log`. Rollback is reverting the change; successful units still delete their directory.
