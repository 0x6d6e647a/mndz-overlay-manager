## Context

See proposal.md for motivation. Today `outdated` runs `checkOverlayWithDepsPlan` (live fetch + deps plan). `update` does **not** reuse those results: `applyGitMv` calls `aeFetcher` again and `applyDepsAndAssets` calls `planDepsPackageWithProgress` again. Config is flat TOML (`overlay-path`, `assets-path`, `github-token`, `distfiles-path`) with no duration keys. XDG cache already hosts manager distfiles under `…/mndz/overlay-manager/distfiles`. The outdated-command spec currently forbids subcommand-local flags; that must change for `--refresh`.

## Goals / Non-Goals

**Goals:**

- Persist successful check/plan network results on disk with a short TTL so `outdated` → `update` (and back-to-back runs) skip repeated upstream discovery.
- Single integration surface used by both commands (cached latest fetch + cached deps plan).
- Safe invalidation via fingerprint; force via `--refresh`; disable via TTL zero.
- Operator-visible config key, help, and one summary log line per run.

**Non-Goals:**

- Caching apply downloads (vendor tarballs, distfiles, language module caches).
- Offline-only mode or cache-directory config override.
- Re-fetching remote when a valid entry exists.
- Invalidating on Portage ceiling changes inside the TTL window.

## Decisions

### D1 — Cache file path

Directory:

```text
${XDG_CACHE_HOME}/mndz/overlay-manager/check-cache/
# else ${HOME}/.cache/mndz/overlay-manager/check-cache/
```

Filename per overlay:

```text
<friendly>-<hash12>.json
```

- **friendly**: basename of the resolved **absolute** overlay path; keep `[A-Za-z0-9._-]`, map other character runs to `-`, trim leading/trailing `-`, cap length (64). Empty after sanitize → `overlay`.
- **hash12**: first 12 lowercase hex chars of SHA-256 of the canonical absolute overlay path (no trailing slash normalization beyond `makeAbsolute` / equivalent).

Lock file: same basename with `.lock` suffix (or OS lock on the JSON path — implementation picks one scheme and keeps it consistent).

**Alternatives:** single global JSON (rejected — multi-overlay merge complexity); per-package files (rejected — more I/O for v1); `repo_name` prefix (rejected — requires valid overlay metadata before path resolve).

### D2 — JSON schema `version: 1`

Top-level shape (conceptual):

```json
{
  "version": 1,
  "overlay": "/abs/path/to/overlay",
  "packages": {
    "category/package": {
      "checked_at": "2026-08-10T18:01:02Z",
      "fingerprint": {
        "local_pvs": ["0.80.0"],
        "source_id": "github:owner/repo",
        "content_hash": "sha256-hex..."
      },
      "kind": "latest",
      "remote_pv": "0.84.0"
    },
    "dev-util/crush": {
      "checked_at": "...",
      "fingerprint": { "...": "..." },
      "kind": "deps",
      "plan": { /* RuntimeLanePlan fields */ }
    }
  }
}
```

- **`kind: latest`**: stores `remote_pv` (pretty PV form sufficient to re-parse as `EbuildVersion`).
- **`kind: deps`**: stores serializable `RuntimeLanePlan` (`lanes`, `ebuilds` with PV/keywords/lane ids, `unique_pvs`, `runtime_atom`).
- Unknown `version` or unreadable JSON → treat as empty cache (miss), do not hard-fail the command solely for corrupt cache; log a warning and rewrite on next successful store when appropriate.

Do **not** store `FetchError` / plan-failure outcomes. Unconfigured packages need not be stored.

### D3 — Fingerprint (stronger)

An entry is valid only when all hold:

1. Wall-clock age of `checked_at` ≤ effective TTL (unless TTL is zero / refresh — see D4/D5).
2. **local_pvs**: sorted non-live local PV strings for the package match.
3. **source_id**: stable id of the hardcoded update source (e.g. `github:owner/repo`, `npm:pkg`, `http:<primary-url>`).
4. **content_hash**: SHA-256 (or project crypto already in use) over a canonical concatenation of package-directory **non-live ebuild file contents** and **Manifest** content when present (deterministic path order). Live (`9999`) ebuilds MAY be omitted from the hash set.

On mismatch → miss (live network work).

Content-fix / Manifest adequacy for gap lines and apply decisions are **always recomputed from disk** after obtaining remote/plan (cached or live). Do not treat cached report lines as the sole authority for `assets_reusable`.

### D4 — TTL and duration config

- Config key: `check-cache-ttl` (optional string).
- Default when omitted: **5 minutes**.
- Parser: pure function, **single unit**, case-insensitive: `N` + `s` | `m` | `h` | `d` (e.g. `30s`, `5m`, `1h`, `2d`). Reject bare integers, multi-unit strings (`1h30m`), empty, and unknown units with a **config load hard failure**.
- **`0` / `0s`**: cache **disabled** — never read, never write for that process.
- Stored as `NominalDiffTime` (or equivalent) after parse.

No CLI override for TTL in v1 (only config + default).

### D5 — `--refresh`

Subcommand-local switch on **both** `outdated` and `update`:

- Treat all packages as cache miss for **reads**.
- After live success, **write** new entries (unless TTL disabled).
- Does not change package target selection rules.

### D6 — Integration points (trust cache)

```text
                    ┌──────────────────────┐
                    │ CheckCache (disk IO) │
                    │ load / lock / store  │
                    └──────────┬───────────┘
           ┌───────────────────┼───────────────────┐
           ▼                   ▼                   ▼
    checkPackage         checkPackageDeps    applyGitMv
    (latest path)        (plan path)         (latest path)
                                             applyDepsAndAssets
                                             (plan path)
```

Suggested approach:

1. Load cache once per command (overlay path known) into an in-memory map + handle for writes.
2. Wrap or parameterize:
   - **Latest**: if valid `kind: latest` entry → use `remote_pv` without HTTP; else fetch and on success store.
   - **Deps plan**: if valid `kind: deps` entry → deserialize `RuntimeLanePlan` without list/probe network; else plan live and on success store.
3. Ceilings discovery is embedded in a full plan; on cache hit, **do not** re-run `portageq` list/probe for that package (accepted ≤ TTL staleness).
4. After **successful** apply of package P (at least one success unit / GitMv success), **rewrite** P’s entry: new fingerprint from post-apply tree, `kind` appropriate, status effectively Ok / updated plan if still needed for multi-PV partial work. Prefer rewriting to reflect **post-apply** local state so a follow-up full-tree `update` within TTL soft-skips without network. If rewrite is hard to derive without re-plan, minimum is store `kind: latest` with remote equal to new local for GitMv, or re-run plan once for deps after success only for that package (still cheaper than full-tree). Prefer **in-process rewrite from known post-apply PVs + prior remote/plan targets** without network when possible.

Concurrent packages in one run share one loaded document; accumulate in-memory updates; flush under lock at end of run (and optionally after batches). Mid-run crash may lose unflushed entries — acceptable.

### D7 — Concurrency across processes

- Acquire exclusive lock on the overlay’s cache file (or sibling `.lock`) for the duration of read-modify-write.
- Write via temp file in the same directory + atomic rename.
- Stale lock recovery: implementation may use non-blocking try with timeout or rely on process-scoped locks (`flock`); document chosen mechanism in module docs. Prefer `flock`-style exclusive lock for v1.

### D8 — Logging

Exactly **one info-level summary** per `outdated` or `update` run that used the check path, e.g.:

```text
check cache: 12 hit, 3 fetch
```

Counts: **hit** = packages that used a valid cache entry; **fetch** = packages that performed live network check/plan (including refresh and misses). Unconfigured packages that skip network MAY be omitted from both counts or listed only if they would have been candidates — prefer counting only packages that participate in check/plan (configured techniques).

Per-package hit/miss detail is **not** required at info; MAY exist at debug later without a spec change.

### D9 — Config / CLI wiring

- `OverlayConfig`: `checkCacheTtl :: Maybe Text` (raw) or parsed duration at load time — prefer **parse at load** into a dedicated field (`Maybe NominalDiffTime` with `Nothing` = use default 5m, or an explicit `CacheTtl = Disabled | Ttl NominalDiffTime` ADT). Recommended ADT:

  ```haskell
  data CheckCacheTtl = CacheDisabled | CacheTtl NominalDiffTime
  ```

  Omitted key → `CacheTtl (5 * 60)`; `0`/`0s` → `CacheDisabled`; other valid → `CacheTtl d`.

- Parser: `outdated` / `update` gain `switch (long "refresh" …)`.
- Footer/help text no longer claims outdated has no local flags.

### D10 — Module placement

| Concern | Suggested home |
|---------|----------------|
| Path resolve, friendly+hash, duration parse, fingerprint, JSON codec, lock/load/store | `Update.CheckCache` (new), keep as `other-modules` unless tests need more |
| Wire into check loop | `Update.Check` / Main outdated path |
| Wire into apply latest/plan | `Update.Apply.GitMv`, `Update.Apply.Materialize` (or ApplyEnv cache handle) |
| Config | `Config.Types`, `Config.Loader` |
| CLI | `CLI.Parser` |

Avoid expanding `exposed-modules` without executable/test need.

### D11 — Tests

- Pure: duration parse (accept/reject), friendly name sanitize, hash path stability, fingerprint equality.
- IO: write/read round-trip, TTL expiry (inject clock), fingerprint mismatch → miss, corrupt JSON → empty, lock doesn’t corrupt file, disabled TTL no files written.
- Integration-style: check stores entry; second check hits; apply uses cached remote/plan without calling fake fetcher; `--refresh` forces fetcher call; successful apply rewrites entry.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Stale plan if Portage go/nodejs ceilings change within 5m | Accepted; short default TTL; `--refresh` |
| Corrupt or partial JSON after crash | Atomic rename; treat bad file as miss + warn |
| Two processes race | File lock + atomic write |
| Plan serialization drift when `RuntimeLanePlan` fields change | Schema `version` + fail-soft decode |
| Trust-cache applies wrong PV if fingerprint too weak | Content hash of ebuilds+Manifest + PVs + source id |
| Full-tree update still hits network for uncached packages | Expected; first `outdated` warms cache |
| Info summary noise | One line only |

## Migration Plan

- No migration of existing user data (new files only).
- Operators get caching by default after upgrade; behavior change is fewer network calls within 5m.
- Rollback: omit feature or set `check-cache-ttl = "0s"`; delete `…/check-cache/` if desired.

## Open Questions

None that block specs or tasks. Implementation may choose exact `flock` API and JSON field names for lane ids as long as round-trip preserves plan equality used by apply.
