## Why

The tool can detect outdated packages but cannot apply version bumps. Maintainers still hand-run `git mv`, `ebuild … manifest`, and signed commits. A first-class `update` command for packages that only need rename-plus-Manifest (with an explicit per-package technique map) closes that loop safely and leaves complex bumps unsupported until later.

## What Changes

- Add CLI subcommand `update` that upgrades outdated packages to the latest upstream version
- Accept zero or more package targets (`category/package` or unambiguous `package`); zero means all outdated candidates
- Maintain a **fully hardcoded** map from `category/package` to update source **and** update technique (no ebuild inference)
- **BREAKING** (library/resolve behavior): remove Level-1 ebuild source inference; packages without a hardcoded source are unconfigured
- Implement technique `GitMvAndManifest`: rename newest local ebuild to the remote PV, run `ebuild <new.ebuild> manifest` from the package directory, then create an isolated signed git commit `category/package: version`
- Mark other packages `Unsupported` (vendor assets, cargo CRATES, npm deps pipelines, etc.) for soft skip
- Parallel per-package check/rename/manifest; barrier; then serial sorted GPG-signed commits (option B: pinentry once after heavy work)
- Action-scoped PATH preflight: `update` requires `git`, `ebuild`, and `gpg` on PATH or exits 1 before any work
- Stdout: one line per successful update (`category/package vLOCAL -> vREMOTE`); soft skips warn; hard failures error and yield exit 1 after all packages finish
- **Non-goals**: complex techniques (go vendor, npm deps, cargo), auto-delete old ebuild versions, force-to-version flag, live `9999` handling beyond awareness, unsigned commits, config-file policy maps, pure-Haskell Manifest generation

## Capabilities

### New Capabilities
- `update-command`: CLI `update` subcommand: targets, preflight, apply pipeline, stdout/stderr, exit codes
- `update-apply`: Package policy model (source + technique), `GitMvAndManifest` apply steps, dirty checks, parallel work + serial signed commits, soft vs hard outcomes

### Modified Capabilities
- `update-source`: Sources come only from the hardcoded map (inference removed); map covers every known overlay package together with technique policy
- `outdated-command`: Resolve path uses hardcoded sources only (behavior change for packages that previously relied on inference)
- `cli-help`: Help text and command enumeration include `update`

## Impact

- **CLI**: `CLI.Parser` gains `Update` with optional package arguments; `Main` dispatches update pipeline
- **Library**: Expand `Update.Hardcoded` into full package policy; remove `Update.Infer` and inference branch of resolve; add apply/git/preflight modules; shell out to `git`, `ebuild`, `gpg`
- **Dependencies**: process spawning (`typed-process` or `process`); concurrency (`async`); no new Portage library binding
- **Tests**: Hand-rolled tests for target resolution, policy lookup, dirty logic, and mocked external commands; no live network or real GPG in default `cabal test`
- **Host**: `update` requires Portage (`ebuild`), git, and gpg; `list`/`outdated` do not
- **Overlay repo**: Mutates ebuild filenames, Manifests, and creates signed commits under the configured overlay path
