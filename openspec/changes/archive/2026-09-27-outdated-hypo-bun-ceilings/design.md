# Design

## Context

See proposal.md for why. Spec deltas under `specs/` are the behavior contract.

`outdated` deps checks build on-disk lane lines in `reportFromDepsPlan`, then `applyOverlayBlockIndication` compares on-disk and hypothetical bun ceilings. Equal ceilings return the on-disk report and skip the second upstream walk. Differing ceilings that change the plan call `annotateBlockedOn`, which either stamps `blocked on <provider>` onto the on-disk lines or synthesizes one highest-PV line. The check does not know the `outdated` selection. `UpdateReport` is one status, and `OutdatedLine` is always `FROM -> TO`.

Apply already deletes non-live PVs absent from the plan except those `keepPVsForProvider` retains for on-disk reverse deps (`Maybe AtomClosureSession` = `Nothing` reads on-disk PVs). `outdated` does not call that keep helper. `pruneExtras` performs the deletion; this change only needs the same PV decision.

`runOutdated` passes the resolved selection as the ebuild list to `checkOverlayWithDepsPlan`. That list's package keys are the check set. An untargeted run includes bun-bin when the overlay contains it.

## Goals / Non-Goals

**Goals:**

- Render the plan `outdated-command` selects with the existing lane-gap builder, then removal lines, then at most one refuse line.
- Decide "provider in the check set" from the keys of that `outdated` invocation.
- Reuse `overlayRefuseMessage` and `keepPVsForProvider` rather than a second copy of either rule.

**Non-Goals:**

- A new ceiling construction, a stored hypothetical plan, or a change to `update` mutate, success lines, or exit status.
- Passing an `AtomClosureSession` of other packages' planned PVs into the `outdated` keep read.

## Decisions

### 1. Thread the check set into the deps check

`checkOverlayWithDepsPlan` already has every selected entry. Pass that key set into `checkPackageDeps` and `applyOverlayBlockIndication`. Direct test calls that check only ralph-tui pass a set that does not contain bun-bin, which is the left-out case. Do not infer the set by scanning the overlay for a bun-bin directory.

**Alternative:** Treat bun-bin as selected whenever its ebuilds were loaded for ceiling discovery. That marks bun-bin selected for `outdated ralph-tui`, and the refuse line would disappear. Rejected.

### 2. Replace `annotateBlockedOn` with a display plan

After a successful provider latest fetch:

- Ceilings equal: return the on-disk report. No second list or probe.
- Provider is in the set and its remote latest is not strictly greater than the newest non-live on-disk PV: return the on-disk report. Do not build a hypothetical plan. An older remote must not replace the preview when bun-bin itself is being checked.
- Otherwise build the hypothetical plan, as the refuse path does now.
- Plan-delta does not hold: return the on-disk report.
- Plan-delta holds and the provider is in the set and GitMv-outdated: stdout is the hypothetical plan's lane gaps plus its removal lines. No refuse line. No on-disk gaps.
- Plan-delta holds and the provider is not in the set: those same hypothetical lines, then one note line. The note text is `overlayRefuseMessage`. The formatter prefixes `category/package: `.

Lane gaps for a plan come from the same assessment `reportFromDepsPlan` already uses (`buildGapLines`, content-fix, `[assets reusable]`). Call that helper on the hypothetical plan directly. Do not call `reportFromDepsPlan` on it; that would re-enter plan-delta. A hypothetical plan or content-assessment failure fail-closes the consumer and names the provider, and does not fall back to on-disk lines.

`blocked on` goes away with `annotateBlockedOn` and `blockedOnLabel` if nothing else references them.

**Alternative:** Keep a single synthetic highest-PV line and delete the words "blocked on". That drops per-lane targets. Rejected by the spec.

### 3. Line kinds, not fake versions

Extend the outdated line type to a sum: lane gap (the fields `OutdatedLine` has now), removal (`PV -> removed`, revision stripped, no lane label, no assets marker), and a trailing note (the refuse message without the package prefix). One package's list is gaps, then removals in ascending PV order, then at most one note. `formatOutdatedLine` branches on the kind. GitMv latest lines stay unlabeled gaps.

Removal candidates are `extrasToDelete` of the **displayed** plan. If that list is empty, skip the keep read. Otherwise, under the existing overlay tree lock, call `keepPVsForProvider Nothing` and drop candidates the keep set still contains (`samePV`). Several revisions of one PV are one line.

A keep failure emits the same class of per-package report as `FetchError` (stderr, package name, no guessed `-> removed` line). When the package still has lane gaps or a refuse note, those stdout lines are still emitted and the keep failure is an additional stderr report. `UpdateReport` gains an optional warning so one status is not forced to choose between lines and the error. When there is nothing left to print, the status is the error alone.

**Alternative:** Encode `removed` as `olTo` or put the refuse sentence in `olLabel`. Both break the `FROM -> TO` readers and the assets marker. Rejected.

### 4. Cache and exit status stay put

`storeDeps` continues to store the on-disk plan only. The hypothetical plan is computed after that store, on a cache hit as well as a miss, and is not written back. A refuse note is an `Outdated` report, so the existing successful-check exit stays `0`.

## Risks / Trade-offs

- [Stdout lines no longer all contain `->`, and `blocked on` disappears from the joint check] → README documents the three line kinds. The refuse line is the sentence `update` already logs.
- [`keepPVsForProvider` walks consumer ebuilds for every deps package that has extras] → Skip the read when `extrasToDelete` is empty. The read takes the overlay tree lock and does not write.
- [A same-run `update` can drop a pin and delete a PV this preview kept] → Accepted. The keep read is on-disk only, matching `update PACKAGE`.
- [Sum-type lines touch every outdated-line test] → Gap lines keep the current fields; only removal and note constructors are new. Update the bun blocked-on tests to the new sentences instead of loosening them.
- [bun-bin ahead of upstream, left out of the check, still plan-delta refuses] → That matches `update` refuse. The "not strictly greater → on-disk" short path applies only when bun-bin is in the check set.

## Migration Plan

No data migration and no config change. The stdout break ships with the commit. Rollback is reverting that commit.

## Open Questions

None.
