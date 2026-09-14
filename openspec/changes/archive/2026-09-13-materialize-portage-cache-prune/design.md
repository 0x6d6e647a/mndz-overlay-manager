## Context

See `proposal.md` for motivation. `renderMaterializeDockerfile` already cache-mounts `/var/cache/distfiles` (`id=mndz-materialize-distfiles`) and `/var/cache/binpkgs` (`id=mndz-materialize-binpkgs`) on every Portage `RUN`, with `FEATURES=getbinpkg buildpkg` and `EMERGE_DEFAULT_OPTS=--usepkg`. `/var/cache/binhost` is not mounted. Generator id is `mndz-overlay-manager-materialize-6`. Base emerge is tar/xz/certs/unzip/git/aria2/wget plus oneshot portage; no gentoolkit. Layer order rust → sbcl → qlot → node → node-gyp → go → bun. Ensure skip vs `docker build` is unchanged (union floors + generator). Host `gentoolkit-0.8.0` `eclean-pkg` walks PKGDIR and every `binrepos.conf` `location` (default `/var/cache/binhost/${name}`). A spike on this daemon showed `RUN --mount=type=bind,from=<extra context>,rw` does not persist writes to the host (snapshot). Fake-docker tests only in `hk check`.

## Goals / Non-Goals

**Goals:**

- Third stable cache id for `/var/cache/binhost` on every Portage `RUN`.
- gentoolkit in the base emerge; one final prune `RUN` after union toolchains.
- Keep existing binpkgs/distfiles ids; bump generator to `…-7`.
- Recipe-text tests only; no live Gentoo `docker build` in CI.

**Non-Goals:**

- Host bind trees; `docker run -v` emerge; changing lazy/growing union.
- Disk-gate number changes; `exposed-modules` / weeder root expansion.
- Live `eclean` against a real PKGDIR in `hk check`.

## Decisions

### D1: Stay on BuildKit `type=cache`; do not bind host dirs

Portage writes during `docker build` must persist for the next ensure. Extra-context bind `rw` does not. `type=cache` already does for distfiles/binpkgs. Operator `du` of `.gpkg` files is not a product requirement; build-log `du -sh` is.

- *Alternative — `materialize/binds/var/cache/…` + extra `--build-context`:* Rejected; spike: `transferring binds` snapshot, host unchanged.
- *Alternative — `docker run -v` + `docker commit` for emerge:* Rejected; larger ensure rewrite; layer cache vs usepkg tradeoff not needed for prune.

### D2: Cache ids

```
id=mndz-materialize-distfiles → /var/cache/distfiles
id=mndz-materialize-binpkgs   → /var/cache/binpkgs
id=mndz-materialize-binhost   → /var/cache/binhost
```

Share `runCache` / `runCacheOverlay` helpers so overlay-bind `RUN`s get binhost too. Do not rename the first two ids.

- *Alternative — one cache id for all of `/var/cache`:* Rejected; would mix unrelated cache and fork the two warm ids.

### D3: gentoolkit in the base `RUN`

`emerge -n app-portage/gentoolkit` with tar/git/…. Prune `RUN` is only `du` + `eclean-*`. gentoolkit is image infrastructure.

- *Alternative — `--oneshot` only in the prune `RUN`:* Rejected; couples prune to a late emerge; base failure is clearer.

### D4: One final prune `RUN`, not per toolchain `RUN`

`--deep` keeps exact installed CPV+`BUILD_TIME`. `FROM stage3` starts with an empty VDB; mid-recipe VDB omits later toolchains. Only after the last union emerge is `--deep` safe. Dedicated last `RUN` (not appended to bun/go, which may be absent). Same three mounts. `eclean-pkg --deep` then `eclean-dist --deep`. No `--package-names`. Non-zero exit fails `docker build` → ensure `Left` (existing build-failure path); do not write sidecar.

Skip-ensure and `MNDZ_MATERIALIZE_IMAGE` never invoke `eclean` (no extra `docker run`).

- *Alternative — `--deep` at the start of every emerge `RUN`:* Rejected; wipes warm cache before `usepkg`.
- *Alternative — `--deep` at the end of each toolchain `RUN`:* Rejected; deletes later toolchains’ binpkgs.
- *Alternative — prune when ensure skips:* Rejected; VDB already matches; no new graveyard.

### D5: Logs

`du -sh /var/cache/binhost /var/cache/binpkgs /var/cache/distfiles` before and after `eclean`. Do not pass `--quiet`. No recursive listing.

### D6: Generator `mndz-overlay-manager-materialize-7`

Adding mounts to existing `RUN`s and a new prune `RUN` changes recipe text. Bump `materializeGeneratorId` so `-6` sidecars rebuild. binpkgs/distfiles ids stay warm; binhost id is new (cold getbinpkg cache once).

### D7: Tests stay fake-docker

Extend `Test.Ensure` recipe assertions: three ids on Portage `RUN`s; prune `RUN` after toolchains contains both `eclean --deep` and not `--package-names`; `eclean --deep` is not before first `emerge`; bun-only still has prune `RUN`; gentoolkit in base; generator mismatch rebuilds. No live Hub/`emerge`/`eclean`.

### D8: README in the same change

Materialize section: BuildKit (not XDG) for the three caches; prune on successful default-tag build; `docker builder prune` wipes them; migrate = `image.json` + image, not a binpkg directory.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| `--deep` mid-build wipes later toolchains | Single prune `RUN` after all emerges; tests forbid early `--deep` |
| Changing binpkgs/distfiles `id=` cold-compiles SBCL/rust | Do not rename those ids |
| `getuto` missing / no `binrepos.conf` | Existing `(getuto \|\| true)`; without binrepos, `eclean-pkg` still walks PKGDIR; binhost mount stays empty |
| Older gentoolkit without binrepo locations | Image emerges current tree gentoolkit with the rest of the stage3 sync |
| `emaint binhost --fix` only rewrites PKGDIR `Packages` | Next emerge/`populate(force_reindex=True)` refreshes binhost index; no second CLI |
| BuildKit GC / `docker builder prune` still cold-starts | Spec already forbids ensure from running builder prune; README says it wipes Portage caches |
| Prune `RUN` fails after hours of emerge | Hard-fail (chosen); operator sees `docker build` tail; no false “satisfies” sidecar |
| bun-only first image `--deep` drops unused rust in a copied BuildKit cache | Documented disposable cache; migrate needs sidecar + image |

## Migration Plan

- Next full-path `update`: generator miss → rebuild `:local` (`-7`). Warm binpkgs/distfiles; cold binhost; then `--deep`.
- `MNDZ_MATERIALIZE_IMAGE`: unchanged (inspect-only, no prune).
- Rollback: revert; binhost may bloat layers again; caches unbounded again.

## Open Questions

None. Live confirmation that image `eclean-pkg --deep` prints a binhost `* Location` can wait for the first operator `docker build`; spec requires the outcome, not a second command.
