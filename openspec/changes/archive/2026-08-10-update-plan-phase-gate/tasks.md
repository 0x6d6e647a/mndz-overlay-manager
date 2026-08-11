## 1. Plan types and pure unit builders

- [x] 1.1 Define plan-phase result types (needs-work / soft-skip / hard-fail; per-PV heavy unit with reuse|full class and baselines) suitable for gate + mutate carry-forward
- [x] 1.2 Implement pure builder from classified needs-work units → `[UnitDiskPlan]` (omit prune/content-only; multi-PV → max single-PV need per package; reuse vs full estimate helpers)
- [x] 1.3 Unit tests for pure builder and multi-PV max; extend `Test.DiskSpace` for mixed reuse/full concurrent sum

## 2. Plan phase (Apply split)

- [x] 2.1 Extract concurrent plan phase over selected packages reusing check/plan paths (`checkPackage` / deps plan + adequacy), check cache hit/store, `--jobs`, multi-progress “Planning packages”
- [x] 2.2 On cache hit, skip upstream plan network but still run local adequacy; progress row still completes
- [x] 2.3 Wire plan hard-fail and soft-skip outcomes without mutation

## 3. Classify reuse vs full

- [x] 3.1 After needs-work ∩ DepsAndAssets hard-requires token + assets-path + `xz` (and SSH prep), probe release assets per heavy unit
- [x] 3.2 Apply classify table: asset+size → reuse; asset no size → reuse Manifest/floor; no asset → full path; probe error → package hard-fail exclude from units; token unusable at require → spine fail
- [x] 3.3 Fake `ReleaseOps` tests for each classify branch

## 4. Conditional preflight from plan (A2)

- [x] 4.1 Derive `AssetsPreflight` from needs-work + full-path classes + cargo needs-work (not technique on full inventory)
- [x] 4.2 Require language tools only for full-path ecosystems; cargo tools when any cargo package needs work (P1)
- [x] 4.3 Tests: bare inventory with up-to-date Go + binary needs-work does not require `go`; reuse-only Go does not require `go`; cargo needs-work still requires pycargoebuild

## 5. Spine orchestration and disk gate

- [x] 5.1 Extract testable `update` spine (e.g. `runUpdatePhases`) used by Main: open cache early → spine tools → layout/distfiles → plan → assets/token → classify → language tools → disk gate → mutate
- [x] 5.2 Replace `buildUnitPlansForPackages selected` product path with needs-work classified units only
- [x] 5.3 Mutate always after successful gate; skip keys hard-failed in plan/classify; merge outcomes; single cache summary at end
- [x] 5.4 Integration tests with injectable plan ops, release ops, free-space probe: free space enough for one needs-work package passes when inventory has many up-to-date heavy packages; full-inventory estimate would fail

## 6. Mutate consumption of plan

- [x] 6.1 Maximal Apply split: mutate phase consumes plan results (avoid re-plan when results/cache sufficient; do not re-enter plan hard-fails)
- [x] 6.2 Preserve soft-skip and success behavior for packages that need work or are up to date
- [x] 6.3 Adjust existing apply tests for plan-then-mutate entry points as needed

## 7. Progress and docs

- [x] 7.1 Plan multi-progress + sequential steps for post-plan tools/disk; mutate multi-progress unchanged in role
- [x] 7.2 Update `README.md` free-space / update preflight prose per `project-docs` delta (needs-work, reuse vs full, plan before gate)

## 8. Quality gate

- [x] 8.1 `openspec validate update-plan-phase-gate --strict` (or project-equivalent) clean
- [x] 8.2 `hk check` green (build, tests, ormolu, hlint, stan, weeder); HIE rebuilt after module moves; no casual weeder/stan weakening
