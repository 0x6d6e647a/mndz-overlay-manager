# Proposal

## Why

`pycargoebuild` 0.17.1 warns that a mode argument will be required. Full-path Cargo materialize still selects use-crate-tarball mode with the deprecated pair `-c` and `--no-write-crate-tarball`, so every crates run prints that warning. The same 0.17.1 already accepts `--use-crate-tarball` as that mode.

## What Changes

- Full-path Cargo materialize (GitTag and CratesIo) passes `--use-crate-tarball` to `pycargoebuild`.
- That argv drops `-c`, `--crate-tarball`, and `--no-write-crate-tarball`.
- It keeps `-i`, `-M`, `-f`, `-d`, `--crate-tarball-path`, `--crate-tarball-prefix` `cargo_home/gentoo`, and the directory operand, in that order aside from the two dropped flags.
- It does not pass `-u`, `-w`, `--write-crate-tarball`, `-C`, or `--fill-crates`.
- The manager still packs `{pn}-{pv}-crates.tar.xz` after `pycargoebuild` returns. `pycargoebuild` still does not write that archive.
- The inplace warning about `CRATES`, `GIT_CRATES`, and crate `LICENSE+=` stays.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `cargo-crates-assets`: GitTag and CratesIo full-path `pycargoebuild` invocations name use-crate-tarball mode with `--use-crate-tarball` and omit the deprecated crate-tarball flags. The manager-owned pack still follows a successful run that did not create the archive.
- `dev-util-biodiff-seed`: The already-published seed's method clause stops naming `--no-write-crate-tarball` and follows the lane mode. The published tarball, sidecars, and ebuild are not rebuilt.

## Impact

- `src/Update/Cargo/Crates.hs` (`runPycargoebuild` argv and the nearby comment that says no-write).
- `test/Test/Ecosystems.hs` (`testCargoMkCommandRunner`).
- Living specs `cargo-crates-assets` and `dev-util-biodiff-seed`, synced at archive. Archived changes stay as history.
- README, CONTRIBUTING, and AGENTS do not quote this argv. No project-doc edit.
- Host and materialize-image `pycargoebuild` 0.17.1 already accept the flag. No image rebuild, no newer `pycargoebuild`, no `sudo`, `emerge`, or live `update`. Gate is `just check`.

## Non-goals

- The `pycargoebuild` failure headline, `pycargoebuild.log`, and aria2 exit 19.
- `/etc/portage/repos.conf/mndz.conf` in the materialize image.
- `crateTarballPrefix`, the pack command, and `XZ_OPT=-T1 -9e`.
- The Codex `pycargoebuild` workspace bug.
- `media-fonts/craft-fonts`.
- `-w` / `--write-crate-tarball` or `-C` / `--fill-crates`.
- Rewriting `-i`, `-M`, `-f`, or `-d` into long options.
- Silencing the inplace metadata warning.
- Re-fetching or re-publishing the biodiff 1.2.0 crates release.
