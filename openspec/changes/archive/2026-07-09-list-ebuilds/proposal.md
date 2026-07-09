## Why

The first real overlay-management tool is a `list` command that prints ebuilds. Beyond that thin CLI, the project needs reusable library logic to discover and represent ebuilds so future commands can operate on the same inventory instead of re-walking the tree.

## What Changes

- Add a `list` subcommand that prints one Gentoo package atom per line (`category/package-version`) for every ebuild in the overlay.
- Complete TOML config loading so non-help invocations always load configuration and resolve the overlay path.
- Add a top-level `--overlay-path` flag that overrides the config's overlay path after config is loaded.
- Gate all non-help commands on existing overlay validation (`validateOverlay`).
- Introduce library types and discovery (`Ebuild`, `ebuildAtom`, `collectEbuilds`) used by `list` and intended for reuse by future tools.
- Fail fast on invalid overlay layout, unparseable ebuild filenames, or an empty ebuild inventory.

## Capabilities

### New Capabilities

- `list-command`: CLI `list` subcommand behavior, output format, and empty-inventory error handling.
- `ebuild-discovery`: Library inventory of ebuilds (types, atom formatting, tree walk, category heuristic, fail-fast parse errors).
- `overlay-path-resolution`: Always load config for non-help commands; resolve overlay path with CLI `--overlay-path` override after load; then validate.

### Modified Capabilities

- (none — existing `cli-help` requirements are unchanged; help still skips config/validation)

## Impact

- `CLI.Parser`: add `List` command and top-level `--overlay-path`.
- `Config.Loader` / `Config.Types`: finish real TOML decode of `mndz-overlay-path`.
- New modules: `Overlay.Types`, `Overlay.Discovery`.
- `Overlay.Validation`: used as gate for non-help commands (no API change required).
- `app/Main.hs`: load → override → validate → dispatch `list`.
- Test fixtures: sample ebuild trees for happy path, empty inventory, and bad filenames.
- Dependencies: may need fuller use of existing `toml-parser`, `directory`, `filepath`, `text` (no new packages expected).
