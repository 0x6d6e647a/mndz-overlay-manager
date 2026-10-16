# Design

## Context

See `proposal.md` for why `2.6.0` fails. The live overlay file is `dev-util/hk/hk-2.6.0.ebuild` (commit `79e20bc`). The installed package is `dev-util/hk-2.5.0`. `2.6.0` is not in the vdb.

`src_configure` only runs `cargo_src_configure --bin hk`. The binary still links `aws-lc-sys` 0.45.0: `hk` enables `pklr` feature `reqwest`, `pklr` 5.1.1 enables `reqwest` feature `rustls`, and that feature is `__rustls-aws-lc-rs`. `hk` 2.5.0 already locked the same `aws-lc-sys` 0.45.0 through `pklr` 4. Its lock resolved `cc` 1.5.1. The 2.6.0 lock resolved `cc` 1.8.0. `cc` 1.6.0 (2026-10-03) reads the process environment once per `Build`, on first use.

`prepare_jitter_entropy_builder` calls `is_flag_supported`, which takes that snapshot while Portage `CFLAGS` and `CFLAGS_x86_64_unknown_linux_gnu` are still `-O2`. `jitter_entropy_cflags_guards` rewrites the process environment only around the later `compile_intermediates`. gcc therefore sees the crate's `-O0` and then `-O2` twice. The last `-O` wins, `__OPTIMIZE__` is set, and `jitterentropy-base.c:47` hits `#error`. The failed tree is `/var/tmp/portage/dev-util/hk-2.6.0-2026-10-15T22:24:07-07:00`.

The crate's supported opt-out is `AWS_LC_SYS_NO_JITTER_ENTROPY=1` (any value whose first character is a digit). It skips the jitter `.c` files, defines `DISABLE_CPU_JITTER_ENTROPY`, and uses the kernel CSPRNG plus RDRAND/RNDR when present. `dev-util/mise` already exports it. An unsandboxed offline mise build with this export and `aws-lc-sys` 0.45.0 finished; that spike was not an hk build and is not the hk proof.

`pycargoebuild -i` rewrites `CRATES` and `LICENSE` only. Apply copies the newest ebuild. The body fix belongs in mndz-overlay.

## Goals / Non-Goals

**Goals:**

- `hk-2.6.0.ebuild` is the only `2.6.0` ebuild, and `src_configure` exports `AWS_LC_SYS_NO_JITTER_ENTROPY=1` before `cargo_src_configure`.
- `metadata/md5-cache/dev-util/hk-2.6.0` keeps that filename and its `_md5_` is the MD5 of the edited ebuild.
- A fresh `emerge =dev-util/hk-2.6.0` completes install, and `hk --version` prints `2.6.0`.

**Non-Goals:**

- Changing cargo.eclass, make.conf `CFLAGS`, or make.conf `RUSTFLAGS`.
- Teaching the manager to inject this export. The next bump copies the ebuild body.
- Reusing the preserved Portage work directory from the failed build as the emerge proof.
- Adding the export to any package other than `dev-util/hk`.

## Decisions

### 1. Edit `hk-2.6.0.ebuild` in place

`2.6.0` never installed, and `2.5.0` upgrades to the same filename. Leave the ebuild name `hk-2.6.0.ebuild`. One file of this PV stays selectable.

- **Alternative — publish `2.6.0-r1` and remove the unrevisioned ebuild:** rejected. The operator asked for a revision on mise after that PV was already on master. This PV never merged, so the fix stays on the filename Portage already resolves.
- **Alternative — keep both an unrevisioned ebuild and a `-r1`:** rejected. The unrevisioned body fails `src_compile`.

### 2. Opt out of CPU jitter instead of changing flags or the crate graph

Set the upstream variable. It is read as `AWS_LC_SYS_NO_JITTER_ENTROPY_<target>` and then `AWS_LC_SYS_NO_JITTER_ENTROPY`. The unscoped name is enough on amd64. Place it before `cargo_src_configure`, with the comment mise already uses:

```ebuild
src_configure() {
	# aws-lc-sys jitterentropy #errors when Portage -O2 follows the crate -O0.
	export AWS_LC_SYS_NO_JITTER_ENTROPY=1

	# Skip the generate-docs helper binary
	cargo_src_configure --bin hk
}
```

Entropy for that aws-lc build becomes the kernel CSPRNG, with RDRAND/RNDR mixed in when the CPU has them. `hk` is a CLI, not a FIPS module boundary.

- **Alternative — strip `-O*` from `CFLAGS`:** rejected. That would deoptimize every other C object in the graph, including vendored libgit2, zlib, mimalloc, and ring.
- **Alternative — patch `cc_builder.rs` in the crates tarball, or pin `cc` below 1.6:** rejected. The next bump replaces the tarball and the lock.
- **Alternative — stop depending on `aws-lc-rs`:** rejected. `pklr`'s `reqwest` feature hard-codes `reqwest` feature `rustls`, which selects the aws-lc provider. That means patching `pklr` or `hk` and republishing `hk-2.6.0-crates.tar.xz`.

### 3. Refresh md5-cache in the same overlay commit

Regenerate `metadata/md5-cache/dev-util/hk-2.6.0` with package-scoped egencache for repo `mndz` and package `dev-util/hk`, using the production argv in `Update.Md5Cache` (location pinned to the overlay checkout). `_md5_` must equal the MD5 of the edited ebuild. The cache filename stays `hk-2.6.0`. Do not commit through the manager `gencache` command: that command writes its own `metadata: regenerate md5-cache` commit. This cache file belongs with the ebuild.

`Manifest` is not part of the commit.

- **Alternative — hand-edit `_md5_`:** rejected. `egencache` is what the tree's other ebuild commits used.

## Risks / Trade-offs

- **[Risk]** The sandbox or `src_install` fails. The mise spike used this export with `aws-lc-sys` 0.45.0, and it was not an hk build. → **Mitigation:** the emerge of `=dev-util/hk-2.6.0` is the gate. Do not resume the failed Portage tree.
- **[Risk]** A later `aws-lc-sys` renames the opt-out and a bump copies a now-dead export, so the `#error` returns. → **Mitigation:** the variable is the crate's documented switch, and `pycargoebuild --inplace` will not delete it. A renamed variable shows up as the same `src_compile` error on the next emerge.
- **[Risk]** CPU jitter is absent, so aws-lc seeding depends on the kernel CSPRNG and hardware RNG. → **Mitigation:** that is the crate's opt-out path. `hk` uses aws-lc only as the rustls crypto provider behind `pklr` package download.

## Migration Plan

1. In mndz-overlay, edit `dev-util/hk/hk-2.6.0.ebuild` and add the export in Decision 2. Do not rename the file. Do not edit `Manifest`.
2. Regenerate `metadata/md5-cache/dev-util/hk-2.6.0` with package-scoped `egencache --repo mndz --update dev-util/hk` and the production repositories-configuration from `Update.Md5Cache`. Check that the cache path is unchanged and `_md5_` equals `md5sum` of the ebuild.
3. Commit those two paths in mndz-overlay. Subject: `dev-util/hk: opt out of aws-lc jitterentropy`. No commit body. The commit is GPG-signed by the overlay hook.
4. Operator: `emerge -av1 =dev-util/hk-2.6.0`, then `hk --version`. Pass requires a finished merge and a version line of `2.6.0`.
5. Rollback is reverting that overlay commit. `2.5.0` stays installed until `2.6.0` emerges.

The manager change is these planning artifacts only. The next `update dev-util/hk` copies the repaired body.
