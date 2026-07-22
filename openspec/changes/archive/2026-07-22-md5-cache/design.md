## Context

`update` already mutates ebuilds, runs Portage `ebuild … manifest`, and creates GPG-signed, path-scoped overlay commits (commit-on-unit-success). The live mndz overlay has no `metadata/md5-cache` and its `layout.conf` does not declare `cache-formats = md5-dict`. Portage consumers benefit from distributed md5-dict cache; the manager should maintain it deliberately rather than leaving clients to regenerate metadata.

Cache **generation** requires Portage’s ebuild metadata phase (bash + master eclasses). A pure-Haskell evaluator is not feasible. The tool shells out to `egencache` (same Portage suite as `ebuild`). Cheap **validation** (`_md5_` vs ebuild file MD5) is pure and used for the strict gate.

## Goals / Non-Goals

**Goals:**

- Ship and maintain `metadata/md5-cache/` (md5-dict only) for the overlay.
- **`gencache`**: bootstrap / bulk regen / forced repair; one signed commit.
- **`update`**: after manifest (and after prune mutations), package-scoped egencache; cache paths co-committed with each unit’s ebuild/Manifest changes.
- **Strict-strict** precondition: package cache complete and matching before any `update` unit mutates that package.
- **overlay-path** is the egencache target via injected `--repositories-configuration` (manager config wins).
- Gate on `cache-formats = md5-dict` in layout.conf; require `egencache` on PATH.
- Operator docs and CLI help for the new surface and recovery.

**Non-Goals:**

- Pure-Haskell metadata evaluation.
- `pms` format, `pkg_desc_index`, `use.local.desc`, `timestamp.chk`, ChangeLogs.
- Auto-editing `layout.conf` to insert `cache-formats`.
- Option B concurrency on `update` (egencache outside the overlay lock).
- Making `list` / `outdated` depend on md5-cache.

## Decisions

### Decision: Shell out to `egencache`, not reimplement Portage

**Choice:** Invoke `egencache` with injectable runner for tests.  
**Why:** Correct metadata requires sourcing ebuilds and eclasses (e.g. `go-module`, `cargo`).  
**Alternatives:** Pure Haskell (incorrect without full bash/eclass eval); Portage Python API (same dependency, worse UX).

### Decision: md5-dict only; layout.conf gate

**Choice:** Only write/read `metadata/md5-cache/`. Refuse cache work if `metadata/layout.conf` does not list `md5-dict` in `cache-formats` (explicit; no auto-write of layout.conf).  
**Why:** Matches GURU/gentoo; `pms` is deprecated. Explicit format avoids old-client ambiguity.  
**Alternatives:** Auto-detect without layout line (weaker intent); auto-edit layout (surprising policy mutation).

### Decision: Strict-strict consistency policy

| Command | Missing cache | `_md5_` mismatch | Match |
|---------|---------------|------------------|--------|
| `update` (per package, all non-live ebuilds) | Hard fail → `gencache <pkg>` | Hard fail → `gencache --force <pkg>` | Proceed |
| `gencache` | Generate | Error unless `--force` | Skip unless `--force` |
| `gencache --force` | Generate | Regenerate | Regenerate |

**Why:** Single responsibility—`gencache` creates/reconciles; `update` only maintains after a clean precondition. Strong “cache-complete” invariant for the managed overlay.  
**Trade-off:** Recovery after partial failure may require `gencache [--force]` then retry `update`. Document in error text and half-applied warnings.  
**Alternatives considered:** Apply-repairs on `update` (less friction, weaker invariant); repair-by-default on `gencache` without `--force` for mismatch (rejected in favor of strict-strict).

**Match definition:** For each non-live `*.ebuild` under `cat/pkg`, file `metadata/md5-cache/cat/pn-ver` exists and its `_md5_` field equals the MD5 hex digest of the ebuild file contents. Live (`9999`) ebuilds are out of scope for the gate if present. Eclass-only drift (same ebuild `_md5_`, changed master eclass) is **not** detected by this gate; full regen via `gencache --force` addresses that when needed.

### Decision: Package-scoped regen on `update`; co-commit per unit

**Choice:** `egencache --update cat/pkg` after successful manifest (and after prune’s manifest/regen needs). Stage all affected paths under `metadata/md5-cache/cat/` for that package (adds/updates/deletions) in the **same** signed commit as the unit’s ebuild/Manifest paths.  
**Why:** egencache’s atom model is package-level; multi-PV packages stay consistent; per-PV user-visible changes land with that unit’s commit.  
**Concurrency:** Run egencache + `git add` + `git commit` inside the existing overlay critical section (Option A). Do not parallelize egencache across packages on `update` outside that lock.

### Decision: `gencache` = bulk + one commit (Option C)

**Choice:** Resolve targets like `update` (zero args = all packages with ebuilds; else selected packages). Run egencache for the selection (prefer one `egencache --update` with atoms, or full-repo when none selected, with `-j` aligned to `--jobs` when useful). Single GPG-signed commit of `metadata/md5-cache/**` (only cache paths unless future design expands). Commit message e.g. `metadata: regenerate md5-cache`.  
**Why:** Bootstrap and repair without overloading `update`; one reviewable commit.

### Decision: Inject `--repositories-configuration` for path fidelity

**Choice:** Always pass a repositories configuration fragment that defines repo name `mndz` with `location = <absolute overlay-path>` (and whatever minimal fields Portage needs so masters/eclasses still resolve—spike during implementation: merge with ambient gentoo or embed gentoo location).  
**Why:** Manager `overlay-path` / `--overlay-path` is source of truth; ambient `repos.conf` must not redirect writes.  
**Alternatives:** Assert Portage location equals overlay-path only (fragile for worktrees).

### Decision: Tool preflight

**Choice:** `update` and `gencache` require `egencache` on PATH (with `git`/`gpg` as needed for signed commits; `ebuild` remains required for `update` manifest).  
**Why:** Explicit errors; same package as `ebuild` in practice.

### Decision: Module shape (implementation sketch)

- `Update.Md5Cache` (or similar): layout gate parse; `_md5_` read/compare; path helpers; `EgencacheRunner` type; production argv builder (`--repositories-configuration`, `--repo mndz`, `--update`, atoms, optional `-j`).
- Wire gate at start of each apply unit (package-level check before dirty/mutate).
- Wire regen after manifest success and before `signedOverlayCommit`; extend path lists.
- Prune path: after extras removed + manifest, egencache package, include cache deletions in prune commit.
- CLI: `Gencache` command in `CLI.Parser` / `Main`.
- Tests: pure match/mismatch/missing; mock runner asserts args include overlay location; apply path lists include cache files.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Injected repos config fails to resolve gentoo masters / eclasses | Spike early; fall back to documented fragment that includes gentoo location from Portage or `/var/db/repos/gentoo` discovery |
| Strict gate blocks recovery after half-applied unit | Error text names exact `gencache` / `gencache --force` command; half-applied warning mentions cache |
| egencache slow under overlay lock | Acceptable for small overlay; Option B deferred |
| `_md5_` gate misses eclass-only staleness | Document; operators use `gencache --force` after major gentoo eclass bumps |
| Operator forgets layout.conf / initial gencache | Hard-fail with clear messages; rollout tasks in tasks.md |

## Migration Plan

1. On **mndz-overlay**: commit `cache-formats = md5-dict` in `metadata/layout.conf` if absent.
2. Deploy manager with `gencache` + `update` integration.
3. Run `mndz-overlay-manager gencache` (full tree) → one signed cache commit.
4. Subsequent version work uses `update` only; repair via `gencache` / `gencache --force` as errors direct.

Rollback: stop using new manager bits; cache files in git are harmless if left in place; removing cache is a separate overlay decision.

## Open Questions

None blocking. Implementation spike only: exact `--repositories-configuration` fragment that loads masters correctly on a typical Gentoo host.
