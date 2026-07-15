## Why

Go packages in the mndz overlay (`dolt`, `beads`, `crush`) cannot use the existing `GitMvAndManifest` path: each bump needs a `go-module.eclass` vendor (module-cache) tarball, checksum sidecars and a GitHub release on `mndz-overlay-assets`, then a real Portage fetch for Manifest. That work is still manual (Python helper + hand-published assets). Now that simple updates land via `update`, the next step is to automate the full Go path in Haskell so `update` can ship those packages end-to-end.

## What Changes

- Add update technique `GoVendorAndAssets` (with hardcoded per-package `go.mod` subdirectory) for `dev-db/dolt`, `dev-util/beads`, and `dev-util/crush`
- Automate: temp clone of upstream at the target tag → `go mod download` module cache → `tar`/`xz` vendor tarball → pure-Haskell multi-hash sidecars → signed commit + **push** in `mndz-overlay-assets` → GitHub **HTTP** release + asset upload → overlay ebuild rename/edit + `ebuild … manifest` → Manifest SHA512 verify against our sidecar → overlay signed commit (no auto-push of overlay)
- Extend config with optional `mndz-overlay-assets-path` and `github-token`; resolve GitHub token from env (`GITHUB_TOKEN` / `GH_TOKEN`) first, then config
- Lazy preflight: require `go`, `xz`, assets path, token, and SSH readiness only when selected packages will use assets techniques
- Spawn an SSH agent early when needed for assets `git push` (or reuse a usable existing agent); load keys from `~/.ssh/config` `IdentityFile` paths and default identities; prompt via `/dev/tty` or askpass; kill only an agent this process started
- Normalize assets `SRC_URI` to `${PV}` form; when PV is unchanged but the ebuild still needs that fix, bump revision (`-r1` / `-rN+1`) automatically (covers frozen dolt URLs)
- Shared assets plumbing (hash, repo commit/push, release) designed so npm/bun deps can reuse it later
- **BREAKING** (config/runtime): `update` of Go packages requires assets path + token + push/release success; missing deps fail when those packages are selected, not always on every command

## Capabilities

### New Capabilities

- `go-vendor-assets`: Clone upstream, build go-module vendor tarball, hash, publish to `mndz-overlay-assets` (git + GitHub release), verify via Manifest after Portage fetch, integrate as `GoVendorAndAssets` apply technique
- `assets-publish`: Shared assets-repo layout, checksum sidecars (basename only), signed commit, push, and GitHub Releases HTTP API (forward-compatible with non-Go tarballs)
- `github-auth`: Resolve GitHub API token from environment then config; use for release create/upload (and shared with existing GitHub version fetch)
- `ssh-agent-session`: Optional short-lived SSH agent for assets git push; key discovery from SSH config; TTY/askpass unlock; reuse existing agent when already usable

### Modified Capabilities

- `update-apply`: Extend technique model beyond `GitMvAndManifest` | `Unsupported`; policy entries for Go packages; parallel apply with serialized assets critical section; orphan-assets warning
- `update-command`: Conditional preflight tools (`go`, `xz`) and auth when assets techniques are in scope; hard-fail isolation for assets publish failures
- `overlay-path-resolution` / config loading: Optional `mndz-overlay-assets-path` and `github-token` keys; assets path validated only when required for selected work

## Impact

- **Code**: `Config.Types` / `Config.Loader`; `Update.Types`, `Update.Hardcoded`, `Update.Apply`, `Update.Preflight`, `Update.GitHub`; new modules for Go vendor, assets hash/repo/release, SSH agent session; `app/Main.hs` wiring
- **Deps**: pure crypto (`crypton` or equivalent + `blake3`), existing `http-client` for Releases API, `async` for package parallelism and assets lock
- **External**: local `mndz-overlay` and `mndz-overlay-assets` git worktrees; `go`, `tar`/`xz`, `git`, `ebuild`, `gpg`, SSH keys; GitHub PAT with release/contents write on assets repo
- **Repos**: fixtures for multi-key config; unit tests with injected git/HTTP/process runners (no live multi-hundred-MB downloads in default CI)
- **Non-goals**: overlay auto-push; npm/bun/cargo techniques (only shared assets seams); rewriting historical full-path hash files in assets git history; project-local clone cache
