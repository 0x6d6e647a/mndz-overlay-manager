## Why

A top-level `help` subcommand (and the planned pattern of per-command `help` subcommands) collides with free-form positionals such as `update PACKAGE...`, where `help` is a legitimate package token. The CLI should use the unambiguous `--help` / `-h` flag pattern only, with brief top-level help and richer per-command help.

## What Changes

- **BREAKING**: Remove the top-level `help` subcommand. Invoking `help` becomes a parse/unknown-command failure.
- Keep top-level `--help` / `-h` as the success path for full program help (global options + brief command list), exit `0`.
- Bare invocation (no command) SHALL print the same top-level help text as `--help` but exit with status `1` (missing command is an error).
- Ensure each real command (`list`, `outdated`, `update`) has command-scoped `--help` / `-h` with usage for that command, main args, a brief behaviour summary, and a footer noting that global options go before the subcommand.
- Drop custom `showHelp` / `Command.Help` parity machinery once the dual API is gone.
- Use the canonical program name `mndz-overlay-manager` consistently in help strings and active specs (replace leftover `mndz-overlay-mgr` in parser header/progDesc).
- Clean “non-help” / “`help` or `--help`” wording in specs to describe help-flag and bare-help-render paths only.

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `cli-help`: Remove help-subcommand parity; define flag-only help, bare-invocation behaviour (full help text, exit 1), per-command detailed `--help`, command enumeration without `help`, and consistent program naming.
- `overlay-path-resolution`: Help-related scenarios and “non-help invocation” language refer to `--help` / `-h` / bare / `COMMAND --help` only (no `help` subcommand); help paths still skip config load and overlay validation.

## Impact

- **Code**: `src/CLI/Parser.hs` (remove `help` command, enrich per-command `info`/`footer`, name strings, bare-help + exit 1); `app/Main.hs` (drop `Help` dispatch / `showHelp` import).
- **Specs**: `openspec/specs/cli-help/`, `openspec/specs/overlay-path-resolution/` (via this change’s deltas).
- **Docs**: `MNDZ.md` backlog item; optional README mention if it still documents `help`.
- **Users**: Anyone relying on `mndz-overlay-manager help` must switch to `--help`.
- **Dependencies**: Still `optparse-applicative`; no new packages.
