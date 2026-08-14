## Context

See proposal.md for motivation. `Update.TempWorkspace.formatRunId` today is:

```text
formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Ez" zt <> "-" <> show pid <> "." <> rand
```

Example: `2026-08-10T15:42:07-07:00-4242.a8f3`. Bun (and any POSIX `PATH` walk) splits that directory on `:`. Isolated `node_modules/.bin` then cannot be found. `test/Test/TempWorkspace.hs` hardcodes the extended example. README uses a `<run-id>` placeholder only.

## Goals / Non-Goals

**Goals:**

- On-disk run ids contain no `:`
- Keep local timezone, seconds, numeric offset, pid, and 4-hex suffix
- Use ISO 8601 basic (the standard compact form), not an ad-hoc strip or `:` → `-`
- Spec, tests, and README example agree

**Non-Goals:**

- Dual pretty-print formatter for logs
- Migrating old colon-named residual trees
- Rejecting `TMPDIR` values that contain `:`
- Bun, ebuild, or install-script policy changes

## Decisions

### D1: ISO 8601 basic, not “delete colons” or `:` → `-`

**Choice:** `formatTime` with `%Y%m%dT%H%M%S%z`, then the existing `-<pid>.<hex>`:

```text
20260810T154207-0700-4242.a8f3
```

`%z` is numeric `±HHMM` (no colon). `%Ez` is the colon offset that caused the 127.

**Alternatives considered:**

- Strip `:` from the current string → `2026-08-10T154207-0700-…` (works, not a named convention)
- Replace `:` with `-` → `2026-08-10T15-42-07-07-00-…` (common in logs; offset looks like a date)
- Escape `:` in `PATH` → not possible on POSIX (bash/`execvp`/`which` all split on `:`)

### D2: One formatter; retain messages print the path

**Choice:** Do not add a pretty extended-ISO printer. Hard-fail already includes the absolute unit path; that path becomes basic automatically.

**Alternatives considered:** Keep extended ISO in logs only. Extra API, easy to accidentally reuse for the directory.

### D3: No migration of old units

**Choice:** Leave existing `$TMPDIR/mndz/overlay-manager/*T*:*:*` trees. Cleanup walks directories; nothing parses run-id syntax.

**Alternatives considered:** Detect and rename leftovers (unnecessary risk; operators may still be inspecting them).

### D4: Do not validate `TMPDIR`

**Choice:** We own only the run-id segment. If an operator sets `TMPDIR` to a path with `:`, that remains their problem.

## Risks / Trade-offs

- **[Risk]** Operators grep for the old `T15:42:07` shape → **Mitigation:** README example; retain paths are still unique and timestamp-sortable (`YYYYMMDDThhmmss`).
- **[Risk]** `%z` locale/platform oddities → **Mitigation:** `defaultTimeLocale`; unit test asserts no `:` and a `T` plus `pid.hex` suffix (existing `testRunIdFormat` plus a no-colon assertion).
- **[Trade-off]** Basic ids are slightly harder to read than extended ISO. Worth it so lifecycle `PATH` works.

## Migration Plan

1. Land `formatRunId` + spec/docs/tests.
2. New `update` runs create basic-named roots only.
3. Rollback is reverting `formatRunId`; old and new trees can coexist under `mndz/overlay-manager/`.
4. No data migration.
