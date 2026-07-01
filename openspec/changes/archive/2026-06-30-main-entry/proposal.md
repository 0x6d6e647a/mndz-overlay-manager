## Why

The project is a fresh `cabal init` skeleton with a placeholder `Main.hs` that prints "Hello, Haskell!". The goal is to build a Gentoo overlay manager tool invoked as `mndz-overlay-mgr <tool>`. Before any tools can be implemented, the program must load and validate a TOML configuration file from `~/.config/mndz/overlay-manager.toml` (respecting `XDG_CONFIG_HOME`), providing a validated overlay path to all future tools.

## What Changes

- Add CLI entrypoint using `optparse-applicative` with subcommand support, global options (`--config`, `-v`/`--verbose`, `--log-level`), and rich `--help`.
- Initialize a rich `co-log` logger (timestamps, colored levels, stderr) at program startup before any parsing or config loading.
- Add TOML config loading via `toml-parser` with schema-driven decoding.
- Implement mandatory validation of the overlay path (existence, required Gentoo layout directories, `repo_name` content).
- Hard-error (error-level log + exit 1) on missing/invalid config or overlay.
- `--help` / `help` at top level shows only main program help and never requires a valid config.
- Tool-specific help will be `<tool> help` (future).
- `--config <FILE.toml>` allows overriding the default config location.

## Capabilities

### New Capabilities

- `cli-entry`: Main CLI parsing, subcommand dispatch, global options, and help behavior.
- `config-loading`: TOML file loading, schema decoding, and overlay validation logic.
- `logging-bootstrap`: Early rich logger initialization independent of config.

### Modified Capabilities

(none — this is a new project with no existing specs)

## Impact

- New dependencies: `optparse-applicative`, `toml-parser`, `co-log` (plus transitive: `ansi-terminal`, `text`, etc.).
- `app/Main.hs` and `src/MyLib.hs` will be replaced with real implementation.
- `mndz-overlay-manager.cabal` will gain the new library dependencies.
- Future tools will receive a validated `OverlayConfig` record.
- Testing strategy includes golden-file overlay fixtures, property-based directory generation, unit tests for decode/validation errors, and integration tests for the binary.
