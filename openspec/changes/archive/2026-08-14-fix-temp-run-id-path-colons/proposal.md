## Why

`update` run ids use extended ISO 8601 with colons (`2026-08-10T15:42:07-07:00-4242.a8f3`). POSIX `PATH` is colon-separated, so Bun lifecycle scripts that prepend `<clone>/…/node_modules/.bin` cannot see those bins. Live `update opencode` then hard-fails with `node-gyp-build: command not found` (127) even though the isolated binary exists. This started when temp work moved under the colon-bearing run root (`73fc3df`, 2026-08-10).

## What Changes

- Run ids use **ISO 8601 basic** local time with numeric offset (`±HHMM`), then the existing `-<pid>.<hex>` suffix. Example: `20260810T154207-0700-4242.a8f3`.
- The run-id path segment **SHALL NOT contain `:`** (POSIX `PATH` separator). No escape exists; do not keep extended `:` in the directory name.
- `temp-workspace` spec example and `formatRunId` match the basic form. Tests that hardcode the old example update.
- README shows one basic run-id example so retain paths match what operators see.
- Existing retained units with colons are left as-is. Nothing parses the run id.

## Non-goals

- Escaping `:` in `PATH` (not possible on POSIX)
- Changing Bun, ebuilds, `--ignore-scripts`, or install-script retries
- A second “pretty” timestamp formatter for logs (retain messages print the real path)
- Migrating or deleting old colon-named residual trees
- Validating operator `TMPDIR` for colons (out of scope; we only own the run-id segment)
- Windows `PATH` (`;`) or other host-specific filename bans

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `temp-workspace`: Run-id requirement becomes ISO 8601 **basic** (no `:` in the path segment), with an explicit colon ban and updated example
- `project-docs`: README documents a PATH-safe basic run-id example (not the extended colon form)

## Impact

- **Code**: `Update.TempWorkspace.formatRunId` (`%Y%m%dT%H%M%S%z` instead of `%Y-%m-%dT%H:%M:%S%Ez`); comment/example; `test/Test/TempWorkspace.hs` hardcoded run-id strings
- **Specs**: `temp-workspace` run-root identity; `project-docs` README bullet if it pins a run-id example
- **Operator**: New retain paths look like `…/mndz/overlay-manager/20260810T154207-0700-<pid>.<hex>/…`. Old colon trees remain until manual `rm`
- **Non-impact**: Unit layout, lifecycle, disk-space math, Bun install flags, host bun version
