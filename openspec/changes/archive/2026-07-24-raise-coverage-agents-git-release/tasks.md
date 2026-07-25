## 1. Re-baseline residual

- [x] 1.1 Run `./scripts/coverage` after Waves 1–4; list residual modules still dark or mid-coverage (SshAgent, GpgAgent, Git, Assets.Release, Http, Npm, others)
- [x] 1.2 Prioritize mockable residual within Wave 5 scope; note any production wrappers left intentionally thin

### Residual baseline (Overall expr after Waves 1–4)

| Module | expr% | Notes |
|--------|------:|-------|
| Update.Git | 8% | production `isGitWorkTree`/`pathsDirty`/`push`/`commit` thin |
| Update.Npm | 10% | only wrong-source branch |
| Update.Assets.Release | 13% | pure parse/lookup + ReleaseOps fakes; raw HTTP dark |
| Update.SshAgent | 18% | partial ensure; production ssh-add/agent thin |
| Update.Http | 20% | tryHttp + wrong-source only |
| Update.GpgAgent | 46% | warm/cold suite solid; production gpg/agent wrappers thin |
| Update.Runtime.Ceilings | 66% | mid; cheap alts only if ROI |
| Update.Md5Cache | 69% | mid |
| Update.EbuildEdit | 84% | already strong |

**Prioritize:** SshAgent ensure/teardown edges (ops fakes), GPG remaining ensure edges, Git real temp-repo + GPG-fail early, Release/Http/Npm via injectable HTTP `Request → Either` seam (no live GitHub). **Intentionally thin:** production `ssh-agent`/`ssh-add`/`kill`, live pinentry, `gpg-connect-agent`, raw process wrappers without seams.
## 2. SSH and GPG residual

- [x] 2.1 Unit/Integration: SSH ensure/teardown and session edge paths via `SshAgentOps` or equivalent fakes
- [x] 2.2 Expand GPG readiness edges not covered by existing warm/cold suite (still no live pinentry)

## 3. Git residual

- [x] 3.1 Unit/Integration: Git ops edge/failure paths via `GitOps` and/or controlled temp repos (dirty paths, non-worktree, commit/push errors as product defines)

## 4. Release HTTP and fetch residual

- [x] 4.1 Unit/Integration: Assets.Release download/create/delete-oriented paths with HTTP fakes (beyond pure parse/find already covered)
- [x] 4.2 Unit/Integration: Http and Npm fetch residual if still thin after earlier waves

## 5. Cheap residual alts

- [x] 5.1 Pick low-effort remaining alts in EbuildEdit / Md5Cache / Runtime.Ceilings (or similar) only if ROI is clear from the fresh report

### 5.1 note

EbuildEdit already high expr (~84%); Md5Cache/Ceilings mid (~66–69%). Skipped further alts — ROI not clear vs agent/Git/Release gains. Production process wrappers (live ssh-agent/pinentry/gpg-connect-agent) remain intentionally thin.

## 6. Verify and handoff

- [x] 6.1 Run `./scripts/coverage`; record final Overall/Unit/Integration summary for floors follow-up
- [x] 6.2 Run `hk check` and fix all gate failures
- [x] 6.3 Confirm floors/ratchet still not implemented; note “floors explore next” in change notes if archiving

### Final coverage (Wave 5 handoff)

| Level | expr% | alt% | bool% |
|-------|------:|-----:|------:|
| Overall | 65.1 | 54.7 | 35.6 |
| Unit | 51.6 | 44.7 | 30.2 |
| Integration | 37.9 | 28.5 | 12.4 |

Baseline before Wave 5: Overall **60.1** / Unit **46.5** / Integration **37.9** expr%.

`floors_enforced: false` in `coverage/summary.json`. Coverage entrypoint still succeeds on tests+report only.

**Floors explore next** — separate explore/propose using this `summary.json` for numeric floors/ratchet design.
