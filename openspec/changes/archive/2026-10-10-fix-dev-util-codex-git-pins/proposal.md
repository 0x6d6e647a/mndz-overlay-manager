# Proposal

## Why

`dev-util/codex-0.160.1` and `dev-util/codex-0.162.0` die in `src_prepare` because the template still rewrites crossterm at rev `45fecb…` from the 0.153.4 body, while each bump's `GIT_CRATES` entry has moved. Cargo 1.97 also still fetches `learning_mode_windows` when resolving the Linux `codex` bin, and that crate is absent from `GIT_CRATES`.

## What Changes

- Publish the fix as `dev-util/codex-0.162.0-r1` by amending the existing `0.162.0` overlay bump. `0.160.1` and `0.162.0` never merged; installed Codex stays `0.153.4` until this revision emerges.
- In the template-owned `src_prepare`, take the commit for the explicit `[patch.crates-io]` set (`crossterm`, `tokio-tungstenite`, `tungstenite`) from that ebuild's `GIT_CRATES` entry and rewrite each matching manifest line to the unpacked path. Die when a listed crate is missing from `GIT_CRATES` or the manifest has no matching `git`/`rev` line.
- Stub `learning_mode_windows` the same way `appcontainer_common` is already stubbed. Do not add it to `GIT_CRATES`.

## Non-goals

- No mndz-overlay-manager Haskell, asset, or `SRC_URI` change. pycargoebuild already refreshes `GIT_CRATES` on bump.
- No change to `CHECKREQS_DISK_BUILD` or `CHECKREQS_MEMORY`. The `0.162.0` pretend failure was a 32 GiB `/var/tmp` tmpfs with 19.59 GiB free.
- No revival of the pruned `0.160.1` ebuild.
- No removal of the existing `nucleo` and `runfiles` path rewrites. On Cargo 1.97 they are redundant with `cargo.eclass` `[patch]` and they already match upstream.
- No new `GIT_CRATES` entries for `appcontainer_common` or `learning_mode_windows`.
- No README, CONTRIBUTING, or AGENTS edit. Operator CLI and the quality pipeline are unchanged.

## Capabilities

### New Capabilities

### Modified Capabilities

- `dev-util-codex-seed`: The template-owned `src_prepare` git rewrite for the explicit `[patch.crates-io]` set takes commits from `GIT_CRATES`, and Windows-only workspace git deps that Cargo still resolves on Linux (`appcontainer_common`, `learning_mode_windows`) stay stubs outside `GIT_CRATES`.

## Impact

- Overlay `dev-util/codex`: replace `codex-0.162.0.ebuild` with `codex-0.162.0-r1.ebuild` inside the existing bump commit, and refresh `metadata/md5-cache` for that revision. Thin manifests keep the current DIST lines.
- No new distfiles. The crossterm checkout `crossterm-ed1cdab335221515706178d68495bba2aed1924f` is already the `GIT_CRATES` tarball.
- Hosts still need at least 20 GiB free on `PORTAGE_TMPDIR` before emerge. The stale `codex-0.160.1` work tree is about 6.4 GiB on this machine.
