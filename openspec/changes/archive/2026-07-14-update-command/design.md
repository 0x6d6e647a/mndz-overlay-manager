## Context

The tool already lists ebuilds and reports outdated packages (`list`, `outdated`). Update sources were resolved as hardcoded map first, else Level-1 ebuild inference. Exploration for applying bumps locked: fully hardcoded package policy (source + technique), simple technique = rename ebuild + Portage `ebuild … manifest` + isolated signed git commit, complex packages unsupported, parallel work then GPG-friendly commit storm.

The real overlay (`mndz-overlay`) has twelve packages; several are pure PV renames in git history (e.g. deno-bin, grok-build-bin), others need vendor/cargo/npm pipelines later.

## Goals / Non-Goals

**Goals:**
- CLI `update` that bumps outdated packages to latest upstream for supported techniques
- Hardcoded `PackagePolicy` (source + technique) for every known overlay package
- Remove Level-1 inference entirely
- `GitMvAndManifest` via filesystem rename + shell-out `ebuild` + signed `git commit`
- Action-scoped PATH preflight (`update`: `git`, `ebuild`, `gpg`)
- Parallel phase 1 (check/rename/manifest); barrier; sorted serial signed commits (GPG option B)
- Soft skips vs hard failures with correct exit policy

**Non-Goals:**
- Complex techniques (go vendor + assets, npm deps tarballs, cargo CRATES)
- Pure-Haskell Manifest generation
- Deleting older ebuild versions in a package dir
- Force-to-version / non-latest targets
- Handling `9999` live ebuilds (none exist today; future note only)
- Unsigned commits or optional signing
- Config-file / TOML policy maps
- Auto-push to remote

## Decisions

**Decision: Full hardcoded package policy**  
One map `PackageKey → PackagePolicy { source, technique }`. Sources always from the map (no infer). Techniques: `GitMvAndManifest | Unsupported reason`.  
Alternatives: keep inference for sources — rejected (technique already forces a map; one table is simpler). TOML policies — rejected for v1 (same as outdated design).

**Decision: Initial technique classification (mndz overlay)**  

| Package | Technique |
|---------|-----------|
| `dev-lang/bun-bin` | GitMvAndManifest |
| `dev-lang/deno-bin` | GitMvAndManifest |
| `dev-util/grok-build-bin` | GitMvAndManifest |
| `dev-util/opencode-bin` | GitMvAndManifest |
| `dev-db/dolt` | Unsupported (vendor assets) |
| `dev-util/beads` | Unsupported (go vendor assets) |
| `dev-util/crush` | Unsupported (go vendor assets) |
| `dev-util/openspec` | Unsupported (npm deps assets) |
| `dev-util/ralph-tui` | Unsupported (deps assets) |
| `dev-util/hk` | Unsupported (cargo) |
| `dev-util/mise` | Unsupported (cargo) |
| `dev-util/usage` | Unsupported (cargo) |

Sources: hardcode GitHub/npm/Http for each (port current inferred + grok Http). Unmapped package → unconfigured / soft skip on update.

**Decision: Shell out to `ebuild … manifest`**  
From package directory: `ebuild ./<pkg>-<newPV>.ebuild manifest` (matches maintainer workflow). Portage expands SRC_URI, fetches, writes thin Manifest.  
Alternatives: pure Haskell digests + URL templates — more code, drifts from ebuild; rejected.

**Decision: Remove `Update.Infer`**  
Delete module and resolve branch; weeder-clean. Tests that only covered inference migrate or drop.

**Decision: Newest local ebuild = max PV; revision ignored vs remote**  
Same as outdated. Local `x.y.z-rN` vs remote `x.y.z` is up to date. Bump target filename uses remote PV without inventing `-rN`. Leave other version files in the package dir untouched.

**Decision: Dirty check on involved paths only**  
For GitMvAndManifest: newest ebuild path and package `Manifest`. If either is dirty vs HEAD (modified/staged), hard-fail that package. Other packages’ dirt is ignored. Overlay must be a git worktree for `update`.

**Decision: Two-phase pipeline**  
Phase 1 (parallel per package): policy, fetch/compare, dirty check, rename ebuild (filesystem rename, not necessarily `git mv`), run `ebuild manifest`.  
Phase 2 (only if ≥1 success): barrier, then serial commits sorted by `category/package`: `git add` pathspecs for that package only, `git commit -S -m "category/package: version"`.  
Pathspecs after a rename MUST include **old ebuild + new ebuild + Manifest**. Staging only the new name leaves the old path as an unstaged deletion (observed bug). `git add` on a deleted tracked path stages the removal.  
No GPG prompt if phase 2 empty.

**Decision: GPG via gpg-agent only (option B)**  
Never capture passphrase in-process. Require `gpg` on PATH. Rely on agent + pinentry at first signed commit of the storm. No `--no-gpg-sign` fallback. Signing failure is a hard package failure.

**Decision: Target resolution**  
Zero args → all packages that are outdated after check (among discovered inventory).  
One or more args: each is `category/package` or PN-only if unique among inventory; ambiguous PN → hard error for that token (and counts toward exit 1). Missing policy → soft skip + warn.

**Decision: Exit policy**  
Spine failure (config, validate, discover empty, preflight missing tool) → exit 1 immediately.  
Per-package hard failures (dirty, ebuild non-zero, git, fetch/compare when attempting update) → log error, continue others, exit 1 at end.  
Soft skips (unsupported, unmapped, not outdated) → warn/info only; alone do not force exit 1.  
Successful updates print stdout lines.

**Decision: Action-scoped preflight**  
| Command | PATH tools |
|---------|------------|
| `list` | none |
| `outdated` | none |
| `update` | `git`, `ebuild`, `gpg` |

Missing any required tool → spine error before package work.

**Decision: Module layout**  
- `Update.Types` — technique, policy, apply outcomes  
- `Update.Hardcoded` — full policy map  
- `Update.Resolve` — map lookup only  
- `Update.Apply` — rename + ebuild manifest  
- `Update.Git` — dirty check, add, signed commit  
- `Update.Preflight` — action-scoped binary checks  
- CLI/Main — `update` command  
- Remove `Update.Infer`  

**Decision: Test strategy**  
Inject process runners / fake git-status for unit tests. No live Portage network or real GPG in default `cabal test`. Optional manual smoke on real overlay outside CI.

**Decision: Future `9999`**  
Document only: when live ebuilds exist, newest-for-update SHOULD ignore `9999` patterns. Not implemented now.

## Risks / Trade-offs

- [Half-applied package after rename if `ebuild manifest` fails] → Hard-fail package; warn that tree may be dirty for that package; no commit for it; other packages continue  
- [Concurrent `ebuild manifest` DISTDIR races] → Accept Portage behavior; package dirs differ; serialize only git  
- [gpg-agent TTL / pinentry in headless env] → Barrier then commit storm minimizes multi-prompt; document `GPG_TTY` / pinentry; fail hard on sign error  
- [Host Portage/config differs from maintainer machine] → `ebuild` is the source of truth for Manifests; preflight catches missing binary  
- [Policy map drifts from real overlay inventory] → Soft skip unmapped; keep map complete for known twelve packages in this change  
- [Removing inference breaks packages not in map] → In-scope map covers all current overlay packages  

## Migration Plan

Developers: rebuild; `outdated` uses map-only sources (ensure Hardcoded lists every package). Operators using `update` need `git`, Portage `ebuild`, and `gpg` with signing configured for the overlay repo. No overlay format migration.

## Open Questions

None — product decisions locked in exploration (shell-out manifest, GPG option B, multi-target CLI, soft unmapped, stdout lines, keep old ebuilds).
