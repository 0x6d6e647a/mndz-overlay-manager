## Why

`update` plans every selected package once against overlay disk at start of run, then applies them concurrently with no overlay-internal order. Overlay `dev-lang/bun-bin` is the runtime-lane ceiling source for `DepsAndAssets Bun` packages (`ralph-tui`, `opencode`). A same-run bun-bin bump therefore cannot raise those ceilings: dependents are skipped as “already matches” or applied under the old cap, and `--jobs` may race bun-bin with ralph. The operator-facing win is one `update` that lands a newer bun-bin **and** a ralph PV that needed that Bun, in that order.

## What Changes

- Introduce **overlay wait-edges** from update technique: `DepsAndAssets Bun` waits on overlay `dev-lang/bun-bin`. Not a per-package map and not ebuild `BDEPEND` scan.
- **Admit-when-ready** apply: packages with no unmet overlay predecessor start under `--jobs` together; a Bun consumer is withheld while bun-bin is in this run and needs work; after bun-bin’s **signed overlay commit**, rediscover overlay bun-bin ceilings, re-plan the consumer (check-cache must not replay the t0 plan), then admit it to the same job pool. Independents (mise, beads, …) overlap the provider; they do not block consumers.
- If the overlay ceiling provider is **not** selected and is itself outdated, **refuse** the consumer when a hypothetical plan under provider-at-remote-latest would differ (**plan-delta**). Hard-fail the consumer, name the provider, recovery `update bun-bin` or untargeted `update`. Other selected packages continue. If that provider latest-fetch **fails**, **fail-closed**: hard-fail the consumer (do not apply the on-disk-ceiling plan). Do **not** auto-expand selection to pull bun-bin in.
- Provider **hard-fail**: do not rediscover from dirty disk; dependents hard-fail naming the provider. Do not apply the t0 dependent plan.
- After admit, re-classify reuse vs full, re-run conditional preflight and the disk-space gate for **new** units; missing docker/token fails dependents, does not roll back a committed provider.
- `outdated`: one existing-style lane line for the consumer **indicates** blocked-on the overlay provider when plan-delta holds (still emit the provider’s own GitMv line when that package is in the check set).
- Check-cache **deps** fingerprint includes the existing package fingerprint of the overlay ceiling-provider tree (non-live ebuilds + Manifest). Missing field is a miss. Gentoo runtimes stay out of this fingerprint.
- One `update` multi-progress panel: consumers appear when admitted; a withheld row may show waiting on the provider. Overlay signed commits stay sequential under the existing critical section.

## Non-goals

- Docker / materialize-image lifecycle, Dockerfile generation, prune, XDG image sidecar, `MNDZ_MATERIALIZE_IMAGE` (design MAY record a one-line hook that `update` MAY re-ensure the materialize image after an overlay runtime mutates; that step does not exist yet).
- Parsing ebuild `DEPEND`/`RDEPEND`/`BDEPEND` or a Portage-quality solver (deferred: wiki `waves-scan-followup.md`).
- A second per-package edge map; auto-pull of an unselected provider; changing GitHub token resolution; host GPG/SSH/Manifest authorship; qemu / `--force-full-assets`; fingerprinting gentoo go/nodejs/rust/sbcl.
- Changing the sequential overlay `egencache`/`git add`/`git commit` rule.

## Capabilities

### New Capabilities

- `overlay-apply-waves`: Technique-implied overlay wait-edges; withhold / admit-when-ready; re-plan after provider signed commit; refuse plan-delta and fail-closed provider-fetch; provider hard-fail fails dependents.

### Modified Capabilities

- `update-command`: Spine is no longer a single plan-then-mutate of the whole selection as one concurrent apply set; classify / conditional preflight / disk gate re-enter when withheld consumers become needs-work after a provider commit.
- `update-apply`: Phase-1 apply no longer starts every needs-work package together; overlay-internal consumers are withheld until the provider unit has a terminal overlay-commit outcome.
- `runtime-lanes`: Overlay bun-bin ceilings MAY be rediscovered mid-`update` after a successful overlay ceiling-provider commit; subsequent Bun plans SHALL use the new disk.
- `check-cache`: Successful `DepsAndAssets` entries whose technique has an overlay ceiling provider SHALL include that provider package’s fingerprint; mismatch or missing field is a miss.
- `outdated-command`: Consumer lane lines SHALL indicate blocked-on overlay provider when plan-delta holds.
- `cli-activity`: One `update` apply panel; withheld packages wait in-row; consumer rows appear (or leave waiting) on admit.
- `cli-concurrency`: `--jobs` bounds **in-flight admitted** package work; not all selected packages need be admitted at plan completion.
- `disk-space-preflight`: Units that appear only after a post-provider re-plan SHALL pass the disk-space gate before those units mutate.
- `project-docs`: README documents same-run overlay runtime order, `outdated` blocked-on, and refuse when a named consumer omits a stale overlay provider.

## Impact

- **Code:** `Update.Spine`, `Update.Apply` / `applyOverlayFromPlan`, `Update.Hardcoded` or a small technique→provider helper, `Update.CheckCache` fingerprint, `Update.Deps.Plan` bun ceiling `MVar` invalidation, `Update.Check` / `outdated` blocked-on, `CLI.Progress` admit/wait, disk/preflight re-entry.
- **Tests:** Pure wait-edge / admit graph; fake-ops spine (provider commit then consumer re-plan; refuse plan-delta; fail-closed fetch; provider hard-fail); check-cache fingerprint miss when bun-bin tree changes; `outdated` indication. No live overlay required for the graph.
- **Docs:** `README.md` `update` / `outdated` operator prose.
- **Operator:** Untargeted `update` can land bun-bin then ralph in one run. `update ralph-tui` while bun-bin is stale and plan-delta holds (or bun-bin latest cannot be fetched) hard-fails ralph instead of silently ceiling-capping.
