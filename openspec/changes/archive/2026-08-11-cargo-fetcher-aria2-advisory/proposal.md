## Why

Cargo full-path materialize runs `pycargoebuild`, which prefers `aria2c` for parallel crate downloads and falls back to sequential `wget`. Preflight already hard-requires a fetcher, but the PATH probe incorrectly accepts a bare `aria2` binary that pycargoebuild never invokes, and operators with only `wget` get no early signal that installing `aria2` would speed up crate fetches.

## What Changes

- Tighten cargo fetcher hard-check to **`wget` or `aria2c` only** (drop bare `aria2` / `aria` from PATH probes and user-facing requirement text that lists them as executable names).
- When at least one **full-path** cargo unit will materialize and **`aria2c` is not on PATH**, soft-advise: log at warn **and** append to update run warnings (`usrWarnings`) with message  
  `pycargoebuild is using wget; install aria2 for faster crate fetches`.
- Keep hard-fail semantics for missing `pycargoebuild` or missing both `wget` and `aria2c` (P1: any cargo package that needs work).
- Fix comments/docs that conflate P1 hard tools with “full path only.”
- Align specs and README wording so PATH tool names match what pycargoebuild actually runs.

### Non-goals

- Changing pycargoebuild invocation flags, distdir layout, or crate packing.
- Hard-requiring `aria2`/`aria2c` (wget-only remains valid).
- Soft warnings for reuse-only cargo units (no crate fetch).
- Portage `FETCHCOMMAND` / global download config.
- Pinning or vendoring `pycargoebuild` or `aria2`.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `cargo-crates-assets`: Cargo preflight tools — fetcher PATH names are `wget` and `aria2c` only; add soft advisory when full-path cargo materialize will use wget because `aria2c` is absent.
- `update-command`: Conditional preflight wording for cargo fetchers drops `aria2` synonym; soft advisory surfaces on the update spine without hard-fail.
- `project-docs`: Operator runtime docs name `wget` or `aria2c` (not bare `aria2`) and may note `aria2` as recommended for faster cargo full-path fetches.

## Impact

- **Code:** `Update.Preflight` (fetcher list, comments, advisory collection), `Update.Spine` (plumb soft warnings into `usrWarnings` + log), tests in `Test.Preflight` (and spine if needed).
- **Specs/docs:** delta specs above; README runtime tools table if it still implies bare `aria2` as a PATH binary.
- **Behavior:** no exit-status change for wget-only hosts; earlier operator tip before long crate downloads; slightly stricter false-pass removal when only a non-`aria2c` name exists on PATH.
