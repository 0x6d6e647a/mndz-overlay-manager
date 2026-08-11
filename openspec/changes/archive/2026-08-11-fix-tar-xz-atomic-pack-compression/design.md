## Context

See `proposal.md` for motivation. Today:

| Ecosystem | Pack entry | `XZ_OPT` | Atomic temp |
|-----------|------------|----------|-------------|
| Cargo | `createArchiveAtomic` → `tar -acf ${out}.tmp` | `-T0 -9e` | **Yes — broken** (`.tmp` disables `tar -a`) |
| Go | `tarXzGoMod` → `tar -acf ${out}` | `-T0 -9` | No (write final path) |
| Npm / Bun | `tar -acf ${out}` | `-T0 -9` | No |
| Sbcl | `tar -acf ${out}` from stage | `-T0 -9` | No |

XZ magic on local distfiles confirms only post–manager-owned Cargo packs (hk 1.54.1, usage 5.1.0, mise 2026.8.3+) are plain tar; other ecosystems are real XZ.

Operator cleanup of published bad assets is out of band (`uncompressed-tar-artifacts-cleanup.md`).

## Goals / Non-Goals

**Goals:**

- One correct pattern for “write xz archive, optionally via atomic replace.”
- Uniform extreme multi-thread xz (`-T0 -9e`) on every DepsAndAssets `*.tar.xz` pack.
- Post-pack hard-fail if the final file is not xz (catches `tar -a` footguns and silent non-compress).
- Tests that would have failed on the `.tmp` bug and that lock `XZ_OPT` to include `-9e`.

**Non-Goals:**

- Shared module that every ecosystem must call if a thin per-call fix + shared verify is enough (prefer shared helper, not mandatory mega-refactor).
- Upload timeout / streaming HTTP.
- Recompressing already-published historical assets from the tool.

## Decisions

### D1 — Fix atomic path by preserving an xz-selecting suffix

**Choice:** When atomically packing to `finalPath` ending in `.xz` (or `.tar.xz`), write tar’s output to a sibling temp whose **name still ends in `.xz`** (e.g. `finalPath <> ".partial"` → `…tar.xz.partial`, or `finalPath <.> "writing"` pattern that keeps `.xz` as the compression-relevant suffix). After success, `rename` to `finalPath`.

**Why not only force `-J`:** Explicit `-J`/`--xz` is also good and makes `-a` irrelevant; combining **forced xz filter** with a temp name that would still work under `-a` is belt-and-suspenders. Prefer:

1. `tar -cJf tmp …` or `tar -acf tmp` where `tmp` ends with `.xz`, **and**
2. env `XZ_OPT=-T0 -9e`.

**Rejected:** Keep `${out}.tmp` and document that operators must not use `-a` — too easy to regress.  
**Rejected:** Write non-atomic to final path for Cargo only — loses partial-write safety the atomic path intended.

### D2 — Shared helper for xz pack + verify

**Choice:** Extract a small internal helper (e.g. under `Update.Process` or `Update.Pack.XzTar`) used by Cargo and ideally Go/npm/Bun/Sbcl:

```text
packTarXzAtomic :: CommandRunner -> cwd/stage args -> finalPath -> IO (Either Text ())
  -- sets XZ_OPT=-T0 -9e
  -- tar creates compressed archive at temp-with-.xz-suffix
  -- rename to finalPath
  -- verifyXzMagic finalPath
```

Non-atomic packs can call a `packTarXz` that writes `finalPath` directly then verifies.

**Verify:** Read first bytes / use a pure magic check for xz stream header `FD 37 7A 58 5A 00` (no subprocess required in tests). Hard-fail with a message that mentions plain tar / compression failure if magic mismatches.

### D3 — Uniform `XZ_OPT=-T0 -9e`

**Choice:** All DepsAndAssets tar.xz packs set exactly that env (replace `-9` with `-9e`). Specs updated so “suitable for large artifacts” means extreme multi-thread, not preset 9 only.

**Trade-off:** More CPU on Go/npm/Bun/Sbcl packs; smaller artifacts; matches Cargo’s stated product intent from `2026-08-07-cargo-crates-tarball-pack`.

### D4 — Tests

| Case | Approach |
|------|----------|
| Cargo atomic temp does not end in bare `.tmp` without xz | Scripted `CommandRunner` records argv; assert archive path passed to tar ends with `.xz` (or `-J` present) |
| Produced file is real XZ | Integration-style unit test with real `tar`/`xz` on a tiny stage tree (gate: tools on PATH), or magic check after runner that writes real xz |
| `XZ_OPT` contains `-T0` and `-9e` | Assert on `prEnv` for pack requests across Cargo + at least one other ecosystem pack helper |
| Verify rejects plain tar | Write a tiny plain tar named `.tar.xz`, call verify → Left |

Avoid depending on live network or full pycargoebuild for the footgun test.

### D5 — Models JSON and non-tar assets

**Choice:** XZ verification applies only to paths that are `*.tar.xz` (or packed as xz tarballs). `*-models.json` and similar remain unchanged.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Temp `*.tar.xz.partial` still confuses some tar builds | Prefer explicit `-J`/`--xz` so suffix is secondary |
| `rename` across filesystems fails | Keep temp in same directory as final (current pattern) |
| Real `tar`/`xz` missing in CI | Prefer magic + argv tests as default; optional tool-gated case |
| `-9e` slower on large Go/Bun trees | Accept; matches space-first policy; multi-thread `-T0` bounds wall time |
| Operators re-run update before cleanup | Handoff documents reuse hazards; not this change’s job |

## Migration Plan

1. Land code + tests; `hk check` green.  
2. Operators run `uncompressed-tar-artifacts-cleanup.md` for already-published plain tars.  
3. No config migration. Rollback = revert commit (old bug returns for Cargo atomic pack).

## Open Questions

None that block implementation. Optional later: raise GitHub upload `responseTimeout` for multi‑hundred‑MiB assets (orthogonal).
