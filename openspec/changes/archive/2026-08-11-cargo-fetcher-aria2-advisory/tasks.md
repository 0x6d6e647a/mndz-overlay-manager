## 1. Preflight hard check and comments

- [x] 1.1 Set `cargoFetcherTools` to `["wget", "aria2c"]` only; keep grouped missing token `"wget or aria2c"`
- [x] 1.2 Fix comments on cargo required tools / fetchers: hard P1 = any cargo needs work (including reuse-only); do not claim fetchers are “full path only”
- [x] 1.3 Export a shared advisory constant for the exact string `pycargoebuild is using wget; install aria2 for faster crate fetches`
- [x] 1.4 Add helper to detect soft advisory: full-path cargo unit present + `aria2c` missing on PATH (injectable finder); return empty when condition false

## 2. Spine dual surface

- [x] 2.1 After successful language-tool hard preflight in `runUpdatePhases`, compute cargo fetcher advisories from classify + PATH
- [x] 2.2 Log each advisory at warn severity immediately (via progress logger / Colog)
- [x] 2.3 Merge advisories into `usrWarnings` alongside disk-gate warnings
- [x] 2.4 Ensure hard-fail path still short-circuits before advisory emission when fetchers/pycargoebuild missing

## 3. Tests

- [x] 3.1 Update `Test.Preflight` constant assertion: fetchers are `wget`, `aria2c` only
- [x] 3.2 Hard preflight: missing both fetchers still fails; presence of only bare `aria2` does not satisfy hard check
- [x] 3.3 Soft advisory unit tests: full-path cargo + wget only → advisory text; `aria2c` present → none; reuse-only cargo → none
- [x] 3.4 Cover spine wiring if needed (advisories land on `usrWarnings` without changing hard-fail exit)

## 4. Docs

- [x] 4.1 README runtime tools: PATH names `wget` or `aria2c` only; optional note that package `aria2` is recommended for faster full-path cargo crate downloads
- [x] 4.2 Scrub any remaining operator-facing claim that bare `aria2` is a valid fetcher executable name

## 5. Quality gate

- [x] 5.1 `openspec validate --change cargo-fetcher-aria2-advisory` (or project equivalent) clean
- [x] 5.2 `hk check` green
