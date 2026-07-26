## 1. Vendor assets

- [x] 1.1 Checkout `dgraph-io/badger` tag `v4.9.4` (clean tree)
- [x] 1.2 Create `badger-4.9.4-vendor.tar.xz` (go-mod top-level) via overlay helper or equivalent
- [x] 1.3 Publish to mndz-overlay-assets: sidecars under `dev-db/badger/`, commit `dev-db/badger: 4.9.4`, push, GitHub release tag `badger-4.9.4` with the tarball asset

## 2. Overlay package

- [x] 2.1 Add `dev-db/badger/metadata.xml` (GitHub remote-id `dgraph-io/badger`)
- [x] 2.2 Write `badger-4.9.4.ebuild`: `go-module` + `shell-completion`, Apache-2.0, crush-style KEYWORDS, BDEPEND from go.mod (`>=dev-lang/go-1.23.0:=` or exact directive)
- [x] 2.3 SRC_URI: GitHub archive `v${PV}`, assets vendor URL with `${PV}`, `jemalloc? ( … fixed jemalloc tarball … )`
- [x] 2.4 IUSE: `bash-completion fish-completion jemalloc test zsh-completion`; `RESTRICT="!test? ( test )"`
- [x] 2.5 `src_compile`: private jemalloc build when USE=jemalloc + `-tags=jemalloc`; else plain `ego build -o badger ./badger`
- [x] 2.6 `src_install`: `dobin badger`, docs, completions via `badger --dir /var/empty completion …`
- [x] 2.7 `src_test`: `ego test ./...`
- [x] 2.8 Run `ebuild … manifest` and commit overlay package

## 3. Operator smoke

- [x] 3.1 Emerge `=dev-db/badger-4.9.4`
- [x] 3.2 Run `badger --help` and confirm success
- [x] 3.3 Report smoke results; mark this change complete only after smoke passes
