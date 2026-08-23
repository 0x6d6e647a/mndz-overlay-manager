## 1. Pure floors, sidecar, and Dockerfile render

- [x] 1.1 Add `other-modules` helpers: needed floors from classified full-path units; satisfy predicate; monotonic union with previous `satisfies`
- [x] 1.2 `image.json` schema (id, tag, satisfies, generator, built_at) and XDG path `…/mndz/overlay-manager/materialize/`
- [x] 1.3 Pure Dockerfile (or recipe) render: Gentoo stage3; `-bin` then binpkg then compile; `dev-lang/bun-bin::mndz` bind-mount + package.accept_keywords for that atom; `DISTDIR`/`PKGDIR` cache mounts; no go.dev/nodejs.org/GitHub zip URLs except ebuild SRC_URI
- [x] 1.4 Tests: union/satisfy; Bun-only first image omits SBCL; render contains `::mndz` and does not contain official tarball URLs; missing sidecar field is a miss

## 2. Ensure IO (injectable)

- [x] 2.1 Production ensure: inspect sidecar + image id; skip `docker build` when satisfies; else conservative disk gate, generate recipe, `docker build -t` default tag, write `image.json` + `Dockerfile`
- [x] 2.2 `MNDZ_MATERIALIZE_IMAGE` set: inspect/satisfy only; never build or `rmi` that tag
- [x] 2.3 Overlay bind-mount read-only at build; Portage must not write the overlay work tree
- [x] 2.4 Inject `ensureImage` on spine/prepare (fake success/fail/skip); no live Gentoo `docker build` in unit tests
- [x] 2.5 Tests: skip when satisfies; override missing hard-fails without build; fake build records union satisfies

## 3. Spine: extract prepare; full-path waits on ensure

- [x] 3.1 Extract classify → docker-on-PATH → ensure → unit disk gate used by t0 and `WavePrepare`
- [x] 3.2 Admit GitMv/reuse immediately; withhold full-path until ensure succeeds; ensure does not take a `--jobs` slot
- [x] 3.3 `WavePrepare` re-ensures after bun-bin commit for new full-path consumers; failure hard-fails consumers and does not roll back the provider commit
- [x] 3.4 After `applyOverlayFromPlan` returns: `docker rmi` previous default-tag id if unused, then `docker image prune -f` (not `-a`, not `builder prune`)
- [x] 3.5 Fake-ops spine tests: bun-bin overlaps ensure; `--jobs 1` bun-bin while full-path waits; second ensure after bun-bin; failed re-ensure keeps bun-bin commit; reuse-only/GitMv-only never calls build

## 4. Progress and disk

- [x] 4.1 t0 sequential step when a `docker build` will run; re-entry `mhStatus` on waiting consumers; full-path waiting-on-ensure presentation (not hard-fail); one apply panel
- [x] 4.2 Conservative image-build free-space check before `docker build`; skip when no build; message names path and free vs need
- [x] 4.3 Tests for waiting-on-ensure vs hard-fail presentation and skip of image disk gate when satisfies

## 5. Docs, in-repo Dockerfile, quality gate

- [x] 5.1 `README.md`: `update` ensures the default image; GitMv/reuse overlap; Bun from `::mndz`; sidecar path; override inspect-only; remove manual `docker build -f docker/materialize/Dockerfile` as a prerequisite (`project-docs`)
- [x] 5.2 Stop using in-repo `docker/materialize/Dockerfile` as the CLI/operator recipe (delete or replace with a pointer) so it cannot drift from Haskell render
- [x] 5.3 Replace inspect-only `missingImageMessage` operator copy with ensure/override failure messages
- [x] 5.4 `openspec validate ensure-materialize-image --strict` clean
- [x] 5.5 `hk check` green; HIE rebuilt if modules move; no casual weeder/stan weakening; no `exposed-modules` expansion unless the test-suite requires it
