## Why

After pure, builder, check/plan, and materialize waves, remaining high-effort dark surface is agents, Git production edges, Assets.Release HTTP, and residual alts in already-partial modules. Wave 5 maximizes coverage on that residual with Unit and Integration tests and fakes so floors can be discussed from a high, honest baseline.

## What Changes

- Add tests (Unit and Integration as appropriate) for residual product surface:
  - `Update.SshAgent` ensure/teardown and session edges via ops/process fakes
  - `Update.GpgAgent` remaining branches not covered by existing warm/cold suite
  - `Update.Git` failure and edge paths via `GitOps` / controlled temp repos
  - `Update.Assets.Release` download/create/delete paths with HTTP-level fakes where practical
  - `Update.Http` / `Update.Npm` fetcher paths still thin after earlier waves
  - Cheap residual alts in `Update.EbuildEdit`, `Update.Md5Cache`, `Update.Runtime.Ceilings` when low-effort
- Re-run `./scripts/coverage`; keep `hk check` green.
- **No** operator-visible product behavior change; **no** numeric floors in this change (floors are a separate follow-up explore/change).

## Program context

- **Wave 5 of 5** of the post-HPC coverage-maximization program.
- **Apply order:** last wave; after `raise-coverage-materialize-ecosystems`.
- **Depends on:** Waves 1–4 recommended so residual list is real, not “everything.”
- **Horizon:** polish toward high 80s Overall expressions where mockable; then separate explore for floors/ratchet using post-wave `summary.json`.

## Non-goals

- Introducing numeric coverage floors, ratchet baselines, or gate failure on percentages.
- Live GitHub API or real pinentry/SSH agent in CI.
- System/E2E process tests of the executable.
- Re-doing Waves 1–4 scope (builders, plan, materialize ecos).
- Product behavior changes.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `test-coverage`: ADDED requirements that residual agent/Git/Release/HTTP surfaces are exercised under Unit and/or Integration with fakes, and that floors remain unenforced after this maximization program.

## Impact

- **Code:** `test/**` (Ssh, Gpg, Assets, Git-related cases); possibly small injectability tweaks if production functions lack seams.
- **Quality:** remaining large single-digit modules reduced where mockable; boolean/alt coverage improved on one-sided branches; `hk check` green.
- **Docs:** none required unless a new injectability seam needs CONTRIBUTING mention (prefer not).
- **Downstream:** unlocks a separate floors/ratchet design with real post-maximize metrics.
