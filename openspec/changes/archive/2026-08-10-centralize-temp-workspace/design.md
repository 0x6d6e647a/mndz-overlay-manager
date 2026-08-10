## Context

See proposal.md for motivation. Today product scratch is created with `withSystemTempDirectory` at seven call sites under the effective temp root (`resolveTempRoot`: usable `TMPDIR`, else process default). Each helper always deletes on scope exit (success and failure). Specs for Go and Bun (and Cargo) require removing temp work when a PV attempt finishes; hard-fail forensics are lost. Free-space preflight already measures the temp-root filesystem; manager distfiles use a separate durable XDG path.

## Goals / Non-Goals

**Goals:**

- Single ownership model for product scratch: run root → unit tree → `out`/`work`
- Deterministic paths operators can open after hard-fail
- Immediate reclaim of successful/soft-skipped unit trees under concurrent `--jobs`
- Clean full-run success (run root gone; empty `overlay-manager` and `mndz` pruned)
- Shared API so new features cannot reintroduce free-floating system temps for product work

**Non-Goals:**

- Folding XDG manager distfiles, overlay-path, or assets-path into the workspace
- Temp GC CLI or signal-safe cleanup on SIGKILL
- Changing disk-space estimate formulas
- Forcing unit-test harnesses onto the product workspace layout

## Decisions

### D1: Workspace module + run handle on the update spine

**Choice:** Introduce a small workspace API (e.g. `Update.TempWorkspace` or similar) that:

1. Reuses `resolveTempRoot` for the effective temp root
2. Opens one **run root** per process that will perform heavy product scratch (primarily `update` apply)
3. Allocates **unit** directories under that run
4. Provides cleanup helpers (unit success, run success with upward prune)

Pass a run handle (or unit allocator) through `ApplyEnv` / materialize so ecosystem builders receive explicit `out` and `work` paths instead of creating their own temps.

**Alternatives considered:** Set `TMPDIR` for the whole process to the run root (fragile: breaks nested assumptions, third-party tools, tests). Keep independent `withSystemTempDirectory` under a branded prefix only (no structured unit lifecycle).

### D2: Path layout (locked)

```
<tempRoot>/mndz/overlay-manager/<run-id>/
  <category>/<package>/<pv>-full|reuse/
    out/
    work/
```

- **Run id:** local-time ISO 8601 with **offset**, seconds precision, plus `-<pid>.<random>` (short hex or similar) for uniqueness
- **Category/package:** real path segments (Portage-shaped)
- **Unit kind:** `full` vs `reuse` only for now
- **Payload:** fixed `out/` (staged distfiles / downloads) and `work/` (clones, caches, dist dirs, stages)

### D3: Lifecycle (locked)

| Outcome | Action |
|---------|--------|
| Unit success or soft-skip | Delete unit dir immediately; prune empty package then category under run root |
| Unit hard-fail | Keep unit dir; error text includes absolute unit path |
| Pre-unit failure (no unit opened) | No retained path (E1) |
| Run ends with no hard-fails | Delete run root; if empty, remove `overlay-manager/`; if empty, remove `mndz/` under temp root |
| Run ends with any hard-fail | Leave run root (only failed units should remain if successes were cleaned immediately) |
| Process crash | Residuals accepted |

Track whether any hard-fail occurred (or whether any unit was retained) to decide run-root deletion. Concurrent package jobs only create children under the shared run root (create run root once before parallel work).

### D4: Builder API change

**Choice:** Ecosystem entry points take parent paths (at least `workDir` and `outDir` for a unit) rather than calling `withSystemTempDirectory`. Materialize:

1. Allocates unit (`…/<pv>-full` or `…/<pv>-reuse`)
2. Creates `out` and `work`
3. Calls builder with those paths
4. On success/soft-skip → cleanup unit; on hard-fail → leave and attach path to error

**Alternatives considered:** Keep builders self-temping and only nest under run root via a custom temp directory function (harder to enforce unit granularity and selective retain).

### D5: Free-space measurement unchanged

**Choice:** Continue measuring free space on the **effective temp root** filesystem (same as today). Product writes land under `mndz/overlay-manager/<run-id>/` on that filesystem. Error hints may mention the run path when one exists; no change to need estimation.

### D6: Durable paths stay out of the workspace

Manager distfiles (`…/mndz/overlay-manager/distfiles` under XDG), overlay, and assets remain separate. Note the shared `mndz/overlay-manager` brand prefix across XDG cache vs TMPDIR — different roots, similar naming by design.

### D7: Random segment

**Choice:** Short non-cryptographic random hex (e.g. 4–8 hex chars) after pid. Sufficient for same-second multi-process uniqueness with pid.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Residual trees fill tmpfs after failures/crashes | Document in README; free-space gate still sees reduced free; operator `rm -rf` under `$TMPDIR/mndz/overlay-manager` |
| Same-second multi-process collision | `pid` + random in run id |
| Incomplete migration leaves a free-floating temp site | Grep gate in tasks; project-wide rule in `temp-workspace` spec |
| Hard-fail without path if error path forgets enrichment | Centralize unit cleanup/error wrapper so hard-fail after unit open always attaches path |
| Multi-PV sequential units share package parent | Per-unit dirs + immediate success delete keep only the failing PV kind |
| Empty-parent prune races under `--jobs` | Only delete a package/category dir if empty after unit delete; ignore benign races or serialize prune per parent |

## Migration Plan

1. Land workspace module + tests for path construction and cleanup helpers
2. Wire run root on update apply path; plumb into materialize
3. Convert materialize out/reuse, then each ecosystem builder
4. Update hard-fail messages; flip specs already drafted in this change
5. README TMPDIR section
6. `hk check` / coverage as required by CONTRIBUTING

Rollback: revert change; no on-disk migration of user data (temps are ephemeral).

## Open Questions

None that affect specs or task breakdown. Implementation may choose exact random width and module module name without further design.
