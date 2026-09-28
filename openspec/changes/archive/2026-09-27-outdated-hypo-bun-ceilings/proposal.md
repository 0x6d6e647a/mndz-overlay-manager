# Proposal

## Why

When bun-bin is behind upstream and a newer bun would change a Bun consumer's plan, untargeted `update` applies that newer plan after bun-bin's signed commit. `outdated` of the same selection still describes the on-disk plan and marks the consumer blocked on `dev-lang/bun-bin`, which reads as a refusal of work `update` will do. The same check also stays silent when the only overlay change would be deleting an ebuild the plan no longer selects.

## What Changes

- **BREAKING** stdout: when bun-bin is in the `outdated` selection and GitMv-outdated, and plan-delta holds, print the consumer's gap lines from the hypothetical working plan `update` would apply. Do not mark those lines blocked on bun-bin. bun-bin keeps its own unlabeled `LOCAL -> REMOTE` line. When that working plan needs no version bump and would delete nothing, the consumer prints nothing.
- **BREAKING** stdout: when bun-bin is not in the selection and plan-delta holds, print that same hypothetical plan's gap lines, then one refuse line using the existing unselected-provider refuse sentence, prefixed `category/package: `. Do not use the words "blocked on". `outdated` still exits `0`. `update` of that selection still exits `1`.
- **BREAKING** stdout for every `DepsAndAssets` package: after version gap lines, print one `PV -> removed` line per non-live version `update` of that package would delete from the tree as it sits (lane leftovers minus versions another on-disk ebuild still requires). No lane label and no assets marker. A keep-set read or parse failure fails that package check and does not guess a removal.
- Equal ceilings still skip the second upstream list/probe and do not print a refuse line. Provider latest-fetch failure stays fail-closed. Hypothetical plans stay out of the check cache.

## Non-goals

- Changing `update` apply, success stdout, the refuse sentence text, commit order, ensure, or disk re-planning after bun-bin's commit.
- Printing the refuse line when bun-bin is in the selection.
- Exit status `1` for an `outdated` refuse preview.
- Previewing a deletion that happens only because another selected package drops its pin in the same run.
- A second wait-edge for opencode's compile pin, or removal lines for `GitMvAndManifest` packages (bun-bin's own line stays the unlabeled latest line).
- Rewriting the stale `runtime-lanes` "ceilings rediscovered after provider commit" requirement, or changing code to match it.
- Mutating the overlay or starting ensure from `outdated`.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `outdated-command`: Selected-provider preview uses the hypothetical working plan; unselected plan-delta prints that plan plus one refuse line; every `DepsAndAssets` check gains removal lines for versions apply would delete.
- `overlay-apply-waves`: `outdated` is required to print the hypothetical working plan when the provider is in the check set and GitMv-outdated and plan-delta holds, instead of being excused from printing hypothetical ceilings.
- `project-docs`: README stops describing every such consumer line as blocked on the on-disk ceiling, and documents the selected preview, the left-out refuse line, and removal lines.

## Impact

- **Code:** `outdated` deps reporting (`Update.Check`), stdout formatting (`app/Main.hs`), and a read-only reverse-dep keep check shared with apply. No `update` mutate path change.
- **Tests:** Selected bun-bin behind prints hypo gap lines and no refuse sentence; left-out bun-bin prints hypo lines plus one `package: ` refuse line and exits `0`; equal ceilings still skip the second probe; provider latest failure stays fail-closed; removal lines follow disk keep, including a keep failure that does not guess; `outdated` does not commit or start Docker.
- **Docs:** `README.md` at operator depth. No CONTRIBUTING or AGENTS change.
- **Operator:** Untargeted `outdated` matches the versions untargeted `update` will apply. `outdated ralph-tui` while bun-bin is left out names the refuse instead of an on-disk gap.
