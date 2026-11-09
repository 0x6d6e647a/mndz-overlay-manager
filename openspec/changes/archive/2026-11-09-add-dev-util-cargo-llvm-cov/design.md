# Design

## Context

`CargoSource` is `CargoGitTag` or `CargoCratesIo`. Full-path Git tag materialize clones the tag and hard-fails when `Cargo.lock` is missing at the lock root. `cargo-llvm-cov` tags omit that file on purpose. The published `.crate` has a lock, drops the `test-helper` git dev-dependency, and omits `tests/fixtures/crates/`, so it cannot run the upstream suite.

Version detection stays a GitHub tag with prefix `v`. `update` still moves to the newest tag and takes no PV. The 0.9.0 crates tarball is packed by hand in the materialize image, the same split the biodiff seed used. The image already provides `rust-bin` new enough for `rust-version` 1.87 and has network for `cargo generate-lockfile`.

Host `dev-lang/rust-bin` does not ship `llvm-cov`. Slotted LLVM lives at `/usr/lib/llvm/<major>/bin`. `cargo.eclass` turns `CARGO_SKIP_TESTS` into harness `--skip` arguments after `--`.

See proposal.md for why this package is in scope.

## Goals / Non-Goals

**Goals:**

- Add provenance `CargoGitTagGenerateLock` and use it only for `dev-util/cargo-llvm-cov`.
- Generate `Cargo.lock` in the materialize container only when the tag lacks one, then reuse the Git tag pycargoebuild and pack path.
- Keep the ebuild body (wrapper, `src_test`, `IUSE`, `RDEPEND`) across the 0.9.0 → 0.9.1 rewrite.
- Prove 0.9.0 with a default emerge, a smoke, and `FEATURES=test` before `outdated`, then the same loop on 0.9.1.

**Non-Goals:**

- A Boolean on every `Cargo` value. `CargoCratesIo` cannot mean "generate a lock".
- A manager command that packs the on-disk PV while a newer tag exists.
- Changing the missing-lock failure of `CargoGitTag`.
- README or CONTRIBUTING edits. This adds no CLI, config key, or quality-gate step. The `cargo-crates-assets` Purpose line gains the new provenance at archive time; deltas cannot carry Purpose.

## Decisions

### Third provenance constructor

`CargoSource` gains `CargoGitTagGenerateLock`. Call sites that mean "GitHub archive plus an existing lock" stay on `CargoGitTag`. Coherence and `SRC_URI` rewrite treat the new constructor like `CargoGitTag`: primary source is `github.com/…/archive/refs/tags/v${PV}.tar.gz`. A crates.io primary line hard-fails.

Alternative: a `generateLock :: Bool` field. Rejected. It is meaningless for `CargoCratesIo` and would touch every `Cargo` literal.

### Generate the lock, then the existing pack

After the tag checkout, if provenance is `CargoGitTagGenerateLock` and `Cargo.lock` is absent at the lock root, the container runs `cargo generate-lockfile` in that directory. An existing lock is left byte-for-byte. A non-zero exit hard-fails the unit and names the lock root; `pycargoebuild` does not run. `CargoGitTag` still hard-fails on a missing lock and does not generate one.

The generated lock is what pycargoebuild and the crates pack already consume. For this package that lock includes git crate `test-helper` at rev `82e3b012a49fb16587e165986674290ef682a5b0`, so the ebuild gains `GIT_CRATES` and `SRC_URI+=" ${CARGO_CRATE_URIS}"` through the existing empty-`CRATES` fetch-line rule. `CRATES` stays empty.

Alternative: check a lock into the overlay `files/` directory. Rejected. The Git tag lane reads the clone, which still has no lock, so `update` could not pack 0.9.1.

### Policy

`hardcodedPolicies` maps `dev-util/cargo-llvm-cov` to GitHub `taiki-e` / `cargo-llvm-cov` / prefix `v`, `DepsAndAssets (Cargo Nothing Nothing CargoGitTagGenerateLock)`, and an empty runtime-lane allowlist (every discovered arch). A `lookupPolicy` test asserts that row.

### One LLVM lookup script

`files/cargo-llvm-cov` is the wrapper installed at `/usr/bin/cargo-llvm-cov`. The built binary goes to `/usr/libexec/cargo-llvm-cov/cargo-llvm-cov` with `QA_FLAGS_IGNORED` on that path. The script reads `LLVM version:` from `rustc -vV`, takes the major component, and fills only the unset one of `LLVM_COV` and `LLVM_PROFDATA` with `/usr/lib/llvm/<major>/bin/llvm-cov` and `llvm-profdata`. A missing path exits non-zero before exec. `src_test` sources the same file from `${FILESDIR}` and exports the two variables before `cargo_src_test`, because the test binary is the just-built executable, not the installed wrapper.

`RDEPEND` is unslotted `llvm-core/llvm`. Slot `:22` matches today's rust-bin and goes stale when rustc's LLVM major changes.

### Test phase

```
src_test() {
    git init && git add -A && git commit with an inline user.name and user.email
    source the wrapper's lookup and export LLVM_COV and LLVM_PROFDATA
    local CARGO_SKIP_TESTS=( trybuild ui_test )
    cargo_src_test
}
```

`git add -A` tracks fixture dotfiles (`.cargo`, `.config`). The commit makes both the index and `HEAD` contain them, which `test_helper::git::copy_tracked_files` needs. `CARGO_SKIP_TESTS` is the eclass array that becomes harness `--skip` after `--`, so the filters hit the `tests/test.rs` binary rather than dropping that binary by Cargo target name. `BDEPEND` is `test? ( dev-vcs/git )`.

### Seed pack is manual, bump is `update`

0.9.0 is packed in the materialize image: clone `v0.9.0`, `cargo generate-lockfile`, `pycargoebuild --use-crate-tarball`, manager-style `cargo_home/gentoo/` pack, publish release `cargo-llvm-cov-0.9.0` with `b3`, `sha256`, and `sha512` sidecars. The ebuild's primary `LICENSE` line is `|| ( Apache-2.0 MIT )`. pycargoebuild fills the dependent-crate block; the rewrite keeps `LICENSE` terms outside that block.

The operator emerges and smokes 0.9.0, then emerges it with `FEATURES=test`, before `outdated`. `update` is the first execution of the Haskell constructor, producing 0.9.1. The operator repeats the default emerge, smoke, `FEATURES=test` emerge, and smoke.

`KEYWORDS` on the seed, and therefore on the copied bump, are `~amd64 ~arm ~arm64 ~loong ~mips ~ppc ~ppc64 ~riscv ~s390 ~sparc ~x86`. `RUST_MIN_VER` is the harvest result, a three-component version at least `1.87.0`.

## Risks / Trade-offs

- [Golden coverage reports disagree with this host's LLVM 22.1.8] → Add that test name to `CARGO_SKIP_TESTS`, say why in an ebuild comment, and extend the seed spec's skip list before `outdated`. Do not turn the suite off.
- [`cargo generate-lockfile` resolves newer compatible crates on a later re-pack] → The published tarball and `GIT_CRATES` pin what emerges use. Do not re-pack 0.9.0 after the release exists.
- [Portage's git has no `user.email`] → The `src_test` commit passes `-c user.name` and `-c user.email` on the command. It does not write git config.
- [Wrapper and `src_test` drift] → Both use `${FILESDIR}/cargo-llvm-cov` for the lookup. The installed copy is that same file.
- [0.9.0 was packed by hand, so it does not exercise the Haskell constructor] → 0.9.1 `update` is that exercise. The 0.9.0 emerges still prove the ebuild body.

## Migration Plan

1. Land the manager constructor, policy, coherence, `SRC_URI` case, and unit tests. `just check` is the gate.
2. Add the 0.9.0 ebuild and hand-publish its assets. Operator emerge, smoke, `FEATURES=test`, smoke. Signed overlay commit. Do not push unless asked.
3. Operator runs `outdated`, then `update` on a TTY. Emerge 0.9.1, smoke, `FEATURES=test`, smoke.
4. On archive, sync both deltas and extend the `cargo-crates-assets` Purpose line to name `CargoGitTagGenerateLock`.

Rollback before the 0.9.0 assets release is deleting the unpublished ebuild. After that release, leave the tag in place. Do not force-move it. A bad 0.9.1 `update` is fixed with a new revision or by not pushing the overlay commit.
