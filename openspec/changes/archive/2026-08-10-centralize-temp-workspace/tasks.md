## 1. Workspace core

- [x] 1.1 Add a product temp-workspace module (path helpers + IO): run-id format (local ISO-8601 with offset, pid, random), run root under `<tempRoot>/mndz/overlay-manager/<run-id>/`, unit path `<cat>/<pn>/<pv>-{full|reuse}/{out,work}`
- [x] 1.2 Implement open-run, ensure-unit (`out`+`work`), delete-unit with empty package/category prune under run root, and full-run success cleanup (delete run root + upward prune empty `overlay-manager` then empty `mndz`)
- [x] 1.3 Unit tests for path construction, unit cleanup prune, full-run upward prune, and uniqueness components (pid/random present)

## 2. Spine wiring

- [x] 2.1 Open one run root on the `update` apply path (or when heavy temp work will run); own lifecycle at end of the run (success prune vs leave on any hard-fail)
- [x] 2.2 Plumb a run/workspace handle through `ApplyEnv` (or equivalent) so materialize and builders do not call free-floating `withSystemTempDirectory`
- [x] 2.3 On unit hard-fail after a unit dir was opened, ensure operator-visible error text includes the absolute unit path

## 3. Materialize and ecosystem builders

- [x] 3.1 Convert `Update.Apply.Materialize` full-path staging (`mndz-deps-out-`) and reuse download (`mndz-reuse-asset-`) to unit `out`/`work` under `full` / `reuse` kinds; immediate success/soft-skip unit cleanup
- [x] 3.2 Convert `Update.Go.Vendor` to use unit `work` (clone + GOMODCACHE) and unit `out` for tarball output
- [x] 3.3 Convert `Update.Npm.Cache` to unit workspace paths
- [x] 3.4 Convert `Update.Bun.Cache` to unit workspace paths
- [x] 3.5 Convert `Update.Cargo.Crates` to unit workspace paths (clone, distdir, stage under `work`; tarball under `out`)
- [x] 3.6 Convert `Update.Sbcl.Deps` to unit workspace paths
- [x] 3.7 Grep product `src/` for remaining `withSystemTempDirectory` (and free-floating product temp prefixes); eliminate product call sites or justify test-only leftovers

## 4. Tests and docs

- [x] 4.1 Integration/unit coverage: successful unit cleaned immediately; hard-fail retains unit tree and message contains path; multi-PV retains only failing unit; full-run success removes run root and empty brand parents
- [x] 4.2 Update README free-space / `TMPDIR` section per `project-docs` delta (workspace layout, retention, residuals, path-in-error)
- [x] 4.3 Adjust existing tests that assumed always-delete or anonymous temp prefixes under the temp root

## 5. Quality gates

- [x] 5.1 `openspec validate --change centralize-temp-workspace` (and strict if project practice requires)
- [x] 5.2 `hk check` green (or full CONTRIBUTING pipeline) with no weeder/stan regressions from new exports (prefer `other-modules` unless an executable/test truly needs exposure)
