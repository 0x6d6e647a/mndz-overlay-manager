## 1. Baseline and placement

- [x] 1.1 Note current Overall/Unit expr% from `coverage/summary.json` (or run `./scripts/coverage` if stale) for an optional before/after comparison
  - Baseline: Overall 65.07% expr / Unit 51.63% expr
- [x] 1.2 Choose target test modules (`Test.Config`, `Test.CLI`, `Test.Overlay`, `Test.Assets`, plus Types host) and register any new module in `test/Main.hs` only if splitting is required
  - Hosts: Config, Overlay, Assets (auth), Policy (Types), CLI; no new module

## 2. Config residual (Unit)

- [x] 2.1 Unit cases for `configErrorMessage` covering `ConfigNotFound` and `DecodeError`
- [x] 2.2 Unit case(s) exercising default config path selection via `loadConfig Nothing` under controlled `XDG_CONFIG_HOME` (and/or missing-file outcome); export `defaultConfigPath` only if env bracketing cannot reach the XDG branch
- [x] 2.3 Unit case for decode failure through `loadConfig` with a temporary invalid TOML file

## 3. Overlay validation and version residual (Unit)

- [x] 3.1 Unit cases for `validateOverlay` failures: not a directory, missing required directory, missing required file, repo name mismatch (temp trees preferred)
- [x] 3.2 Unit cases for remaining `Overlay.Version` residual edges visible in HPC (parse/render/compare arms not already covered)

## 4. Auth and Types pure helpers (Unit)

- [x] 4.1 Expand pure `resolveGitHubTokenWith` edges (whitespace-only, strip, env vs config precedence) on product API
- [x] 4.2 Optional thin IO case for `resolveGitHubToken` with env bracket if low cost
- [x] 4.3 Unit tables for `techniqueNeedsAssets`, `ecosystemIsGo` / `ecosystemIsNpm` / `ecosystemIsBun` / `ecosystemIsCargo`, and `splitPackageKey` success + `Nothing` arms

## 5. CLI parser residual and logging bootstrap (Unit)

- [x] 5.1 Extend pure parser evaluation for residual verbosity / work-command edges not already covered
- [x] 5.2 Exercise `showTopLevelHelpExit1` under Unit via exit-code catch when practical (do not require full help prose)
- [x] 5.3 Unit cases constructing product log hold + `mkLogger` for controlled verbosity/color inputs (and flush/hold edges if exported and still cold)

## 6. Quality gate

- [x] 6.1 Run instrumented tests via `./scripts/coverage` and confirm reports write; confirm no floors introduced
- [x] 6.2 Run full `hk check` and fix format/lint/analysis failures
- [x] 6.3 Mark tasks complete only when the gate is green; optionally record post Overall/Unit expr% for the program log
  - Post: Overall ~66.2–66.3% expr / Unit 52.7% expr (baseline Overall 65.07% / Unit 51.63%); floors still false
