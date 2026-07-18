## Context

The executable uses `optparse-applicative`. Top-level `parserInfo` wires `optionsParser <**> helper`, so `--help`/`-h` already render usage. A `help` subcommand maps to `Command.Help` and `showHelp` reuses the library’s `ShowHelpText` path so `help` matches `--help` (from archived `help-flag-cmd-parity`).

`update` already accepts free-form `PACKAGE...` arguments. A positional `help` token cannot mean “show help” without colliding with package targets. Per-command `--help` already works for `list` / `outdated` / `update` via optparse, but command help is thin (one-line `progDesc` only). Bare invocation prints a truncated “Missing: COMMAND” usage fragment and exits `1`.

Help strings still say `mndz-overlay-mgr` in `header`/`progDesc` while the cabal executable and most of the codebase use `mndz-overlay-manager`.

## Goals / Non-Goals

**Goals:**

- Single help convention: `--help` / `-h` only (no `help` subcommand).
- Top-level help: program overview, global options, brief one-line list of real commands.
- Per-command help: command-scoped usage, main args, brief behaviour, footer pointing at top-level for globals.
- Bare invocation: full top-level help text, exit status `1`.
- Explicit `--help` / `-h` (top-level and per-command): exit status `0`.
- Help rendering never loads config or validates overlay.
- Canonical name `mndz-overlay-manager` in user-facing help and active specs.

**Non-Goals:**

- Man pages or exhaustive preflight/Go documentation in CLI help.
- Golden-file tests of full help text (brittle against optparse reflow).
- Per-command local flags that do not exist yet (`list` / `outdated` remain zero-arg).
- Rewriting archived OpenSpec changes that still mention `mndz-overlay-mgr` or `help`.
- Shell completion generation.

## Decisions

**1. Remove `help` entirely; rely on library `helper`.**

Delete `Command.Help`, the `command "help"` entry, exported `showHelp`, and Main’s `Help` branch. Top-level and subcommand help use optparse’s built-in `--help`/`-h` paths. No dual-API parity glue.

- *Alternative — keep `help` as alias for `--help`:* Rejected; free-form args make positional help a permanent footgun if nested later, and top-level `help` teaches the wrong pattern.
- *Alternative — special-case only `update help`:* Rejected; inconsistent UX.

**2. Bare argv: full top-level help body, exit `1`.**

Users who run the binary with no command should see the same substantive help as `--help` (not the short “Missing: COMMAND” fragment alone), but exit non-zero so scripts do not treat “I forgot the subcommand” as success.

Implementation approach (spike if needed):

- Prefer rendering the same failure path as top-level help (or `parserFailure` + `ShowHelpText`) then force `ExitFailure 1` when the input is empty / missing command.
- Do **not** rely on stock `showHelpOnEmpty` alone if that path exits `0` like `--help`.
- Keep `customExecParser` prefs explicit if prefs must stay shared.

- *Alternative — bare exits `0` like `--help`:* Rejected by product decision; bare is missing-command error.
- *Alternative — bare keeps current truncated error only:* Rejected; user wants full top-level help content.

**3. Enrich each command’s `ParserInfo` with scoped text + globals footer.**

For each of `list`, `outdated`, `update`:

- `progDesc` stays short (appears in top-level “Available commands”).
- Longer behaviour lives in `footer` / `footerDoc` (and richer `help` on arguments where present).
- Shared footer line (or equivalent): global options are accepted **before** the subcommand; see `mndz-overlay-manager --help`.
- Attach `<**> helper` on each subcommand parser if not already effective, so `-h`/`--help` stay first-class on that command.

**`update` depth:** document `PACKAGE...` forms (`category/package` or unambiguous package name), omit-means-all-packages-that-need-work, and a short apply/signed-commit blurb. Preflight tool lists and Go-lane rules stay in specs / future man pages.

**`list` / `outdated` depth:** what they print, empty-inventory error, no subcommand-local flags, globals still apply (via footer).

**4. Top-level help remains the brief catalog.**

Top-level `Available commands` one-liners only. No wall of per-command detail at top level.

**5. Naming: `mndz-overlay-manager` only in live help strings.**

Replace `mndz-overlay-mgr` in `header` and `progDesc`. Executable name from cabal already matches.

**6. Spec language: “work subcommand” vs “help render path”.**

Replace “non-help command” / “`help` or `--help`” with language that means: any path that only renders help (`--help`, `-h`, bare full-help render, `COMMAND --help`) skips config and overlay validation; work subcommands (`list`, `outdated`, `update`) load config as today.

## Risks / Trade-offs

- **[Bare exit code vs optparse defaults]** → Stock empty-input help may exit `0`; verify and force exit `1` if needed.
- **[Help content drift]** → Specs require topics (targets, footer, name), not golden strings; manual review of footer wording after implement.
- **[BREAKING: `help` removed]** → Small audience; document in proposal/CHANGELOG if maintained.
- **[Subcommand help omits global flags]** → Intentional (optparse scoped help); mitigated by shared footer pointing at top-level help.

## Migration Plan

1. Land parser/Main changes and delta specs.
2. Operators switch from `… help` to `… --help`.
3. No config or data migration.
4. Rollback: reintroduce `help` command (not planned).

## Open Questions

None remaining from exploration; footer copy and exact `update` blurb length are polish after implementation.
