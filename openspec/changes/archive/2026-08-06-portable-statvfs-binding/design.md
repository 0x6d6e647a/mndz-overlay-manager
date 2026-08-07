## Context

See proposal.md — Why. Current production free-space path is `getFreeBytes` → `getFreeBytesStatvfs` in `Update.DiskSpace`, which calls POSIX `statvfs` via FFI and peeks `f_frsize` / `f_bavail` with hardcoded size `112` and offsets `8` / `32` (glibc LP64 x86_64 layout). Pure gate math and `DiskSpaceProbe` injection already isolate unit tests from real layout. Device identity uses portable `System.Posix.Files` and is out of scope. The `unix` package provides no free-space API. No `.hsc` or `c-sources` exist in the package yet; `hsc2hs` is available via the GHC toolchain. Product remains a Linux Gentoo operator tool (not multi-OS).

## Goals / Non-Goals

**Goals:**

- Derive `struct statvfs` size and field offsets at **compile time** from the build sysroot headers.
- Preserve the existing `getFreeBytes` / `DiskSpaceProbe` contracts and pure feasibility evaluation.
- Keep the binding small and internal (`other-modules`); do not expand public surface without need.
- Prove the production path with a non-flaky smoke test on a real path.

**Non-Goals:**

- Full `struct statvfs` Haskell API (only free-byte math: `f_bavail * f_frsize`).
- C helper alternative (rejected in favor of hsc2hs for this change).
- Shell-out to `df`.
- Multi-arch CI matrices (optional later; correctness follows the headers used when building).
- Estimate / gate / Portage policy changes.

## Decisions

### 1. hsc2hs module over C helper or `df`

**Choice:** New `Update.DiskSpace.StatVfs` implemented as `src/Update/DiskSpace/StatVfs.hsc`.

**Rationale:** Layout tracks compile-time `<sys/statvfs.h>`; stays Haskell-centric; Cabal Simple preprocesses `.hsc` without extra build-type machinery; matches the explored Option A recommendation.

**Alternatives considered:**

| Option | Why not |
|--------|---------|
| Tiny C helper (`mndz_free_bytes`) | Fine audit story, but introduces first C sources when hsc2hs is enough for two peeks |
| Shell out to `df -B1` | Process/PATH surface, parsing fragility, worse test story |
| Keep hardcodes | Known wrong on 32-bit; unverified on musl; accidental on aarch64 |

### 2. Thin `#{size}` / `#{peek}` rather than full `Storable` instance

**Choice:** `allocaBytes #{size struct statvfs}` plus `#{peek struct statvfs, f_frsize}` and `#{peek struct statvfs, f_bavail}` (typed as `CULong`), multiply with `toInteger`.

**Rationale:** Same control flow as today’s probe with zero magic numbers; full `Storable` is ceremony for a one-shot read-only fill via `statvfs`.

**Alternatives considered:** Full `data CStatvfs` + `Storable` — acceptable if preferred later; not required for correctness.

### 3. Module visibility and wiring

**Choice:**

- `Update.DiskSpace.StatVfs` in **`other-modules`** (not `exposed-modules`).
- Export a single entrypoint e.g. `freeBytesStatvfs :: FilePath -> IO Integer` that throws `IOError` on failure (same as current low-level path).
- `Update.DiskSpace.getFreeBytes` continues to wrap with `try @IOError` → `Either Text Integer`.
- Keep exported `getFreeBytesStatvfs` as a thin alias to the new helper (or reimplement body via import) so the public export list does not need churn.

**Rationale:** App and tests only need `getFreeBytes`; AGENTS.md discourages casual public surface expansion.

### 4. Field types

**Choice:** Peek as `CULong` and convert with `toInteger` before multiply.

**Rationale:** Matches glibc’s typical `unsigned long` / `fsblkcnt_t` on LP64 Linux; avoids hardcoding `Word64` layout assumptions.

### 5. Testing strategy

**Choice:**

- Leave pure / injected `Test.DiskSpace` gate tests unchanged.
- Add one **smoke** case: resolve a usable temp path (or `withSystemTempDirectory`), call `getFreeBytes`, expect `Right n` with `n >= 0`.
- Do not assert exact free space or `sizeof == 112`.

**Rationale:** Proves real FFI + non-negative free bytes without flaky absolute values.

### 6. Specs

**Choice:** `skip_specs: true`. Living `disk-space-preflight` already requires free bytes on the backing filesystem; this change does not alter operator-visible gate semantics on correctly built hosts.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| First `.hsc` surprises quality hooks (ormolu/hlint paths) | Run full `hk check`; adjust only if a tool genuinely cannot see `.hsc` (prefer formatting the source the hooks touch). |
| Stale HIE after module add → stan/weeder false failures | `cabal build all` (or full gate) before static analysis; HIE under `.hie/lib/`. |
| Cross-compile against wrong headers | Correctness is always “for the sysroot you build with”; document Linux Gentoo host builds as the normal path. |
| Weeder flags unused StatVfs exports | Keep the module minimal; only export what `DiskSpace` uses. |
| Smoke fails on exotic CI mounts | Use process temp / system temp directory that must exist for the test suite already. |

## Migration Plan

1. Land the `.hsc` module and wire `DiskSpace`; delete hardcodes in the same change.
2. No config or CLI migration; operators see no interface change.
3. Rollback = revert the change (restore hardcodes only if urgently needed — prefer forward fix).
4. Deferred note `manager-arch-portability.md` may be marked done or removed after archive; not required for gate green.

## Open Questions

None for apply readiness. Optional later: multi-arch CI smoke (aarch64) when such CI exists.
