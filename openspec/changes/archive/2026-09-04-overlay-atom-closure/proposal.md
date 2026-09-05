## Why

`update` can leave overlay git HEAD in a state Portage cannot emerge: a retained consumer ebuild names another overlay package at a version the tree no longer has (DepsAndAssets exact-set prune, or GitMv rename of the only matching provider PV). Technique wait-edges already order Bun consumers after `dev-lang/bun-bin` for **ceiling planning**; they do not close overlay-internal `DEPEND*` atoms (today `hk`/`mise` → `dev-util/usage`, plus bun-bin BDEPEND as Portage truth). Same-run apply of consumer and provider is not ordered by those atoms, so a signed commit can land the consumer first.

## What Changes

- After **every signed overlay commit**, every retained non-live consumer ebuild’s overlay-internal `DEPEND`/`RDEPEND`/`BDEPEND`/`PDEPEND`/`IDEPEND` atoms SHALL be satisfiable by some retained non-live provider ebuild still in the tree (**atom closure**).
- Discover those atoms by scanning ebuild text (to-be-written bytes for the unit being committed, plus remaining overlay package ebuilds), keeping atoms whose `category/package` is an overlay package directory. No second edge table. This parse SHALL NOT create Graph 1 ceiling wait-edges.
- **Forward:** if a consumer’s to-be-written ebuild would be unsatisfied, and the provider is in this `update` selection and its **planned** retained PVs would satisfy, wait for that provider’s signed overlay commit (before taking the overlay critical section), then write the consumer. Otherwise hard-fail the consumer naming the provider and the atom. Do not auto-expand selection. Do not hypo-plan or use plan-delta.
- Consumer **materialize may overlap** the provider; only overlay write/commit waits. Never wait while holding the overlay lock.
- **Backward (B):** DepsAndAssets prune of a provider is runtime-lane unique PVs (**A**) ∪ provider PVs still required by **planned remaining** consumer ebuilds. B does not resurrect missing PVs.
- **GitMv rename-away guard:** hard-fail the GitMv unit if renaming away the old newest PV would unsatisfy a retained consumer and no sibling PV still satisfies.
- Parse subset: PV-only match; USE over-approx (conditionals still required); `||` needs one overlay-named branch; blockers and unparseable atoms fail-closed; ignore self-atoms; no eclass inherit, no subslots, no KEYWORDS visibility.

## Non-goals

- Graph 1 / OverlayWaves: technique wait-edges, hypo ceilings, plan-delta refuse, bun-bin fingerprint, delayed GPG.
- Auto-pull of an unselected provider; resurrecting pruned/renamed-away PVs from upstream or git history.
- `outdated` lines, check-cache fingerprint changes, materialize-image / qlot / node-gyp file-gates (Graph 2).
- Portage-quality solver (`||` beyond one overlay branch, full USE expand, KEYWORDS visibility, slots/subslots).
- A per-package declared edge map; changing GitHub token, host GPG/SSH/Manifest authorship, or sequential overlay `egencache`/`git add`/`git commit`.

## Capabilities

### New Capabilities

- `overlay-atom-closure`: Overlay commits closed under overlay-internal atom satisfiability; scan overlay-dir keys from to-be-written and remaining ebuilds; wait-if-selected-else-refuse at overlay write; DepsAndAssets reverse-dep keep; GitMv rename-away guard; parser subset and fail-closed rules.

### Modified Capabilities

- `overlay-apply-waves`: SHALL NOT parse `DEPEND*` to discover **ceiling wait-edges**; atom-closure parsing is `overlay-atom-closure` and SHALL NOT create Graph 1 edges.
- `update-apply`: DepsAndAssets prune is A ∪ B; GitMv rename-away guard; consumer overlay write gated on atom closure (wait before overlay lock).
- `runtime-lanes`: Exact-set unique PVs remain the lane plan (A). Extra keep of unplanned PVs for reverse-dep B is `overlay-atom-closure` / `update-apply`, not a change to lane selection.
- `update-command`: Targeted `update` of a consumer whose to-be-written atoms are unsatisfied and whose provider is unselected (or whose planned PVs cannot satisfy) hard-fails that consumer; selection is not expanded.
- `cli-activity`: When a consumer blocks before overlay write on atom closure, the package row shows waiting on the provider.
- `project-docs`: README `update` prose: overlay commits stay atom-closed; prune will not drop a provider PV a remaining consumer ebuild still names.

## Impact

- **Code:** Parser/satisfiability helpers (library `other-modules`, not a new public export unless the executable needs it); `Update.Apply` overlay-write gate and wait-before-lock; DepsAndAssets prune extras; GitMv rename-away check; progress waiting chrome. Do not extend `classifyAdmit` / OverlayWaves.
- **Tests:** Fixture ebuilds (no live overlay): parse subset; USE over-approx; overlay-dir filter vs gentoo atoms; wait vs refuse; prune A ∪ B from planned remaining C; GitMv rename-away; cycle and parse fail-closed; self-atom ignored. Quality gate `hk check`.
- **Docs:** `README.md` operator `update` paragraph.
- **Operator:** Untargeted `update` of hk/mise/usage commits usage before an hk/mise overlay write that would otherwise be unsatisfiable. `update hk` while usage cannot satisfy hk’s atoms hard-fails hk naming usage. Unversioned `dev-util/usage` on hk/mise stays satisfied by any remaining usage PV (B keeps nothing extra until the atom is a pin or upper bound).
