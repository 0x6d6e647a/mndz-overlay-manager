## Context

See `proposal.md` for motivation. Today `Update.Preflight.preflightUpdateToolsWithImage` `docker image inspect`s `mndz-overlay-manager/materialize:local` (or `MNDZ_MATERIALIZE_IMAGE`). Missing image is `missingImageMessage` with a manual `docker build -f docker/materialize/Dockerfile` line. `Update.Spine.runUpdatePhases` inspects after classify of **admitted** units; `WavePrepare` (lambda in Spine) repeats classify → inspect → disk after bun-bin commit. `Update.Apply.runAdmitPool` withholds Bun consumers on bun-bin; GitMv and independents share `--jobs`. `productionMaterializeRunner` captures the **tag string** once at mutate start; `docker run` resolves that tag at exec time. Overlay wait-edges: `Update.OverlayWaves` (`Bun` → `dev-lang/bun-bin`).

Constraints: injectables (`CommandRunner`, spine deps); no live `docker build` in `hk check`; weeder roots stay entrypoint-oriented; new internals as `other-modules`; overlay bind-mount must not become Portage DISTDIR.

## Goals / Non-Goals

**Goals:**

- Re-entrant `ensureMaterializeImage` used at t0 and in `WavePrepare`.
- Admit GitMv/reuse immediately; withhold full-path until ensure succeeds; ensure outside `--jobs`.
- Generated Gentoo recipe; one growing image; XDG `image.json`; prune after mutate; `::mndz` bun-bin; `-bin` → binpkg → compile.

**Non-Goals:**

- Registry publish/pull; official tarball installs; whole-image `ACCEPT_KEYWORDS=~amd64`; BuildKit occupancy accounting; `docker builder prune`; building override tags; a second CLI command.

## Decisions

### D1: Extract prepare; ensure is a step inside it

**Choice:** One helper “prepare units for language materialize”: classify (if not done) → docker on PATH → ensure → unit disk gate. `runUpdatePhases` t0 and `WavePrepare` both call it. Floors come from classified full-path units’ existing plan probes (`go.mod` / engines / rust-version / sbcl.version / overlay bun-bin PV).

**Why:** Spine duplicates that path today; two inspect sites would become two divergent `docker build`s.

**Alternatives:** Paste ensure into the lambda only — rejected (t0 GitMv overlap lives in the admit pool, not only in WavePrepare).

### D2: Full-path waits on ensure in the admit pool

**Choice:** At t0, admitted GitMv/reuse enqueue immediately. Admitted full-path packages are **waiting on ensure** (same panel, no job slot). Ensure runs outside the QSem (like `WavePrepare`). On success, enqueue those full-path items. On failure, hard-fail them. After bun-bin commit, `WavePrepare` ensures then `admitResults` as today.

**Why:** Replacing inspect in-place before `runMutate` would block bun-bin on a long emerge.

**Alternatives:** Spine-blocking ensure before mutate — rejected (placement issue).

### D3: Haskell-generated Dockerfile; default tag unchanged

**Choice:** Render Dockerfile text from a typed floor set (pure). `docker build -t mndz-overlay-manager/materialize:local -f <temp or sidecar Dockerfile>`. Context: empty or a stub dir (no overlay `COPY`). In-repo `docker/materialize/Dockerfile` is **not** the build input; README stops teaching it; the file MAY be removed or reduced to a pointer so two recipes do not drift.

**Why:** Floors and `::mndz` bind-mounts are the manager’s problem shape (`EcosystemSpec`, overlay path).

**Alternatives:** ARG-fill the in-repo file — rejected in explore (translation layer).

### D4: `image.json` is the record; one image

**Choice:** `${XDG_CACHE_HOME:-$HOME/.cache}/mndz/overlay-manager/materialize/image.json` plus `Dockerfile`. Fields: schema version, image id (`sha256:…`), tag, `satisfies` (optional go/node/bun/rust/sbcl version strings), generator version, `built_at`. Reuse: id exists (`docker image inspect`) and each needed floor ≤ recorded satisfies (and/or live `go version` probe if sidecar missing). Union on build: `max(old.satisfies, needed)`.

**Why:** Pointer-only `current.json` was dropped when we decided not to keep old images.

### D5: Overlay bun-bin via bind-mount; package.accept_keywords

**Choice:** `docker build` RUN `--mount=type=bind,src=<overlayRoot>,dst=<same path>,ro` plus a generated `repos.conf` for `::mndz`. `DISTDIR`/`PKGDIR` on `--mount=type=cache`. `/etc/portage/package.accept_keywords`: `dev-lang/bun-bin::mndz ~<host-arch>` only. Emerge `dev-lang/bun-bin::mndz` at the on-disk (post-commit) PV when Bun is needed.

**Why:** Same atom as overlay BDEPEND. Read-only bind avoids writing the git tree.

**Alternatives:** `COPY` overlay — busts cache and snapshots. Official bun zip — rejected. Whole-image `ACCEPT_KEYWORDS=~amd64` — pulls testing `::gentoo`.

### D6: Layer order and Portage install policy

**Choice:** Generated stages roughly: stage3 → binhost keys / `FEATURES=getbinpkg` → base (`tar`/`xz`/`git`/certs/wget/aria2) → rust-bin + pycargoebuild → sbcl → node → go → bun-bin::mndz last when needed → `/home/builder` 0777 as today. Each toolchain `RUN` pins an atom/floor so Docker cache hits when floors are unchanged. `::gentoo` sync/webrsync lives in cache mounts inside the RUN that needs a new atom, not as an early layer that always invalidates. Install: `-bin` if the atom exists, else binpkg, else source. No go.dev/nodejs.org/GitHub zip except whatever the **ebuild** `SRC_URI` fetches for `bun-bin`.

**Why:** High-churn Bun last; binhost key sync once.

### D7: Conservative image disk gate

**Choice:** Before `docker build`, `statvfs` (existing disk probe) on Docker’s storage dir if cheap to discover, else the filesystem of `/var/lib/docker` or `docker info` root, plus overlay root if bind-mounted. Bounds are constants (implementation: generous first-image vs add-one-toolchain). Skip when no build. Do not query BuildKit cache size.

**Why:** Spec forbids cache simulation; ENOSPC mid-emerge is the failure to avoid.

### D8: Prune after `applyOverlayFromPlan`

**Choice:** Remember `oldImageId` at successful retag. After mutate returns, if the new id is current and old id is unused, `docker rmi oldId` then `docker image prune -f`. Never mid-`prepare`. Never `-a`. Never `builder prune`. Never rmi `MNDZ_MATERIALIZE_IMAGE` override.

**Why:** In-flight `docker run` still references the old id.

### D9: Override is inspect-only

**Choice:** Non-empty `MNDZ_MATERIALIZE_IMAGE`: satisfy/inspect that tag; no generate/build/rmi. Unusable → hard-fail those units.

### D10: Injectable ensure for tests

**Choice:** `UpdateSpineDeps` (or prepare env) carries `ensureImage :: NeededFloors -> IO (Either Text ())`. Production: sidecar + docker. Tests: fake success/fail/skip. Pure tests for union, satisfy, Dockerfile fragments (`::mndz`, no go.dev URL, accept_keywords line). No live Gentoo `docker build` in `hk check`.

### D11: Progress

**Choice:** t0: existing sequential step host (“Ensuring materialize image”) when a build will run. Re-entry: `mhStatus` on waiting consumers; extend waiting presentation for “waiting on materialize image” at t0 full-path. Do not open a second apply panel.

### D12: Module layout

**Choice:** `other-modules` e.g. `Update.Materialize.Ensure` (IO) + pure render/satisfy helpers. Do not expand `exposed-modules` unless tests cannot import internals. No weeder `root-modules` blanket.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| First `emerge` of `dev-lang/go` is very long | Unattended by design; progress step; overlap GitMv |
| `docker rmi` while mise still running | Prune only after mutate |
| Overlay bind visible to Docker (rootless path) | Same class of risk as unit bind-mounts; hard-fail with path in message |
| Portage writes overlay | `ro` bind + DISTDIR/PKGDIR cache mounts |
| Testing `::gentoo` pulled in | package.accept_keywords only for `bun-bin::mndz` (and per-atom if a gentoo floor is testing) |
| Sidecar lies vs daemon | Re-inspect image id; treat mismatch as miss |
| Two recipes (in-repo Dockerfile vs generated) | Stop building the in-repo file; README + optional delete |
| `--jobs 1` worker stuck in WavePrepare ensure | Spec’d: GitMv already finished; independents may have finished; acceptable |

## Migration Plan

- Operators with an existing `:local` image: first ensure reuses if live versions satisfy; else rebuild union.
- Operators who only ran the README `docker build`: still works as a pre-seeded image until floors exceed it.
- Rollback: revert; inspect + manual `docker build` message returns. Sidecar dir can be left unused.
- `MNDZ_MATERIALIZE_IMAGE` users unchanged (inspect-only).

## Open Questions

None blocking. Exact conservative byte floors and Gentoo binhost URI are implementation constants in the ensure module (tune if false disk fails appear).
