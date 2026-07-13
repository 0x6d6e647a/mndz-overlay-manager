## 1. Cabal project and HIE

- [x] 1.1 Create `cabal.project` with `packages: .` and placeholder/solved `constraints:` for ormolu, hlint, stan, and weeder
- [x] 1.2 Enable HIE generation (`-fwrite-ide-info`, `-hiedir=.hie`) for library, executable, and test components (common stanza and/or project program-options)
- [x] 1.3 Update `.gitignore` for `.tools/`, `.hie/`, and any tool caches

## 2. Tool install (Option B, strict)

- [x] 2.1 Spike: `cabal install` each tool on GHC 9.10.3; record working version pins in `cabal.project` constraints
- [x] 2.2 Add `scripts/install-dev-tools` that installs all four tools into `.tools/bin` with copy/overwrite and project constraints
- [x] 2.3 Make the script executable and document usage/failure expectations in its header comment
- [x] 2.4 Run the script once locally and verify `.tools/bin/{ormolu,hlint,stan,weeder}` exist and run `--help`/`--version`

## 3. Analyzer configuration

- [x] 3.1 Add `weeder.toml` with roots for app/test mains and `Paths_*` as needed
- [x] 3.2 Run weeder against a fresh HIE tree; fix real weeds or adjust roots until baseline is intentional
- [x] 3.3 Run stan; add minimal config/ignores only if required for a clean intentional baseline
- [x] 3.4 Optionally add `.hlint.yaml` if default hlint is unusably noisy; otherwise rely on defaults

## 4. hk configuration

- [x] 4.1 Add `hk.pkl` pinning the hk Config/Builtins package version compatible with installed hk
- [x] 4.2 Implement strict preflight step that fails if any required `.tools/bin` tool is missing (message points to `scripts/install-dev-tools`)
- [x] 4.3 Wire ordered steps: ormolu → `cabal test all` → hlint → stan → weeder using `.tools/bin` paths
- [x] 4.4 Configure pre-commit (fix-oriented for ormolu), plus `check` and `fix` hooks for `hk check` / `hk fix`
- [x] 4.5 Validate config with `hk validate` (or equivalent)

## 5. Baseline code quality and docs

- [x] 5.1 Run ormolu across the tree and commit formatting fixes if needed
- [x] 5.2 Ensure `cabal test all` passes with HIE flags enabled
- [x] 5.3 Ensure full pipeline passes via `hk check`
- [x] 5.4 Add a short bootstrap note (README section or CONTRIBUTING snippet): install tools script, `hk install`, strict policy

## 6. Verification

- [x] 6.1 Verify missing-tool path: rename/remove one binary and confirm hook/check fails with bootstrap message
- [x] 6.2 Verify a deliberate test or format failure blocks the pipeline
- [x] 6.3 Confirm global-only tool on PATH is not used when `.tools/bin` entry is missing
- [x] 6.4 Run `hk install` as needed and confirm pre-commit fires on a dry-run commit attempt (or `hk run pre-commit`)
