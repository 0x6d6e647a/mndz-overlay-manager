# Design

## Context

See `proposal.md` for why the mode flag is required. Full-path Cargo materialize has one argv, `runPycargoebuild` in `src/Update/Cargo/Crates.hs`. GitTag and CratesIo both call it. `pycargoebuild` 0.17.1 treats `-u` and `--use-crate-tarball` as the same `Mode.USE_CRATE_TARBALL`. That mode fetches and verifies crates, inplace-updates the ebuild, logs `Skipping creating crate tarball`, and does not call `repack_crates`. The deprecated pair `-c` plus `--no-write-crate-tarball` selects the same mode and then warns that a mode argument will be required.

## Goals / Non-Goals

**Goals:**

- Replace that deprecated pair with `--use-crate-tarball` in the one argv both provenances use.
- Keep the manager pack as the writer of `{pn}-{pv}-crates.tar.xz`.
- Make `testCargoMkCommandRunner` reject the deprecated flags and the short `-u` spelling.

**Non-Goals:**

- A second argv, a stderr filter, or a runtime check of the image's `pycargoebuild` version.
- Changing which operands `-i`, `-M`, `-f`, and `-d` keep.
- Teaching the pack path to read `--crate-tarball-prefix` back from `pycargoebuild`. The prefix the archive uses stays `crateTarballPrefix`.

## Decisions

### D1 — Long mode flag

**Choice:** Pass `--use-crate-tarball`. Do not pass `-u`.

**Rationale:** Both spellings set `Mode.USE_CRATE_TARBALL`. The 0.17.1 help text for `--no-write-crate-tarball` names `--use-crate-tarball` as the replacement. The long spelling is the one this change standardizes, and the test locks it by requiring `-u` to be absent.

**Alternative:** Pass `-u`. Same mode, shorter logs. Rejected because the requested spelling is the long option.

### D2 — Drop the deprecated pair

**Choice:** Remove `-c` and `--no-write-crate-tarball`. Do not leave them beside the new flag.

**Rationale:** Once `args.mode` is set, 0.17.1 skips the "mode argument will be required" warning even if the deprecated flags are still present. Those flags are how the warning is reached when mode is unset, and a later `pycargoebuild` can reject them. The argv after the edit is:

```
pycargoebuild
  --use-crate-tarball
  -i <ebuild>
  -M
  -f
  --crate-tarball-path <tarball>
  --crate-tarball-prefix cargo_home/gentoo
  -d <distdir>
  <lock-or-package dir>
```

`-w`, `--write-crate-tarball`, `-C`, and `--fill-crates` stay absent. `-w` would call `repack_crates` with `pycargoebuild`'s own `lzma` preset and fight the manager pack.

**Alternative:** Add `--use-crate-tarball` and keep `-c` and `--no-write-crate-tarball`. The warning would stop, and the process would still depend on deprecated flags. Rejected.

### D3 — Keep path and prefix

**Choice:** Keep `--crate-tarball-path` and `--crate-tarball-prefix cargo_home/gentoo`.

**Rationale:** On the inplace path 0.17.1 actually runs, `update_ebuild` uses a non-empty crate-tarball path only to emit an empty `CRATES` list. It does not write that path into the donor. `--crate-tarball-prefix` is read only inside `repack_crates`, which `USE_CRATE_TARBALL` does not call. The default path would also empty `CRATES`. The flags stay so the argv still names the manager's basename and prefix, which the living spec already requires, and so a later `pycargoebuild` that records the basename still sees the manager's path. The archive member prefix continues to come from `crateTarballPrefix` in the manager pack.

**Alternative:** Drop both as unused by 0.17.1 inplace. Rejected. That would shrink the spec contract for no gain on this version.

### D4 — Spec text, not a new capability

**Choice:** Modify the three `cargo-crates-assets` requirements that name the old flags, and the biodiff seed sentence that names `--no-write-crate-tarball`. Leave archived changes alone. Do not edit README, CONTRIBUTING, or AGENTS.

**Rationale:** Those living requirements are the argv contract. The biodiff edit is the method clause only. The published 1.2.0 tarball, sidecars, and ebuild stay. Operator docs do not quote this argv.

## Risks / Trade-offs

- [Risk] The materialize image's `pycargoebuild` rejects `--use-crate-tarball`. → Mitigation: the filmcraft stderr is the 0.17.1 warning that names that flag, and the host copy of 0.17.1 accepts it. This change does not rebuild the image. A mismatch shows up as a `pycargoebuild` failure on the next full-path cargo unit, with the existing failure prefix.
- [Risk] Keeping `--crate-tarball-prefix` reads as if `pycargoebuild` applied the prefix. → Mitigation: D3 records that the pack owns the prefix. This change does not alter `crateTarballPrefix` or `XZ_OPT`.
- [Risk] The mode-warning scenario is not executed by the stub runner. → Mitigation: the stub asserts the argv that 0.17.1 uses to skip that warning. `just check` does not run a live `pycargoebuild`.
- [Risk] The inplace warning ("updates CRATES, GIT_CRATES and crate LICENSE+= variables only") still prints. → Mitigation: that warning is expected. Do not filter stderr.

## Migration Plan

No operator migration and no asset rewrite. The next full-path Cargo materialize uses the new argv. Rollback is restoring the previous argv in `runPycargoebuild` and the matching test assertions. Published crates tarballs stay valid. The biodiff 1.2.0 release is not republished.

## Open Questions

None. Path and prefix stay. The short mode flag stays out of the argv.
