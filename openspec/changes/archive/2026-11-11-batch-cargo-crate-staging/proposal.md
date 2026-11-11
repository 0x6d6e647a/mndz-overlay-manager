# Proposal

## Why

Full-path Cargo pack stages each lock-listed registry crate with its own `tar -xzf` process. Inside the materialize container, each of those is a separate `docker exec`, so staging is dominated by exec round-trip latency (about 42 ms each), not extraction. Measured on 890 real crates, serial staging took 40.9 s against 113 s for the xz pack: about 27% of the pack phase for a large lockfile. Extracting every crate through one builder invocation with `--jobs`-wide parallelism took 0.94 s. Per-crate concurrency plateaued at about 15 s, because dockerd exec throughput caps it and every concurrent unit shares that cap.

## What Changes

- Crate staging extracts every lock-listed registry crate through **one** builder invocation, running at most `--jobs` extracts at a time, instead of one process per crate.
- Before any extraction, pack checks every lock-listed registry crate against the distdir. If any are missing, pack hard-fails, lists every missing crate, and extracts nothing.
- Extraction no longer stops at the first failing crate. Every crate is attempted. Every failure is reported in lock order, including a crate whose extract did not produce its `{name}-{version}/` directory.
- Staging failures produce a short hard-fail header with the failure total, the first failure in lock order, and the path of a new `crate-staging.log` in the retained unit directory, which lists every failure.
- The per-crate `staging crates k/N` status line is replaced by a single `staging N crates` line emitted before extraction.
- Archive bytes stay independent of extraction order. The xz pack step, `XZ_OPT`, thread count, and the shared compress slot are unchanged.

## Non-goals

- No change to `XZ_OPT`, `-T{N}`, `--block-size`, or the shared compress slot.
- No change to `pycargoebuild` crate fetching (aria2 already parallelizes it).
- No change to the rusty_v8 snapshot path or its single-crate extract.
- No change to staging for other DepsAndAssets ecosystems (Go, Npm, Bun, Sbcl, Uv, Pdm).
- No in-process (Haskell) crate decompression and no new library dependencies.
- No PV selection or package-target changes.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `cargo-crates-assets`: adds crate staging requirements alongside the unchanged **Manager-owned crates tarball pack**: missing-crate preflight with full listing, one builder invocation bounded by `--jobs`, every extract failure reported in lock order, a staging failure summary, a `crate-staging.log` transcript file, archive bytes independent of extraction order, and a `staging N crates` progress line.

## Impact

- **Code:** `src/Update/Cargo/Crates.hs` (`stageAndArchive`, `extractCrate`, `CargoProgress.cgpOnStageCrate`), `src/Update/Apply/Materialize.hs` (`cargoCratesProgress` status text).
- **Tests:** `test/Test/Ecosystems.hs`. Runner stubs that match `ExecCmd "tar"` for extraction must accept the batched invocation. `testCargoStagingProgress` changes to the new status line. New tests cover a single invocation, missing-crate listing without extraction, and multi-failure lock order with the log file.
- **Docs:** `README.md` temp-workspace section (retained unit contents gain `crate-staging.log` on a staging hard-fail), per `project-docs`.
- **Runtime:** large cargo full-path units spend about 40-60 s less in staging. Staging briefly runs up to `--jobs` `tar` processes per unit, outside the compress slot. No new tools: `xargs` and `sh` are already in the materialize image.
- **Evidence:** benchmark script and results are recorded in `design.md`.
