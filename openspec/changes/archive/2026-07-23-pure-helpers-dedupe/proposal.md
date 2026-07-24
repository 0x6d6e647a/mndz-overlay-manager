## Why

The same pure helpers are reimplemented across Apply, Check, Deps.Plan, Go.Plan, and several HTTP clients (`renderPVNoRev`×4, `samePV`×many, `tryHttp`×6, quote-stripping×3, divergent Cargo MSRV fetch loops). Later quality-audit changes rename and split these modules; consolidating helpers first shrinks the blast radius and prevents one-site-only bug fixes.

## What Changes

- Move `renderPVNoRev` and a shared PV-equality helper (`eqPV` / `samePV`) to a single home next to version compare (prefer `Overlay.Version`).
- Extract one shared HTTP exception→`Either Text` helper and rewire GitHub, Http, Npm, Npm.Cache, Assets.Release, and Go.ModFetch.
- Extract one shared quote-strip helper for KEYWORDS/TOML-ish token cleanup and rewire Cargo.Msrv, Go.Tree, and EbuildEdit.
- Unify Cargo MSRV fetch loops used by Check and Apply into one shared implementation.
- Delete local duplicate definitions; update imports and tests only as needed.
- **No operator-visible behavior change** (same messages, exit codes, and command surfaces).

## Program context

- **Part 1 of 8** of the post-audit quality program.
- **Apply order:** 1 → `runtime-naming-cleanup` → `split-apply-module` → `structured-domain-errors` → `library-api-encapsulation` → `progress-soft-skip-semantics` → `test-suite-modularize` → `quality-tooling-tighten`.
- **Depends on:** none (foundation change).

## Non-goals

- No Apply module split.
- No Go*/runtime renames.
- No structured error ADTs.
- No cabal export / weeder root changes.
- No test harness modularization or property tests.
- No progress UI semantics changes.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ebuild-version`: Add requirements for single bare-PV (no revision) render used by filenames/tags, and same-PV equality aligned with `comparePV` equality.

## Impact

- **Code:** `Overlay.Version`, `Update.Apply`, `Update.Check`, `Update.Deps.Plan`, `Update.Go.Plan`, `Update.Go.Lanes`, `Update.EbuildEdit`, `Update.Http`, `Update.GitHub`, `Update.Npm`, `Update.Npm.Cache`, `Update.Assets.Release`, `Update.Go.ModFetch`, `Update.Cargo.Msrv`, `Update.Go.Tree`; possibly a small new pure helper module if quote-strip / HTTP catch do not fit existing homes.
- **Tests:** import and call-site updates; existing assertions should still pass without scenario rewrites.
- **Docs / specs:** none required (`project-docs` internal-only rule).
- **Downstream changes:** unlocks safer rename and Apply split in parts 2–3.
