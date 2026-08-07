## Why

Free-space probing for `update` peeks Linux `struct statvfs` with hardcoded buffer size and field offsets measured on glibc x86_64. That is an implementation footgun (wrong free-byte math or heap corruption on other arches/libcs), not a product rule that only amd64 is supported. Fix it with a portable binding before multi-arch use or further disk-space work builds on the probe.

## What Changes

- Replace the fixed-size `allocaBytes` / `peekByteOff` path in production free-space measurement with an **hsc2hs** binding that uses compile-time `struct statvfs` layout from `<sys/statvfs.h>`.
- Keep the public `getFreeBytes` / `DiskSpaceProbe` injection surface and all pure gate math unchanged.
- Add a small smoke test that exercises real production free-space measurement on a usable path (non-negative success), without asserting exact free space.
- Remove magic offsets and “measured on x86_64” layout comments as long-term design.

### Non-goals

- Multi-OS (non-Linux) product support.
- Changing estimate factors, floors, margin, concurrent-sum math, same-device merge, or Portage DISTDIR warn-only policy.
- Disk resource pooling / reservation (`resource-scheduling.md`).
- Advertising architecture limits in README instead of fixing the probe.
- musl-specific dual bindings (correctness follows the sysroot used at build time).

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- (none — operator-facing free-space requirements in `disk-space-preflight` already require measuring free bytes on the filesystem that backs each path; this change is binding/implementation quality only. `skip_specs: true`.)

## Impact

- **Code:** `src/Update/DiskSpace.hs` (drop hardcodes; call portable helper); new `src/Update/DiskSpace/StatVfs.hsc` (or equivalent); `mndz-overlay-manager.cabal` (`other-modules` for the hsc2hs module).
- **Tests:** `test/Test/DiskSpace.hs` — keep injectable gate tests; add real-`getFreeBytes` smoke.
- **Build:** first `.hsc` module in the package; Cabal Simple + bundled `hsc2hs`; needs platform headers at compile time (already true for any FFI).
- **Docs:** optional tidy of deferred note `manager-arch-portability.md` after land; no operator CLI/config change → no README requirement unless arch support claims appear.
- **Quality gates:** full `hk check` after HIE rebuild for the new module.
