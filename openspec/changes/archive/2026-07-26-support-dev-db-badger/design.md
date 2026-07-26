## Context

`seed-dev-db-badger` leaves a template ebuild at `dev-db/badger` with vendor assets SRC_URI, optional jemalloc companion SRC_URI, and custom `src_compile`/`src_install`. mndz-overlay-manager already supports `DepsAndAssets` Go packages (dolt, beads, crush) via hardcoded policy, temp clone, vendor publish, and ebuild rewrite. Badger is not in the policy map yet, so update soft-skips or treats it as unconfigured.

Go apply rewrites assets URLs via `parameterizeAssetsSrcUri` (marker `mndz-overlay-assets/releases/download/`) and adjusts BDEPEND/KEYWORDS. Companion non-assets URIs should already survive if only that path runs, but this is not specified or tested — jemalloc USE depends on that preservation.

## Goals / Non-Goals

**Goals:**

- Register `dev-db/badger` as first-class Go `DepsAndAssets` policy.
- Guarantee jemalloc (and other non-assets) `SRC_URI` lines survive apply rewrites; prove with tests.
- Enable operator smoke: update past 4.9.4, emerge, `badger --help`.

**Non-Goals:**

- Creating the seed ebuild.
- Auto-bumping jemalloc version.
- Changing KEYWORDS tilde policy.
- Regenerating or inventing `src_compile` jemalloc logic (template-owned).

## Decisions

### 1. Policy entry

```text
dev-db/badger → GitHub dgraph-io/badger, tag prefix "v"
             → DepsAndAssets (Go Nothing)  -- go.mod at repo root
```

Same shape as beads/crush (not dolt’s `go/` subdir).

### 2. Companion SRC_URI preservation

- Treat as a **requirement** on Go ebuild rewrite: any `SRC_URI` / `SRC_URI+=` content that is not an mndz-overlay-assets vendor URL SHALL remain byte-stable aside from intentional global edits (none for jemalloc).
- Prefer minimal change: keep using `parameterizeAssetsSrcUri` only; add regression tests with a badger-like multi-line SRC_URI including `jemalloc? ( … )`.
- If cargo-style rebuilds ever apply to Go, they must not strip companions — out of scope unless code paths share helpers.

### 3. Template dependence

- Apply continues to `findTemplate` from existing ebuilds in the package dir. Seed must exist before first update.
- `src_compile`, USE flags, and jemalloc private build remain from the template; manager only moves PV, assets URL, BDEPEND, KEYWORDS, Manifest.

### 4. Specs surface

- Extend `go-vendor-assets` hardcoded Go packages requirement to include badger.
- Add requirement for non-assets SRC_URI preservation on Go rewrite.
- Align `update-apply` hardcoded policy list to mention badger if that requirement enumerates Go packages by name.

### 5. Acceptance

Operator runs manager update targeting `dev-db/badger` after merge; expects a newer PV than 4.9.4 if upstream tags exist; emerge + `badger --help`.

## Risks / Trade-offs

- **[Risk]** Seed missing or wrong template → **Mitigation:** hard dependency on `seed-dev-db-badger` completion; apply fails clearly without template.
- **[Risk]** Aggressive SRC_URI rewrite later breaks jemalloc → **Mitigation:** dedicated unit test; code review on EbuildEdit.
- **[Risk]** KEYWORDS still bare/tilde mix → **Mitigation:** accepted until `overlay-tilde-keywords`.

## Migration Plan

1. Implement policy + tests; `hk check`.
2. Operator: update badger; verify assets release for new PV; emerge; smoke help.
3. Confirm jemalloc USE still present in rewritten ebuild.

## Open Questions

- None blocking; jemalloc pin remains whatever the seed ebuild chose.
