## Context

Display versions go through `prettyVersion` in `Overlay.Version`, which currently is `("v" <>) . renderPV`. Call sites are stdout formatters and a few soft-skip / log messages in `app/Main.hs` and `Update.Apply`. Stored form, ebuild names, commit messages, and assets release tags already use `renderPV` / `renderPVNoRev` without a leading `v`. GitHub upstream tags remain a separate concern via `ghTagPrefix` and `versionTag`.

## Goals / Non-Goals

**Goals:**

- Human-facing version strings match Gentoo PV form (`1.2.3`, `1.5.3-r2`).
- Single definition change drives all `prettyVersion` call sites.
- Specs and unit tests that pin display format match the new behavior.
- Quality gate (`hk check`) stays green.

**Non-Goals:**

- Changing `ghTagPrefix`, strip-on-parse, or clone tag construction.
- Renaming ebuilds, assets releases, or commit message formats.
- Migrating `mndz-overlay` or `mndz-overlay-assets`.
- Rewriting archived OpenSpec change history.

## Decisions

### 1. Redefine `prettyVersion` as bare PV (keep the name)

**Choice:** `prettyVersion = renderPV` (or equivalent: stop prepending `"v"`).

**Rationale:** Smallest diff; all existing call sites keep compiling and automatically emit bare PV. Display vs stored form remain the same string today, but the name still marks “for humans / UI.”

**Alternatives considered:**

| Option | Pros | Cons |
|--------|------|------|
| Keep name, drop prefix | Minimal churn | `prettyVersion` ≈ `renderPV` for now |
| Delete `prettyVersion`, use `renderPV` everywhere | One less API | More import/call edits; no hook if display ever diverges again |
| Configurable prefix | Flexible | Unneeded; we want one fixed convention |

Prefer keep-and-redefine; optional follow-up to collapse the API is out of scope.

### 2. Spec deltas only on display contracts

Update `ebuild-version` pretty-render requirement, plus stdout wording in `outdated-command` and `update-command`. Leave `update-source` and `go-vendor-assets` tag examples (`v0.82.0` as upstream tags) unchanged.

### 3. No sibling-repo work

Artifacts written to overlay/assets already omit display `v`. No migration plan for those repos.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Operators or scripts parse stdout for `vN.N.N` | Document as **BREAKING** for CLI consumers in proposal; format remains `category/package LOCAL -> REMOTE` |
| Confusion with GitHub tag `v` | Specs keep tag-prefix language separate from display PV |
| Missed string in a log line hardcoding `v` | Grep for `prettyVersion` / `"v" <>` after change; only definition should own the prefix |

## Migration Plan

1. Land code + tests + main-spec sync via this change’s apply.
2. Operators update any local scripts that require a leading `v` on CLI lines.
3. No rollback of published assets or overlay commits.

## Open Questions

None blocking. Optional later: remove `prettyVersion` entirely if it remains a pure alias of `renderPV`.
