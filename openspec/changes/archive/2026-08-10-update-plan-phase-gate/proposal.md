## Why

The `update` disk-space feasibility gate estimates free-space need from the full **selected inventory** and assumes full-path materialize for every `DepsAndAssets` package. On bare `update`, that falsely reserves concurrent capacity for packages that will soft-skip, and often fails free-space checks when only a few packages need work. Living specs already require gating **packages that need work**; the first disk-space implementation never finished that step. Conditional tools, assets path, token, and SSH preflight have the same root cause (technique on inventory, not “will attempt”), so operators can also be blocked on missing `go`/`npm`/token when only a binary package needs work.

## What Changes

- Split `update` into an explicit **plan phase** then **mutate/apply phase** (maximal Apply refactor), with the check cache opened **before** plan.
- Plan phase determines **needs-work** (same semantics as outdated/apply soft-skip rules), using multi-progress and `--jobs`; cache hits skip upstream plan network but still run local adequacy.
- After plan, when `needs-work ∩ DepsAndAssets` is non-empty: hard-require token, assets-path, `xz`, and SSH; set language tools from **planned full-path** ecosystems (`go`/`npm`/`bun`); require cargo tools when any **cargo package needs work** (P1: still when that work is reuse-only).
- **Classify** reuse vs full for assets units after token/assets preflight (policy table in design): asset present → reuse; no asset → full path; probe/API error → package hard-fail; token unusable at hard-require → spine fail.
- Run the disk-space gate only on **heavy units from packages that need work**, with reuse vs full estimates (depth C); multi-PV sequential work in one package contributes the **largest single-PV** need to concurrent sum; prune/content-only with no heavy IO contribute no unit; plan failures and classify hard-fails are **excluded** from the gate.
- Always continue to mutate/apply after a successful spine (no special-case exit when nothing needs work); mutate **skips** keys already hard-failed in plan (carry outcomes forward).
- Single check-cache hit/fetch summary at end of the run.
- Tests: pure builders, fake-ops integration, and extracted testable spine used by Main.
- README free-space / preflight prose aligned with needs-work + reuse vs full + plan phase.

## Non-goals

- Dropping soft-skip messages or changing soft-skip copy/UX beyond not re-processing plan hard-fails.
- Disk reserve/wait pool, serial-heavy primary scheduling, or CPU token pools.
- Changing expansion factors, floors, or 256 MiB margin constants (unless a test forces a pure helper fix).
- Live GitHub E2E in CI (injectable fakes only).
- Disabling cargo P1 (pycargoebuild still required when a cargo package needs work, including reuse-only).
- Changing `outdated` command behavior except shared plan/cache helpers if extracted.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `disk-space-preflight`: Gate units only from needs-work heavy work; reuse vs full classification policy; multi-PV max-single-PV concurrent contribution; exclude plan/classify failures from units; supersede “unknown → overestimate full-path” for probe errors.
- `update-command`: Spine order (spine tools → plan → conditional preflight → classify → disk gate → mutate); plan multi-progress; conditional tools/assets/token/SSH from needs-work and full-path class (A2); always run apply after successful gate; carry plan hard-fails.
- `cli-activity`: Plan-phase multi-progress presentation for `update` (and cache-hit behavior).
- `check-cache`: Check cache opened and used during `update` plan phase before mutation; single end-of-run summary.
- `project-docs`: README documents plan-before-gate, needs-work-only free-space estimates, and reuse vs full basis.

## Impact

- **Code:** `app/Main.hs` (`runUpdate` spine reorder); `Update.Apply` maximal plan/mutate split; `Update.Preflight` / `Update.DiskSpace` plan-aware unit builders; assets release probe at classify; progress wiring.
- **Tests:** `Test.DiskSpace` extensions; new integration-style module(s) with fake `DepsPlanOps` / `ReleaseOps` / free-space probe; spine extraction for Main-level tests.
- **Docs:** `README.md` free-space and update preflight sections.
- **Operator:** Bare `update` no longer fails free space or language tools solely because up-to-date heavy packages are in inventory; first-time full materialize and probe failures behave per classify table.
