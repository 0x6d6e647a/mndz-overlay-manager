# Tasks

## 1. Config keys and lock helper

- [x] 1.1 Add optional config keys `gentoo-tree-max-age` (default `6h`) and `materialize-base-check-interval` (default `3d`) in `src/Config/Types.hs`, reusing the `check-cache-ttl` duration parser. Invalid values fail config load. Verify with config tests covering default, valid, and invalid values for both keys (`just coverage <pattern>`).
- [x] 1.2 Generalize `withExclusiveLock` from `src/Update/CheckCache.hs` into a shared `flock` helper that supports shared and exclusive modes and waits. Move check-cache onto it with no behavior change. Verify with the existing check-cache lock tests plus a new test showing a shared holder blocks an exclusive taker until release.

## 2. Managed tree sync (`gentoo-tree`)

- [x] 2.1 Create the tree module (working name `Update.GentooTree`, design D11) with injectable git, gpg, HTTP, clock, and lock operations. Add path resolution under XDG cache (`…/overlay-manager/gentoo`, keyring `…/gentoo-keyring` mode 0700, stamp `last-sync-check`, lock `gentoo.lock`). Put it in `other-modules` unless the test suite needs it exposed. Verify with path tests for `XDG_CACHE_HOME` set and unset.
- [x] 2.2 Implement pure helpers: parse the `TIMESTAMP` from a `Packages` header; select the target commit from a `git log` listing (mirror metadata commits only, at most `T − 1h`); parse `git verify-commit --raw` status lines and accept only `VALIDSIG` with primary fingerprint `EF9538C9E8E64311A52CDEDFA13D0EF1914E7A72`. Verify with unit tests: the spike example (12:35 → 11:16 pick), a developer commit skipped, `NO_PUBKEY`, a wrong primary key, and `REVKEYSIG`/`EXPKEYSIG`.
- [x] 2.3 Implement key handling: import by WKD (HTTP), falling back to `keys.gentoo.org --recv-keys <fpr>`, with fingerprint check before trust; refresh on every sync; a failed refresh warns. Verify with fake gpg/HTTP tests: first fetch, mismatched fingerprint rejected, refresh failure warns and proceeds, revoked key fails.
- [x] 2.4 Implement sync: first clone (`--depth 1 --branch stable`) after a 1 GiB free-space check; fetch with `--shallow-since=T−6h`, deepening to `T−7d`; verify the target; `checkout --detach`; write `.dockerignore` and `.git/info/exclude`; write the stamp on success, including "no change". Apply every fallback row in the `gentoo-tree` spec (binhost unreachable, stalled binhost, offline with and without a tree, verification failure leaves the tree unchanged). Verify with fake-runner tests for each fallback scenario in `specs/gentoo-tree/spec.md`.
- [x] 2.5 Implement `resolveGentooTree`: take `LOCK_SH`; when due (no stamp, stamp older than `gentoo-tree-max-age`, or refresh requested), take `LOCK_EX`, sync, then downgrade. Log while waiting for another run. Expose path and commit. Verify with tests: fresh tree skips the network, due tree syncs, refresh forces a sync, and a concurrent holder makes the sync wait (two threads, fake lock).
- [x] 2.6 Manual live probe (not part of the gate): run the production sync into a scratch `XDG_CACHE_HOME`. Confirm the clone, the aligned commit for today's binhost `TIMESTAMP`, `VALIDSIG` with the pinned fingerprint, and a second run inside the max age making no network calls. Note results in the PR.

## 3. One tree for every reader

- [x] 3.1 Replace `gentooRepoPath`/`PortageqRunner` in `Update.Runtime.Ceilings`, `Update.Deps.Plan`, `Update.Go.Plan`, and `Update.Uv.Python` with a tree path parameter. Delete `PortageqRunner`, `mkPortageqRunner`, `productionPortageqRunner`, and `gentooRepoPath`. Verify with `grep -rn "portageq\|PortageqRunner\|gentooRepoPath" src app` finding only the eclean DISTDIR probe in `Update.Distfiles`, and `just build-release`.
- [x] 3.2 Wire the resolver into the spine for `outdated`, `update`, and `gencache` (once per run, before planning), pass `--refresh` through, and replace `ecGentooRoot` in `app/Main.hs` with the resolved path. `list` and `eclean` do not resolve. Verify with tests showing `list` makes no tree calls and `outdated --refresh` forces a sync.
- [x] 3.3 Migrate the tests that fake `portageq` (`test/Test/Lanes.hs`, `Ecosystems.hs`, `Apply.hs`, `CheckPlan.hs`, `Materialize.hs`, `Md5Cache.hs`, `Ensure.hs`, and the other single hits) to inject a temp tree directory. Add the runtime-lanes scenario "Gentoo ceilings ignore the host tree". Verify with `just coverage` green for those groups.
- [x] 3.4 Add the managed tree identity to deps-payload fingerprints in `Update.CheckCache`. An entry without it, or with a different commit, misses. GitMv latest-only entries are unaffected. Verify with tests for both check-cache scenarios in `specs/check-cache/spec.md`.
- [x] 3.5 Update `README.md`: managed tree section (path, git mirror, gpg verification against the mirror key, binhost alignment, offline behavior), the two config keys with defaults, `--refresh` syncing the tree, and the `outdated` row (`git` + `gpg`, no Portage or Docker), per `specs/project-docs/spec.md`. Verify by reading the rendered README against both new project-docs requirements.

## 4. Portage tools container

- [x] 4.1 Add a tools-container profile in `Update.Process.Docker`: tree read-only at `/var/db/repos/gentoo`; overlay and manager distfiles at their host absolute paths; operator `--user`; writable `HOME` and `egencache` cache dir; `PORTAGE_REPOSITORIES` for gentoo and mndz; product and run labels; lazy create on first use; removed at exit. Verify with argv-shape unit tests for create/exec, and a test showing removal at exit.
- [x] 4.2 Run `mkEbuildRunner` (`Update.Apply.Env`) and `mkEgencacheRunner` (`Update.Md5Cache`) through exec in the tools container. Keep cwd, `DISTDIR`, `GENTOO_MIRRORS=`, and `--repositories-configuration` (gentoo at the container path, mndz at the overlay path). Delete `discoverGentooLocationWith`. Verify with injectable-runner tests asserting the exec argv and environment, and the md5-cache "Eclass checksums come from the managed tree" scenario.
- [x] 4.3 Image selection for the tools container: sidecar current image, else `MNDZ_MATERIALIZE_IMAGE`, else ensure with an empty floor set (base-only image, recorded with empty floors). Verify with tests for all three paths, including "GitMv-only update on a fresh host".
- [x] 4.4 Spine preflight: `update` requires `git`, `gpg`, `docker` and no longer `ebuild`/`egencache`. `gencache` requires `git`, `gpg`, `docker`. Plan-phase step 4 and re-admit checks require a toolchain image rather than `docker` on `PATH`. Verify with the update-command and md5-cache preflight scenarios in the delta specs (missing docker fails the spine; host Portage tools not required).
- [x] 4.5 Update `README.md`: runtime table rows for `update` and `gencache` (`docker`, no host `ebuild`/`egencache`), the first-run base-only image, and the host/container split (`ebuild … manifest` and `egencache` in a container), per the modified project-docs requirements. Verify by reading the README against those requirements.
- [x] 4.6 Manual live probe (not part of the gate): on this host, regenerate one GitMv Manifest and run `gencache` for one package through the tools container. Confirm byte-identical output to the committed files and operator ownership. Note results in the PR.

## 5. Image builds from the managed tree

- [x] 5.1 Recipe (`Update.Materialize.Recipe`): remove every `emerge-webrsync`; bind `from=gentoo` at `/var/db/repos/gentoo` in each Portage `RUN`; base step `getuto`, Portage upgrade, `emerge -uDN @world`, then tools; `FROM gentoo/stage3:<tag>@sha256:<digest>`. Verify with recipe golden or shape tests: no `emerge-webrsync`, a bind on every Portage `RUN`, `@world` before the first toolchain, digest-pinned `FROM`, cache ids unchanged.
- [x] 5.2 Ensure (`Update.Materialize.Ensure`): pass `--build-context gentoo=<tree>`; choose atoms from the managed tree; do not build solely because the tree commit changed. Verify with tests for "Synced tree leaves a satisfying image" and "Build sees the planning tree" (the recorded commit equals the resolver's).
- [x] 5.3 Registry client (injectable HTTP): anonymous token from `auth.docker.io`, then `HEAD` the manifest with OCI index and manifest-list `Accept` headers, reading `Docker-Content-Digest`. Base check in ensure per design D8: different digest → build; same → record the check; failure → warn, leave due; skipped for `MNDZ_MATERIALIZE_IMAGE`. Verify with tests for all four base-check scenarios.
- [x] 5.4 Sidecar (`Update.Materialize.Sidecar`): add `treeCommit`, `stage3Digest`, `lastBaseCheck`. Old sidecars parse with them missing (base check due). Verify with round-trip and old-format parse tests.
- [x] 5.5 Materialize sessions bind the managed tree read-only at `/var/db/repos/gentoo`, so `pycargoebuild` reads `metadata/license-mapping.conf` from it. Check for other in-image readers of the old baked tree (`grep -rn "/var/db/repos/gentoo" src`). Verify with a session create-argv test, and the Cargo full-path tests still passing.
- [x] 5.6 Update `README.md` materialize sections: no baked tree, the tree bound per build, `@world` in base, stage3 pinned by digest and checked every `materialize-base-check-interval`, and rebuilds re-running all layers after a tree change. Verify against the modified "README documents Docker full-path materialize and config mode" requirement.
- [x] 5.7 Manual live probe (not part of the gate): let ensure rebuild the image on this host. Record build time, `image.json` fields, file count (`find / -xdev | wc -l` in a container), and `docker create` time compared with the 15–18 s baseline. Note results in the PR and in `docker-create-slow-handoff.typ`.

## 6. Disk gate and metrics cleanup

- [x] 6.1 Remove the Portage DISTDIR root and its warning from the disk gate (`Update.DiskSpace`, both `lookupPortageDistDir` calls in `Update.Spine`). Keep `lookupPortageDistDir` for the eclean guard. Verify with the "Host Portage DISTDIR not measured" scenario test, and the existing eclean refusal tests passing.
- [x] 6.2 Run-metrics: make sure tree-sync `git`/`gpg` calls go through the shared command runner (normal `proc` spans), and that the eclean DISTDIR probe still records its wall-clock span. Verify with the modified run-metrics scenario test (`eclean` produces a `portageq` `proc` span with no `time` object).
- [x] 6.3 Update the `README.md` free-space section to drop the "system Portage DISTDIR low space may only warn" remediation line. Verify against the modified free-space project-docs requirement.

## 7. Specs, docs, and gate

- [x] 7.1 Check `CONTRIBUTING.md` and `AGENTS.md` for host Portage or `portageq` mentions (`grep -niE "portageq|egencache|ebuild|portage" CONTRIBUTING.md AGENTS.md`) and update any that describe them as host requirements, per `project-docs`.
- [x] 7.2 Sync the delta specs into `openspec/specs/` (on archive or `openspec-sync-specs`). Then scrub living specs for residue: `grep -rn "portageq\|emerge-webrsync\|host Portage" openspec/specs` should leave only the eclean DISTDIR probe. Verify with `openspec validate --specs --strict`.
- [x] 7.3 Run `openspec validate managed-gentoo-tree --strict`, then `just check` (format, hlint, release build, stan, weeder, coverage), and verify it is green. Mark tasks complete only after this passes.

## Workflow follow-up

- Update `managed-gentoo-tree-handoff.typ` in the wiki with the spec names (`gentoo-tree`, `portage-tools-container`), the resolver (`resolveGentooTree`, `gentooTreePath`, `gentooTreeCommit`), and how to read the tree identity, so the paused `smoke` session can resume.
- Archive the change after review, and verify with `openspec validate --specs --strict`.
