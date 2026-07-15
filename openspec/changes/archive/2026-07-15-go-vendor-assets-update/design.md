## Context

`update` already applies `GitMvAndManifest` for simple binary packages (rename + `ebuild … manifest` + isolated GPG-signed overlay commits). Go packages (`dev-db/dolt`, `dev-util/beads`, `dev-util/crush`) are marked `Unsupported` because each bump requires:

1. A go-module.eclass **module-cache** tarball (`go mod download` into `go-mod/`, then `tar`/`xz` with top-level `go-mod/`)
2. Checksum sidecars and a signed commit in **mndz-overlay-assets** (hashes only; not the tarball)
3. A GitHub **release** on that repo with tag `{pn}-{pv}` and the tarball as the asset
4. Overlay ebuild bump whose `SRC_URI` points at that release, then Manifest via real Portage fetch

Today a Python script (`go-make-vendor-tarball.py`) covers only step 1; the rest is manual. Exploration locked full automation in Haskell, dual-repo orchestration, lazy preflight, and verification by comparing Manifest SHA512 to our sidecar after download.

Constraints: project quality gates (`hk check`); shell-out for `go`/`git`/`tar`/`ebuild` is acceptable; pure Haskell for multi-hash; no ambient global tool install for quality tools (unrelated); GPG option B (agent/pinentry only); overlay auto-push remains out of scope.

## Goals / Non-Goals

**Goals:**

- `GoVendorAndAssets` technique for the three Go packages with hardcoded `go.mod` subdir
- End-to-end: temp clone → vendor tarball → hash → assets commit/push/release → overlay apply + Manifest SHA512 verify → overlay signed commit
- Config: `mndz-overlay-assets-path`, `github-token`; token also from env
- Lazy validation/preflight only when assets techniques will run
- SSH agent session for assets push (spawn + early `ssh-add` when needed)
- Shared assets layer reusable by future npm/bun techniques
- Automated SRC_URI `${PV}` normalization and same-PV revision bump when needed (dolt)

**Non-Goals:**

- Overlay remote push / build-test automation (later)
- npm, bun, or cargo techniques (only shared assets seams)
- Project-local clone/tarball cache
- Rewriting historical full-path lines in existing assets hash files (separate rebase session)
- DISTDIR seeding to skip download (we want Portage to fetch for integrity)
- Pure-Haskell Manifest generation
- Config-file package policy maps (hardcoded policy remains)

## Decisions

**Decision: Technique model extension**

```text
UpdateTechnique
  = GitMvAndManifest
  | GoVendorAndAssets { goModSubdir :: Maybe FilePath }
  | Unsupported Text
```

| Package | Technique |
|---------|-----------|
| dolt | `GoVendorAndAssets (Just "go")` |
| beads, crush | `GoVendorAndAssets Nothing` |
| openspec, ralph-tui, cargo pkgs | still `Unsupported` |
| bin packages | unchanged `GitMvAndManifest` |

Alternatives: infer `go.mod` path — rejected (wild variance; policy already hardcoded).

**Decision: Pipeline phases**

```text
spine → optional SSH agent setup → phase 1 (parallel packages) → phase 2 (serial overlay commits)
```

Within phase 1 for `GoVendorAndAssets`:

1. Fetch/compare remote PV (same as today)
2. If same PV and ebuild already has parameterized assets SRC_URI → soft-skip
3. If same PV but SRC_URI needs fix → plan revision bump (`-rN+1`); still rebuild/publish vendor for that PV so Manifest stays consistent, **or** only rewrite + manifest if vendor release already exists — **prefer always rebuild+publish for the target PV filename when applying**, except pure soft-skip when already correct and up to date
4. Temp dir: `git clone --depth 1 --branch <tag>` from `https://github.com/{owner}/{repo}.git` (tag = policy prefix + PV, e.g. `v2.1.6`)
5. `cd` to go.mod dir; `GOMODCACHE=$PWD/go-mod go mod download -modcacherw`
6. `XZ_OPT=-T0 -9 tar -acf {pn}-{pv}-vendor.tar.xz go-mod`
7. Single-pass multi-hash (SHA-256, SHA-512, BLAKE3) → write  
   `{assets}/{cat}/{pkg}/{tarball}.{sha256,sha512,b3}` with **basename-only** lines
8. **Assets critical section** (global lock): signed commit in assets repo → `git push` → HTTP create release + upload asset  
   - On failure: package hard-fail; **no** overlay mutation
9. Overlay: dirty check → write/rename ebuild (PV or -rN; ensure `${PV}` SRC_URI) → `ebuild … manifest` (real download)
10. Parse Manifest SHA512 for vendor DIST; compare to our `.sha512`; mismatch → hard-fail + warn assets published
11. Collect overlay paths for phase 2 commit

`GitMvAndManifest` packages continue without the assets lock.

**Decision: Parallel package work; serialize only assets git/push/release**

Use `mapConcurrently` (or equivalent) for phase 1. Protect assets repo mutations with an `MVar`/`QSem` critical section. Large parallel `go mod download` is accepted.

Alternatives: fully serial Go packages — rejected by product preference.

**Decision: Assets publish before overlay mutate**

Portage must fetch the release URL during `ebuild manifest`. Publish first. Do not seed DISTDIR.

**Decision: Naming conventions (locked to existing releases)**

| Artifact | Pattern | Example |
|----------|---------|---------|
| Tarball | `{pn}-{pv}-vendor.tar.xz` | `crush-0.76.0-vendor.tar.xz` |
| Release tag | `{pn}-{pv}` | `crush-0.76.0` |
| Release name | `{category}/{pn}-{pv}` | `dev-util/crush-0.76.0` |
| Release body / commit msgs | `{category}/{pn}: {pv}` | `dev-util/crush: 0.76.0` |
| Assets paths | `{category}/{pn}/{tarball}.{b3,sha256,sha512}` | |

Historical assets commits without colon stay as-is; new commits use colon style.

**Decision: Pure Haskell single-pass multi-hash**

Stream the tarball once; update SHA-256, SHA-512, and BLAKE3 digesters. Libraries: `crypton` (or sha packages) + `blake3`. Sidecar format: `{hex}  {basename}` (two spaces). No shell-out to `*sum`.

**Decision: Manifest verification uses SHA512**

Portage Manifest `DIST` lines include SHA512 matching our sidecars today. After manifest, parse vendor distfile SHA512 and compare (case-insensitive hex). Optionally compare size. BLAKE2B in Manifest is Portage-internal; `.b3` sidecars are operator provenance (BLAKE3-256).

**Decision: Config keys**

```toml
mndz-overlay-path = "…"              # required (existing)
mndz-overlay-assets-path = "…"       # optional until assets technique selected
github-token = "…"                   # optional until GitHub write/read needs it
```

- `mndz-overlay-path` still required for all non-help commands
- Assets path: required only when a selected package will attempt an assets technique apply
- Token resolution: non-empty `GITHUB_TOKEN` or `GH_TOKEN` env **overrides** config `github-token`
- Same resolved token used for Releases API and existing GitHub version fetch when present

**Decision: Lazy preflight**

| Scope | Tools / deps |
|-------|----------------|
| Always on `update` | `git`, `ebuild`, `gpg` |
| If any selected package will use `GoVendorAndAssets` (outdated or same-PV fix) | + `go`, `xz` (or `tar` that needs xz), assets path exists + is git worktree, GitHub token present, SSH session ready for push |

Up-to-date Go packages that need no fix do not force assets path.

**Decision: SSH agent session for assets push**

- Prefer existing reachable `SSH_AUTH_SOCK` when it already has identities
- If agent is empty but reachable: load keys into it; if sock is stale/unreachable: start a new agent
- Else spawn `ssh-agent` at spine (when assets techniques are in scope), export `SSH_AUTH_SOCK` / `SSH_AGENT_PID` for child `git push`
- **Key discovery**: parse `IdentityFile` from `~/.ssh/config` (tilde-expand) plus existing default `~/.ssh/id_*` files; pass those paths explicitly to `ssh-add`. Bare `ssh-add` with no args is insufficient when keys live only under custom paths (e.g. `~/.ssh/keys/shanty_github_id`)
- **Passphrase prompt**: prefer `/dev/tty` attached to `ssh-add` stdin; fall back to `SSH_ASKPASS` / `ksshaskpass` with `SSH_ASKPASS_REQUIRE=force` when no usable TTY
- On process exit: kill agent **only if we started it**
- Do not rewrite remotes to HTTPS; use worktree’s configured remote (SSH preferred)
- Token is **not** used for git push when remote is SSH
- Operator does **not** need to manually start `ssh-agent` for the normal path

**Decision: GitHub Releases via HTTP API (not `gh` CLI)**

- `POST /repos/{owner}/{repo}/releases` with tag, name, body, `target_commitish` (typically `main` after push)
- Upload asset to `upload_url` with appropriate `Content-Type` (e.g. `application/x-xz`)
- Owner/repo for assets repo: parse from `git remote get-url origin` or hardcode `0x6d6e647a/mndz-overlay-assets` with override later if needed — **prefer parse remote** with fallback constant

**Decision: SRC_URI normalization + revision bump**

When applying Go technique, ensure assets SRC_URI uses the **full** release download URL with `${PV}`:

```text
https://github.com/0x6d6e647a/mndz-overlay-assets/releases/download/{pn}-${PV}/{pn}-${PV}-vendor.tar.xz
```

Portage expands `${PV}` at fetch time (e.g. `dolt` + `2.1.11` →  
`…/download/dolt-2.1.11/dolt-2.1.11-vendor.tar.xz`). Upstream source archive URLs continue to use `${PV}` as today.

Rewrite must **rejoin** split path parts with `T.intercalate` on `(prefix : rewrittenSegs)` so the `mndz-overlay-assets/releases/download/` segment is never dropped (singleton intercalate bug produced `https://github.com/0x6d6e647a/dolt-${PV}/…` and broke `ebuild manifest` despite a valid GitHub release).

If remote PV equals local PV but content must change → new filename `{pn}-{pv}-rN.ebuild` with N = previous rev+1 (or 1). If remote PV newer → new PV filename without inventing revision, with fixed SRC_URI content written (not only rename when content must change).

Implementation: for Go packages, prefer read ebuild → rewrite → write to new path → delete/rename old, rather than blind filesystem rename-only when content differs.

**Decision: Failure isolation and warnings**

- Assets commit/push/release failure → hard-fail package; no overlay mutation; siblings continue
- Overlay fail after successful assets publish → hard-fail + **warning** that assets were published and overlay was not fully updated
- Best-effort: if release create succeeds and asset upload fails, attempt delete empty release; still hard-fail package
- Phase 2 overlay commit failures unchanged (half-applied warning)

**Decision: Module layout**

| Module | Role |
|--------|------|
| `Config.Types` / `Loader` | assets path + token |
| `Update.Types` | technique + opts |
| `Update.Hardcoded` | Go policy entries |
| `Update.GitHub` | token resolver; release create/upload helpers (or `Update.Assets.Release`) |
| `Update.Go.Vendor` | clone, download, tar |
| `Update.Assets.Hash` | multi-hash + sidecar write |
| `Update.Assets.Repo` | path layout, commit, push (injectable) |
| `Update.Assets.Release` | HTTP release + upload |
| `Update.SshAgent` | session lifecycle |
| `Update.Apply` | dispatch + orchestration + lock |
| `Update.Preflight` | conditional tools |
| `Update.EbuildEdit` (optional) | SRC_URI rewrite helpers |

**Decision: Test strategy**

- Unit: hash known bytes; sidecar format; SRC_URI rewrite; token precedence; technique policy
- Inject: fake `GitOps`, fake release HTTP, fake process runner for go/tar/clone
- No multi-hundred-MB network in default `cabal test`
- Manual smoke on real overlay/assets outside CI

**Decision: Dependencies**

Add `crypton` (or minimal sha libs) and `blake3` to library `build-depends`. Keep process/http-client/async.

## Risks / Trade-offs

- [Parallel multi-GB Go vendor builds] → Accept disk/network pressure; temp dirs isolated per package; document operator machine expectations
- [Assets git races] → Global critical section around commit/push/release
- [Orphan GitHub releases if overlay fails after publish] → Warning + leave release (useful for retry); do not auto-delete successful full releases
- [Partial release (tag without asset)] → Best-effort delete; hard-fail package
- [SSH agent kill races if user nested agents] → Only kill agent PID we spawned; reuse existing sock when it has identities  
- [Bare ssh-add finds no keys / no passphrase prompt] → Discover IdentityFile + defaults; prompt via /dev/tty or SSH_ASKPASS  
- [No TTY under some runners] → Askpass fallback (ksshaskpass); clear error if neither works
- [Token in TOML accidental commit] → Document; never log token; env override for one-offs
- [gpg-agent + ssh-add double prompt] → Both early/spine-ish; commit storm keeps gpg warm
- [dolt frozen SRC_URI] → Automated rewrite + -rN; covered by ebuild edit path
- [go/xz missing only for Go targets] → Lazy preflight; GitMv-only updates stay light
- [Release exists already for tag] → Hard-fail today; **resume/skip-if-exists** is a follow-up (see below)
- [SRC_URI intercalate drops assets path] → Fixed: rejoin with full `intercalate marker (prefix : segs)`; regression tests required

## Migration Plan

1. Implement behind existing `update` command; no new subcommand required
2. Operators add `mndz-overlay-assets-path` and `github-token` (or env) to config when ready to update Go packages
3. Ensure assets worktree clean enough for new sidecar paths; SSH remote push works
4. First dolt run may produce `2.1.6-r1` (SRC_URI fix) or jump to newer PV with fixed URLs
5. Rollback: leave code unused by not selecting Go packages; assets releases already published are retained by design
6. After the SRC_URI path bug: half-applied packages with orphan releases need manual SRC_URI repair + `ebuild manifest` until resume follow-up lands

## Open Questions

None product-level for this change. Assets remote parse vs constant and exact `xz` preflight binary remain implementation details.

## Follow-ups (new OpenSpec session)

Track these as a **separate** change proposal later (do not block archiving this change):

| ID | Topic | Notes |
|----|--------|--------|
| F1 | **Half-apply / orphan-assets resume** | Detect existing GitHub release+asset for `{pn}-{pv}`; skip rebuild/publish; continue overlay SRC_URI repair + `ebuild manifest` + commit. Detect “has `${PV}` but wrong/missing assets path” as needing fix (not soft-skip). Avoid soft-skip when local already at remote PV but overlay is half-applied or Manifest incomplete. |
| F2 | **Crush / host Go toolchain** | `go.mod` may require newer Go than host (`GOTOOLCHAIN=local` fails). Options: document min Go, allow toolchain download, or surface clearer preflight. Not tracked in policy today. |
| F3 | **`update --force` (dirty paths)** | Optional flag to override “involved paths are dirty” hard-fail (e.g. `opencode-bin` after partial runs). Define which dirt is forceable vs still fatal. |

Suggested next change name (example): `update-resume-and-force` (or split F1/F2/F3 if preferred).