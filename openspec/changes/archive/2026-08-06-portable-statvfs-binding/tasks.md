## 1. Portable binding

- [x] 1.1 Add `src/Update/DiskSpace/StatVfs.hsc` with `freeBytesStatvfs` using `#{size struct statvfs}` and `#{peek}` for `f_frsize` / `f_bavail` (CULong → Integer free bytes); throw `IOError` on `statvfs` failure
- [x] 1.2 List `Update.DiskSpace.StatVfs` under library `other-modules` in `mndz-overlay-manager.cabal`
- [x] 1.3 Wire `Update.DiskSpace.getFreeBytesStatvfs` (or equivalent) to call `freeBytesStatvfs`; delete `statvfsBufSize`, fixed `peekByteOff` offsets, and the local `c_statvfs` import if unused

## 2. Tests

- [x] 2.1 Add a smoke test in `test/Test/DiskSpace.hs` that calls production `getFreeBytes` on a usable temp path and asserts `Right n` with `n >= 0`
- [x] 2.2 Confirm existing injectable pure-gate tests still pass without depending on real layout

## 3. Verification and cleanup

- [x] 3.1 Run full `hk check` (rebuild HIE for the new module; fix any ormolu/hlint/stan/weeder issues without weakening baselines)
- [x] 3.2 Confirm no remaining magic `struct statvfs` size/offset hardcodes remain as the long-term design
- [x] 3.3 Optionally mark or retire deferred note `manager-arch-portability.md` after the binding is in place
