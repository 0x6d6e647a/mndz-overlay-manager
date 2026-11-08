# Tasks

## 1. pycargoebuild argv

- [x] 1.1 In `runPycargoebuild`, replace `-c` and `--no-write-crate-tarball` with `--use-crate-tarball` and keep `-i`, `-M`, `-f`, `--crate-tarball-path`, `--crate-tarball-prefix`, `-d`, and the directory operand in the order in `design.md` D2. Update the `buildCargoCratesTarball` comment that says no-write. Verify with a tree search that production Haskell no longer passes `-c`, `--crate-tarball`, `--no-write-crate-tarball`, `-u`, `-w`, `--write-crate-tarball`, `-C`, or `--fill-crates` to `pycargoebuild`.
- [x] 1.2 In `testCargoMkCommandRunner`, require `--use-crate-tarball` and require `-u`, `-c`, `--crate-tarball`, `--no-write-crate-tarball`, `-w`, and `--write-crate-tarball` to be absent. Keep the stub from writing the tarball, keep the `-i` ebuild write, and keep the assertion that the manager pack produces `pkg-0.1.0-crates.tar.xz`. Verify with `just test cargo mk path`.

## 2. Gate

- [x] 2.1 Validate this change with `openspec validate pycargoebuild-use-crate-tarball --type change --strict` and confirm it passes.
- [x] 2.2 Run `just check` and confirm the full gate passes. Do not rebuild the materialize image, and do not run `sudo`, `emerge`, or a live `update`.

## Workflow follow-up

- Archive this change after review. Archive syncs the `cargo-crates-assets` and `dev-util-biodiff-seed` deltas into `openspec/specs/`. The biodiff 1.2.0 release is not republished.
- Archived changes that still name `--no-write-crate-tarball` stay as history.
