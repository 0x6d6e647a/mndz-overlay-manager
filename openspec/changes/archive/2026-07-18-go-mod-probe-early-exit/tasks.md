## 1. Probe walk with early exit

- [x] 1.1 Replace all-version concurrent go.mod probing in `Update.Go.Plan` with a sequential newest-first walk over the listed versions
- [x] 1.2 After each parseable `go_req`, accumulate candidates (or update per-lane picks) and stop when every ceilinged lane has a target
- [x] 1.3 Skip missing/unparseable go.mod without filling a lane; continue until list end if needed
- [x] 1.4 Keep each probe under `withWorkSlot`; leave tag listing and ceiling discovery unchanged

## 2. Progress hooks

- [x] 2.1 Change `PlanProgress` / `goPlanProgress` so planning reports three coarse steps (ceilings, list, probe walk) instead of `2 + n` per-tag steps
- [x] 2.2 Complete the single probe step when the early-exit walk finishes (not per tag)

## 3. Tests

- [x] 3.1 Unit/integration tests: tip fills all lanes → only one go.mod fetch for that plan
- [x] 3.2 Tests: plain needs older PV than tilde → both targets correct and no probes older than the plain target once filled
- [x] 3.3 Tests: early-exit lane targets equal full-probe + `selectAllLaneTargets` on the same fixture
- [x] 3.4 Tests: unparseable tip is skipped and older parseable version is used
- [x] 3.5 Adjust any tests that assert per-tag progress step totals or concurrent multi-tag probe behavior for one plan

## 4. Quality gates

- [x] 4.1 Run `hk fix` / format and full `hk check` until green
