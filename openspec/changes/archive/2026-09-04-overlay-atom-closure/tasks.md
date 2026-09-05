## 1. Pure parse and satisfiability

- [x] 1.1 Add an internal module (cabal `other-modules`, not `exposed-modules`) that extracts DEPEND-family assignments, same-file `${RDEPEND}`/`${BDEPEND}`/`${DEPEND}` expand, overlay-dir `category/package` filter, USE over-approx, `||` one overlay-named branch, self-atom ignore, `:=` strip, and PV match via existing `comparePV` for unversioned/`>=`/`<=`/`>`/`<`/`=`/`~`; verify unit tests on fixture ebuilds (hk usage USE-conditional, opencode ripgrep ignored, ralph bun-bin `>=`, autolith gentoo `||` ignored, self-atom ignored)
- [x] 1.2 Fail-closed paths: unparseable DEPEND-family, overlay-internal blocker, explicit non-`0` slot, unknown operator; verify tests expect `Left` with an operator-facing reason and do not treat those ebuilds as having zero overlay-internal atoms
- [x] 1.3 Keep-set helper: planned unique PVs ∪ PVs on disk still required by planned-remaining consumer ebuilds; verify extras-to-delete drops unneeded siblings and retains an exact-pin PV; verify keep does not invent a PV absent from disk

## 2. Overlay-write gate and GitMv rename-away

- [x] 2.1 Before DepsAndAssets overlay rewrite and GitMv rename, evaluate to-be-written ebuild against current provider PVs; if unsatisfied and the provider is selected with planned remaining PVs that would satisfy, wait for that provider’s terminal overlay outcome **outside** `aeOverlayLock`, re-check, then mutate; verify a fake-ops test that usage commit happens before hk overlay mutation when the atom would otherwise be unsatisfied, and that the overlay lock is not held during the wait
- [x] 2.2 If the provider is unselected or planned PVs still would not satisfy, hard-fail the consumer naming provider and atom without overlay mutation and without adding the provider to the selection; verify `update hk` fake-ops refuses and does not apply usage
- [x] 2.3 Already-satisfiable unversioned atoms do not wait; verify hk/mise overlay write may overlap usage when some usage PV already exists
- [x] 2.4 Provider hard-fail while a consumer waits: consumer hard-fails naming the provider, no overlay mutation; verify test
- [x] 2.5 Cycle of atom-closure waits hard-fails the involved packages naming the cycle; verify a fixture two-package cycle
- [x] 2.6 GitMv rename-away guard: hard-fail without rename when dropping Old would unsatisfy a planned-remaining consumer and no sibling (including New) satisfies; verify exact-pin fail and `>=` / unversioned rename success; do not extend `classifyAdmit`

## 3. DepsAndAssets prune and progress

- [x] 3.1 After successful planned-PV apply, prune using keep-set from (1.3) with planned-remaining consumers (selected: post-apply trees; unselected: on-disk); verify exact-pin keeps extra PV, unversioned usage allows pruning the extra, and a selected consumer that will drop the pin does not force keep
- [x] 3.2 Apply progress: when blocked on atom-closure overlay write, waiting presentation names the provider, no second apply panel, wait does not occupy a job slot; verify hk-waiting-on-usage chrome vs mise not waiting when already closed; Graph 1 ralph-waiting-on-bun-bin unchanged

## 4. Docs and quality gate

- [x] 4.1 `README.md` operator `update` prose for atom-closed commits, reverse-dep prune, GitMv rename-away, targeted refuse without auto-pull; does not claim hk/mise ceiling-wait on usage (`project-docs`)
- [x] 4.2 `openspec validate --strict --change overlay-atom-closure` (and affected capabilities) clean
- [x] 4.3 `hk check` green; HIE rebuilt if modules move; no casual weeder/stan weakening; no `exposed-modules` expansion unless the test-suite requires it
