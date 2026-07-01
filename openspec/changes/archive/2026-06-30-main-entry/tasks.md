## 1. Project Setup

- [x] 1.1 Add `optparse-applicative`, `toml-parser`, and `co-log` (plus transitive dependencies) to `mndz-overlay-manager.cabal`
- [x] 1.2 Create module layout under `src/` for `CLI`, `Config`, `Logging`, and `Overlay` concerns
- [x] 1.3 Replace placeholder `app/Main.hs` and `src/MyLib.hs` with real module structure (keep the existing test stub for now)

## 2. Logging Bootstrap

- [x] 2.1 Implement a rich stderr `LogAction` (timestamps + colored levels via `ansi-terminal`) using `co-log`
- [x] 2.2 Wire the logger into `main` as the very first action, defaulting to `warn` level
- [x] 2.3 Expose a `WithLog` environment that can be reconfigured later for higher verbosity or additional sinks

## 3. CLI Parsing

- [x] 3.1 Define the top-level `Parser` using `optparse-applicative` with `hsubparser` for future subcommands
- [x] 3.2 Add global options: `--config <FILE.toml>`, `-v`/`--verbose` (repetition), `--log-level <error|warn|info|debug>`
- [x] 3.3 Implement early short-circuit for top-level `help` / `--help` / `-h` so no config loading occurs
- [x] 3.4 Integrate log-level flags with the bootstrap logger so verbosity takes effect immediately

## 4. Config Loading & Validation

- [x] 4.1 Define a TOML schema record (`OverlayConfig`) with `FromValue`/`ToValue` instances via `GenericTomlTable`
- [x] 4.2 Implement config path resolution (respect `XDG_CONFIG_HOME`, fallback to `~/.config/mndz/overlay-manager.toml`)
- [x] 4.3 Add `--config` override handling that accepts a direct file path
- [x] 4.4 Implement overlay validation: existence, directory check, presence of `profiles/`, `metadata/`, `profiles/repo_name`, `metadata/layout.conf`, and exact `repo_name` content `"mndz"`
- [x] 4.5 Produce precise error-level log messages for every failure case and exit with status 1

## 5. Testing

- [x] 5.1 Create golden-file fixture directories under `test/fixtures/` for valid and invalid overlay layouts
- [x] 5.2 Add property-based tests (Hedgehog/QuickCheck) that generate random directory trees and assert only correct layouts pass validation
- [x] 5.3 Write unit tests for TOML decode failures and validation error messages (exact text + source locations)
- [x] 5.4 Add integration tests that invoke the built binary with missing/invalid config and `--config` overrides and assert exit codes + logged output

## 6. Documentation & Polish

- [x] 6.1 Update `CHANGELOG.md` with the initial release notes for the skeleton
- [x] 6.2 Ensure `cabal build` and `cabal test` succeed with no warnings
- [x] 6.3 Verify that `mndz-overlay-mgr --help` works and that early error paths produce rich log output
