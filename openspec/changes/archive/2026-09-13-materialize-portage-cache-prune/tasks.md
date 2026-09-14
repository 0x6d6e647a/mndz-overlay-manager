## 1. Recipe cache mounts and gentoolkit

- [x] 1.1 Add `binhostCacheId = "mndz-materialize-binhost"` and include `--mount=type=cache,id=…,target=/var/cache/binhost` on every Portage `RUN` (`runCache` and `runCacheOverlay`) without changing `mndz-materialize-distfiles` or `mndz-materialize-binpkgs`; verify rendered Dockerfiles in `Test.Ensure` contain all three ids on emerge `RUN`s and still use the old two ids
- [x] 1.2 Add `app-portage/gentoolkit` to the base emerge list; verify the recipe emerges gentoolkit in the base `RUN` (bun-only included)

## 2. Prune RUN and generator

- [x] 2.1 Append a final cache-mounted `RUN` (same three ids) after all toolchain `RUN`s: `du -sh` of `/var/cache/binhost`, `/var/cache/binpkgs`, and `/var/cache/distfiles`; `eclean-pkg --deep`; `eclean-dist --deep`; `du -sh` again; no `--package-names`; verify `Test.Ensure` places that `RUN` after toolchain emerges, that `eclean-pkg --deep` / `eclean-dist --deep` do not appear before the first `emerge`, and that a bun-only recipe still has the prune `RUN`
- [x] 2.2 Bump `materializeGeneratorId` to `mndz-overlay-manager-materialize-7`; verify existing generator-mismatch rebuild tests still pass with the new id
- [x] 2.3 Confirm skip-ensure and `MNDZ_MATERIALIZE_IMAGE` paths do not invoke `eclean` (no extra `docker run`); verify with existing skip/override tests plus recipe-only prune coverage

## 3. Docs and gate

- [x] 3.1 Update `README.md` materialize section: BuildKit DISTDIR/PKGDIR/binhost (not XDG trees); prune on successful default-tag build; `docker builder prune` wipes them; migrate is `image.json` + image; verify those sentences are present in `README.md`
- [x] 3.2 `openspec validate materialize-portage-cache-prune --strict`
- [x] 3.3 `hk check` green; no weeder/stan weakening; no `exposed-modules` expansion
