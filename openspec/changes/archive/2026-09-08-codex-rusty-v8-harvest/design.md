## Context

See `proposal.md` for motivation. `harvestRustyV8Snapshot`, `parseV8RegistryPin`, `rustyV8ReleaseTag`, and `rustyV8SnapshotBasename` already exist and are unit-tested with an injected clone. `applyDepsAndAssets` never calls them: `requiredAssetBasenames` is crates-only (plus opencode models), `materializeCompanionAssets` only knows opencode, and `gitCloneTag` is shallow without `--recurse-submodules`. Seed published a fake overlay atom (`dev-util/rusty-v8/`, GitHub title `dev-util/rusty-v8-150.4.0`). Tag `codex-0.153.3` points at the rusty-v8 sidecar commit (`cfd53b4`) because GitHub create used `target_commitish = "main"` after both seed commits. Codex ebuild already downloads `rusty-v8-${RUSTY_V8_VER}` and hardcodes GCS names that round-trip `v8/DEPS` at rusty_v8 `v150.4.0`.

## Goals / Non-Goals

**Goals:**

- Call harvest from Codex full-path apply with recursive clone, pin-keyed publish, and `RUSTY_V8_VER` / SRC_URI write.
- Parse `v8/DEPS` GCS Linux_x64 objects on pin change; copy donor GCS lines on same pin.
- Layout/release helpers that do not invent `{category}/{package}` for rusty-v8.
- Two complete publish cycles (or explicit sidecar `target_commitish`) so tags match sidecar commits.
- Relocate existing 150.4.0 metadata without a new tarball.

**Non-Goals:**

- System clang/rustc instead of Chromium GCS.
- Attaching the snapshot to `codex-${PV}`.
- Harvest for any package except `dev-util/codex`.
- Rewriting `cfd53b4`’s commit message.

## Decisions

1. **Codex-only gate on `PackageKey`, not on “lock has v8”.** Alternative: any Cargo GitTag with a `v8` pin (archived spec) — rejected until a second consumer exists; hk must stay out even if a future lock grew `v8`. Alternative: denylist hk/mise/usage/biodiff — rejected; a new Cargo GitTag would silently harvest.

2. **Independent tag `rusty-v8-${ver}`, not a Codex release asset.** Alternative: extra asset on `codex-${originPV}` — rejected: `parameterizeAssetsSrcUri` rewrites any `codex-` tag to `codex-${PV}`; required-asset sets become PV-dependent; existing crates tags are immutable. Keep the current SRC_URI shape.

3. **Assets path `rusty-v8/` at repo root.** Alternative: `dev-util/rusty-v8/` — rejected (fake atom). Alternative: `third-party/rusty-v8/` — extra prefix, no benefit. Commit `rusty-v8: ${ver}`; GitHub name equals tag.

4. **Lookup both oracles.** Reuse only when worktree `rusty-v8/${basename}.{sha256,sha512,b3}` exist **and** GitHub tag `rusty-v8-${ver}` has that asset, and bytes match. Alternative: GitHub-only — flakes and ignores the assets git SoT. Alternative: worktree-only — Portage downloads GitHub.

5. **Recursive clone helper, not `gitCloneTag`.** `git clone --recurse-submodules --depth 1 --branch v${ver}`. Without recurse, `v8/DEPS` and ICU/rust submodules are missing and parse/pack fail closed. `harvestRustyV8Snapshot` stays; production cloneFn becomes the recursive helper.

6. **Two publish cycles when harvest runs.** Crates: existing `dev-util/codex` spine, `target_commitish` = that commit SHA (or complete cycle before rusty-v8 starts). Then rusty-v8 identity. Alternative: batch two GitHub releases after both commits — reproduces the `codex-0.153.3` tag-on-wrong-commit bug. Prefer passing the just-created commit SHA as `target_commitish` even for overlay packages.

7. **`RUSTY_V8_VER` is manager-owned from `parseV8RegistryPin`.** Harvest without this write publishes a tarball the ebuild does not fetch. `parameterizeAssetsSrcUri` already skips tags that do not start with `{pn}-`; keep the unit test that Codex does not retag rusty-v8 as `codex-${PV}`.

8. **GCS parse scans `v8/DEPS`; does not `exec` it; does not read `update.py`.** Brace-scan GCS blocks `'third_party/llvm-build/Release+Asserts'` and `'third_party/rust-toolchain'`; keep unique `Linux_x64/` objects with `condition` exactly `host_os == "linux"` and prefixes `clang-llvmorg-` / `rust-toolchain-`. Golden fixture: 150.4.0 names in the seed ebuild. `update.py` matches clang only. Same pin: copy donor; do not clone to re-parse. Pin change with existing snapshot (retry): extract `v8/DEPS` from the verified tarball. Fail closed on 0 or >1 keep-set match or non-GCS dep type.

9. **Historical cleanup is tag/title/`git mv`, not rebase.** Force-move `codex-0.153.3` → `d4aed56`; PATCH GitHub name; `git mv dev-util/rusty-v8 rusty-v8` with commit `rusty-v8: 150.4.0`. Operator rewords `cfd53b4` off-book. No overlay `-rN` (SRC_URI tag unchanged).

## Risks / Trade-offs

- [DEPS format moves to CIPD or drops exact `host_os == "linux"`] → hard-fail; do not guess filenames. Fixture test is the canary.
- [Clone without recurse] → parse and emerge fail; production cloneFn must recurse; unit tests inject a tree that contains `v8/DEPS`.
- [Two cycles lengthen Codex full-path] → only when the pin is new; same-pin skips clone and rusty-v8 publish (~1.1 GiB saved).
- [Worktree hashes exist but GitHub asset missing] → not reuse; harvest would try to create tag `rusty-v8-${ver}` that may already exist empty — hard-fail with operator repair, do not upload onto a pre-existing tag (assets-publish immutability).
- [Same-pin copies a hand-edited wrong GCS line] → accepted; next pin change re-parses.
- [Cleanup `git mv` while manager still writes `dev-util/rusty-v8/`] → order: manager layout change before or with the mv; do not harvest 150.5.0 into the old directory.

## Migration Plan

1. Implement layout exception, recursive clone, Codex apply harvest, DEPS parser, `RUSTY_V8_VER`/GCS write; `hk check`.
2. Merge spec deltas into living SoT (`cargo-crates-assets`, `assets-publish`, `dev-util-codex-seed`).
3. Assets cleanup: move `codex-0.153.3` tag; PATCH release title; `git mv` sidecars; commit `rusty-v8: 150.4.0`.
4. Confirm overlay ebuild SRC_URI still hits tag `rusty-v8-150.4.0` (no `-rN`).
5. Rollback: revert manager harvest gate (Codex falls back to preserving extras); assets dir/title can stay relocated because SRC_URI never used `dev-util/` in the tag.

## Open Questions

None. Spike closed GCS parse; remaining identity/scope questions are decided in this document.
