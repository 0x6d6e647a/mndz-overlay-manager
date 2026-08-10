## Why

Heavy `update` work (clones, language caches, tarball staging, reuse downloads) creates many independent directories under the process temp root via always-delete helpers. That scatters forensics, always erases evidence on hard-fail, and gives no project-wide home for future scratch. Operators need one predictable run tree under `$TMPDIR`, immediate reclaim of successful unit work under `--jobs`, and retained failing unit trees with paths in error messages.

## What Changes

- Introduce a **project-wide temp workspace** convention under the effective temp root:
  - `$TMPDIR/mndz/overlay-manager/<local-ISO8601-with-offset>-<pid>.<random>/`
  - Unit trees: `<category>/<package>/<pv>-{full|reuse}/{out,work}`
- **One run root per process** that opens heavy temp work; unit dirs created only when a unit is admitted to heavy work
- **Lifecycle**:
  - Unit **success** or **soft-skip** → delete that unit tree immediately; prune empty package/category parents under the run root
  - Unit **hard-fail** → retain that unit tree; error message **SHALL** include its absolute path
  - **All units succeed** (no hard-fail in the run) → delete the run root; upward-prune empty `overlay-manager/` then empty `mndz/` under the temp root
  - Process crash / SIGKILL → accept residuals (no temp-clean command in this change)
- Replace free-floating `withSystemTempDirectory` product call sites (materialize out/reuse, Go/npm/Bun/Cargo/Sbcl builders) with workspace-allocated `out/` + `work/`
- Free-space gating still measures the **effective temp root filesystem** (`TMPDIR` or process default); messaging MAY name the run root for clarity
- **Not** consolidating manager distfiles (XDG), overlay-path, or assets-path into this tree
- Specs that require “remove temp on success **or** failure” flip to workspace lifecycle
- README (project-docs) documents layout, retention, residuals, and remediation

## Non-goals

- Moving manager distfiles, overlay, or assets worktrees into the temp workspace
- A CLI command to garbage-collect residual temp trees
- Signal handlers that guarantee cleanup on SIGKILL
- Changing disk-space estimation formulas or jobs accounting
- Host tool global caches outside product-owned dirs (e.g. default `GOCACHE`) unless already overridden into `work/`
- Test harness fixtures must use this layout (tests may keep their own temps unless a product API under test requires the workspace)

## Capabilities

### New Capabilities

- `temp-workspace`: Project-wide temporary workspace under the effective temp root — run root naming, unit layout (`category/package/pv-full|reuse` with `out`/`work`), lifecycle (immediate success/soft-skip clean, hard-fail retain + path in error, full-run success upward prune), and the rule that new product scratch follows this convention

### Modified Capabilities

- `go-vendor-assets`: Temp clone lives under the unit `work/` tree; remove always-delete-on-failure requirement in favor of `temp-workspace` lifecycle
- `bun-deps-assets`: Same for clone/cache work under the unit workspace
- `npm-deps-assets`: Materialize scratch under the unit workspace (`out`/`work`) rather than an anonymous system temp dir
- `cargo-crates-assets`: Clone/distdir/stage under the unit workspace
- `sbcl-deps-assets`: Deps materialize scratch under the unit workspace (align with project-wide convention)
- `disk-space-preflight`: Clarify effective temp root remains the free-space measurement root; product writes go under the workspace subtree on that filesystem
- `project-docs`: README documents workspace layout under `TMPDIR`, clean-on-success / retain-on-hard-fail, residual acceptance, and hard-fail path logging

## Impact

- **Code**: New workspace module (or equivalent) for resolve temp root, open run root, allocate unit dirs, cleanup helpers; `ApplyEnv` / update spine ownership of the run root; `Update.Apply.Materialize` and ecosystem builders (`Go.Vendor`, `Npm.Cache`, `Bun.Cache`, `Cargo.Crates`, `Sbcl.Deps`) stop calling `withSystemTempDirectory` for product scratch; hard-fail message enrichment with retained paths; tests for layout, lifecycle, and path-in-error
- **Specs**: New `temp-workspace`; deltas for ecosystem temp language and project-docs / disk-space wording
- **Operator**: Residual trees under `$TMPDIR/mndz/overlay-manager/` after failures or crashes; free space may need manual reclaim; successful runs leave no product temp tree
- **Non-impact**: Manager distfiles XDG path, `eclean`, overlay/assets git worktrees, disk-space estimate math
