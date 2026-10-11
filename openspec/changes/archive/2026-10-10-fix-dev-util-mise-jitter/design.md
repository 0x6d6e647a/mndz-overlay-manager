# Design

## Context

See `proposal.md` for why `2026.10.5` fails. The live overlay file is `dev-util/mise/mise-2026.10.5.ebuild`. The installed package is `dev-util/mise-2026.10.3` (`dev-util/mise` is in world). `2026.10.5` is commit `1a63ffa` and is not in the vdb.

`src_configure` already exports `OPENSSL_NO_VENDOR=1` and `ZSTD_SYS_USE_PKG_CONFIG=1`, then runs `cargo_src_configure --no-default-features` with `myfeatures=( native-tls )`. That still compiles `aws-lc-sys` 0.45.0. `mise` depends on `aube` with `features = ["rustls"]`, and that feature enables `reqwest/rustls`, which selects `aws-lc-rs`. `OPENSSL_NO_VENDOR` only affects `openssl-sys`. System OpenSSL stays a second TLS stack.

The failing gcc line compiles `jitterentropy-base.c` as `-O3` (aws-lc), then the crate dialect `-O0`, then Portage `CFLAGS` `-O2` twice (`CFLAGS` and `CFLAGS_x86_64_unknown_linux_gnu`). The last `-O` wins, `__OPTIMIZE__` is set, and `jitterentropy-base.c` hits `#error`. `cc` 1.6 snapshots the process environment on first use, so the crate's later rewrite of those variables never reaches the compiler. The crate's supported opt-out is `AWS_LC_SYS_NO_JITTER_ENTROPY=1` (any value whose first character is a digit). That skips the jitter `.c` files, defines `DISABLE_CPU_JITTER_ENTROPY`, and uses the kernel CSPRNG plus RDRAND/RNDR when present.

An unsandboxed offline release build with the ebuild's cargo line, Portage `CFLAGS`, eclass rustflags, Rust 1.97.1, and this export finished in 27m 01s (exit 0). `libaws_lc_0_45_0_crypto.a` has no jitterentropy members and defines `opt_out_cpu_jitter_*`. `mise --version` printed `2026.10.5`. That build did not run inside the Portage sandbox and did not run `src_install`.

`SRC_URI` uses `${PV}` and `${P}`. Neither includes the revision, so a `-r1` keeps the same distfiles. `thin-manifests` means an ebuild rename does not edit `Manifest`.

Apply copies the newest ebuild (`groupNewest` prefers a revision) and runs `pycargoebuild -i`, which rewrites `CRATES` and `LICENSE` only. The body fix belongs in mndz-overlay.

## Goals / Non-Goals

**Goals:**

- `mise-2026.10.5-r1` is the only `2026.10.5` ebuild, and `src_configure` exports `AWS_LC_SYS_NO_JITTER_ENTROPY=1` before `cargo_src_configure`.
- The checked-in md5-cache name matches `2026.10.5-r1` and its `_md5_` is the MD5 of that ebuild.
- A fresh `emerge =dev-util/mise-2026.10.5-r1` completes install, and `mise --version` prints `2026.10.5`.

**Non-Goals:**

- Changing cargo.eclass, make.conf `CFLAGS`, or make.conf `RUSTFLAGS`.
- Teaching the manager to inject this export. The next bump copies the ebuild body.
- Reusing the preserved Portage work directory from the failed build as the emerge proof. That tree was used for the unsandboxed spike.

## Decisions

### 1. Publish `2026.10.5-r1` and remove the unrevisioned ebuild

`2026.10.5` never installed, and `2026.10.3` upgrades to either filename. The revision is still the published identity: `2026.10.5` is already on `master`, and the fix is a new ebuild of that PV. Rename `mise-2026.10.5.ebuild` to `mise-2026.10.5-r1.ebuild`. Leaving both files would keep `=dev-util/mise-2026.10.5` selectable, and that body does not build.

- **Alternative — edit `2026.10.5` in place:** rejected for this change. The operator asked for a `-r1`.
- **Alternative — keep both ebuilds:** rejected. The unrevisioned body fails `src_compile`.

### 2. Opt out of CPU jitter instead of changing flags or the crate graph

Set the upstream variable. It is read as `AWS_LC_SYS_NO_JITTER_ENTROPY_<target>` and then `AWS_LC_SYS_NO_JITTER_ENTROPY`. The unscoped name is enough on amd64. Place it with the other `src_configure` exports:

```ebuild
	# aws-lc-sys jitterentropy #errors when Portage -O2 follows the crate -O0.
	export AWS_LC_SYS_NO_JITTER_ENTROPY=1
```

Entropy for that aws-lc build becomes the kernel CSPRNG, with RDRAND/RNDR mixed in when the CPU has them. `mise` is a CLI, not a FIPS module boundary.

- **Alternative — strip `-O*` from `CFLAGS`:** rejected. That would deoptimize every other C object in the graph.
- **Alternative — patch `cc_builder.rs` in the crates tarball:** rejected. The next bump replaces the tarball and drops the patch.
- **Alternative — stop depending on `aws-lc-rs`:** rejected. That means patching `aube` or `mise` and republishing `mise-2026.10.5-crates.tar.xz`. Upstream `aube` has no `native-tls` feature.

### 3. Refresh md5-cache in the same overlay commit

After the rename, remove `metadata/md5-cache/dev-util/mise-2026.10.5` and generate `mise-2026.10.5-r1` with package-scoped `egencache --repo mndz --update dev-util/mise`. `_md5_` must equal the MD5 of the `-r1` ebuild. Do not commit through the manager `gencache` command: that command writes its own `metadata: regenerate md5-cache` commit. This cache file belongs with the ebuild.

`Manifest` is not part of the commit.

- **Alternative — hand-edit `_md5_` and copy the old cache:** rejected. `egencache` is what the tree's other revision commits used, and a copied file can keep a stale path association.

## Risks / Trade-offs

- **[Risk]** The sandbox or `src_install` fails even though the unsandboxed compile succeeded. → **Mitigation:** the emerge of `=dev-util/mise-2026.10.5-r1` is the gate. The spike is evidence for the export, not a substitute.
- **[Risk]** A later `aws-lc-sys` renames the opt-out and a bump copies a now-dead export, so the `#error` returns. → **Mitigation:** the variable is the crate's documented switch, and `pycargoebuild --inplace` will not delete it. A renamed variable shows up as the same `src_compile` error on the next emerge.
- **[Risk]** `2026.10.5-r1` and a future PV are both visible during the bump window, and `groupNewest` could copy the wrong body. → **Mitigation:** one live `2026.10.5` ebuild, the revision. `groupNewest` prefers a revision of the same PV, and a newer PV replaces it after the body is copied.
- **[Risk]** CPU jitter is absent, so aws-lc seeding depends on the kernel CSPRNG and hardware RNG. → **Mitigation:** that is the crate's opt-out path (`opt_out_cpu_jitter_*`). The static archive from the spike contains those symbols and no jitterentropy objects.

## Migration Plan

1. In mndz-overlay, `git mv` `dev-util/mise/mise-2026.10.5.ebuild` to `mise-2026.10.5-r1.ebuild` and add the export in Decision 2. Do not edit `Manifest`.
2. Remove `metadata/md5-cache/dev-util/mise-2026.10.5`. Run package-scoped `egencache --repo mndz --update dev-util/mise`. Check that `metadata/md5-cache/dev-util/mise-2026.10.5-r1` exists, the old cache path is gone, and `_md5_` equals `md5sum` of the ebuild.
3. Commit those two paths in mndz-overlay. Subject: `dev-util/mise: 2026.10.5-r1`. No commit body. The commit is GPG-signed by the overlay hook.
4. Operator: `emerge -av1 =dev-util/mise-2026.10.5-r1`, then `mise --version`. Pass requires a finished merge and a version line of `2026.10.5`.
5. Rollback is reverting that overlay commit. `2026.10.3` stays installed until `-r1` emerges.

The manager change is these planning artifacts only. The next `update dev-util/mise` copies the repaired body.
