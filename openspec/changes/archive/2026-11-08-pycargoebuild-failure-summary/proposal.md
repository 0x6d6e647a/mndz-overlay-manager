# Proposal

## Why

A failed `pycargoebuild` is logged as one message, and the logger stamps `[Error]` on the first line only. On 2026-11-06 that line was a Portage `!!! Section` warning, while aria2's failure sat hundreds of lines later. The operator needs the failure named up front, with the transcript saved beside the retained unit.

## What Changes

- A non-zero `pycargoebuild` on a full-path Cargo unit produces a short hard-fail message: `pycargoebuild failed`, the process exit code, then every captured stdout or stderr line that contains `error` in any letter case, each indented four spaces, stderr lines before stdout lines.
- Captured lines that lack that substring stay out of the message. The full stdout and stderr are written to `pycargoebuild.log` in the unit directory, and the message names that path. The existing retained-unit path stays on the message.
- A successful `pycargoebuild` leaves no such log. If the log cannot be written, the message says so and still omits the unquoted transcript.
- README's temp-workspace lifecycle names that log file for a Cargo hard-fail.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `cargo-crates-assets`: A non-zero `pycargoebuild` hard-fail quotes transcript lines that contain `error`, names `pycargoebuild.log` in the unit directory, and keeps the rest of the transcript in that file.

## Impact

- `src/Update/Cargo/Crates.hs` (`runPycargoebuild`) builds the short `Left` and writes the log on failure. The unit directory is the parent of `work/`, and `distdir` is `work/distdir`.
- `retainUnitError` still appends the unit path. `emitOutcome` stays a single `logError` of that message.
- `test/Test/Ecosystems.hs` gains a scripted-runner case for a Portage warning, aria2 notices, an `[ERROR]` line, and a `CalledProcessError`. Stubs that already return `Left "pycargoebuild failed: …"` stay valid.
- README lifecycle: one clause that a `pycargoebuild` hard-fail leaves `pycargoebuild.log` in the retained unit and names it. `project-docs` already requires that README stay accurate; its requirements do not change.
- `temp-workspace` already requires the unit path in every hard-fail that opened a unit directory. That requirement stays as it is.

## Non-goals

- Parsing aria2's block shape, exit status `19`, or a `Failed to resolve` sentence that lacks the substring `error`.
- Capping how many matching lines are quoted.
- Changing the `pycargoebuild` argv, passing `--license-mapping`, or retrying aria2 and falling through to wget.
- Redesigning `productionCommandRunner`, streaming child stderr, or the `cli-activity` progress hold.
- The materialize image `repos.conf`, the `storytold/egui` git pin, and re-running the filmcraft update.
- Half-applied overlay recovery. This failure happens before overlay write.
- Running `sudo`, `emerge`, or `docker build` as proof of this change.
