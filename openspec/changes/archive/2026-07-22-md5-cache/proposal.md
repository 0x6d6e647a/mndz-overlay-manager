## Why

The mndz overlay does not ship Portage `metadata/md5-cache`, so consumers cannot rely on pre-generated metadata for fast dependency calculation after sync. Overlay commits from `update` already co-commit ebuild renames/rewrites and Manifest regeneration; md5-cache should be maintained the same way so every version change is accompanied by its cache entry, with an explicit bootstrap/repair path for the full tree.

## What Changes

- Add a **`gencache`** work subcommand to generate or regenerate `metadata/md5-cache` (md5-dict format) for all packages or selected package targets, producing **one** GPG-signed overlay commit.
- Integrate package-scoped **`egencache`** into the `update` apply success path: after `ebuild … manifest` and before the unit’s signed commit, regenerate that package’s cache and include affected `metadata/md5-cache/` paths in the same commit as the ebuild/Manifest (and prune) changes.
- Enforce a **strict-strict** consistency gate: `update` hard-fails when any non-live ebuild under a package is missing cache or has an `_md5_` mismatch; operators must bootstrap with `gencache` or reconcile with `gencache --force`.
- Require `cache-formats = md5-dict` in overlay `layout.conf` before cache work; require `egencache` on `PATH` alongside existing Portage tools for `update`/`gencache`.
- Drive `egencache` with an injected `--repositories-configuration` so the effective **overlay-path** is always the repository location (manager config wins over ambient Portage `repos.conf`).
- Update operator-facing docs and CLI help for the new command, tool requirements, and recovery messages.
- Rollout on the live overlay (operator/tasks): add `cache-formats` if missing, run full `gencache` once, then rely on `update` for ongoing maintenance.

## Capabilities

### New Capabilities

- `md5-cache`: Portage md5-dict cache consistency checks, `egencache` orchestration (including repositories-configuration injection), layout.conf gate, `gencache` command behavior, and rules for co-committing cache paths with apply units.

### Modified Capabilities

- `update-apply`: After successful manifest (and after prune mutations), regenerate package md5-cache and stage cache paths in the unit commit; pre-unit cache completeness/match gate with hard-fail and recovery messaging.
- `update-command`: Preflight requires `egencache`; document cache gate relative to package mutation.
- `cli-help`: Catalog and per-command help for `gencache`; update `update` help if recovery/tools are mentioned at help depth.
- `project-docs`: README (and help-aligned) operator docs for `gencache`, runtime tools, and bootstrap/recovery.

## Impact

- **CLI**: New `gencache` subcommand; `update` behavior and preflight tools expanded.
- **Runtime tools**: `egencache` (Portage, same suite as existing `ebuild`) required for `update` and `gencache`.
- **Overlay repo (mndz-overlay)**: Expects `cache-formats = md5-dict` and populated `metadata/md5-cache/` after bootstrap; not implemented inside this manager repo’s tree except via operator tasks against the configured overlay-path.
- **Code**: Apply pipeline, preflight, git path staging, new modules/CLI wiring, tests (injectable cache runner; pure `_md5_` checks).
- **Out of scope**: Pure-Haskell metadata evaluation; `pms` cache format; `pkg_desc_index` / `use.local.desc` / `timestamp.chk`; concurrent egencache outside the overlay lock on `update` (Option B).
