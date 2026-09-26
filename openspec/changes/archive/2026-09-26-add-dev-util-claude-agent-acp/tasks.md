# Tasks

## 1. Manager policy

- [x] 1.1 Add `dev-util/claude-agent-acp` to `hardcodedPolicies` in `src/Update/Hardcoded.hs` with source `Npm "@agentclientprotocol/claude-agent-acp"`, technique `DepsAndAssets NpmEco`, and arch allowlist `["amd64"]`. Verify with a new assertion in `test/Test/Policy.hs` modeled on the codex case: `lookupPolicy` returns that source, technique, and allowlist.
- [x] 1.2 Run the policy test group and confirm the new assertion passes and existing policy assertions still pass.
- [x] 1.3 Confirm README, CONTRIBUTING, and AGENTS need no edit: this change adds no work subcommand, config key, quality-pipeline step, or agent-process rule (`project-docs`).

## 2. Seed assets materialize

- [x] 2.1 In the materialize image container, mirror the registry-only npm cache steps for `@agentclientprotocol/claude-agent-acp@0.81.1`: `npm pack` into a work area with an empty userconfig, then `npm --cache <npm-cache> install` of that tarball with the same empty userconfig. Verify `npm-cache/` is populated, contains the `linux-x64` Claude CLI tarball, and has no `_logs/` entries.
- [x] 2.2 Pack `claude-agent-acp-0.81.1-deps.tar.xz` with top-level `npm-cache/`, excluding `npm-cache/_logs/` and `npm-cache/_update-notifier*`, using hermetic tar/xz (`XZ_OPT` containing `-T1` and `-9e`). Verify the file is an xz stream (`file` or `xz -t`).
- [x] 2.3 Compute `b3`, `sha256`, and `sha512` sidecars in the `dev-util/openspec` sidecar format. Verify the filenames are `claude-agent-acp-0.81.1-deps.tar.xz.{b3,sha256,sha512}`.

## 3. Assets release publish

- [x] 3.1 Write the sidecars under `dev-util/claude-agent-acp/` in the mndz-overlay-assets worktree. Verify `git status` shows only those paths.
- [x] 3.2 Publish release tag `claude-agent-acp-0.81.1` on mndz-overlay-assets with the deps tarball as the release asset. Verify the release lists that tarball.
- [x] 3.3 Operator: GPG-sign the assets commit of the sidecar files. Verify `git log --show-signature -1` in the assets repo shows a signed commit touching `dev-util/claude-agent-acp/`.

## 4. Overlay seed

- [x] 4.1 Write `dev-util/claude-agent-acp/claude-agent-acp-0.81.1.ebuild` from the rulesync shape: scoped registry `SRC_URI` renamed to `${P}.tgz`, assets deps `SRC_URI` parameterized by `${PV}`, `S=${WORKDIR}/package`, `LICENSE=Apache-2.0`, `KEYWORDS="-* ~amd64"`, `>=net-libs/nodejs-22[npm]`, `IUSE=test` only, `RESTRICT="!test? ( test )"`, `QA_PREBUILT` covering `usr/lib*/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude`, offline `src_install`, and `src_test` that checks `claude-agent-acp --version` prints the PV. Verify the ebuild has no completion USE flags, no `shell-completion` inherit, and does not install `/usr/bin/claude`.
- [x] 4.2 Write `dev-util/claude-agent-acp/metadata.xml` with GitHub remote-id `agentclientprotocol/claude-agent-acp`. Verify it matches the rulesync metadata.xml shape.
- [x] 4.3 Regenerate `Manifest` via `ebuild claude-agent-acp-0.81.1.ebuild manifest` with the manager private DISTDIR, and regenerate the package md5-cache. Verify `DIST` entries exist for `claude-agent-acp-0.81.1.tgz` and `claude-agent-acp-0.81.1-deps.tar.xz`, and that `metadata/md5-cache/dev-util/claude-agent-acp-0.81.1` exists.
- [x] 4.4 Operator: GPG-sign the overlay commit adding the package. Verify `git log --show-signature -1` in the overlay shows the signed commit.

## 5. Seed install and smoke

- [x] 5.1 Emerge `=dev-util/claude-agent-acp-0.81.1` with the test USE flag. Verify the build and `src_test` succeed offline from the deps cache.
- [x] 5.2 Run `claude-agent-acp --version` and confirm it exits 0 and prints `0.81.1`. Confirm `/usr/bin/claude-agent-acp` is the installed command.

## 6. Manager bump smoke

- [x] 6.1 Run `mndz-overlay-manager outdated claude-agent-acp --refresh` and verify it reports local `0.81.1` against the newest comparable upstream PV (`0.81.2` at capture; a later stable `latest` if one has been published) on an amd64 nodejs lane, with planned keywords `-* ~amd64`.
- [x] 6.2 Run `mndz-overlay-manager update claude-agent-acp --refresh` and verify the full-path unit: the deps tarball for that PV is published as release `claude-agent-acp-<PV>` with sidecars, the new ebuild keeps `QA_PREBUILT` and the `--version` test, the `0.81.1` ebuild is pruned, Manifest and md5-cache are regenerated, and the overlay and assets commits are GPG-signed.
- [x] 6.3 Emerge the bumped PV with the test USE flag and verify `claude-agent-acp --version` prints that PV.

## 7. Integration gate

- [x] 7.1 Run `hk check` and confirm it is green.
- [x] 7.2 Run `openspec validate add-dev-util-claude-agent-acp --type change --strict` and confirm zero issues. Confirm the living `npm-deps-assets` Purpose names `dev-util/claude-agent-acp` and that no delta-residue language ("in this change", "as today") is in the living specs.
