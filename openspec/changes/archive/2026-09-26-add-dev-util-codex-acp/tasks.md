# Tasks

## 1. Manager policy

- [x] 1.1 Add `dev-util/codex-acp` to `hardcodedPolicies` in `src/Update/Hardcoded.hs` with source `Npm "@agentclientprotocol/codex-acp"`, technique `DepsAndAssets NpmEco`, and arch allowlist `["amd64"]`. Verify with a new assertion in `test/Test/Policy.hs` modeled on the `claude-agent-acp` case: `lookupPolicy` returns that source, technique, and allowlist.
- [x] 1.2 Run the policy test group and confirm the new assertion passes and existing policy assertions still pass.
- [x] 1.3 Confirm README, CONTRIBUTING, and AGENTS need no edit: this change adds no work subcommand, config key, quality-pipeline step, or agent-process rule (`project-docs`).

## 2. Absent engines.node uses the donor atom

- [x] 2.1 When registry metadata and the packed `package.json` omit `engines.node`, npm lane planning SHALL read `>=net-libs/nodejs-<version>[npm]` from the highest local non-live ebuild and use `<version>` as that candidate's node requirement so the candidate stays eligible under a sufficient nodejs ceiling. A present parseable `engines.node` still wins over the donor atom. A present unparseable value (`*`, `<`, hyphen ranges, empty) still hard-fails with no donor fallback. A missing donor atom hard-fails with an error that identifies the missing atom. Verify by tracing one absent-engines candidate through planning: the plan's node requirement equals the donor version, and apply's nodejs rewrite writes `>=net-libs/nodejs-<version>[npm]`.
- [x] 2.2 Add tests beside the existing `engines.node` probe tests for: omitted `engines.node` plus donor `>=net-libs/nodejs-22[npm]` resolves to `22` and the candidate is eligible; omitted `engines.node` with no donor atom fails and the error names the missing atom; `engines.node` `*` still fails when a donor atom exists; present `>=20.19.0` with donor `22` resolves to `20.19.0`; BDEPEND rewrite of an omitted-engines candidate keeps `>=net-libs/nodejs-22[npm]` with a single `[npm]` USE. Verify those tests pass.

## 3. Seed assets materialize

- [x] 3.1 In the materialize image container, mirror the registry-only npm cache steps for `@agentclientprotocol/codex-acp@1.13.0`: `npm pack` into a work area with an empty userconfig, then `npm --cache <npm-cache> install` of that tarball with the same empty userconfig. Verify `npm-cache/` is populated, contains the linux-x64 `@openai/codex` optional package, and has no `_logs/` entries.
- [x] 3.2 From that cache, offline-install the tarball into a prefix and record the nested Codex ELF path under `usr/lib*/node_modules/@agentclientprotocol/codex-acp/node_modules/`, plus `file`/`ldd` output. Verify the path contains no Codex version component that would differ between `^0.155.1` and `^0.156.1`. Run `codex-acp --version` in that prefix and verify it exits 0 and prints `@agentclientprotocol/codex-acp 1.13.0`. If the printed string differs, correct the seed spec's expected stdout in this change before writing the ebuild test.
- [x] 3.3 Pack `codex-acp-1.13.0-deps.tar.xz` with top-level `npm-cache/`, excluding `npm-cache/_logs/` and `npm-cache/_update-notifier*`, using hermetic tar/xz (`XZ_OPT` containing `-T1` and `-9e`). Verify the file is an xz stream (`file` or `xz -t`).
- [x] 3.4 Compute `b3`, `sha256`, and `sha512` sidecars in the same checksum sidecar format as `dev-util/claude-agent-acp`. Verify the filenames are `codex-acp-1.13.0-deps.tar.xz.{b3,sha256,sha512}`.

## 4. Assets release publish

- [x] 4.1 Write the sidecars under `dev-util/codex-acp/` in the mndz-overlay-assets worktree. Verify `git status` shows only those paths.
- [x] 4.2 Publish release tag `codex-acp-1.13.0` on mndz-overlay-assets with the deps tarball as the release asset. Verify the release lists that tarball.
- [x] 4.3 Operator: GPG-sign the assets commit of the sidecar files. Verify `git log --show-signature -1` in the assets repo shows a signed commit touching `dev-util/codex-acp/`.

## 5. Overlay seed

- [x] 5.1 Write `dev-util/codex-acp/codex-acp-1.13.0.ebuild` from the `claude-agent-acp` shape: scoped registry `SRC_URI` renamed to `${P}.tgz`, assets deps `SRC_URI` parameterized by `${PV}`, `S=${WORKDIR}/package`, `LICENSE=Apache-2.0`, `KEYWORDS="-* ~amd64"`, `>=net-libs/nodejs-22[npm]`, `IUSE=test` only, `RESTRICT="!test? ( test )"`, `QA_PREBUILT` covering the ELF path recorded in 3.2, `src_install` that `dostrip -x`s that path and dies when the ELF is missing, offline `src_install`, and `src_test` that checks `codex-acp --version` prints `@agentclientprotocol/codex-acp ${PV}`. Verify the ebuild has no completion USE flags, no `shell-completion` inherit, no dependency on `dev-util/codex`, does not set `CODEX_PATH`, and does not install `/usr/bin/codex`.
- [x] 5.2 Write `dev-util/codex-acp/metadata.xml` with GitHub remote-id `agentclientprotocol/codex-acp`. Verify it matches the `claude-agent-acp` metadata.xml shape.
- [x] 5.3 Regenerate `Manifest` via `ebuild codex-acp-1.13.0.ebuild manifest` with the manager private DISTDIR, and regenerate the package md5-cache. Verify `DIST` entries exist for `codex-acp-1.13.0.tgz` and `codex-acp-1.13.0-deps.tar.xz`, and that `metadata/md5-cache/dev-util/codex-acp-1.13.0` exists.
- [x] 5.4 Operator: GPG-sign the overlay commit adding the package. Verify `git log --show-signature -1` in the overlay shows the signed commit.

## 6. Seed install and smoke

- [x] 6.1 Emerge `=dev-util/codex-acp-1.13.0` with the test USE flag. Verify the build and `src_test` succeed offline from the deps cache, and that the nested Codex ELF is still unstripped.
- [x] 6.2 Run `codex-acp --version` and confirm it exits 0 and prints `@agentclientprotocol/codex-acp 1.13.0`. Confirm `/usr/bin/codex-acp` is the installed command and this package did not install `/usr/bin/codex`.

## 7. Manager bump smoke

- [x] 7.1 Run `mndz-overlay-manager outdated codex-acp --refresh` and verify it reports local `1.13.0` against the newest comparable upstream PV (`1.13.1` at capture; a later stable `latest` if one has been published) on an amd64 nodejs lane, with planned keywords `-* ~amd64`, and that planning does not fail with `missing engines.node`.
- [x] 7.2 Run `mndz-overlay-manager update codex-acp --refresh` and verify the full-path unit: the deps tarball for that PV is published as release `codex-acp-<PV>` with sidecars, the new ebuild keeps `QA_PREBUILT`, `dostrip -x`, the donor nodejs atom (or a registry `engines.node` atom if that PV publishes one), and the `--version` test, the `1.13.0` ebuild is pruned, Manifest and md5-cache are regenerated, and the overlay and assets commits are GPG-signed.
- [x] 7.3 Emerge the bumped PV with the test USE flag and verify `codex-acp --version` prints `@agentclientprotocol/codex-acp` plus that PV. Verify the nested Codex ELF named by `QA_PREBUILT` is present.

## 8. Integration gate

- [x] 8.1 Run `hk check` and confirm it is green.
- [x] 8.2 Run `openspec validate add-dev-util-codex-acp --type change --strict` and confirm zero issues. Confirm the living `npm-deps-assets` Purpose names `dev-util/codex-acp` and that no delta-residue language ("in this change", "as today") is in the living specs.
