## 1. Config and auth foundation

- [x] 1.1 Extend `Config.Types` / `Config.Loader` with optional `mndz-overlay-assets-path` and `github-token`; update fixtures and decode tests
- [x] 1.2 Implement GitHub token resolver (env `GITHUB_TOKEN` / `GH_TOKEN` then config); wire into `Update.GitHub` fetch path; never log raw token
- [x] 1.3 Export config values through Main/spine so update can read assets path and token

## 2. Types, policy, and preflight

- [x] 2.1 Extend `UpdateTechnique` with `GoVendorAndAssets { goModSubdir :: Maybe FilePath }`
- [x] 2.2 Change hardcoded policy for `dev-db/dolt`, `dev-util/beads`, `dev-util/crush` to `GoVendorAndAssets` with correct subdirs; keep npm/cargo packages `Unsupported`
- [x] 2.3 Extend preflight: always `git`/`ebuild`/`gpg`; conditionally `go`/`xz` when selected packages need Go technique
- [x] 2.4 Validate assets path (set, exists, git worktree) and token presence only when Go/assets apply is in scope
- [x] 2.5 Update unit tests for policy classification and conditional preflight

## 3. Pure hashing and assets layout

- [x] 3.1 Add library dependencies for SHA-256/SHA-512 and BLAKE3 (`crypton`/`blake3` or equivalent)
- [x] 3.2 Implement single-pass multi-hash and sidecar writers (basename-only `hex  name` lines)
- [x] 3.3 Implement assets path layout helpers `{category}/{package}/{distfile}.{sha256,sha512,b3}`
- [x] 3.4 Unit tests for hash digests on known bytes and sidecar formatting

## 4. Assets repo commit, push, and release API

- [x] 4.1 Extend git ops (or assets-specific ops) for signed commit + `git push` against assets worktree with injectable interface for tests
- [x] 4.2 Implement GitHub Releases HTTP create + asset upload using resolved token and `http-client`
- [x] 4.3 Release metadata: tag `{pn}-{pv}`, name `{cat}/{pn}-{pv}`, body `{cat}/{pn}: {pv}`
- [x] 4.4 Best-effort cleanup if release create succeeds but asset upload fails
- [x] 4.5 Unit/integration tests with mocked HTTP for release create/upload

## 5. SSH agent session

- [x] 5.1 Implement SSH agent session: reuse usable existing agent, else spawn + load keys, track ownership
- [x] 5.2 Ensure assets `git push` children inherit agent env; teardown only owned agent on exit
- [x] 5.3 Skip SSH setup when no assets push is required
- [x] 5.4 Tests with injected process runners for agent lifecycle
- [x] 5.5 Discover keys from `~/.ssh/config` IdentityFile + default id_* paths; pass explicitly to ssh-add
- [x] 5.6 Passphrase via /dev/tty or SSH_ASKPASS (e.g. ksshaskpass); clear errors when neither works

## 6. Go vendor construction

- [x] 6.1 Implement temp-dir shallow clone at `prefix <> pv` tag for GitHub sources
- [x] 6.2 Implement `go mod download -modcacherw` with `GOMODCACHE=go-mod` in go.mod directory
- [x] 6.3 Implement `XZ_OPT=-T0 -9 tar -acf {pn}-{pv}-vendor.tar.xz go-mod` and cleanup temp clone
- [x] 6.4 Injectable process interface so tests do not run real `go`/network

## 7. Ebuild SRC_URI rewrite and apply orchestration

- [x] 7.1 Implement ebuild text rewrite so assets `SRC_URI` uses `${PV}` (and related parameterization); cover dolt frozen URL case
- [x] 7.2 Implement same-PV revision bump (`-r1` / `-rN+1`) when fix needed without upstream PV change
- [x] 7.3 Wire `GoVendorAndAssets` apply: build → hash → assets critical section (commit/push/release) → overlay dirty check → write/rename ebuild → `ebuild manifest` → Manifest SHA512 verify
- [x] 7.4 Global lock for assets critical section; keep phase-1 parallel for builds and GitMv packages
- [x] 7.5 Orphan-assets warning on overlay/hash failures after successful publish; no overlay mutate if publish fails
- [x] 7.6 Parse Manifest DIST SHA512 for vendor tarball and compare to generated sidecar
- [x] 7.7 Phase-2 overlay signed commits unchanged for successful Go applies (paths include old/new ebuild + Manifest)

## 8. CLI spine integration

- [x] 8.1 Main/`update` spine: detect whether assets/Go apply is needed for selected targets; run conditional preflight and SSH session setup
- [x] 8.2 Pass assets root, token, locks, and runners into apply
- [x] 8.3 Ensure soft-skip no longer treats Go packages as unsupported; hard-fail isolation for siblings
- [x] 8.4 Update help/docs snippets only if required by existing CLI help specs (keep concise)

## 9. Quality gates and weeder

- [x] 9.1 Export new modules in cabal; update `weeder.toml` roots if needed
- [x] 9.2 `hk fix` / format; `cabal test all`; resolve hlint/stan/weeder
- [x] 9.3 `hk check` green

## 10. Manual smoke (optional, outside CI)

- [ ] 10.1 Dry-run or real smoke: `update` one Go package against local overlay + assets with token and SSH (operator machine)
- [ ] 10.2 Confirm dolt SRC_URI normalization path (`-r1` or newer PV) and release appears on GitHub

## 11. Spec / follow-up hygiene (this change)

- [x] 11.1 Spec assets SRC_URI full path + `${PV}` parameterization (Portage expands to concrete release URL)
- [x] 11.2 Document SRC_URI intercalate regression and fix in design
- [x] 11.3 Record follow-ups F1 resume, F2 Go toolchain, F3 `--force` dirty in design + FOLLOWUPS.md for a later OpenSpec session
