## Context

See `proposal.md` for motivation. Today:

- `Update.Preflight.cargoFetcherTools = ["wget", "aria2c", "aria2"]` and hard-fail if **all** are missing when `apNeedCargo` (P1: any cargo package needs work).
- pycargoebuild 0.16 invokes only **`aria2c`** or **`wget`** (`-F` logical name `aria2` ≠ PATH binary `aria2`).
- Language preflight runs after classify in `runUpdatePhases`; full vs reuse is already known.
- Soft warnings exist for disk Portage DISTDIR: `DiskGateOk [Text]` → `usrWarnings`, logged in `Main` after the spine via `logWarning`. There is no cargo fetcher advisory.

## Goals / Non-Goals

**Goals:**

- Align hard fetcher PATH probe with pycargoebuild (`wget` | `aria2c`).
- Soft-advise before long full-path cargo fetches when only wget is available.
- Surface the tip early (warn log at detection) and in the same collected-warnings channel as disk advisories.
- Keep comments and operator docs accurate (P1 hard vs full-path soft).

**Non-Goals:**

- Changing when P1 hard-requires pycargoebuild/fetcher (still any cargo needs work).
- Hard-requiring aria2/aria2c.
- Changing pycargoebuild CLI flags or packing.
- A general “optional tools” framework beyond this advisory.

## Decisions

### 1. Hard fetcher list = `wget` and `aria2c` only

**Choice:** `cargoFetcherTools = ["wget", "aria2c"]`. Keep grouped failure token `"wget or aria2c"`.

**Why:** Matches pycargoebuild’s `subprocess` targets. Bare `aria2` on PATH is a false pass today.

**Alternatives:** Keep probing `aria2` for exotic symlinks — rejected; would not make pycargoebuild succeed without `aria2c`.

### 2. Soft advisory condition (option C)

**Choice:** Emit when:

1. Classify has at least one unit with `ecosystemIsCargo` and class ≠ `ReusePath`, and
2. `aria2c` is missing on PATH, and
3. Hard cargo fetcher preflight already passed (so `wget` is present).

**Why:** Matches “pycargoebuild would fetch crates”; avoids noise on reuse-only cargo work.

**Alternatives:** Warn whenever `apNeedCargo` — rejected (reuse-only). Warn only when both wget present and aria2c missing without checking full path — same rejection.

### 3. Advisory text (fixed)

Exact string (single place, shared constant for tests):

```text
pycargoebuild is using wget; install aria2 for faster crate fetches
```

Package name `aria2` (Gentoo `net-misc/aria2`); no optional “provides aria2c” parenthetical.

### 4. Dual surface: immediate warn log + `usrWarnings`

**Choice:**

1. At language-preflight time (after hard tools succeed), if advisory applies: log via the spine’s progress logger (`ProgressConfig` / Colog `logWarning`) so operators see it **before** mutate.
2. Append the same text to the warnings list that becomes `usrWarnings` (alongside disk gate warnings). `Main` already `mapM_ logWarning` on `usrWarnings` at spine end — acceptable double log of the same line (once early, once in end-of-run batch) **or** spine may include it only in `usrWarnings` **and** log immediately while still returning it for any consumer of `UpdateSpineResult`. Prefer: **log once immediately at detection, still put on `usrWarnings` for result completeness**; if end-of-run would duplicate visibly, either accept duplicate or have Main dedupe — prefer **accept one early log + include in `usrWarnings` and let Main log again** only if product already does that for disk (disk is end-only). **Prefer:** log early at detection **and** put on `usrWarnings`; Main continues to log all `usrWarnings` (may re-log). Simpler: **put on `usrWarnings` and log early in spine; Main keeps logging usrWarnings** — slight duplicate is OK for a rare advisory, or implement spine so Main-only end log is enough for disk but cargo needs early — then **must** log early in spine with logger from `usdProgress`.

Practical approach:

- Extend preflight helper to return `Either Text [Text]` (hard error | soft advisories), or keep hard `Either Text ()` and a separate pure/IO `cargoFetcherAdvisories findTool classifyResults`.
- Spine after successful language hard preflight: compute advisories, `usingLoggerT` / logger action from `pcLogger` to warn each, then `usrWarnings = diskWarns <> cargoAdvisories`.

**Alternatives:** Only `usrWarnings` (end of run) — fails “clue in before download.” Only log, not `usrWarnings` — fails dual-surface decision.

### 5. Comment accuracy

**Choice:** Document in `Preflight.hs` that:

- `cargoRequiredTools` / fetcher hard check are **P1** (any cargo needs work, including reuse-only).
- Soft aria2 advisory is **full-path cargo only**.

### 6. Docs

**Choice:** README runtime tools already say `wget` or `aria2c` in places; scrub remaining `aria2` PATH-synonym wording; optional short “recommended for full-path cargo” is fine if it fits the existing table without a new section.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Duplicate warn line (early + Main `usrWarnings`) | Accept for rare advisory, or skip Main re-log if already printed — implementer picks simplest path that keeps both surfaces. |
| Classify false full-path then reuse at apply | Same as language tools; advisory is best-effort before mutate. |
| Operators without warn log level | Unlikely: default verbosity starts at Warn. |
| Future pycargoebuild renames binary | Unlikely; comment that probe matches pycargoebuild 0.16. |

## Migration Plan

No data migration. Operators who only had bare `aria2` without `aria2c`/`wget` may newly hard-fail — correct relative to pycargoebuild. Rollback: revert preflight list and advisory.

## Open Questions

None.
