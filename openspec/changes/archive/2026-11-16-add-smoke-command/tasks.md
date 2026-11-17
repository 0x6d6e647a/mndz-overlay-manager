# Tasks

## 1. Verify unproven Docker and emerge behavior

- [x] 1.1 Import a small labeled image with `docker import --change 'LABEL …'`, list it with `docker images --filter label=…`, mount it into a container with `--mount type=image`, and try `docker rmi` while it is mounted. Done when design.md's spike table records each result and D12 names labels or the record-file fallback.
- [x] 1.2 Create the tree snapshot with `tar` running in a container piped to `docker import` (D4) and time it. Done when the mounted result has `metadata/md5-cache`, has no `.git`, and the time is recorded in design.md.
- [x] 1.3 On a running container, run `docker network disconnect bridge` then `connect`, checking reachability from inside each time. Done when design.md D9 records that detach blocks the network and reattach restores it, or names the fallback.
- [x] 1.4 By hand, in a container built as in D6 (stage3 with `@world` updated, `SYS_ADMIN`, tree and overlay mounted), run the D8 dependencies and package steps for one Go package at its tilde ceiling and one binary package. Done when both install, the Go build used the capped version, the package's distfiles are absent from the distfiles volume, and any flag corrections are written into D6 and D8.

## 2. Materialize recipe keeps Portage sandboxes

- [x] 2.1 Remove `-ipc-sandbox -network-sandbox -pid-sandbox` from the recipe `FEATURES` in `Update.Materialize.Recipe` and bump `materializeGeneratorId` to `…-materialize-11`. Verify with a recipe test that the `FEATURES` value has no `-…sandbox` token and still has `getbinpkg buildpkg`, and that an older generator identity is a sidecar miss (`test/Test/Ensure.hs`).
- [x] 2.2 Run one real ensure (`update` of a full-path package, or the tools image path) and confirm the image builds with `Unable to unshare` warnings in the build log and a new sidecar generator identity.
- [x] 2.3 With a system containerd, treat the BuildKit cache as living on containerd's data root with the image layers, not on the Docker data-root (D15). Verify with the layout unit test, and by the gate passing on this host in task 2.2.

## 3. Runtime floor readers and run planning

- [x] 3.1 Add `Smoke.Floors` with readers for Go, Node.js, and SBCL `>=` atoms, the Python `PYTHON_COMPAT` slot, and wrappers over the existing Cargo and Bun readers (D2). Verify with unit tests on real ebuild texts from the overlay (`beads`, `gastown`, `node-gyp`, `claude-agent-acp`, `autolith`, `mise`, `opencode`, `codex-as-mcp`), including an ebuild with no floor.
- [x] 3.2 Add `Smoke.Plan`: host-arch keyword skip, unlabeled single runs, lanes served, one run per distinct ceiling, no-lane rule, floor-above-ceiling and no-ceiling plan failures, and the stable order. Verify with unit tests that cover every scenario of the `smoke-command` requirements from "Ebuild not keyworded for the host is skipped" through "Runs are sequential in a stable order".
- [x] 3.3 Add the ceiling loader that calls the existing `discover*CeilingsWith` functions with a tree path and the overlay, and returns ceilings for the host arch only. Verify with a test on a temporary tree that it performs no HTTP request (fake manager that fails on use).

## 4. Smoke image

- [x] 4.1 Add `Smoke.Recipe.renderSmokeDockerfile` (D3). Verify with tests: digest-pinned `FROM`, tree bind on the Portage `RUN`, `@world` update, `sys-process/time`, no toolchain or fetch-tool atom, no sandbox opt-out, and no cache mount id shared with the materialize recipe.
- [x] 4.2 Lift the helpers `Smoke.Image` needs out of `Update.Materialize.Ensure` without changing materialize behavior (stage3 digest and base-check decision, image inspect, Docker storage disk gate, previous-image removal). Verify the existing `test/Test/Ensure.hs` suite still passes unchanged.
- [x] 4.3 Add `Smoke.Image`: sidecar read/write under `<cache>/mndz/overlay-manager/smoke/`, the build decision, the disk gate with the base-only bounds, `docker build` with the `gentoo` build context, and previous-image removal. Verify with fake-runner tests for each `smoke-image` scenario: reuse, tree-moved no build, generator mismatch, missing image id, newer stage3, registry failure with and without a recorded image, build failure, unmapped arch, and the disk gate.

## 5. Tree snapshot and lock release

- [x] 5.1 Add `Smoke.Tree`: create the snapshot image (per 1.1 and 1.2), remove it, and sweep leftovers whose pid is not a live overlay-manager. Verify with fake-runner tests: create argv, removal on normal exit and on exception, leftover removed, live command's snapshot kept.
- [x] 5.2 Release the tree lock after the snapshot and keep the managed tree path out of everything that runs afterwards (D5). Verify with a test using fake lock operations that the shared lock is released before the first run starts and that a second resolver can take the exclusive lock while runs continue.

## 6. Smoke container

- [x] 6.1 Add `Smoke.Container` create and remove: name, labels, `--cap-add SYS_ADMIN`, image mount, read-only overlay bind, the two volumes, optional metrics time bind, removal in every outcome. Verify with argv tests, including that no `--privileged`, no `seccomp` option, and no token, GPG, or SSH variable appears.
- [x] 6.2 Add the Portage configuration writer and check-user creation (D6): repos.conf, `make.conf` with `MAKEOPTS` from jobs, license, overlay keywords, runtime cap lines and masks, Python slot line, definition extras. Verify with pure tests of the rendered files for a plain-lane run, a tilde-lane run, a Cargo run (both rust packages), a Bun run, a Uv run, and an unlabeled run.
- [x] 6.3 Add the sandbox probe (D7) and the three emerge steps (D8, as corrected by 1.4), with output streamed to log files and failures mapped to `dependencies`, `build`, and `check` stages. Verify with fake-runner tests: probe failure stops before any emerge, dependency failure skips the package step, the overlay name list is passed to both exclude options, and the package step sets the empty distfiles directory.
- [x] 6.4 Add network detach after installs and attach/detach around a network check. Verify with a fake-runner test of the docker call order for a definition with one offline and one network check.
- [x] 6.5 Wrap exec requests with GNU time when recording and take the container resource snapshot before removal (D14). Verify with `test/Test/Metrics.hs`-style tests for the `.outer`/`.inner` pair and the `container` event, and that `--no-metrics` wraps nothing.

## 7. Check framework

- [x] 7.1 Add `Smoke.Check` types and combinators (`versionCheck`, `helpCheck`, `filesExist`, `exitsWith`, `outputContains`, `outputLacks`, `firstLineIs`, `allOf`). Verify with unit tests for each combinator's pass and fail result, and that version expectations take the PV from the context.
- [x] 7.2 Add the interpreter: steps in order as the check user, per-command timeout through `timeout`, stop a check at its first failed step, continue with later checks, collect failed check names. Verify with fake-exec tests for every scenario of "Checks are named and independent", "Check commands time out", and "A run passes only when everything passes".

## 8. Package definitions

- [x] 8.1 Add `Smoke.Definitions` with the floor definitions for `dolt`, `bun-bin`, `deno-bin`, `beads`, `crush`, `grok-build-bin`, `hk`, `mise`, `opencode`, `openspec`, `ralph-tui`, `usage`, and `craft-fonts`, confirming each program's version or help invocation against the installed program. Verify with a unit test that the definition map's keys equal the `hardcodedPolicies` keys once 8.2 to 8.4 land (the test may list the still-missing keys explicitly until then, and must end with none).
- [x] 8.2 Add the shared craft-app definition for the 13 Storytold apps (`<name> --version` and `<name>-cli --version`, no display). Verify with a fake-exec test on one app that both commands run offline.
- [x] 8.3 Port the seed-spec smokes for `node-gyp`, `badger`, `qlot`, `biodiff`, `cargo-llvm-cov`, `cargo-outdated`, `cargo-update`, `rulesync`, `caddy-analyzer`, and `cmake-language-server`, reading each `*-seed` spec's smoke requirement. Verify with fake-exec tests for qlot's accepted status 255, the cargo-outdated network declaration and `libc` expectation, and caddy-analyzer's JSON expectation.
- [x] 8.4 Port the seed-spec smokes for `autolith`, `gastown`, `codex`, `codex-acp`, `codex-as-mcp`, `claude-agent-acp`, `grok-bot-bin`, `kiro-cli-bin`, `kiro-ide-bin`, and `witen-warden-bin`. Verify with fake-exec tests for autolith's no-argument start and its own timeout, kiro-cli's first-line rule, and witen-warden's partial-ok `validate`; and that the coverage test from 8.1 now lists no missing key.
- [x] 8.5 Add `sdPackageUse` (written to `/etc/portage/package.use/smoke`) and `sdCheckGroups` (check user joins after the installs, this package's containers only), and run checks under `/etc/profile`. Set USE lines for the craft apps, `grok-bot-bin`, `kiro-ide-bin`, `autolith`, and `claude-agent-acp`, and group `witen-warden` for `witen-warden-bin` (found by task 10.5). Verify with unit tests for the files, the `usermod` order and failure stage, and the wrapper, and with a host `smoke` of those packages in which none fails in dependencies or in `check validate`.

## 9. Command, reporting, and docs

- [x] 9.1 Add the `Smoke` constructor to `CLI.Parser` (`PACKAGE...`, `--exclude`, no `--refresh`), its help text, `commandTreeSync = Just False`, and the metrics `commandName` and `invocationFor` cases. Verify with `test/Test/CLI.hs` cases for parse, rejected `--refresh`, top-level and command help content, and exit 0 for help without config.
- [x] 9.2 Add the smoke preflight: tools on `PATH`, git work tree, Docker version at least 28.0, containerd image store (D11). Verify with pure tests for version parsing (`27.5.1` rejected, `28.0.0` and `29.8.1` accepted) and for the classic-driver error.
- [x] 9.3 Add `Smoke.Run` and the `Main` dispatch following the D1 pipeline: selection, missing-definition hard fail, tree resolve, plan, sweep, image, snapshot, probe, runs, summary, exit status. Verify with an integration test over fakes: mixed pass, fail, and skip results give the exact stdout lines, the summary counts, exit status `1`, and continuation after a failed run.
- [x] 9.4 Add run logs, the ten-run prune, the uncommitted-package report, and the stderr progress line (D10). Verify with tests on a temporary cache directory (log paths named in failures, eleventh directory pruned) and a temporary git work tree (modified, staged, and untracked files each reported).
- [x] 9.5 Document `smoke` in `README.md`: runtime-requirements row, a `smoke` section, the environment (capability, image tag, volumes, snapshot image, logs), and the shared base-check interval. Add the smoke tests to the test layout in `CONTRIBUTING.md`. Verify each README statement against the `project-docs` delta and that the documented example invocations parse.
- [x] 9.6 Update the work-command list in `openspec/config.yaml` context to include `smoke`. Verify `openspec validate add-smoke-command --strict` still passes.

## 10. Integration

- [x] 10.1 Run `just check` and fix everything it reports, without widening `.stan.toml` excludes or `weeder.toml` roots. Done when it exits 0.
- [x] 10.2 On the development host, run `smoke crush deno-bin craft-fonts` (a Go lane package, a binary package, a package with no program). Done when all three report `pass`, the Go package shows one line per distinct ceiling, `docker ps -a` and `docker images` show no smoke container or snapshot left, and `git status` in the overlay is unchanged.
- [x] 10.3 Run `smoke` on the same host for a package with a network check (`cargo-outdated`) and for one failing case (a temporary uncommitted edit that breaks an ebuild). Done when the network check passes, the broken ebuild reports `fail: build` with a log path that contains the Portage error, the summary names the uncommitted package, and the exit status is `1`.
- [x] 10.4 Start `smoke` for a slow package and, once its emerge is running, run `outdated --refresh` in another terminal. Done when `outdated` syncs the tree without waiting and the smoke command finishes normally.
- [x] 10.5 Run a full `smoke` with no targets and record the wall time and the per-package results in the change's design.md. Done when every failure is either fixed in the definition or reported to the operator as an overlay defect.

## Workflow follow-up

- Archive the change after review; at sync time, update the `package-exclude` Purpose line to name `smoke`.
- Update `smoke-pass-cache-handoff.typ` in the operator's wiki to match the landed smoke specs (tree snapshot, two emerge steps, definition types).
