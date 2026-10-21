# Design

## Context

See `proposal.md` for why `4.9.6` fails. The live overlay file is `dev-db/badger/badger-4.9.6.ebuild` (commit `1a61bee` on `origin/master`). The installed package is `dev-db/badger-4.9.6`, built 17 October 2026 13:40, before `/usr/bin/g++` switched to gcc-16 at 15:50. The vdb `USE` includes `jemalloc`. `USE_MISC` in `/etc/portage/make.conf` turns that flag on globally. The installed `/usr/bin/badger` contains `je_malloc_stats_print` and `NEEDED` is only `libc.so.6`.

`src_compile` with `USE=jemalloc` unpacks `jemalloc-5.3.0`, runs `econf --with-jemalloc-prefix=je_ --disable-shared --enable-static`, then `emake`. The C objects in the failed build compiled. `src/jemalloc_cpp.cpp:90` did not:

```
std::__throw_bad_alloc();
```

GCC 16.2.1 reports that name is not a member of `std`. The failed tree is `/var/tmp/portage/dev-db/badger-4.9.6-2026-10-20T17:17:07-07:00`. `ego build` and the ristretto `#cgo LDFLAGS` `sed` never ran.

Gentoo's fix for the same tarball is `dev-libs/jemalloc/files/jemalloc-5.3.0-dont-call-libstdcxx-internals.patch` (bug 967868, commit `4b929d70`). It replaces that call with `throw std::bad_alloc()`. `CXXFLAGS` on this host come from `COMMON_FLAGS` and do not pass `-fno-exceptions`, so that throw compiles. jemalloc 5.4.0 does the same throw when exceptions are enabled.

`${S}` is the badger tree. The jemalloc sources are `${WORKDIR}/jemalloc-5.3.0`. `go-module` `src_prepare` applies `PATCHES` to `${S}` only.

The next `update dev-db/badger` copies the newest ebuild body and deletes the previous ebuild file. It does not delete `files/`. `go-vendor-assets` requires the manager to leave the jemalloc companion `SRC_URI` in place while rewriting the vendor URL.

## Goals / Non-Goals

**Goals:**

- The only `4.9.6` ebuild is `badger-4.9.6-r1.ebuild`.
- `USE=jemalloc` applies Gentoo's patch to `jemalloc-5.3.0` before `econf`, then builds with the existing `je_` prefix and `-tags=jemalloc`.
- `metadata/md5-cache/dev-db/badger-4.9.6-r1` exists, `badger-4.9.6` does not, and `_md5_` is the MD5 of the `-r1` ebuild.
- A fresh `emerge =dev-db/badger-4.9.6-r1` completes install, and `badger --help` runs.

**Non-Goals:**

- Changing the jemalloc version, configure flags, or the ristretto `sed`.
- Teaching the manager to inject this patch. The next bump copies the ebuild body, and `files/` stays in the package directory.
- Reusing the preserved Portage work directory from the failed build as the emerge proof.
- Applying any other Gentoo jemalloc patch (page size, `make check`, emap null pointer).

## Decisions

### 1. Publish `4.9.6-r1` and remove `4.9.6`

`4.9.6` is on `origin/master` and installed. An in-place edit of that filename is invisible to `emerge -uDN @world`. Rename the ebuild. One file of this PV stays selectable.

The previous revision bump in this package is `9645edd`, subject `dev-db/badger: 4.9.5-r1`, empty body, renaming the ebuild and the md5-cache. Follow that subject. `thin-manifests` leaves `Manifest` out of the commit.

- **Alternative — edit `badger-4.9.6.ebuild` in place:** rejected. The operator said this revision is already published.
- **Alternative — keep both the unrevisioned ebuild and a `-r1`:** rejected. The unrevisioned body fails `emake` on this compiler.

### 2. Vendor Gentoo's patch and `eapply` it in the jemalloc workdir

Copy `jemalloc-5.3.0-dont-call-libstdcxx-internals.patch` from the Gentoo tree into `dev-db/badger/files/` unchanged. The hunk is the one-line replacement at `handleOOM`, and the failed tree's `jemalloc_cpp.cpp` matches that context at line 90.

Apply it inside the existing `pushd`, before `econf`. `eapply` dies when the hunk does not match. EAPI 8 does not need `|| die`.

```ebuild
		pushd "${jemalloc_src}" >/dev/null || die
		# GCC 16 no longer declares std::__throw_bad_alloc from <new> (bug 967868).
		eapply "${FILESDIR}/jemalloc-5.3.0-dont-call-libstdcxx-internals.patch"
		econf \
```

Leave `PATCHES` unset. A global entry would try to patch the badger sources.

- **Alternative — `sed` the call in `src_compile`:** rejected. `sed` exits 0 when the pattern misses, so a drifted line dies later inside `g++` with the same error. The ristretto rewrite stays a `sed` because the replacement path is computed.
- **Alternative — `--disable-cxx`:** rejected. That skips `jemalloc_cpp.cpp`. The C objects in the failed log already compiled, and the installed binary was built with cxx left on, which is also what upstream badger's Makefile does.
- **Alternative — pin jemalloc 5.4.0:** rejected. Upstream PR #2900 fixes this call, and Gentoo's 5.4.0-r2 still patches the emap null-pointer bug (984178). The seed pin is 5.3.0 so the distfile matches Gentoo. Badger's own Makefile pin of 5.3.1 still contains `std::__throw_bad_alloc()`.
- **Alternative — depend on `dev-libs/jemalloc`:** rejected. `dev-db-badger-seed` forbids that dependency. Gentoo deletes the static archives and builds without the `je_` prefix that ristretto calls.

### 3. Refresh md5-cache in the same overlay commit

Regenerate with package-scoped egencache for repo `mndz` and package `dev-db/badger`, using the production argv in `Update.Md5Cache` (location pinned to the overlay checkout). The new cache path is `metadata/md5-cache/dev-db/badger-4.9.6-r1`. Remove `metadata/md5-cache/dev-db/badger-4.9.6`. `_md5_` must equal the MD5 of `badger-4.9.6-r1.ebuild`.

Do not commit through the manager `gencache` command. That command writes its own `metadata: regenerate md5-cache` commit. This cache file belongs with the ebuild.

`Manifest` is not part of the commit.

- **Alternative — hand-edit `_md5_`:** rejected. `egencache` is what the tree's other ebuild commits used.

## Risks / Trade-offs

- **[Risk]** The Go half of `src_compile` has not run on GCC 16. The failed build died in `emake` before the ristretto `sed` and `ego build`. → **Mitigation:** the emerge of `=dev-db/badger-4.9.6-r1` is the gate. The 17 October install used this same ebuild body once jemalloc existed. Do not resume the failed Portage tree.
- **[Risk]** A later jemalloc pin bump leaves the `eapply` in the copied body, and the 5.3.0 hunk no longer matches. → **Mitigation:** `eapply` fails before `econf`. Drop the patch when the pin moves to a tarball that already throws `std::bad_alloc()`.
- **[Risk]** `throw std::bad_alloc()` fails to compile if a future `CXXFLAGS` passes `-fno-exceptions`. → **Mitigation:** this host does not. jemalloc 5.4.0's fuller fix (`std::terminate()` without exceptions) is out of scope while the pin stays 5.3.0 and exceptions stay on.

## Migration Plan

1. In mndz-overlay, `git mv` `dev-db/badger/badger-4.9.6.ebuild` to `badger-4.9.6-r1.ebuild`. Copy Gentoo's patch into `dev-db/badger/files/jemalloc-5.3.0-dont-call-libstdcxx-internals.patch`. Add the `eapply` from Decision 2. Do not edit `Manifest`, `SRC_URI`, or `PATCHES`.
2. Regenerate md5-cache with package-scoped `egencache --repo mndz --update dev-db/badger` and the production repositories-configuration from `Update.Md5Cache`. The cache path becomes `metadata/md5-cache/dev-db/badger-4.9.6-r1`. Remove the `badger-4.9.6` cache file. Check that `_md5_` equals `md5sum` of the `-r1` ebuild.
3. Commit the `-r1` ebuild, the new patch, and the cache rename in mndz-overlay. Subject: `dev-db/badger: 4.9.6-r1`. No commit body. The commit is GPG-signed by the overlay hook.
4. Operator: `emerge -av1 =dev-db/badger-4.9.6-r1`, then `badger --help`. Pass requires a finished merge and a help listing. `strings /usr/bin/badger | grep je_malloc_stats_print` confirms the jemalloc tag still linked.
5. Rollback is reverting that overlay commit. Installed `4.9.6` stays until `-r1` emerges.

The manager change is these planning artifacts only. The next `update dev-db/badger` copies the repaired body.

## Open Questions

None. The revision, the patch file, and the `eapply` site are settled.
