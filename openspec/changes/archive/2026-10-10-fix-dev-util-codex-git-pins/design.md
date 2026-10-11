# Design

## Context

See proposal.md for why `0.160.1` and `0.162.0` failed. The codex ebuild body is template-owned: a DepsAndAssets Cargo bump runs pycargoebuild in place, which refreshes `GIT_CRATES`, then the manager rewrites `SRC_URI`, `KEYWORDS`, and `RUST_MIN_VER`. The Python block in `src_prepare` is copied forward with whatever commits it already contains.

`cargo.eclass` writes `[patch]` into `CARGO_HOME/config.toml`. On Cargo 1.97 that table does not satisfy a git dependency that the workspace manifest itself lists under `[patch.crates-io]`. It does satisfy git dependencies that are `GIT_CRATES` keys, including `rmcp`, `h3`, `h3-quinn`, `wxc_common`, `nucleo`, and `runfiles`. An offline `cargo tree` of `codex-cli` and `codex-code-mode-host` for `x86_64-unknown-linux-gnu` showed those crates on the unpacked checkouts without rewriting their manifest lines.

`learning_mode_windows` is a `cfg(windows)` dependency of `codex-mxc-sandbox` and is not a `GIT_CRATES` key. The same tree still tried to check out `https://github.com/microsoft/mxc` for it. `appcontainer_common` is already replaced with an empty stub for the same reason.

Overlay commit `50da8d5` (`dev-util/codex: 0.162.0`) is local only: `master` is ahead of `origin/master`, and no remote branch contains that commit. Installed Codex is `0.153.4`.

## Goals / Non-Goals

**Goals:**

- The three `[patch.crates-io]` rewrites read commit and checkout path from `GIT_CRATES` at prepare time.
- `learning_mode_windows` gets the same empty stub as `appcontainer_common`.
- The published ebuild is `codex-0.162.0-r1.ebuild`, amended into `50da8d5`.

**Non-Goals:**

- See proposal.md. In particular, do not drop the existing `nucleo` and `runfiles` rewrites, do not add stub crates to `GIT_CRATES`, and do not change the manager.

## Decisions

### Read the three commits from GIT_CRATES

Before the Python rewriter runs, bash looks up `crossterm`, `tokio-tungstenite`, and `tungstenite` in `GIT_CRATES`. Each value is `uri;commit;crate_dir` as `cargo.eclass` already documents. `%commit%` in `crate_dir` is replaced with that commit. The unpacked path is `${WORKDIR}/` plus that directory. Pass the three commits and paths into the existing Python block.

Python replaces every workspace-manifest line whose crate name and `rev` equal that pair. `tungstenite` has two such lines (the crates.io patch table and the `ssh://` patch table); both go to the same path. Die if the associative-array entry is missing, if the value does not yield a commit and directory, if the manifest contains no matching line, or if that checkout's `Cargo.toml` is absent. Delete the hardcoded `45fecb…` crossterm string and the matching `[[ -f ]]` path. Keep the other existence checks (`nucleo`, `runfiles`, `rusty_v8`, and the two tungstenite-family checkouts) but point the three patch-table checks at the derived paths so they cannot drift from the rewrite.

Alternative considered: paste `ed1cdab…` into the literal. That fixes only `0.162.0` and repeats this outage on the next crossterm bump. Rejected.

Alternative considered: walk every `Cargo.toml` and path-rewrite every `git =` line that matches `GIT_CRATES`. The spike showed that is unnecessary for crates the eclass patch already covers, and it would fight the two stubs. Rejected.

### Stub learning_mode_windows

Create `${WORKDIR}/learning_mode_windows_stub` the same way as `appcontainer_common_stub`: package name `learning_mode_windows`, version `0.8.0`, edition `2021`, empty `src/lib.rs`. Rewrite the workspace line

`learning_mode_windows = { git = "https://github.com/microsoft/mxc", rev = "6cd3d58f05d3447e67109cfb75e042803b843ca4" }`

to that path. Leave the real tree at `mxc-…/src/backends/learning_mode/windows` unused. That manifest uses `version.workspace` and depends on `learning_mode_core`, so pointing at it pulls more of the mxc graph into the resolve. The empty stub is what `cargo tree` accepted for `0.162.0`.

The mxc rev stays a literal on these two stub lines. Those crates are deliberately absent from `GIT_CRATES`, so there is no entry to read. A missing line dies, same as today for `appcontainer_common`.

### Amend the unmerged bump to -r1

Rename `codex-0.162.0.ebuild` to `codex-0.162.0-r1.ebuild` in the overlay. Replace `metadata/md5-cache/dev-util/codex-0.162.0` with the cache entry for `codex-0.162.0-r1`. Thin manifests do not gain a DIST change. Amend those path changes into `50da8d5` rather than adding a second commit. The operator does the amend; implementation prepares the tree.

Nothing has emerged `0.162.0`, so a follow-up commit that leaves the unrevisioned ebuild in history is the worse record. The commit is not on a remote.

## Risks / Trade-offs

- [Cargo changes the `[patch.crates-io]` line shape, for example `branch` instead of `rev`, or a multiline table] → `src_prepare` dies with the missing-snippet error. That is the signal to update the matcher. No silent skip.
- [A later lock requires a `learning_mode_windows` version other than `0.8.0`] → resolve fails after prepare. The `0.162.0` tree accepted `0.8.0`. Adjust the stub version if Cargo reports a mismatch; do not switch to the real mxc crate unless the stub cannot satisfy the dependency.
- [The offline tree resolve did not compile rusty_v8 or run protoc] → those paths are unchanged from the ebuild that produced installed `0.153.4`. Acceptance is still an emerge of `=dev-util/codex-0.162.0-r1` once `/var/tmp` has 20 GiB free. The operator runs emerge; the agent shell cannot sudo.
- [Leaving `nucleo` and `runfiles` as extra path rewrites] → two more literals that can rot if those commits move. They match `0.162.0` today, and this revision does not take on a second generator for them.

## Migration Plan

1. Edit and rename the ebuild, refresh the md5-cache entry, amend `50da8d5`.
2. Remove the stale `/var/tmp/portage/dev-util/codex-0.160.1-*` work tree (about 6.4 GiB) so the 20 GiB disk check can pass.
3. Emerge `=dev-util/codex-0.162.0-r1::mndz`. `codex --version` should report `0.162.0`.
4. Rollback is resetting the amended commit back to the current `50da8d5` tree, which is still unpublished.

## Open Questions

None. The commit set, the stub, and the `-r1` amend are decided.
