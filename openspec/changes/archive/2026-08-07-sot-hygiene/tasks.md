## 1. Validate change deltas

- [x] 1.1 Run `openspec validate --change sot-hygiene` (or project equivalent) and fix any delta format issues
- [x] 1.2 Confirm every capability listed in `proposal.md` has a corresponding `specs/<name>/spec.md` delta

## 2. Residue scrub (living SoT)

- [x] 2.1 Apply `overlay-test-use` delta to `openspec/specs/overlay-test-use/spec.md` (no “this change” / “after this change”)
- [x] 2.2 Apply `ssh-agent-session` delta (SSH remote rule without “as part of this change”)
- [x] 2.3 Apply `update-command` rename/MODIFIED (package-apply multi-progress)
- [x] 2.4 Apply `cli-activity` multi-progress wording (package-apply, not “phase 1”)

## 3. Policy single-home

- [x] 3.1 Apply `update-apply` delta: expanded canonical policy list; remove duplicate autolith-only requirement; “program SHALL” on policy model
- [x] 3.2 Apply `deps-assets` delta: drop authoritative partial package list; point to `update-apply`; keep technique/naming/spine
- [x] 3.3 Apply `go-vendor-assets` delta: remove hardcoded Go package list requirement; keep Go materialize edges
- [x] 3.4 Diff canonical policy list against `src/Update/Hardcoded.hs` (badger, opencode, usage `cli`, autolith, all GitMv packages)

## 4. Domain thinning and language

- [x] 4.1 Apply `go-tree-lanes` delta: remove exact-set requirement; program-subject ceilings/`go.mod` text; KEYWORDS points at `runtime-lanes`
- [x] 4.2 Apply `ebuild-version` delta: program/observable PV parse/render/compare (no library/`comparePV` pins)

## 5. test-coverage collapse

- [x] 5.1 Apply `test-coverage` delta: rename floors requirement; MODIFIED excludes; ADDED consolidated surface requirement; REMOVED all wave/residual/per-wave floor requirements
- [x] 5.2 Spot-check living `test-coverage` is under ~120 lines and has no Wave-N / “residual” / “leftover” requirement titles

## 6. Living SoT gates

- [x] 6.1 `openspec validate --specs` (or `--all`) green after living merges
- [x] 6.2 `rg` living `openspec/specs` for banned residue: `this change`, `as part of this change`, `Wave-`, `GoVendorAndAssets`, `at the time of this change`, `as today` — clean or justified exceptions only
- [x] 6.3 Confirm no second authoritative package list remains in `deps-assets` / `go-vendor-assets`
- [x] 6.4 No product code changes required; skip full `hk check` unless accidental code edits — if code touched, run full gate

## 7. Close out

- [x] 7.1 Mark tasks complete only when validate + residue greps are green
- [x] 7.2 Ready to archive with `openspec archive` workflow when implementation is done
