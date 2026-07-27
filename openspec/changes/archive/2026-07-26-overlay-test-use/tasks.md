## 1. Convention / shared

- [x] 1.1 Confirm live PVR inventory for targets: ralph-tui, dolt, beads, crush, hk, mise, usage, opencode, openspec (badger verify-only; bins skipped)
- [x] 1.2 For every content edit: git-mv to next `-rN`, never leave final live path as unrevised overwrite; update Manifest + md5-cache per package

## 2. Fix incomplete gate (Bun)

- [x] 2.1 `dev-util/ralph-tui`: revbump; keep `IUSE=test`; add `RESTRICT="!test? ( test )"`; `src_test` → `bun test` without redundant `if use test`

## 3. Gate existing Go suites

- [x] 3.1 `dev-db/dolt`: revbump; add `IUSE="test"` + `RESTRICT="!test? ( test )"`; keep `ego test ./...`
- [x] 3.2 `dev-util/beads`: revbump; same IUSE/RESTRICT/`src_test` pattern
- [x] 3.3 `dev-util/crush`: revbump; same IUSE/RESTRICT/`src_test` pattern

## 4. Gate inherited Cargo suites

- [x] 4.1 `dev-util/hk`: revbump; append `test` to IUSE; add RESTRICT gate; leave `cargo_src_test` (or thin wrapper); add skips only if required offline
- [x] 4.2 `dev-util/mise`: revbump; same as hk
- [x] 4.3 `dev-util/usage`: revbump; same as hk

## 5. Introduce gated src_test (Bun / npm)

- [x] 5.1 `dev-util/opencode`: revbump; append `test` to IUSE; merge `RESTRICT="strip !test? ( test )"`; add offline-friendly Bun `src_test`
- [x] 5.2 `dev-util/openspec`: revbump; append `test` to IUSE; add RESTRICT gate; add offline-friendly npm/`src_test`

## 6. Verify and hygiene

- [x] 6.1 Confirm `dev-db/badger` still has full pair; no unnecessary revbump
- [x] 6.2 Confirm prebuilts unchanged
- [x] 6.3 Spot-check at least one package per class (Go / Cargo / Bun / npm): `USE=-test FEATURES=test` skips; `USE=test FEATURES=test` enters `src_test`
- [x] 6.4 Update any mndz-overlay-manager fixture that embeds old ebuild shapes if present
- [x] 6.5 Commit overlay package(s) in overlay style (`cat/pkg: PV-rN`)
