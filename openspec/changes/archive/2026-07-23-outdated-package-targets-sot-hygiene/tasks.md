## 1. CLI: outdated package targets

- [x] 1.1 Change `Command` so `Outdated` carries `[String]` package tokens (same shape as `Update` / `Gencache` packages)
- [x] 1.2 Add `outdated` argument parser for optional `PACKAGE...` (`category/package` or unambiguous package name); update help/footer text to match `update` selection wording
- [x] 1.3 In `runOutdated`, call `resolveTargets` on inventory + tokens; hard-fail (log + exit 1) on unknown/ambiguous; filter entries to selected keys before checks
- [x] 1.4 Ensure multi-progress package totals and deferred stdout/warnings cover only the selected set
- [x] 1.5 Add/adjust tests for zero-arg full inventory, `cat/pn`, bare `pn`, ambiguous, and unknown targets

## 2. Operator docs and help

- [x] 2.1 Update `README.md` outdated section: package targets, empty = all, at least one filtered example
- [x] 2.2 Confirm `outdated --help` documents `PACKAGE...` and zero-arg behavior (parser footer / scenarios)

## 3. Living SoT: apply delta requirements

- [x] 3.1 Merge delta into living `openspec/specs/outdated-command/spec.md` (package targets; set Purpose to a real one-line description)
- [x] 3.2 Merge delta into living `update-command` (automatic version selection; DepsAndAssets soft-skip includes Cargo; scrub residual `GoVendorAndAssets` / “in this change” in remaining requirements)
- [x] 3.3 Merge delta into living `update-apply` (renames + Cargo first-class + exact-set + dirty paths; refresh Purpose; drop “at the time of this change” / “as today”)
- [x] 3.4 Merge delta into living `go-tree-lanes` (multi-arch labels; refresh Purpose away from `GoVendorAndAssets`)
- [x] 3.5 Merge delta into living `go-vendor-assets` (renames + scrub; drop “future non-Go”; prefer “unset” over `Nothing` in modified requirements)
- [x] 3.6 Merge delta into living `cli-activity` (behavior-only presentation + teardown; DepsAndAssets Go progress wording)
- [x] 3.7 Merge delta into living `cli-help` and `project-docs`
- [x] 3.8 Merge delta purpose ADDED into living `ebuild-version` and `update-source` (Purpose sections + any ADDED requirements)
- [x] 3.9 Repo-wide scrub under `openspec/specs/`: no remaining `GoVendorAndAssets`; no “in this change” / “at the time of this change” where residual; `rg` clean for those strings

## 4. OpenSpec config

- [x] 4.1 Fill `openspec/config.yaml` with project context (Haskell/Gentoo overlay manager, DepsAndAssets vocabulary, package-target model, quality gates pointer)
- [x] 4.2 Add artifact rules: Purpose required (no TBD); proposal/design non-goals; SoT must not say “in this change”; prefer behavior over library/MVar names in requirements; use `DepsAndAssets` not `GoVendorAndAssets`

## 5. Quality gate

- [x] 5.1 `openspec validate outdated-package-targets-sot-hygiene` (and `--specs` if needed) green
- [x] 5.2 `hk check` green (format, build, tests, lint, stan, weeder as applicable)
