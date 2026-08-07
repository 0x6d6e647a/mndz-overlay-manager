## Context

See `proposal.md` for motivation. Today full-path Cargo materialize clones a GitHub tag, runs `pycargoebuild -c -i … -M -f --crate-tarball-path … --crate-tarball-prefix cargo_home/gentoo -d $DISTDIR $pkgDir`, then applies manager SRC_URI / MSRV / KEYWORDS fixes. pycargoebuild hardcodes single-threaded `tarfile` + `lzma` at `preset=9|PRESET_EXTREME` for the crates distfile; there is no external knob. Other DepsAndAssets packs (Go/npm/Bun/Sbcl) already use `tar` with `XZ_OPT=-T0 -9`.

Profile evidence (session report `no-pycargoebuild-parallelism.md`): mise-class ~964 crates; ~85–99% of pycargo wall time in extreme xz; fetch and LICENSE+ are secondary.

`pycargoebuild --no-write-crate-tarball` still fetches, verifies, and inplace-updates CRATES/LICENSE+/GIT_CRATES when `-c` is set, but skips creating the archive. The tarball path need not exist for ebuild update; empty CRATES is driven by tarball mode.

## Goals / Non-Goals

**Goals:**

- Own crate-tarball **layout and compression** in the manager after pycargoebuild no-write.
- Pack via stage directory + system `tar` + `XZ_OPT=-T0 -9e` (multi-threaded extreme-class compression).
- Drive registry crate set and `.cargo-checksum.json` `package` hashes from **parsed `Cargo.lock`**.
- Keep pycargoebuild for fetch, verify, license, and GIT_CRATES ebuild surgery.
- Preserve reuse path (no pycargo, no pack).
- Update cargo-crates-assets requirements to match the split.

**Non-Goals:**

- Job/CPU pool interaction with `-T0` (future proposal).
- Deterministic tar metadata for bit-identical rebuilds.
- Shared persistent distdir across runs.
- Replacing pycargoebuild fetch/license entirely.
- Pure-Haskell xz codecs.

## Decisions

### D1 — Split at `--no-write-crate-tarball`

**Choice:** Keep invoking pycargoebuild with `-c`, `--crate-tarball-path`, `--crate-tarball-prefix cargo_home/gentoo`, and add `--no-write-crate-tarball`. After success, manager packs.

**Alternatives:** (a) Full pycargo write (status quo). (b) Drop pycargo and reimplement fetch+license. (c) Fork pycargo for compression knobs only.

**Rationale:** Official flag exists for “you create the tarball”; removes the unconfigurable bottleneck without reimplementing SPDX/license or fetch.

### D2 — Stage + `tar` + `XZ_OPT=-T0 -9e`

**Choice:** For each registry package from the lock with a checksum:

1. Ensure `{name}-{version}.crate` exists under pycargo distdir (fail if missing after pycargo).
2. Extract into `stage/cargo_home/gentoo/{name}-{version}/` (crate layout as shipped).
3. Write `stage/cargo_home/gentoo/{name}-{version}/.cargo-checksum.json` as `{"package":"<lock-checksum>","files":{}}`.
4. `tar -acf $OUT` from stage with env `XZ_OPT=-T0 -9e`, archiving the `cargo_home` top-level entry (same prefix cargo.eclass expects).
5. Write via temp file in the output directory, then rename to the final `{pn}-{pv}-crates.tar.xz`.

**Alternatives:** Stream-repack without full extract (less disk, more code); pure Haskell compression (no `-T0`); `XZ_OPT=-T0 -9` without extreme (smaller wall, larger size; rejected—product chose `-9e`).

**Rationale:** Matches Go vendor packing style; multi-threaded; layout parity with pycargo’s FileCrate repack. Git crates stay out of the tarball (pycargo/GIT_CRATES), same as stock pycargo repack.

### D3 — Parse `Cargo.lock` for pack inputs

**Choice:** Parse the lock at the policy lock root (post-clone) for registry packages that carry a checksum; use name, version, and checksum for staging and JSON. Ignore path/git/workspace-only entries for packing.

**Alternatives:** Glob `*.crate` + SHA-256 of file bytes (simpler; rejected—product chose lock parse).

**Rationale:** Checksums match what Cargo and pycargo used to verify; lock is the authoritative dependency set. Missing `.crate` after pycargo is a hard pack error naming the package.

Implementation note: prefer a focused lock parser for `[[package]]` name/version/source/checksum needed for packing (and reuse existing MSRV tree walk where helpful). Do not reimplement pycargo’s SPDX license aggregation.

### D4 — Temp tree and space

**Choice:** Stage under the existing cargo full-path temporary directory (alongside clone and distdir). Tear down with that temp. Extend FullCargo-oriented disk checks so headroom accounts for expanded crate sources plus output tarball, not only post-clone size.

**Rationale:** Same lifecycle as today; avoids orphan stages; aligns with existing ENOSPC learnings.

### D5 — Errors and progress

**Choice:** Distinct error prefixes: `pycargoebuild failed: …` vs pack failures (`cargo crates pack failed: …` or equivalent). Progress: keep pycargo step; add a pack/stage status step if the materialize progress host already has step slots (mirror “pycargoebuild” → “crates pack” naming).

**Atomicity:** Pack to a temp path next to the final out path; rename on success; do not leave a partial final basename.

### D6 — Spec boundary

**Choice:** Requirements state that the program SHALL NOT reimplement pycargoebuild’s **crate fetch or license logic** in Haskell; **MAY/SHALL** parse `Cargo.lock` for packing (and existing MSRV). Manager SHALL own tarball creation after no-write pycargo.

### D7 — Concurrency

**Choice:** No change to `--jobs` or nested CPU caps in this design. Document risk only; future resource-scheduling proposal owns it.

### D8 — Validation

**Choice:** Production: final tarball exists and size &gt; 0 after pack. Tests: unit coverage for lock→checksum JSON and path prefix; fixture-scale integration (tiny fake distdir + lock) without network; mocks for pycargo still injectable via `CargoOps`.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Expanded stage uses multi‑GB disk on large trees | FullCargo space checks include extract + tarball headroom; temp under configured TMPDIR |
| `xz -T0` oversubscribes with concurrent cargo packages | Accepted; future jobs/CPU proposal; operators can lower `--jobs` |
| Lock parse incompleteness (TOML edge cases) | Fail closed with clear error; test against real locks from hk/mise/usage samples in unit fixtures |
| Layout mismatch vs cargo.eclass | Mirror pycargo FileCrate layout; prefix `cargo_home/gentoo`; checksum JSON shape; smoke unpack in tests |
| pycargo still slow on cold fetch | Unchanged; aria2/shared distdir are separate wins |
| New tarballs larger/smaller than historical extreme ST | Expected; reuse keys on published hash only |
| GIT_CRATES packages | Unchanged: pycargo still updates ebuild; pack only registry FileCrates |

## Migration Plan

- No operator config migration.
- No need to rebuild historical assets; only new full-path publishes use the new compressor.
- Rollback: revert to pycargo writing the tarball (remove `--no-write` and pack step) if pack regresses emerge consumers—verify one package emerge smoke after first real publish if possible.

## Open Questions

None that block specs or tasks. Deferred: concurrent `-T0` policy; persistent distdir; tar determinism.
