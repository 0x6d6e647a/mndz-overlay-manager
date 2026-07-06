## 1. Implement help rendering

- [x] 1.1 In `src/CLI/Parser.hs`, add `showHelp :: IO a` defined as `handleParseResult . Failure $ parserFailure defaultPrefs parserInfo (ShowHelpText Nothing) mempty`
- [x] 1.2 Add `showHelp` to the `CLI.Parser` module export list
- [x] 1.3 Confirm no new imports are needed (all names are re-exported from the existing `import Options.Applicative`)

## 2. Wire up dispatch

- [x] 2.1 In `app/Main.hs`, change the `Help` branch from `exitSuccess` to `showHelp` and import `showHelp` from `CLI.Parser`
- [x] 2.2 Remove the now-unused `import System.Exit (exitSuccess)` from `app/Main.hs`

## 3. Verify

- [x] 3.1 Run `cabal build` and confirm it succeeds with zero `-Wall` warnings
- [x] 3.2 Confirm `cabal run mndz-overlay-manager -- help` prints the top-level usage text and exits `0`
- [x] 3.3 Confirm the output of `help` is identical to the output of `--help` (e.g. diff the two captured outputs)
