## Why

Full-path `update` requires a host-arch Gentoo materialize image, but the CLI only `docker image inspect`s it: a missing or stale image is a hard-fail that tells the operator to `docker build` by hand. After overlay apply waves, the same inspect runs again when a withheld Bun consumer is admitted—so a same-run `bun-bin` bump can still leave ralph blocked on an image whose Bun is the *old* overlay package. `update` should be one unattended shot: create or refresh the image only when classified full-path work needs it, from the same atoms overlay consumers use.

## What Changes

- **`update` ensures the materialize image** when some unit that will actually run is classified full-path. Reuse-only, GitMv-only, `list`, and `outdated` still do not need Docker or an image. Missing `docker` on `PATH` remains a hard-fail; there is still no host `go`/`npm`/`bun` fallback.
- **GitMv/reuse start immediately; full-path waits on ensure.** Ensure does not occupy a `--jobs` slot (same idea as ralph waiting on bun-bin). A first `docker build` overlaps `bun-bin`; mise/ralph start when the image satisfies their floors.
- **Two call sites:** (1) t0, for *admitted* full-path units; (2) `WavePrepare` after an overlay wait-edge provider’s signed commit, for *newly* admitted full-path consumers (waves D11). Failed ensure hard-fails those consumers and does not roll back a committed provider.
- **Haskell generates the Dockerfile** from this prepare’s needed toolchain floors unioned with the previous image’s `satisfies` (monotonic growing image). Static in-repo `docker/materialize/Dockerfile` is no longer the operator recipe or the CLI source of truth.
- **Sidecar** under XDG cache: `image.json` (id, satisfies, generator, built_at) and the last `Dockerfile`. After a successful mutate run, prune the previous image id if unused, then `docker image prune -f` (dangling only). Never `prune -a` or auto `docker builder prune`.
- **Install policy inside the image:** `-bin` → binpkg → compile. **No official language tarballs.** Bun is **only** `dev-lang/bun-bin::mndz` (overlay bind-mounted at build; `DISTDIR`/`PKGDIR` on cache mounts). Container Portage uses package.accept_keywords for that overlay atom (host arch, typically `~amd64`), not whole-image `ACCEPT_KEYWORDS=~amd64`. Overlay ebuild KEYWORDS/BDEPEND stay runtime-lane driven.
- **Conservative free-space check** before `docker build` (not a BuildKit hit-rate model). Skip when `image.json` already satisfies.
- **Progress:** t0 step for ensure; re-entry `mhStatus` on waiting consumers. Extract the duplicated classify → docker → disk path so both spine sites call one prepare/ensure helper.
- **`MNDZ_MATERIALIZE_IMAGE`:** if set to a non-empty tag the CLI did not just build, inspect/satisfy only—never `docker build` or `docker rmi` that tag.

**Not BREAKING** for overlay consumers. **Operator-visible:** `update` may `docker build` unattended; README no longer treats a manual `docker build` as a prerequisite.

### Non-goals

- Publishing or pulling a registry image
- Alpine or other non-Gentoo bases; official go.dev / nodejs.org / GitHub zip installs (Bun comes through the overlay ebuild’s SRC_URI via `emerge ::mndz`)
- Changing overlay KEYWORDS, BDEPEND, or runtime-lane planning; host `emaint sync` as a side effect
- Long-lived materialize sidecar container; qemu / foreign-arch
- Modeling BuildKit cache occupancy; `docker builder prune`
- Building or deleting an operator override tag (`MNDZ_MATERIALIZE_IMAGE`)
- Putting GPG, SSH, or the GitHub token into the image
- A second CLI command for image ensure (it lives in `update`)

## Capabilities

### New Capabilities

- `ensure-materialize-image`: When `update` will full-path materialize, it ensures a host-arch Gentoo image that satisfies those units’ toolchain floors: generated Dockerfile, one growing image, XDG sidecar, prune-after-run, `::mndz` bun-bin, Gentoo `-bin`/binpkg/compile, overlap with work that does not need the image

### Modified Capabilities

- `hermetic-asset-materialize`: A usable image is something `update` ensures, not only inspects; missing/stale image is ensure (or hard-fail if Docker/override/build fails), not an operator `docker build` recipe
- `update-command`: Spine requires `docker` on `PATH` for full-path units but admits GitMv/reuse without waiting on ensure; ensure runs before those units mutate; re-entry after overlay provider commit re-ensures
- `overlay-apply-waves`: After a wait-edge provider signed commit, prepare SHALL re-ensure the materialize image for newly full-path consumers (fills the unimplemented D11 hook)
- `disk-space-preflight`: Conservative free-space gate before `docker build` when ensure will build
- `cli-activity`: Ensure has t0 step progress and re-entry per-consumer status; full-path packages may wait on ensure
- `cli-concurrency`: Ensure MUST NOT take a package job slot; full-path work waits outside the limiter until ensure succeeds
- `project-docs`: README runtime/materialize sections describe auto-ensure, sidecar location, override inspect-only, and no longer require a manual `docker build` before `update`

## Impact

- **Code:** `Update.Spine` (extract prepare; withhold full-path on ensure at t0); `WavePrepare` / `Update.Apply` admit pool (full-path wait on ensure); new image-ensure module (generate Dockerfile, sidecar, `docker build`, prune, floors union); `Update.Preflight` / `Update.Process.Docker` (inspect becomes ensure-or-inspect); overlay bind-mount at build; progress labels
- **Tests:** Pure floors union / satisfy / Dockerfile shape / sidecar schema; fake `docker` / inspect so CI does not `docker build`; spine fakes: GitMv proceeds while full-path waits on ensure; second ensure after bun-bin commit; override tag never built/rmi; failed ensure does not roll back provider. No live Gentoo image build in `hk check`
- **Docs:** `README.md` (project-docs); drop operator `docker build` as the required path
- **Operator:** One `update` can build/refresh the image and materialize; first run may compile for a long time; Docker daemon still required for full-path
