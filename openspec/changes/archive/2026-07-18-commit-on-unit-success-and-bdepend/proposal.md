## Why

Multi-PV Go apply materializes planned versions sequentially but defers all overlay commits until a package-wide barrier. After the first PV runs `ebuild … manifest`, the shared package `Manifest` is dirty, so the next PV hard-fails with “involved paths are dirty” even on a clean start—blocking tree-lane updates such as `dev-util/crush`. Separately, content-fix and soft-skip treat Go `BDEPEND` as “any `dev-lang/go` present,” so missing or wrong atoms relative to upstream `go.mod` are not reliably planned or applied.

## What Changes

- **Commit-on-unit-success (C-everywhere):** After each successful apply unit mutates the overlay and verifies integrity, create the signed overlay commit immediately. Units are: one `GitMvAndManifest` package apply; one `GoVendorAndAssets` planned PV materialization; and a Go exact-set prune when extras remain after all planned PVs succeed.
- **Retire the deferred overlay commit barrier:** `ApplySuccess` means the unit is already committed (in HEAD), not “paths pending a later phase.”
- **Overlay git lock:** Serialize overlay `git add` / `git commit` under mutual exclusion so concurrent packages can still run apply work in parallel without corrupting the shared overlay index.
- **Dirty checks stay per unit:** Foreign uncommitted dirt still hard-fails before mutation; dirt from a prior unit no longer blocks the next unit because that prior unit is committed.
- **Partial multi-PV success retained:** Earlier PVs may commit successfully while a later PV hard-fails; exact-set prune runs only when the package storm has zero hard-fails.
- **Full Go BDEPEND vs `go.mod`:** Content-fix and soft-skip require `>=dev-lang/go-<ver>:=` matching that PV’s `go.mod` `go` directive (missing or mismatch). Use the existing go.mod probe cache (same data as tree-lane planning) rather than presence-only checks.
- **Not in scope:** `update --force` / dirty override (F3); changing assets publish semantics; `GOTOOLCHAIN` policy.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `update-apply`: Replace barrier deferred overlay commits with commit-on-unit-success for all techniques; require overlay git lock during concurrent apply; redefine success as committed; document multi-PV sequential commits and prune-as-unit; keep partial PV success and dirty-before-mutate semantics.
- `go-vendor-assets`: Strengthen BDEPEND needs-work and soft-skip rules to match `go.mod` (not mere presence of `dev-lang/go`); ensure reuse/full paths still apply matching BDEPEND; clarify that overlay commit for a PV follows successful overlay mutation immediately under the apply model.
- `update-command`: Align hard-fail / success reporting with commit-on-unit-success (no separate post-apply commit phase for pending paths); multi-PV partial success and exit status unchanged in spirit.
- `outdated-command`: Content-fix / gap reporting for Go packages must treat BDEPEND mismatch vs probed `go.mod` as needs-work (parity with apply soft-skip).

## Impact

- **Code:** `Update.Apply` (`applyOverlay`, `materializePlan` / `materializeOne`, `overlayAfterAssets`, `gitMvDo`, `commitSuccesses` lifecycle, prune path); `ApplyEnv` (overlay lock); `Update.Types` (`ApplySuccess` meaning); `Update.EbuildEdit` / content-fix (`ebuildNeedsContentFix` / go.mod-aware match); `Update.Check` / plan soft-skip parity; `app/Main.hs` wiring; unit tests with mocked git commit timing and BDEPEND detection.
- **Operator:** Overlay signed commits (and pinentry when cold) may interleave with apply work, similar to assets-repo commits today; multi-PV Go packages no longer self-block on `Manifest`; retries after a successful PV need not restore self-dirt from that PV.
- **Specs:** Delta requirements under the four modified capabilities above; archive of deferred-barrier language.
- **Out of scope:** F3 dirty force; new CLI flags; assets release reuse redesign.
