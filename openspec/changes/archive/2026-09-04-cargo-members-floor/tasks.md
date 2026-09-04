## 1. Path-closure walker and inheritance

- [x] 1.1 In `Update.Cargo.Msrv`, add an internal tag-floor result (complete with optional floor and provenance, incomplete with reasons, failed) and a callback-parameterized walker that starts at the policy package (`package <|> lock <|> root`). Keep `Update.Cargo.Msrv` free of `Update.Deps.Plan` imports. Verify `cabal build all`.
- [x] 1.2 Resolve `rust-version.workspace = true` against `package.workspace` when present, otherwise lock-root then repository-root `[workspace.package]`. Direct `[package].rust-version` still wins in the same file. Verify tests: resolved inheritance `1.91`, missing workspace document is incomplete, `package.workspace` escape hard-fails, same-file package field still precedes workspace.package.
- [x] 1.3 Walk enabled-feature local path deps: `[dependencies]` and `[build-dependencies]`; honor `default-features = false`; union listed features with the dep’s `default`; follow `dep:` optional path crates; resolve `workspace = true` via `[workspace.dependencies]`; skip `[dev-dependencies]`; visit each normalized path once. Unreadable feature/`dep:` syntax is incomplete. `name/feature` is readable (enables that feature on path-dep `name`); `name?/feature` is weak and does not enable optional `name` by itself. Verify tests: `usage`-style `cli` plus `usage-rs`/`lib`/`derive`, default-on optional raises the floor, dev-only path crate does not, xtask/benches members do not, cycles do not loop, in-tree missing path is incomplete, `vfox/vendored-lua` and `usage-argv/spec` complete, `usage-test?/completions` does not raise, `dep:foo?` remains incomplete.
- [x] 1.4 Classify `[target]` tables: ignore windows/wasm-only; watch macos/BSD-only; treat `cfg(unix)`, Linux triples, and `cfg(not(windows))` as active; unparsed cfg is incomplete. If watched max strictly exceeds active max (absent < present), fail and name watched path, watched floor, and active floor. Equal watched floors succeed. Verify tests for ignore, watched-raise fail, watched-equal success, unix included, unparsed incomplete.
- [x] 1.5 Hard-fail a path that normalizes outside the tagged/clone root (error names the path). Hard-fail a virtual workspace start path when `cargoPackageSubdir` is unset (error asks for a package subdirectory). Follow in-tree `[patch]` paths; escaping patch paths hard-fail. Verify those failure tests.

## 2. Planning, lanes, and fail-closed mapping

- [x] 2.1 Wire `planCargo` to the walker. Complete `Just v` stores `Just v` and uses it as the lane requirement. Complete `Nothing` stores absence and uses selection-only `"0.0.0"`. Incomplete yields `vcGoReq = Nothing` (skip candidate, do not persist). Walker `Failed` is `PlanProbeFailed`. Memoize fetches in memory by `(tag, path)` for the plan only. Verify ordered-candidate tests: incomplete newest skipped for an older complete PV; complete empty still selects with `0.0.0`; parse/HTTP failure still fails the package.
- [x] 2.2 Keep donor/template/harvest out of lane selection. Confirm materialize-image rust lookup still uses the declared snapshot floor and never treats complete absence as `0.0.0`. Verify existing donor-1.95 vs tag-1.91 lane tests plus the new absence-vs-image-floor case.

## 3. Snapshot enrichment and cache policy v2

- [x] 3.1 Bump `cargoFloorPolicyVersion` to `"2"` and extend selected-PV serialization with coverage, reasons, and per-path provenance inside the existing `DepsPayload`. Do not add `FloorPayload`. Verify JSON round-trip of a complete snapshot with provenance.
- [x] 3.2 Treat v1 Cargo plans (missing coverage or policy version `1`) as misses; keep otherwise-valid non-Cargo entries usable. Policy key still includes prefix and Cargo package/lock paths. Verify old-Cargo miss, v2 hit with zero Cargo.toml re-fetch, non-Cargo compatibility, and prefix/subdir/policy-version invalidation.

## 4. Clone harvest alignment and harvest-versus-ceiling

- [x] 4.1 Replace recursive whole-tree `Hclone` with the same walker on the clone (filesystem fetch). Keep registry package-root harvest unchanged. Resolve inheritance on disk the same way as at tag time. Verify clone `1.91` plus bench/xtask `1.99` writes `1.91` from clone harvest, and registry `1.95` still raises the build floor.
- [x] 4.2 After pack, if `max(Hclone, Hregistry)` is strictly greater than any selecting lane’s rust ceiling, hard-fail before ebuild/Manifest/publish/commit. Error names planned tag floor, harvest floor, the binding ceiling, and PV. Do not switch reuse/full routes. Verify no-write coverage for harvest `1.95` under ceiling `1.92`.

## 5. Adequacy, outdated, and apply consumption

- [x] 5.1 Decision and reuse-write floors continue to use the planned tag snapshot (now member-aware). Incomplete PVs never become reuse-write `"0.0.0"`. Verify `usage` path-closure adequacy, incomplete candidate not listed as a `0.0.0` outdated `TO`, and apply still does not re-fetch tagged Cargo.toml on a valid plan.
- [x] 5.2 Confirm production apply, direct plan-and-apply, and outdated share the same snapshot. Update constructors/fixtures that build `RuntimeLanePlan` / cache JSON. Verify non-Cargo Go/Npm/Bun/Sbcl planning, cache, image-floor, reuse, and apply tests stay green.

## 6. Cleanup and gates

- [x] 6.1 Remove or narrow any recursive clone-toml harvest that is no longer the build-floor operand. Keep numeric combinators that remain live. Do not expand `exposed-modules` or weeder roots. Clear stale `.hie` if module changes require it. Verify `cabal build all`.
- [x] 6.2 Per `project-docs`, confirm no README/CONTRIBUTING/AGENTS change (no CLI/config/tooling change; new errors are fail-closed strings only). Do not manually copy delta specs into living `openspec/specs/`.
- [x] 6.3 Run `openspec validate cargo-members-floor --strict --json` and resolve every issue. Confirm the change still contains deltas for `cargo-crates-assets`, `runtime-lanes`, `check-cache`, `deps-assets`, `outdated-command`, and `ensure-materialize-image`.
- [x] 6.4 Run the full required quality gate `hk check` (build, coverage-enabled tests, formatting, hlint, stan, weeder) and confirm exit success before marking implementation complete.
