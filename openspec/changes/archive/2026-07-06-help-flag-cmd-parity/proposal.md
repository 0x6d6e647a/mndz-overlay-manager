## Why

Running `mndz-overlay-manager --help` prints the usage text, but running `mndz-overlay-manager help` silently exits with no output. The two ways to ask for help should behave identically. Establishing this parity now sets the pattern for every future subcommand.

## What Changes

- The `help` subcommand renders the exact same top-level usage text as the `--help` flag, writing to stdout and exiting `0`.
- `help` takes no arguments; its sole purpose is parity with `--help`.
- Establish "help parity" as a convention: every command surfaces help both as a `--help` flag and a `help` subcommand, producing identical output.

## Capabilities

### New Capabilities
- `cli-help`: How the CLI exposes usage/help text to users, including the requirement that the `--help` flag and the `help` subcommand produce identical output and behavior.

### Modified Capabilities
<!-- None: no existing specs. -->

## Impact

- `src/CLI/Parser.hs`: add an exported help-rendering entry point (`showHelp`).
- `app/Main.hs`: dispatch the `help` command to render help; remove the now-unused silent-exit path.
- No new dependencies (uses existing `optparse-applicative` re-exports).
- No breaking changes; `--help` behavior is unchanged.
