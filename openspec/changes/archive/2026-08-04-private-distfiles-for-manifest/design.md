## Context

See proposal.md for motivation. Today `Update.Apply.Env` runs `ebuild ./$file manifest` with `prEnv = Nothing`, so Portage inherits the host `DISTDIR` (usually sticky `/var/cache/distfiles`). Config only has `overlay-path`, `assets-path`, `github-token` (`Config.Types`). Default config path already follows XDG: `${XDG_CONFIG_HOME:-$HOME/.config}/mndz/overlay-manager.toml`. Process env injection already exists elsewhere (Go `GOMODCACHE`, bun/npm, gpg); `prEnv = Just env` **replaces** the full environment, so runners must merge with `getEnvironment`.

## Goals / Non-Goals

**Goals:**

- Isolate all manager-driven `ebuild … manifest` fetches under a default private DISTDIR the operator owns.
- Fail early if that DISTDIR cannot support Portage’s create-then-rename fetch pattern.
- Make sticky/EPERM-class failures actionable when they still occur.
- Avoid Portage GENTOO_MIRRORS layout side-fetches during those manifests (absolute SRC_URI only).
- Provide `eclean` to reclaim the manager cache safely (never wipe system DISTDIR).
- Document config/CLI/command surfaces in README and help.

**Non-Goals:**

- Changing host Portage configuration or system distfile ownership.
- Sharing or hardlinking from system DISTDIR (future optimization).
- Using `sudo` / `portage` user for fetch.
- Cleaning language caches (Go/npm/bun) under the same command.

## Decisions

### D1 — Default path and overrides

| Priority | Source |
|----------|--------|
| 1 | CLI global `--distfiles-path DIR` |
| 2 | Config key `distfiles-path` |
| 3 | Default `${XDG_CACHE_HOME:-$HOME/.cache}/mndz/overlay-manager/distfiles` |

Resolution mirrors overlay-path (CLI beats config beats default). Create the directory if missing with mode **`0700`**. One shared private DISTDIR for all parallel package units in a run.

**Alternatives:** inherit system DISTDIR by default (rejected — footgun); auto-detect sticky and only then switch (rejected — non-deterministic, still hits EPERM on first foreign-owned file).

### D2 — System DISTDIR escape hatch vs `eclean` guard

Operators MAY set `distfiles-path` / `--distfiles-path` to the system Portage DISTDIR (e.g. `/var/cache/distfiles`) if they accept sticky risks. **`eclean` SHALL refuse** when the resolved path is the system DISTDIR:

- Canonicalize and compare to Portage’s configured DISTDIR when discoverable (`portageq envvar DISTDIR` or equivalent), and/or
- Treat path equality (after `canonicalizePath`) with `/var/cache/distfiles` as system.

On refuse: log error, exit `1`, do not delete. When not system, delete the directory tree contents (or the directory and recreate empty `0700`) for the manager cache only.

**Alternatives:** never allow system path (too rigid); allow `eclean` with `--force` on system (rejected — footgun).

### D3 — Preflight probe (before package mutation)

On `update` spine after tool preflight (and alongside other gates), for the resolved DISTDIR:

1. Ensure directory exists (`0700`).
2. Write a unique probe file (e.g. `.mndz-om-distfiles-probe.$$`).
3. Rename it to a second name in the same directory (models Portage `.__download__` → final).
4. Unlink the probe.

Any failure → hard-fail the command with a message naming the DISTDIR and explaining sticky/ownership / pointing at default private path and `eclean` (not for system wipe). No package mutation, no assets publish for that run.

`list` / `outdated` / `gencache` do **not** require this probe (no `ebuild manifest`).

### D4 — Ebuild runner environment

For every production `ebuild … manifest` invocation:

1. Start from full parent environment (`getEnvironment`).
2. Set `DISTDIR` to the resolved private (or overridden) path.
3. **Disable Gentoo mirror tries** for this child so Portage does not fetch `.layout.conf.<host>` from `GENTOO_MIRRORS`:

   **Pinned form (spike):** set `GENTOO_MIRRORS` to the empty string in the child env.

   Rationale: Portage only walks `GENTOO_MIRRORS` when `try_mirrors` is on; an empty list skips mirror URL construction and thus `async_mirror_url` / layout.conf.  

   **Not** `FEATURES=-mirror`: the FEATURES token `mirror` means “fetch all SRC_URI for mirror distribution,” not “use GENTOO_MIRRORS.” Using FEATURES would not achieve the intent.

4. Merge env carefully: replace any existing `DISTDIR` / `GENTOO_MIRRORS` keys; keep `PATH`, `HOME`, SSH/GPG agent vars, etc.

Implementation: extend `mkEbuildRunner` / `productionEbuildRunner` to take the resolved distfiles path (or a small `DistfilesEnv` record) and always pass `prEnv = Just merged`.

### D5 — Sticky / EPERM message mapping

When `ebuild manifest` fails, if stderr matches known signatures (case-insensitive / substring):

- `Operation not permitted` with `distfiles` or `.__download__` or `.layout.conf`
- Portage `Failed to move` under DISTDIR

Then the unit hard-fail text SHALL include, in addition to truncated stderr:

- that DISTDIR may be sticky or not owned by the operator
- the resolved DISTDIR path in use
- guidance: use default private path or a user-owned `distfiles-path`; do not share system sticky distfiles without fixing ownership

This is additive to existing `ebuild manifest failed: …` wording.

### D6 — `eclean` command shape

```text
mndz-overlay-manager [--config FILE] [--distfiles-path DIR] eclean
```

- Loads config only as needed for `distfiles-path` (overlay validity not required).
- Resolves distfiles path (CLI → config → XDG default).
- Refuses system DISTDIR (D2).
- Deletes manager cache contents; success exit `0`.
- Missing cache dir: success (nothing to clean) or informational no-op — prefer **success** with log that path was absent.
- Help: top-level one-liner; `eclean --help` describes manager distfiles only and names the default path pattern.

No dry-run in v1 (can add later).

### D7 — Config / CLI wiring

- `OverlayConfig`: add `distfilesPath :: Maybe FilePath` (`optKey "distfiles-path"`).
- Global options: `--distfiles-path` alongside `--overlay-path`.
- Effective path function used by update preflight, ebuild runner construction, and `eclean`.

### D8 — Module placement (suggested)

| Concern | Suggested home |
|---------|----------------|
| Default XDG path, resolve, system-DISTDIR predicate, ensure `0700`, probe | new small module e.g. `Update.Distfiles` or `Config.Distfiles` |
| Ebuild env merge | `Update.Apply.Env` |
| `eclean` command | CLI command module + Main dispatch |
| Tests | pure resolution + temp-dir probe + env construction fakes; integration optional |

Prefer pure path resolution for unit tests; IO for probe/eclean in temp directories.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Re-download distfiles already only in system DISTDIR | Accept; document; optional hardlink later |
| Operator points at system DISTDIR and hits EPERM again | Preflight probe catches sticky rename; C maps residual errors; docs warn |
| Empty `GENTOO_MIRRORS` breaks `mirror://` SRC_URI packages | Overlay packages under automation use absolute HTTPS SRC_URI; document limitation; escape hatch is override without empty mirrors only if we later split flags — for v1 always empty GENTOO_MIRRORS on ebuild child |
| `eclean` deletes wrong tree | System path refuse; only delete resolved manager path |
| `prEnv = Just` drops agent env if merge wrong | Always merge full `getEnvironment` first |
| Parallel manifests race same basename | Portage uses unique temp names; single shared DISTDIR is OK |

## Migration Plan

1. Ship default private DISTDIR — no config required for the fix.
2. Operators with large system caches: first `update` re-fetches needed SRC_URI into XDG cache; disk grows until `eclean`.
3. No overlay repo migration.
4. Rollback: remove private path / env (revert binary); no host state required beyond optional leftover XDG cache dir (safe to `rm -rf`).

## Open Questions

None blocking. Implementation may refine system-DISTDIR detection (`portageq` vs path constants) without changing requirements if both refuse `/var/cache/distfiles` and the live Portage DISTDIR when queryable.
