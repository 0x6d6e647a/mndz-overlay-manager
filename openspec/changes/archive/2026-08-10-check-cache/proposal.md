## Why

Running `outdated` then `update` repeats the same network-backed check: latest-version fetches for simple techniques and full runtime-lane planning for `DepsAndAssets`. That doubles GitHub/npm/HTTP traffic and wall time for the common inspect-then-apply workflow. The manager should persist check/plan results for a short TTL so a second command can reuse them without re-discovering upstream.

## What Changes

- **Shared check cache** under XDG cache (`…/mndz/overlay-manager/check-cache/`), one JSON file per overlay named `<friendly>-<hash12>.json` (basename prefix + hash of absolute overlay path).
- **Store full network results** (depth C): GitMv/Http/Npm latest remote PV; DepsAndAssets full `RuntimeLanePlan`. Also cache **Ok** (and Ahead) outcomes so full-tree `update` does not re-plan packages that need no work.
- **TTL**: optional config key `check-cache-ttl` as a human duration string (default **5m** when omitted). Small pure parser (single unit, case-insensitive). `0` / `0s` disables cache (never read, never write).
- **Trust cache on apply**: when an entry is valid, `update` uses cached remote PV / plan without re-fetching or re-planning. Content-fix / Manifest adequacy always recomputed from disk.
- **`--refresh`** on both `outdated` and `update`: ignore existing cache, perform live network work, write fresh entries.
- **Strong fingerprint**: non-live local PVs + update-source id + content hash of package ebuilds and Manifest; mismatch invalidates even inside TTL.
- **Never cache** fetch/plan failures. **Rewrite** a package entry after successful apply (Ok / updated plan + new fingerprint).
- **Concurrency**: file lock + atomic write (tmp + rename).
- **Logging**: one **info** summary of hit vs live-fetch counts per command run.
- **Docs / help**: README config key, default TTL, cache location pattern, `--refresh`; command help for `outdated` and `update`.

### Non-goals

- Caching assets/distfiles downloads, language module caches, or md5-cache generation.
- Offline-only mode (`--offline` / fail on cache miss).
- Config override for the check-cache directory path.
- Sharing cache across machines or multi-user systems.
- Re-verifying remote at apply when the cache entry is valid (explicitly rejected for v1).
- Invalidating on Portage runtime-ceiling changes within TTL (accepted ≤5m staleness).
- A separate `cache clean` subcommand for check-cache (operators may delete the XDG files manually).

## Capabilities

### New Capabilities

- `check-cache`: disk layout, JSON schema (`version: 1`), TTL/duration parsing, fingerprint rules, read/write/lock semantics, validity (TTL + fingerprint), what is stored per technique, disable-via-zero, post-apply rewrite, and hit/miss summary logging.

### Modified Capabilities

- `outdated-command`: use check-cache on the check path; accept `--refresh`; allow this subcommand-local flag (overrides prior “no local flags” rule).
- `update-command`: use check-cache for latest fetch and deps plan on the apply path; accept `--refresh`.
- `cli-help`: document `--refresh` on `outdated` and `update` help; note check-cache behavior at command-scoped depth.
- `project-docs`: README documents `check-cache-ttl`, default 5m, XDG cache path pattern, and `--refresh` on both commands.

## Impact

- **CLI**: `--refresh` on `outdated` and `update` (subcommand-local).
- **Config**: optional `check-cache-ttl` on `OverlayConfig`.
- **Code**: new check-cache module(s); config loader/types; CLI parser; wire cache into check (`Update.Check`) and apply (`applyGitMv` fetcher path, `applyDepsAndAssets` plan path); tests for path naming, duration parse, fingerprint invalidation, TTL, lock/atomic write, integration with check/apply.
- **Operator disk**: small JSON files under XDG cache (not distfiles).
- **Behavior**: default runs may skip network for packages with valid cache entries within 5m; `--refresh` restores always-live behavior.
