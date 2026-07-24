## Why

A full OpenSpec quality audit found living source-of-truth drift (legacy `GoVendorAndAssets` naming, incomplete Cargo coverage in shared requirements, contradictory multi-arch vs four-lane labels, residual “in this change” language, TBD purposes, empty `config.yaml`) that will keep confusing agents and humans. Separately, `outdated` still checks the entire inventory while `update` and `gencache` already accept package filters (`category/package`, unambiguous package name, or none for all); operators need the same selection model for focused checks. The misleading “no user-specified target version” wording on `update` also conflicts with first-class package targets and must be rewritten to distinguish package selection from automatic PV selection.

## What Changes

- **`outdated` package targets:** Accept zero or more `PACKAGE` arguments in the same form as `update`/`gencache` (`category/package` or unambiguous bare package name; empty means all discovered packages). Resolve via the shared target helper; run checks only for selected packages; keep soft outcomes and exit-zero-on-success-check semantics for the filtered set.
- **CLI help / README:** Document `outdated PACKAGE...` parity with update selection; refresh outdated help footer.
- **`update` selection wording:** Rewrite the “Latest upstream only / no user-specified target version” requirement so package targets remain normative and PV is never a CLI argument (GitMv → latest from source; DepsAndAssets → runtime-lane plan).
- **SoT hygiene (no intentional product behavior change beyond the above):**
  - Scrub residual `GoVendorAndAssets` from living titles, purposes, and scenarios; use `DepsAndAssets` (Go) vocabulary that matches code.
  - Complete Cargo in shared requirements that still say only Go/Npm/Bun (first-class apply, soft-skip, exact-set prune attribution).
  - Fix `go-tree-lanes` four-lane amd64/arm64-only labels to match multi-arch discovery; thin/clarify overlap with `runtime-lanes` where deltas are needed.
  - Remove residual delta language (“in this change”, “at the time of this change”, “as today”, “future non-Go”).
  - Fill Purpose TBD on `ebuild-version`, `outdated-command`, `update-source`; refresh stale purposes (`update-apply`, `go-tree-lanes`, `update-command` as needed).
  - De-implement `cli-activity` where library/MVar details are normative; keep observable hang-free teardown and presentation rules.
  - Populate `openspec/config.yaml` with project context and artifact rules that prevent recurrence.
- **Not in scope:** PV/version pinning on CLI; first-import empty dirs; live/9999; overlay auto-push; splitting archive history.

## Capabilities

### New Capabilities

_(none)_

### Modified Capabilities

- `outdated-command`: Package targets (`PACKAGE...`); purpose; remove “no arguments / in this change”; filter check set; scenarios for empty / cat-pn / bare pn / ambiguous.
- `update-command`: Rewrite PV vs package selection requirement; Cargo soft-skip completeness; residual `GoVendorAndAssets` / “in this change” scrub where those requirements live.
- `update-apply`: Technique vocabulary and first-class `DepsAndAssets` including Cargo; exact-set prune for all deps techniques; residual naming and “at the time of this change” / “as today”.
- `go-tree-lanes`: Purpose; multi-arch lane labels (not exactly four amd64/arm64); align with `runtime-lanes` for shared label rules; residual `GoVendorAndAssets`.
- `go-vendor-assets`: Title/body rename scrub; drop “future non-Go” / technique constructor residue; optional `Nothing` → unset wording where requirements touch it.
- `cli-activity`: Replace layoutz/MVar-normative requirements with behavior-only progress guarantees; residual `GoVendorAndAssets` in progress status requirements.
- `cli-help`: Outdated help documents package targets; any update help wording if selection text is wrong.
- `project-docs`: README `outdated` examples and package-target description.
- `ebuild-version`: Purpose (was TBD).
- `update-source`: Purpose (was TBD).
- `runtime-lanes`: Only if cross-refs or exact-set/label wording need a small alignment with go-tree-lanes (no product change).
- `deps-assets`: Only if shared technique wording still claims Go-only constructors or incomplete ecosystems (minimal).

## Impact

- **Code:** `CLI.Parser` (`Outdated [String]` or equivalent), `app/Main.hs` outdated path filters via `Update.Targets` (or shared resolve), help strings; tests for target resolution on outdated; no change to check algorithms beyond which packages run.
- **Specs:** Multi-domain living SoT deltas listed above; `openspec/config.yaml` project rules.
- **Docs:** README outdated section; possibly CONTRIBUTING only if agent/config rules are referenced there (prefer config.yaml + existing project-docs triggers).
- **Operator:** `outdated crush` / `outdated dev-util/crush` works like update; full inventory when no args.
- **Non-goals:** Version arguments; reimplement progress host; archive rewrites; new ecosystems.
