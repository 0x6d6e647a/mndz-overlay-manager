## Why

Ensure’s Gentoo `docker build` already cache-mounts PKGDIR and DISTDIR and writes binpkgs (`buildpkg` / `usepkg` / `getbinpkg`) so a later layer rebuild does not recompile toolchains. Those BuildKit caches accumulate old PVs (SBCL and rust especially). Fetched official binpkgs go to `/var/cache/binhost` (Portage’s split from PKGDIR) and that path is **not** cache-mounted, so they can land in image layers. Host `eclean-pkg` cannot see BuildKit; bind-mounting host trees into `docker build` does not persist writes.

## What Changes

- **Cache-mount `/var/cache/binhost`** on every Portage `RUN` with a new stable BuildKit id (`mndz-materialize-binhost`). Keep existing ids `mndz-materialize-binpkgs` and `mndz-materialize-distfiles` (do not fork warm PKGDIR/DISTDIR).
- **`app-portage/gentoolkit`** in the image base emerge so `eclean-*` exists for prune.
- **One final cache-mounted `RUN`** after all union toolchain emerges, only when default-tag ensure actually `docker build`s: `du -sh` of `/var/cache/{binhost,binpkgs,distfiles}`, `eclean-pkg --deep`, `eclean-dist --deep`, `du -sh` again. `eclean-pkg --deep` walks PKGDIR and `binrepos.conf` locations (gentoolkit 0.8+). Failure of that `RUN` hard-fails ensure. Not at `FROM stage3`, not on intermediate toolchain `RUN`s, not when ensure skips, not for `MNDZ_MATERIALIZE_IMAGE`.
- **Generator identity** `mndz-overlay-manager-materialize-7` so existing `:local` rebuilds once (layer miss; warm binpkgs/distfiles ids; cold binhost id).
- **README:** Portage caches are BuildKit (not XDG); `docker builder prune` wipes them; `--deep` keeps exact installed PVs; migrate is sidecar + image, not a cache-directory copy.

### Non-goals

- Host bind-mounts of PKGDIR/DISTDIR/binhost under XDG (`materialize/binds/…`); operator `du` of `.gpkg` files on disk
- Kitchen-sink / always-all-five toolchains; world-file reconstruction; changing lazy/growing union
- `eclean --deep` at the start of a from-scratch build or at the end of intermediate toolchain `RUN`s
- `--deep --package-names`; Haskell gpkg-name parsing; skip-ensure prune
- Manager `eclean` / Manifest distfiles; host `/var/cache`; `docker builder prune` from ensure
- Overlay KEYWORDS/BDEPEND, atom resolve, `~arch` unmask, disk-gate **numbers**

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `ensure-materialize-image`: binhost BuildKit cache mount; gentoolkit in the image; post-union `eclean-pkg --deep` + `eclean-dist --deep` on those mounts when ensure builds; generator `…-7`
- `project-docs`: README documents BuildKit Portage caches, prune, `docker builder prune`, and that a cache-only copy is not a migrate path

## Impact

- **Code:** `Update.Materialize.Recipe` (third cache id on Portage `RUN`s; gentoolkit in base; final prune `RUN`); `materializeGeneratorId`
- **Tests:** fake-docker / rendered recipe: three cache ids; existing binpkgs/distfiles ids unchanged; prune `RUN` after toolchains with both `eclean --deep`; no early `--deep`; bun-only still has the prune `RUN`; generator mismatch rebuilds
- **Docs:** `README.md` materialize section
- **Operator:** first full-path `update` after this change rebuilds `:local`; binpkgs/distfiles `usepkg`; binhost refill then `--deep`; later rebuilds keep a bounded cache. Size signal is the ensure build log (`du` / `eclean`) and `docker system df` / `buildx du`
