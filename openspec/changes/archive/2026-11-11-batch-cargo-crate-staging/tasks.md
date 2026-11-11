# Tasks

## 1. Missing-crate preflight

- [x] 1.1 In `src/Update/Cargo/Crates.hs`, split `stageAndArchive` so every lock-listed crate's existence is checked before any extraction, producing a lock-ordered list of missing-crate records (design D3). Verify that `testPackCratesTarballMissingCrate` still passes.
- [x] 1.2 Add a test in `test/Test/Ecosystems.hs`: three lock-listed crates, two absent. Pack hard-fails, no extraction request reaches the runner, and both missing crates are reported first-in-lock-order. Verify with `just coverage <pattern>`.

## 2. Batched extraction invocation

- [x] 2.1 Replace per-crate `extractCrate` with the single `xargs -0 -P W -n 1 sh -c EXTRACT sh <gentooDir> <errDir>` request: NUL-joined crate paths in lock order on `prStdin`, W = the `threads` argument, per-crate stderr files under `work/crate-errors/` (design D1, D2). Verify that `testPackCratesTarballFixture` (production runner) still passes and produces the same tarball members.
- [x] 2.2 Implement the post-invocation host pass in lock order: an `.err` file means an extract failure, a missing crate directory means a no-directory failure, otherwise write `.cargo-checksum.json`. A non-zero exit with no records is an invocation failure (design D3, D5). Verify with the tests in 2.4.
- [x] 2.3 Update the runner stubs in `test/Test/Ecosystems.hs` that match `ExecCmd "tar"` for extraction (around lines 1731, 1963, 2091) to delegate or stub the `xargs` request. Verify that every existing cargo pack and `buildCargoCratesTarball` test passes.
- [x] 2.4 Add tests: (a) a fixture with several crates issues exactly one extraction request, whose argv carries `-P` equal to the `threads` value; (b) two corrupt crates and one good crate, where every crate is attempted, both failures are reported in lock order, and the good crate's directory exists; (c) a stubbed extract that exits zero without creating the crate directory is reported as a no-directory failure; (d) an invocation that fails with no `.err` files yields the invocation-failure message. Verify with `just coverage <pattern>`.
- [x] 2.5 Add a test that packs the same fixture twice, with the stubbed extraction completing crates in different orders, and asserts byte-identical archives (spec: archive independent of extraction order). Verify with `just coverage <pattern>`.

## 3. Failure summary and `crate-staging.log`

- [x] 3.1 Write `crate-staging.log` in the unit directory on any staging failure: one block per record in lock order with filename, kind, and indented full stderr for extract failures. Build the summary message for missing and extract/no-directory failures, with singular forms, and add the "log could not be written" fallback (design D4). Verify with 3.2.
- [x] 3.2 Add tests: the log lists every failure in lock order with kinds and full stderr; the missing-crate log lists every missing crate; success leaves no log; an unwritable unit directory gives a message that says the log was not written and still names the first failing crate; the summary begins `cargo crates pack failed:`, states the count, names the first crate and its first stderr line, and includes the unit path. Verify with `just coverage <pattern>`.
- [x] 3.3 Update the temp-workspace bullets in `README.md` (around line 227): a crate staging hard-fail leaves `crate-staging.log` in the retained unit directory and names it in the error, alongside the existing `pycargoebuild.log` note. Verify by reading the rendered section.

## 4. Progress line

- [x] 4.1 Change `CargoProgress.cgpOnStageCrate` and the `packCratesTarballWith` `onStage` parameter to a count-only hook called once before extraction, and skipped for zero crates. Render `staging N crates` / `staging 1 crate` in `cargoCratesProgress` (`src/Update/Apply/Materialize.hs`) (design D6). Verify that the project builds.
- [x] 4.2 Update `testCargoStagingProgress` to expect `["staging 1 crate", "crates pack"]`, and add cases for N > 1 (`staging 3 crates`) and zero registry crates (no staging event before `crates pack`). Verify with `just coverage <pattern>`.

## 5. Specs and full gate

- [x] 5.1 Verify that `openspec validate batch-cargo-crate-staging --strict` passes.
- [x] 5.2 Run `just check` (hk check: format, hlint, release build, stan, weeder, coverage tests) and verify that it is green, with no new weeder roots or stan excludes.
- [x] 5.3 Manually smoke-test a full-path `update` of a large cargo package (for example `dev-util/mise`), confirm that `staging N crates` appears once and staging completes in seconds, and record the observed time in `design.md` Measurements.

## Workflow follow-up

- Sync the delta into `openspec/specs/cargo-crates-assets/spec.md` and archive the change after review.
