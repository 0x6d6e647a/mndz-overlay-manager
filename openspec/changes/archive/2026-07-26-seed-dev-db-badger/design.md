## Context

BadgerDB (`github.com/dgraph-io/badger`) provides an embeddable KV store and a cobra CLI under `./badger`. The mndz overlay has no `dev-db/badger` package; Gentoo only has unrelated `pgbadger`. Existing Go packages (beads, crush, dolt) document the vendor + assets pattern in `mndz-overlay/go-ebuild-context.md`. This change is **manual** work in mndz-overlay and mndz-overlay-assets; mndz-overlay-manager only holds the OpenSpec plan.

Upstream at v4.9.4: `go 1.23.0` at repo root, Apache-2.0, CLI via `go build ./badger`. Official Makefile uses `-tags=jemalloc` against a jemalloc built with `--with-jemalloc-prefix=je_`. Stock `dev-libs/jemalloc::gentoo` does not ship that prefix or static `.a` libraries.

## Goals / Non-Goals

**Goals:**

- Ship a working `=dev-db/badger-4.9.4` that emerges and runs `badger --help`.
- Publish go-module-compatible vendor assets for that PV.
- Encode jemalloc (private static build), test, and shell-completion USE flags in the seed ebuild so later manager updates keep them via template.

**Non-Goals:**

- Manager policy or apply code.
- Version newer than 4.9.4.
- Tilde-only KEYWORDS policy (later change).
- Depending on `dev-libs/jemalloc::gentoo` at runtime or build time as the jemalloc provider.

## Decisions

### 1. Package identity

- **Category/PN:** `dev-db/badger` (same category family as dolt).
- **PV:** `4.9.4` from tag `v4.9.4` (not 4.9.5) so the next manager-driven update is a real bump.
- **Binary:** install as `badger` from `ego build -o badger ./badger`.

### 2. Vendor assets

- Build with overlay `go-make-vendor-tarball.py` (or equivalent) on a clean checkout of `v4.9.4`.
- Distfile: `badger-4.9.4-vendor.tar.xz` with top-level `go-mod/`.
- Assets repo: sidecars under `dev-db/badger/`, commit message `dev-db/badger: 4.9.4`, GitHub release tag `badger-4.9.4`, asset the tarball.
- Ebuild `SRC_URI` uses `${PV}` parameterization for the assets URL (same form as crush/beads).

### 3. jemalloc = private static build (path A)

- `IUSE=jemalloc` with conditional `SRC_URI` for a **fixed** jemalloc upstream tarball (prefer 5.3.0 to match Gentoo distfiles, or 5.3.1 per upstream Makefile).
- When `use jemalloc`: unpack/build jemalloc in work dir with `--with-jemalloc-prefix=je_` (and sensible malloc conf if desired); set `CGO_*` / `LDFLAGS` so the build does **not** rely on `/usr/local/lib/libjemalloc.a` hardcodes in ristretto; `ego build -tags=jemalloc …`.
- When `use !jemalloc`: build without the tag (optionally `CGO_ENABLED=0`); binary prints jemalloc disabled — acceptable.
- **No** `DEPEND`/`RDEPEND`/`BDEPEND` on `dev-libs/jemalloc`.

### 4. Completions

- Inherit `shell-completion`.
- Generate with `badger --dir /var/empty completion {bash,zsh,fish}` because PersistentPreRunE requires `--dir` even for completion.
- USE flags: `bash-completion`, `zsh-completion`, `fish-completion` (no powershell).

### 5. test USE

- `IUSE` includes `test`; `RESTRICT="!test? ( test )"`.
- `src_test` runs `ego test ./...` when tests are allowed (Portage `FEATURES=test` + `USE=test`).

### 6. KEYWORDS (temporary pattern)

- Match crush-style multi-arch set from go-lane arches **without** forcing all-tilde yet (same mixed bare/`~` style as current Go ebuilds). Phase 3 revises this.

### 7. Work locations

| Artifact | Repository |
|----------|------------|
| ebuild, metadata, Manifest | mndz-overlay |
| vendor tarball release + sidecars | mndz-overlay-assets |
| OpenSpec only | mndz-overlay-manager |

## Risks / Trade-offs

- **[Risk]** jemalloc CGO/`#cgo LDFLAGS` hardcodes `/usr/local` → **Mitigation:** override via environment / patch in `src_prepare` / build flags before `ego build`.
- **[Risk]** Full `ego test ./...` is heavy or flaky → **Mitigation:** RESTRICT + USE=test; default emerge smoke does not run tests.
- **[Risk]** Completion generation starts debug HTTP listener in `main` → **Mitigation:** accept noise during install; does not block packaging.
- **[Risk]** Seed KEYWORDS will be rewritten by manager later → **Mitigation:** accepted until `overlay-tilde-keywords`.

## Migration Plan

1. Checkout badger `v4.9.4`; create vendor tarball; publish assets.
2. Add ebuild + metadata; `ebuild … manifest`; commit overlay.
3. Operator: `emerge -av1 =dev-db/badger-4.9.4` then `badger --help`.
4. Proceed to `support-dev-db-badger` when smoke passes.

## Open Questions

- Exact jemalloc pin (5.3.0 vs 5.3.1) — default **5.3.0** unless emerge/distfile convenience prefers otherwise.
- Whether `src_test` should exclude integration packages if they fail under sandbox — decide during implement if needed.
