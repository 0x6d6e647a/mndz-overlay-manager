# Tasks — add dev-util/rulesync package

## 1. Manager policy (inert until seed exists)

- [x] 1.1 Add `dev-util/rulesync` → `(Npm "rulesync")` / `(DepsAndAssets NpmEco)` to `hardcodedPolicies` in `src/Update/Hardcoded.hs`; verify `lookupPolicy (PackageKey "dev-util/rulesync")` resolves via a new assertion in `test/Test/Policy.hs` modeled on the openspec case
- [x] 1.2 Run the test-suite policy group (cabal test) and confirm the new assertion passes and no other policy assertions regress

## 2. Seed assets materialize (agent, in materialize container)

- [x] 2.1 In the materialize image container, mirror the registry-only npm cache steps for `rulesync@16.22.1`: `npm pack rulesync@16.22.1` into a work area, then populate `npm-cache/` via `npm --cache <npm-cache> install <tarball>` with an empty userconfig; verify `npm-cache/` is populated and no `_logs/` entries remain
- [x] 2.2 Pack `rulesync-16.22.1-deps.tar.xz` under the unit `out/` with top-level `npm-cache/`, excluding `npm-cache/_logs/` and `npm-cache/_update-notifier*`, using the hermetic tar/xz rules (`XZ_OPT` with `-T1` and `-9e`); verify the file is an xz stream (`file` / `xz -t`)
- [x] 2.3 Compute `b3`, `sha256`, `sha512` sidecars matching the existing `dev-util/openspec` sidecar formats; verify filenames are `rulesync-16.22.1-deps.tar.xz.{b3,sha256,sha512}`

## 3. Assets release publish (agent + operator GPG)

- [x] 3.1 Write sidecars under `dev-util/rulesync/` in the mndz-overlay-assets worktree; verify `git status` shows only those paths
- [x] 3.2 Publish release tag `rulesync-16.22.1` on mndz-overlay-assets with the deps tarball as release asset (`gh release create rulesync-16.22.1`); verify the release lists exactly the deps tarball
- [x] 3.3 Operator: GPG-sign the assets commit of the sidecar files; verify `git log --show-signature -1` in the assets repo shows a signed commit touching `dev-util/rulesync/`

## 4. Overlay seed (agent writes, operator signs)

- [x] 4.1 Write `dev-util/rulesync/rulesync-16.22.1.ebuild` modeled on the openspec ebuild minus `shell-completion` (frozen pin 16.22.1, primary npm SRC_URI `${P}.tgz`, assets deps SRC_URI, `S=${WORKDIR}/package`, `>=net-libs/nodejs-22.0.0[npm]`, openspec KEYWORDS set, `IUSE=test` + `RESTRICT=!test? ( test )`, offline src_test help smoke); verify no completion USE flags and no GitHub binary SRC_URI entries
- [x] 4.2 Write `dev-util/rulesync/metadata.xml` with GitHub remote-id `dyoshikawa/rulesync`; verify against the openspec metadata.xml shape
- [x] 4.3 Regenerate `Manifest` via `ebuild rulesync-16.22.1.ebuild manifest` with the manager private DISTDIR (fetches npm tgz from registry and deps tarball from the published release); verify `DIST rulesync-16.22.1.tgz` and `DIST rulesync-16.22.1-deps.tar.xz` entries exist
- [x] 4.4 Operator: GPG-sign the overlay commit adding the package; verify `git log --show-signature -1` in the overlay shows the signed commit

## 5. Seed install and smoke (operator, root)

- [x] 5.1 Emerge `=dev-util/rulesync-16.22.1` from the overlay; verify build succeeds with network isolation (offline deps cache path)
- [x] 5.2 Run `rulesync --version` and confirm it exits 0 reporting `16.22.1`; run `rulesync --help` and confirm exit 0; record whether a completion subcommand exists (feeds the design note only)

## 6. Manager smoke test (agent)

- [x] 6.1 Run `mndz-overlay-manager outdated rulesync --refresh` and verify it reports the newer upstream PV (16.23.0 or whatever is latest at run time) against local 16.22.1
- [x] 6.2 Run `mndz-overlay-manager update rulesync --refresh` and verify the full-path unit: docker container appears for the unit, `rulesync-16.23.0` (or latest) deps tarball is packed and release `rulesync-<PV>` published with sidecars, new ebuild written, 16.22.1 ebuild pruned, Manifest + md5-cache regenerated, overlay and assets commits GPG-signed
- [x] 6.3 Emerge `=dev-util/rulesync-16.23.0` (or the PV applied in 6.2) and verify `rulesync --version` reports it and `rulesync --help` exits 0

## 7. Gates and SoT

- [x] 7.1 Run `hk check` (ormolu/hlint/stan/weeder + build + tests) and confirm green after the manager code change
- [x] 7.2 Run `openspec validate` on the change and confirm zero issues; confirm no delta-residue language leaked into living specs (npm-deps-assets Purpose edit already applied directly)