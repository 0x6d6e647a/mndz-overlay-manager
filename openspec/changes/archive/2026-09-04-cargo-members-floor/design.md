## Context

See `proposal.md` for why. After `cargo-floor-parity`, `Update.Cargo.Msrv.probeDirectTagFloor` still walks at most three tagged paths and returns the first direct rust-version. `rust-version.workspace = true` is `Right Nothing` and probing continues. `maxRustVersionInTree` recursively maxes every `Cargo.toml` under the clone. `RuntimeLanePlan` stores `glpDirectTagFloors :: [(PV, Maybe Text)]` and `glpFloorPolicy` version `"1"`. Candidate selection maps complete absence to `"0.0.0"`. Production apply does not re-fetch Cargo.toml. Those formulas and the eleven parity decisions stay locked; this design only replaces how `T(pv)` and `Hclone` are computed and how incomplete or watched-OS facts fail closed.

`dpoFetchCargoToml` is still raw.githubusercontent.com GET of a known path. There is no GitHub tree listing. The walker must request literal paths.

## Goals / Non-Goals

**Goals:**

- One callback-parameterized path-closure walker used at tag time (HTTP) and clone harvest (filesystem).
- Table-aware inheritance resolution and an enabled-feature local path graph.
- Coverage, provenance, and policy version `2` on the existing selected-PV snapshot.
- Fail-closed plan errors versus skippable incomplete candidates versus complete absence, as specified.
- `Hclone` on the active set only; harvest versus selected rust ceiling before overlay writes.

**Non-Goals:**

- GitHub tree/glob APIs; max-all-members; `default-members`; pycargo at a virtual root; USE flags from Cargo features; `FloorPayload`; crates.io / `cargo-msrv`; Go/Npm/Bun/Sbcl apply re-fetch removal; public library exports for walker types.

## Decisions

### D1. Walker lives in `Update.Cargo.Msrv`, still without importing `Update.Deps.Plan`

Extend `Msrv` with a result type conceptually:

```text
TagFloorResult
    Complete { floor :: Maybe Text, provenance :: [(path, Maybe Text)] }
    Incomplete { reasons :: [Text], provenance :: [(path, Maybe Text)] }
    Failed Text
```

`probeDirectTagFloor` remains for tests that only need a direct field, or is reimplemented as a thin wrapper. Production planning calls a new `probePolicyTagFloor` (name internal) with:

- policy package path, lock path
- fetch callback `Maybe FilePath -> IO CargoTomlFetch` (same as today)
- optional on-disk root for harvest

`Update.Deps.Plan.planCargo` maps `Complete (Just v)` → store `Just v`, lane req `Just v`; `Complete Nothing` → store `Nothing`, lane req `Just "0.0.0"`; `Incomplete` → lane req `Nothing` (skip candidate), do not persist; `Failed` → `PlanProbeFailed`. Hard-fail cases in the spec (escape, virtual root without subdir, watched raise) are `Failed`, not `Incomplete`.

**Alternatives:** a new `Update.Cargo.Workspace` module — acceptable if `Msrv` grows past one-file comfort; do not put the walker in `Plan.hs` (cycle risk). Exact Cargo `cargo metadata` — requires clone at probe time.

### D2. Active set is enabled-feature path closure, not `workspace.members`

Start at `cargoPackageSubdir <|> cargoLockSubdir <|> root`. Parse `[dependencies]`, `[build-dependencies]`, and classified `[target.*.dependencies]` / `[target.*.build-dependencies]`. Skip `[dev-dependencies]`.

For each dep:

- `path = "rel"` → follow if the edge is enabled
- `workspace = true` → look up `[workspace.dependencies]` on the workspace document; follow only if that entry is a path
- enabled = features listed on the line ∪ the dep package’s `default` features, unless `default-features = false`
- follow `dep:name` optional path deps those enabled features turn on
- `name/feature` enables feature `feature` on path-dep `name` and, if `name` is optional, enables that dep (Cargo namespaced features; `mise` `vfox/vendored-lua`, `usage` `usage-argv/spec`)
- `name?/feature` is weak: it does not enable optional `name` by itself; if `name` is already enabled, request `feature` on it
- registry/git sources stop the walk

Visit each normalized repo-relative path once (cycles). `foo = { workspace = true, features = ["a"] }` merges with the workspace dependency’s path and features.

Unreadable feature / `dep:` syntax → `Incomplete`. Weak `dep:name?` is unreadable. Do not implement full Cargo feature unification or `cfg` on dependency entries beyond: if the syntax cannot be interpreted, incomplete.

**Alternatives considered:** max-all-members (contaminates `usage` with benches/xtask); all optional paths regardless of features (lets `usage-test` raise the binary); non-optional only (misses default-on `usage-derive`).

### D3. Workspace document for inheritance

When a reached package has `rust-version.workspace = true` and no direct `[package].rust-version`:

1. If `package.workspace` is a relative path, fetch that `Cargo.toml` (joined with the package dir, then normalized).
2. Else fetch lock-root `Cargo.toml`, then repository-root `Cargo.toml`, and use `[workspace.package].rust-version` from the first that is a workspace document.

A workspace pointer that normalizes outside the tagged tree is `Failed`. If no workspace document can be identified, that package is `Incomplete`. Direct `[package].rust-version` still wins in the same file (existing parser).

### D4. Target tables: exclude windows/wasm; watch macos/BSD-only; active otherwise

Classify each `[target.'cfg(…)']` / `[target.<triple>]` table:

| Class | Examples | Role |
|-------|----------|------|
| Ignore | `cfg(windows)`, `target_family = "windows"`, `*-pc-windows-*`, `wasm32-*`, `target_arch = "wasm32"` | Do not walk |
| Watched | `target_os = "macos"` / `"freebsd"` / `"netbsd"` / `"openbsd"` / `"dragonfly"`, `*-apple-darwin`, `*-unknown-freebsd` | Walk for comparison only |
| Active | `cfg(unix)`, Linux triples, `cfg(not(windows))`, `cfg(target_os = "linux")` | In `T` and `Hclone` |
| Incomplete | unparsed `cfg` | Candidate incomplete |

Compute `T_active` and `T_watched`. If `T_watched` is strictly greater than `T_active` (absent `<` present), `Failed` naming watched path, watched floor, active floor. Successful `T` and `Hclone` use **active only**.

When Darwin/BSD become overlay KEYWORDS later, move those OS families from watched to active; no walker rewrite.

**Alternatives:** Linux-gnu-only evaluation (closes Prefix-on-Darwin); include macos/BSD in `T` silently (over-constrains Linux).

### D5. Escape vs in-tree 404

Normalize every followed path against the repository root (tag-time: no `..` above root; harvest: `canonicalize` staying under clone root). Escape → `Failed` with the path. In-tree 404 / `CargoTomlMissing` on a **needed** path → `Incomplete` (walker may have joined wrong; do not take down the package). Expected missing **policy** path still falls through to lock/root only when discovering the policy package itself (empty repo-root package on a virtual workspace with a subdir is normal).

Virtual workspace (`[workspace]` present, `[package]` absent) at the start path when `cargoPackageSubdir` is unset → `Failed` asking for a package subdirectory. When the subdir is set, the workspace document is used for inheritance and `workspace.dependencies` only.

### D6. Snapshot and cache key

Bump `cargoFloorPolicyVersion` to `"2"`. Keep `cargoFloorPolicyKey` shape `version|prefix=…|pkg=…|lock=…`.

Serialize per selected PV (names internal):

```text
{ pv, floor :: Maybe Text,
  coverage: "complete" | "incomplete",
  reasons: [Text],          -- empty when complete
  provenance: [{ path, floor :: Maybe Text }]
}
```

`cachedCargoPlanUsable` requires policy key match, a snapshot for every unique planned PV, and complete/incomplete coverage present. v1 entries (floor only, or policy version `1`) miss. Non-selected candidate walks stay in an in-memory `MVar` keyed by `(tag, path)` for the duration of `planCargo` only.

Do not persist donor floors. Do not add `FloorPayload`. Do not change Go/Npm/Bun/Sbcl JSON.

### D7. `Hclone` uses the same walker on the clone

Replace recursive `findCargoTomls` / `maxRustVersionInTree` as the build-floor clone operand with the walker rooted at `pycargoDir` / lock root on disk, resolving inheritance from files on disk. `harvestRegistryPackageRoots` is unchanged. Registry harvest still does not resolve workspace members of a crates.io crate beyond that package-root manifest (existing nested-example exclusion).

Harvest versus lane: after both harvests, let `H = max(Hclone, Hregistry)`. For each `LaneTarget` whose `ltPackagePV` is this PV and that has a rust ceiling, if `H` is strictly greater than that ceiling, hard-fail before overlay writes. If several lanes selected the PV, any ceiling below `H` fails (the ebuild must build for every selecting lane). Error text names planned `T`, `H`, the binding ceiling, and the PV. Do not switch `ExpectedReuse`/`ExpectedFull`.

### D8. Module and test boundaries

- `Update.Cargo.Msrv`: parse, normalize, walker, target classification, coverage. No `Plan` import.
- `Update.Deps.Plan`: fetch callback, map results onto candidates and selected snapshots.
- `Update.Go.Lanes`: snapshot fields if the current pair list is insufficient; keep `other-modules`.
- `Update.CheckCache`: JSON encode/decode and `cachedCargoPlanUsable`.
- `Update.Cargo.Crates`: disk walker for `Hclone`; keep registry harvest.
- `Update.Apply.Materialize`: harvest-versus-ceiling using plan lanes.
- `Update.Materialize.Floors`: still reads declared snapshot floor, never `"0.0.0"` absence.

Tests: table-driven walker (inheritance, path closure, default-on optional, dev-dep skip, glob-irrelevant members, escape, in-tree 404, windows ignore, watched raise, watched equal, unparsed cfg); lane skip of incomplete; cache v1 miss / v2 round-trip / zero re-fetch; `Hclone` ignores benches; harvest > ceiling no overlay write. Prefer fixtures over network.

## Risks / Trade-offs

- [Enabled-feature closure is not full Cargo] → Named manager policy; unreadable syntax is incomplete, not a guessed graph.
- [Watched macos/BSD crate with a higher floor hard-fails Linux planning] → Intentional until those OS families are overlay KEYWORDS; equal floors do not fail.
- [Newest incomplete tag skipped] → Operator may see an older PV; louder than 0.0.0 admission, quieter than package-wide fail. Escape / virtual-root / watched-raise stay package-wide fails.
- [More raw.githubusercontent.com GETs per candidate] → In-memory `(tag, path)` memo; path closure for `usage` is tens of files, not hundreds; probe still newest-first until lanes fill.
- [Narrowing `Hclone` can lower a future full-path write versus today’s tree max] → That is the check/write fix; registry harvest still raises for `kdl`.
- [Harvest > ceiling cannot pick a lower PV] → Locked no-route-switch; fail closed instead of writing an ebuild that cannot build on the admitting lane.

## Migration Plan

- Policy version `2` makes existing Cargo deps cache entries miss; live plan replaces them. Overlay files unchanged until apply.
- First full Cargo path after this change may write a lower clone-harvest floor than a previous tree-wide max if unrelated members had been contributing. Same-PV rewrite still ratchets with `D(pv)`.
- No CLI, config, or README/CONTRIBUTING/AGENTS change. New errors are fail-closed strings (escape path; missing package subdir; watched raise; harvest vs ceiling).
- Rollback: policy v2 fields ignored or miss; already-written `RUST_MIN_VER` remains a valid conservative constraint.

## Open Questions

None. Remaining edges (in-tree 404 → incomplete, unparsed cfg → incomplete, `[patch]` in-tree follow / escape fail, cycle visit-once) are specified above.
