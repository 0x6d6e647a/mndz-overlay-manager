## 1. Assets identity

- [x] 1.1 Add pin-keyed rusty-v8 layout helpers (sidecars under `rusty-v8/`, tag/name `rusty-v8-${ver}`, commit `rusty-v8: ${ver}`) without `{category}/{package}`; verify unit tests for basename, tag, name, sidecar paths, and that overlay packages still use `dev-util/hk/`-style paths
- [x] 1.2 Pass `target_commitish` as the assets commit SHA that added the sidecars (not hardcoded `"main"`); verify a test or fake that a later HEAD does not receive the new tag

## 2. Harvest clone and DEPS parse

- [x] 2.1 Add a recursive-submodule clone (`git clone --recurse-submodules --depth 1 --branch v${ver}`) and wire it as production `cloneFn` for `harvestRustyV8Snapshot`; verify the existing reuse-vs-clone test still skips clone on reuse and that the production argv includes `--recurse-submodules`
- [x] 2.2 Parse `v8/DEPS` GCS blocks without `exec`: unique `Linux_x64/` objects with `condition` exactly `host_os == "linux"` and prefixes `clang-llvmorg-` / `rust-toolchain-`; verify a 150.4.0 DEPS excerpt fixture yields `clang-llvmorg-23-init-10931-g20b6ec66-11.tar.xz` and `rust-toolchain-4c4205163abcbd08948b3efab796c543ba1ea687-4-llvmorg-23-init-10931-g20b6ec66.tar.xz`, and that tidy/objdump objects and missing/duplicate keep-sets fail

## 3. Codex apply path

- [x] 3.1 Gate rusty_v8 harvest on `PackageKey` `dev-util/codex` only; verify hk/mise/usage/biodiff full-path tests do not clone rusty_v8 or require a rusty-v8 release
- [x] 3.2 After the Codex lock exists, parse the `v8` pin, look up worktree checksums **and** GitHub tag `rusty-v8-${ver}`, reuse when both verify, otherwise harvest+publish as a second complete cycle after crates; verify same-pin does not clone and still publishes `{pn}-{pv}-crates.tar.xz`, and missing pin harvests `rusty-v8-${ver}-with-submodules.tar.xz` on tag `rusty-v8-${ver}`
- [x] 3.3 Keep Codex crates `requiredAssetBasenames` as `{pn}-{pv}-crates.tar.xz` only; verify a crates tag without a rusty-v8 asset is not classified partial, and a missing rusty-v8 snapshot does not hard-fail solely because the crates tag exists
- [x] 3.4 Write `RUSTY_V8_VER` and rusty-v8 `SRC_URI` from the lock pin; on pin change write `CLANG_DIST`/`RUST_TC_DIST` from DEPS (or from `v8/DEPS` extracted from a verified snapshot tarball on retry); on same pin copy donor GCS lines; verify parameterization still does not rewrite rusty-v8 tags to `codex-${PV}`

## 4. Specs and docs

- [x] 4.1 Merge delta specs into living SoT (`cargo-crates-assets`, `assets-publish`, `dev-util-codex-seed`) and scrub delta residue; verify `openspec validate --strict`
- [x] 4.2 Confirm README/CONTRIBUTING/AGENTS need no updates (no operator CLI/config, quality pipeline, or agent-process change) and record that in archive notes when archiving

## 5. Assets repo cleanup (mndz-overlay-assets)

- [x] 5.1 Force-move git tag `codex-0.153.3` to commit `d4aed56` and push; verify `git rev-parse codex-0.153.3` is `d4aed56` and the GitHub release for that tag follows
- [x] 5.2 PATCH GitHub release title `dev-util/rusty-v8-150.4.0` → `rusty-v8-150.4.0` (tag unchanged); verify the release name is `rusty-v8-150.4.0` and SRC_URI still uses tag `rusty-v8-150.4.0`
- [x] 5.3 `git mv dev-util/rusty-v8 rusty-v8`, commit `rusty-v8: 150.4.0`, GPG-sign and push; verify sidecars exist under `rusty-v8/` and `dev-util/codex/` crates sidecars are untouched
- [x] 5.4 Confirm overlay `dev-util/codex` ebuild text and distfile URLs are unchanged so no `-rN` is required; verify no new overlay commit is needed for this cleanup

## 6. Quality gate

- [x] 6.1 `hk check` green over the manager change (build, tests, ormolu, hlint, stan, weeder)
