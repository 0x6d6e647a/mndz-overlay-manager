## Context

Live mndz-overlay inventory (post tilde-keywords):

| Package | `IUSE=test` | RESTRICT gate | `src_test` |
|---------|-------------|---------------|------------|
| `dev-db/badger` | yes | yes | `ego test ./...` |
| `dev-util/ralph-tui` | yes | **no** | `bun test` behind `if use test` |
| `dev-db/dolt`, `dev-util/beads`, `dev-util/crush` | no | no | explicit `ego test ./...` |
| `dev-util/hk`, `mise`, `usage` | no | no | **inherited** `cargo_src_test` from cargo.eclass |
| `dev-util/opencode`, `openspec` | no | no | none |
| `*-bin` prebuilts | no | n/a | none (out of scope) |

Portage: `FEATURES=test` schedules the test phase; `RESTRICT` containing `test` skips it. The idiomatic opt-in is `RESTRICT="!test? ( test )"` with `test` in `IUSE`. Relying only on `if use test` inside `src_test` is incomplete (phase still “runs,” tools/deps semantics differ).

## Goals / Non-Goals

**Goals:**

- One overlay-wide convention for all non-prebuilt packages that should expose tests.
- Fix ralph-tui’s incomplete gate; gate Go and Cargo suites; introduce Bun/npm `src_test` for opencode/openspec.
- Mandatory `-rN` for every non-version ebuild content change in this work.

**Non-Goals:**

- Prebuilt smoke tests.
- Manager automation of RESTRICT/IUSE (human-owned ebuild contract).
- Default-enabling `USE=test` in profiles.

## Decisions

### 1. Canonical ebuild shape

```bash
IUSE="… test"   # merge with existing IUSE tokens
RESTRICT="!test? ( test )"
# If RESTRICT already has tokens (e.g. strip), merge:
# RESTRICT="strip !test? ( test )"

src_test() {
	# real suite; no need for `if use test` when RESTRICT is present
	…
}
```

Reference implementations: overlay `dev-db/badger`, Gentoo `dev-go/delve`.

### 2. Per-package plan

**ralph-tui (Bun, incomplete gate)**

- Keep `IUSE="test"`.
- Add `RESTRICT="!test? ( test )"`.
- `src_test`: `bun test || die` (remove redundant `if use test`).
- Rev: `0.12.0` → `0.12.0-r1`.

**dolt, beads, crush (Go, suite already present)**

- Add `IUSE="test"` and `RESTRICT="!test? ( test )"`.
- Keep `ego test ./...` as-is (or package-specific flags if already tuned).
- Rev: next `-rN` on current PV (`dolt-2.2.2-r3` → `-r4`, `beads-1.1.2` → `1.1.2-r1`, `crush-0.82.0-r3` → `-r4`).

**hk, mise, usage (Cargo, eclass-exported tests)**

- Append `test` to existing completion IUSE lists.
- Add `RESTRICT="!test? ( test )"`.
- Prefer **not** overriding `src_test` so `cargo_src_test` remains the implementation; RESTRICT alone gates when `USE=-test`.
- If a suite needs offline skips, set `CARGO_SKIP_TESTS=( … )` or a thin `src_test` wrapper that calls `cargo_src_test` with documented args — do not leave FEATURES=test ungated.
- Rev: next `-rN` on current PV for each.

**opencode (Bun, new src_test)**

- Append `test` to `IUSE` (keep `bash-completion +webui zsh-completion`).
- Merge RESTRICT: `RESTRICT="strip !test? ( test )"`.
- Add `src_test` that runs the upstream Bun test entrypoint offline using the install-tree deps already unpacked under `${S}` (same network constraints as compile). Prefer a scoped command if full monorepo tests need network; document choice in ebuild comments if non-obvious.
- Rev: `1.18.5` → `1.18.5-r1`.

**openspec (npm, new src_test)**

- Append `test` to completion IUSE.
- Add `RESTRICT="!test? ( test )"`.
- Add `src_test` using offline npm/cache layout consistent with `src_install` (deps tarball under `${T}` / cache). Prefer upstream unit tests that do not require network; if none are offline-safe, implement the best offline subset and comment limitations — do not omit the USE/RESTRICT pair.
- Rev: `1.6.0-r1` → `1.6.0-r2`.

**badger**

- Verify only; no revbump for this change.

**Prebuilts**

- Explicitly out of scope.

### 3. Revision policy (mandatory)

For **any** ebuild content change that is not a PV/version bump (KEYWORDS, IUSE, RESTRICT, `src_*`, deps tokens, etc.):

1. Do **not** edit the live `${P}.ebuild` filename in place as the final published form.
2. Ship as **`${PN}-${PV}-rN.ebuild`** with N = previous revision + 1 (or `-r1` if unrevised).
3. Prefer git mv / rename so history tracks the revision.
4. Drop or prune the previous revision ebuild for that PV when replacing (overlay practice: one live ebuild per package unless multi-PV is intentional).
5. Regenerate Manifest and package md5-cache entries for the new revision.

This matches recent overlay content fixes (e.g. tilde-keywords revbumps).

### 4. Manager

- No product code change expected.
- Update fixtures only if they embed ebuild snippets that would be wrong after this convention.

### 5. Verification (operator / implementer)

Spot-check at least one package per class (Go, Cargo, Bun, npm):

- `USE=-test FEATURES=test` → test phase restricted / skipped.
- `USE=test FEATURES=test` → `src_test` runs (may still die on flaky upstream — treat green suite as stretch; gate presence is the hard requirement).

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Cargo/Go/Bun suites fail under Portage sandbox or need network | Scope command, `CARGO_SKIP_TESTS`, skip known-bad tests; RESTRICT still correct for default emerge |
| opencode/openspec have no offline-friendly suite | Ship USE+RESTRICT + best-effort `src_test`; document; follow-up can harden |
| Operators who relied on ungated FEATURES=test lose automatic suite runs | Intended; enable `USE=test` (package.use) when testing |
| Large multi-package commit noise | One logical change; per-package commits OK if preferred (`cat/pkg: PV-rN`) |

## Migration Plan

1. Inventory current PVR for each target package (done in explore).
2. For each package: revbump ebuild, apply IUSE/RESTRICT/`src_test` edits, Manifest, md5-cache, commit.
3. Leave badger and prebuilts untouched.
4. Optional emerge smoke on representative packages.

## Open Questions

- None blocking. Implementer chooses exact opencode/openspec test commands after reading upstream package scripts in the unpacked source + deps layout.
