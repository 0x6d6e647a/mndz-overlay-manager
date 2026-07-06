## Context

The executable uses `optparse-applicative` (0.19). `CLI.Parser.parserInfo` wires the top-level parser with `<**> helper`, so `--help`/`-h` already renders usage. A `help` subcommand also exists (`hsubparser (command "help" ...)`) and parses into a `Help` constructor. However, `app/Main.hs` handles `Help` with `exitSuccess`, printing nothing — so `help` and `--help` diverge.

Investigation of the library source (`Options/Applicative/Extra.hs`) showed that `--help` is not special output: `helper` triggers a `ShowHelpText Nothing` parse error, which `execParserPure` turns into `Failure (parserFailure prefs pinfo (ShowHelpText Nothing) ctx)`, rendered by `handleParseResult` (stdout + `ExitSuccess`). The library's own haddock documents the reusable idiom:

```
handleParseResult . Failure $ parserFailure pprefs pinfo (ShowHelpText Nothing) mempty
```

`Main` runs the parser via `execParser` (= `customExecParser defaultPrefs`), so `defaultPrefs` is the preference set to reuse. All required names (`ParseError(..)`/`ShowHelpText`, `ParserResult(..)`/`Failure`, `parserFailure`, `handleParseResult`, `defaultPrefs`) are re-exported from the single `Options.Applicative` module already imported by `CLI.Parser`.

## Goals / Non-Goals

**Goals:**
- `help` subcommand produces byte-for-byte identical output and exit behavior to `--help`.
- Keep help-rendering logic encapsulated in `CLI.Parser`; `Main` stays a thin dispatcher.
- Guarantee parity structurally (shared code path), not by duplicating rendering.

**Non-Goals:**
- Per-command help (`help <command>` / nested `--help`). Convention only; not built now.
- Splitting subcommands into per-command modules. Noted as future direction; out of scope.
- Any change to `--help` behavior itself.

## Decisions

**1. Reuse the library's failure→render path (approach C).**
Add an exported `showHelp :: IO a` to `CLI.Parser`:

```haskell
showHelp :: IO a
showHelp =
  handleParseResult . Failure $
    parserFailure defaultPrefs parserInfo (ShowHelpText Nothing) mempty
```

`Main` dispatches `Help -> showHelp`. Because this reuses the same `defaultPrefs`, the same `parserInfo`, the same `parserFailure`, and the same `handleParseResult` that `--help` flows through, parity is guaranteed by construction — identical text, stdout routing, and `ExitSuccess`.

- *Return type `IO a`*: `handleParseResult` on this failure always `exitWith`s and never returns, so `a` is free and unifies with the sibling `pure ()` branch.
- *Alternative — render in `Main` (approach A)*: same mechanism but leaks optparse rendering concerns into `Main`; rejected to keep `Main` thin.
- *Alternative — `abortOption`/scoped `helper` on the `help` subcommand (approach B)*: renders the subcommand's usage/context (`Usage: prog help`), not the top-level program help; wrong scope. Rejected.

**2. Keep all parsing in `CLI.Parser` for now; grow into per-command modules later.**
With a single real command, per-command modules would be premature. The intended growth path: each future command gets its own module (e.g. `CLI.Command.Sync`) exporting a `Parser`/`ParserInfo`; `CLI.Parser` remains the thin composition root wiring them via `hsubparser`. Per-command `--help` comes from attaching `<**> helper` to each subcommand's `info`; a per-command `help` subcommand reuses the same `parserFailure` idiom scoped to that command's `pinfo`.

**3. Remove the now-unused `exitSuccess` import from `Main`.**
`-Wall` is enabled via the `warnings` common stanza; leaving the unused import would warn.

## Risks / Trade-offs

- `parserFailure defaultPrefs parserInfo ...` references the same `parserInfo` at top level → No recursion concern; `ParserInfo` is plain data, not evaluated circularly.
- Preferences drift: if `Main` later switches to `customExecParser` with non-default prefs, `showHelp` must use the same prefs to stay identical → Keep the prefs source consistent (single definition) if/when custom prefs are introduced; noted for future.
- `showHelp :: IO a` never returns → Intentional; it terminates via `exitWith`, matching the current `exitSuccess` behavior. `runWithLogger` has no bracket/cleanup, so propagation is unchanged.
