## 1. Pure revision selection

- [x] 1.1 Add pure helper (e.g. `writeVersionForPlannedPV`) that returns bare planned PV when no local same-PV exists, otherwise `nextRevisionVersion` of the highest local same-PV revision
- [x] 1.2 Export helper from `Update.EbuildEdit` (alongside `nextRevisionVersion`)

## 2. Apply wiring

- [x] 2.1 Use the helper in `materializeOne` instead of always `nextRevisionVersion targetVer` when `alreadyLocal`
- [x] 2.2 Confirm asset path still uses `renderPVNoRev` / PV without revision

## 3. Tests and gate

- [x] 3.1 Unit test: no local same-PV → bare write version
- [x] 3.2 Unit test: local bare only → `-r1`
- [x] 3.3 Unit test: local `-r1` (or bare + `-r1`) → `-r2`
- [x] 3.4 `hk check` green; mark tasks complete
