# Proposal

## Why

The manager reads the host's Gentoo tree through `portageq` for lane ceilings, ensure atom choice, and `egencache`. It runs host `ebuild … manifest` against the host's `repos.conf` and profile. Meanwhile the materialize image bakes its own `emerge-webrsync` tree. The two trees disagree: on 2026-11-13 the host tree had `dev-lang/go` 1.26.11 and 1.27.4, the image tree had neither, and ensure picked atoms from one tree and emerged them against the other. The README also claims `outdated` does not need Portage, but lane planning calls `portageq`.

The planned `smoke` command needs one tree that it can bind read-only into a container, and a cheap identity for that tree. This change gives the manager its own tree and removes host Portage as a dependency.

## What Changes

- **New managed Gentoo tree** under the manager's XDG cache, a shallow clone of the Gentoo git mirror (`stable` branch) kept current with host `git`. Each commit is verified with host `gpg` against the pinned Gentoo repository-mirror key, in an isolated keyring. The key comes from WKD or keys.gentoo.org and is refreshed on every sync.
- **Binhost-aligned commit selection.** A sync moves the tree to the newest mirror metadata commit no newer than the Gentoo binhost index (`Packages` `TIMESTAMP`) minus a margin, so image builds resolve versions the binhost carries. Fallbacks keep the current tree when alignment or the network fails. They use the branch tip only on a host with no tree yet, and never move the tree to a commit that fails verification.
- **Sync policy.** New config key `gentoo-tree-max-age` (default `6h`). `outdated`, `update`, and `gencache` sync when the tree is missing or older than that. `--refresh` on `outdated` and `update` also forces a sync. A sync waits for other manager runs that are using the tree.
- **One tree everywhere.** Lane ceilings, ensure atom choice, image builds, materialize sessions, and Portage tool runs all use the managed tree. The tree identity is its commit id. **BREAKING:** the program no longer runs `portageq`, reads `/var/db/repos/gentoo`, or uses host `repos.conf` or profile for these purposes.
- **No host Portage tools.** `ebuild … manifest` and `egencache` run in a container from the current materialize image, with the managed tree bound read-only. On a host with no image, the program first builds a base-only image (no toolchains). **BREAKING:** `update` and `gencache` require `docker` on every run. `ebuild` and `egencache` are no longer host requirements.
- **Image builds from the managed tree.** The generated recipe drops `emerge-webrsync` and bind-mounts the managed tree read-only into each Portage `RUN`. The tree is no longer baked into image layers. The base step runs `emerge -uDN @world`. `FROM` pins the `gentoo/stage3` tag by digest.
- **Image base freshness.** New config key `materialize-base-check-interval` (default `3d`). When ensure runs and that interval has passed, the program asks the registry for the current stage3 digest. A newer digest triggers a rebuild. The same digest resets the timer. A failed check keeps the image, warns, and does not reset the timer.
- **Check cache.** Deps-plan entries include the managed tree commit in their fingerprint, so a tree change invalidates lane plans.
- **Disk gate.** Remove the Portage DISTDIR free-space warning. The `eclean` system-DISTDIR guard stays.
- **Specs.** Remove the `go-tree-lanes` rule that forbids a non-`portageq` tree path. That rule was an early scope cut, not a principle.
- **Docs.** The README runtime-requirements table changes: `outdated` needs `git` and `gpg` and no Docker or Portage; `update` and `gencache` need `docker` and no `ebuild` or `egencache`. The README also gains a managed-tree section.

## Capabilities

### New Capabilities

- `gentoo-tree`: the manager-owned Gentoo tree. Covers location, git source, signature verification and key handling, binhost-aligned commit selection and fallbacks, sync triggers and max age, locking, tree identity, and the rule that every consumer uses it.
- `portage-tools-container`: running Portage `ebuild … manifest` and `egencache` inside a container from the materialize image family, with the managed tree, overlay, and manager distfiles bound in, including the base-only image on a fresh host.

### Modified Capabilities

- `go-tree-lanes`: Go ceilings come from the managed tree, not `portageq`. The config-override prohibition is dropped.
- `runtime-lanes`: the per-ecosystem ceiling sources name the managed tree instead of `portageq`.
- `cli-concurrency`: the work-budget wording drops `portageq`.
- `ensure-materialize-image`: no `emerge-webrsync`; the managed tree is bound into Portage `RUN`s; `@world` update in base; stage3 pinned by digest; base freshness check and rebuild; sidecar records tree commit, stage3 digest, and last base check; the union-satisfied skip yields to a stale base.
- `hermetic-asset-materialize`: sessions bind the managed tree read-only. Manifest and md5-cache work after publish run through the Portage tools container.
- `md5-cache`: `egencache` runs in the Portage tools container against the managed tree. `gencache` preflight requires `docker` instead of `egencache`.
- `manager-distfiles`: `ebuild … manifest` environment wording for a container process.
- `update-command`: spine tools become `git`, `gpg`, `docker`. `--refresh` also forces a tree sync.
- `outdated-command`: `--refresh` also forces a tree sync.
- `check-cache`: deps-plan fingerprints include the managed tree commit.
- `disk-space-preflight`: drop the live Portage DISTDIR root and its warning.
- `run-metrics`: the Portage DISTDIR span example moves from `update` to `eclean`.
- `test-coverage`: process-adapter coverage names the Portage tools container and tree-sync runners in place of `portageq`.
- `project-docs`: README requirements for runtime tools, free-space remediation, and Docker/host split change, and the README documents the managed tree.

## Impact

- Code: `Update.Runtime.Ceilings` (`gentooRepoPath`, `PortageqRunner`), `Update.Deps.Plan`, `Update.Go.Plan`, `Update.Uv.Python`, `Update.Materialize.{Ensure,Recipe,Sidecar,Resolve}`, `Update.Md5Cache` (`discoverGentooLocationWith`, `mkEgencacheRunner`), `Update.Apply.Env` (`mkEbuildRunner`), `Update.Process.Docker`, `Update.Cargo.Crates` (`pycargoebuild` license mapping through the bound tree), `Update.Spine` and `Update.DiskSpace` (Portage DISTDIR warning), `Update.CheckCache` (fingerprint), `Update.Preflight`, `Config.Types` and `CLI.Parser` (new keys), `app/Main.hs` wiring, plus a new tree module.
- Tests: fakes of `portageq` across `test/Test/{Lanes,Ecosystems,Apply,CheckPlan,Materialize,Md5Cache}.hs` and others move to an injected tree path. `test/Test/Ensure.hs` (`ecGentooRoot`). New tests for sync, verification, alignment and fallbacks, locking, and the base check, all with fake git, gpg, HTTP, and registry runners.
- External services: `github.com/gentoo-mirror/gentoo` (git), `openpgpkey.gentoo.org` or `keys.gentoo.org` (key), `distfiles.gentoo.org` binhost `Packages` header, and the Docker Hub registry (stage3 digest, `HEAD` only).
- Disk: about 700 MB for the tree plus about 100 MB of `.git` under the cache. The materialize image loses the baked tree (161,587 of 259,281 files in the current image).
- Operator-visible: `outdated` may run `git` and `gpg`. `update` and `gencache` always need Docker. The first `update` or `gencache` on a fresh host builds a base-only image. Image builds re-run every layer after a tree change.
- Docs: `README.md` runtime requirements, cache layout, config keys, free-space remediation, and materialize sections.

## Non-goals

- The `smoke` command and its pass cache.
- Changing the `-ipc-sandbox -network-sandbox -pid-sandbox` FEATURES in the recipe.
- Changing which toolchains the image installs or how floors are chosen.
- Non-host architectures for alignment or images. The tree itself is architecture-independent.
- An HTTP snapshot or rsync source for the tree, a config key pointing at an existing (host) tree, or a separate tools image.
- Investigating slow `docker create` (separate handoff: `docker-create-slow-handoff.typ`).
- Changing package selection or PV selection. No CLI version pins.
