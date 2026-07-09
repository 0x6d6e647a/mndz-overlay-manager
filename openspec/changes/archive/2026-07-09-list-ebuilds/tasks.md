## 1. Config loading

- [x] 1.1 Complete `Config.Loader` to decode TOML and require `mndz-overlay-path`
- [x] 1.2 Map missing file / decode / missing-key failures to `ConfigError` with actionable messages
- [x] 1.3 Keep XDG default path and `--config` override behavior

## 2. CLI surface

- [x] 2.1 Add top-level `--overlay-path` option to `Options` / parser
- [x] 2.2 Add `List` constructor to `Command` and `list` subcommand in `hsubparser`
- [x] 2.3 Export any new fields needed by `Main`

## 3. Overlay types and discovery

- [x] 3.1 Add `Overlay.Types` with `Ebuild` and pure `ebuildAtom`
- [x] 3.2 Add `Overlay.Discovery` with `collectEbuilds` and discovery errors
- [x] 3.3 Implement structural category heuristic and package/version filename parse (fail on mismatch or unparseable names)
- [x] 3.4 Expose new modules in the cabal library `exposed-modules`

## 4. Main orchestration

- [x] 4.1 For non-help commands: load config, apply `--overlay-path` override, run `validateOverlay`
- [x] 4.2 Dispatch `list`: `collectEbuilds` → empty inventory error → print atoms to stdout
- [x] 4.3 Ensure `help` still skips config load and validation

## 5. Tests and fixtures

- [x] 5.1 Extend fixtures with populated overlay (categories + ebuilds), empty valid overlay, and bad ebuild names
- [x] 5.2 Unit tests for `ebuildAtom`, discovery happy path, skip non-categories, fail on bad names / package mismatch
- [x] 5.3 Integration-style coverage for config load failure, path override, empty inventory error, and successful `list` output

## 6. Verification

- [x] 6.1 Build and run test suite successfully
- [x] 6.2 Manually smoke-test `list`, `--overlay-path`, and `help` against fixtures
