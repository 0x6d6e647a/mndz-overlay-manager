# Tasks

## 1. Outdated line kinds

- [x] 1.1 Replace `OutdatedLine` with a sum of lane gap, removal, and trailing note, and teach `formatOutdatedLine` the three shapes (`FROM -> TO` with optional lane label and assets marker, `PV -> removed` with no lane label or assets marker, and `category/package: ` plus the note). Give `UpdateReport` an optional warning so a keep failure can be logged without dropping stdout lines. Verify a formatter test covers all three shapes and that existing GitMv latest lines still format as unlabeled `LOCAL -> REMOTE`.

## 2. Removal lines

- [x] 2.1 When building a deps `outdated` report, append removal lines for `extrasToDelete` of the displayed plan after the lane gaps, skipping the keep read when that list is empty. Under the overlay tree lock, drop PVs `keepPVsForProvider` with no atom-closure session still retains. Collapse revisions of one PV, strip the revision, and sort ascending. On keep failure, emit the package error and no `-> removed` line, and still emit lane gaps when the report has them. Verify tests for a prune-only package (`PV -> removed`, package not omitted), a PV another on-disk ebuild still requires (no removal line), a keep failure (error, no guessed removal), and `dev-lang/bun-bin` with a compile-pin ebuild still present (no `-> removed` line).

## 3. Hypothetical preview and refuse line

- [x] 3.1 Pass the `outdated` selection's package keys into the deps check. In `applyOverlayBlockIndication`, keep the equal-ceiling return with no second upstream list or probe. When the provider is in the set and its remote latest is not strictly greater than the newest non-live on-disk PV, keep the on-disk report and do not build a hypothetical plan. When plan-delta holds and the provider is in the set and GitMv-outdated, replace the report with the hypothetical plan's lane gaps (same gap builder as the on-disk plan, including `[assets reusable]`) plus that plan's removal lines, and do not add a refuse note. When plan-delta holds and the provider is not in the set, use those hypothetical lines and append one note whose text is `overlayRefuseMessage`. A hypothetical plan or content-assessment failure fail-closes and names the provider. Do not store the hypothetical plan. Remove `annotateBlockedOn` and `blockedOnLabel` if they have no remaining callers. Verify: selected bun-bin plus ralph prints per-lane hypothetical gaps and no `blocked on` or `category/package:` refuse line; two hypothetical lanes stay two lines; a satisfied hypothetical plan with nothing to delete prints no ralph line while bun-bin keeps its unlabeled latest line; left-out bun-bin prints the hypothetical gaps plus exactly one `dev-util/ralph-tui:` refuse line and the report status stays outdated (successful-check exit, not a package error); left-out plan-delta with no gaps and no removals prints only that refuse line; provider not GitMv-outdated keeps on-disk lines; equal ceilings still do not re-list or re-probe; provider latest failure names bun-bin and does not omit the consumer; these tests use the fake deps ops and do not construct an apply, commit, or docker runner.

## 4. README

- [x] 4.1 Update the `outdated` section of `README.md` so it documents the hypothetical-plan preview when bun-bin is included and GitMv-outdated, the single refuse line when bun-bin is left out, successful exit for that report, silence when the hypothetical plan has no gap and nothing to delete, and `PV -> removed` lines including the on-disk pin exception. Verify each of those claims appears in `README.md` and the `update` section still describes same-run bun-bin-then-consumer order and refuse-when-bun-bin-is-omitted.

## 5. Gate

- [x] 5.1 Run `openspec validate --change outdated-hypo-bun-ceilings --strict` and `hk check`, and verify both succeed.
