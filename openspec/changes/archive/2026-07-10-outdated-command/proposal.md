## Why

The overlay manager can list ebuilds but cannot tell which packages lag upstream. Maintainers currently rely on ad-hoc scripts (e.g. Python for grok-build) and manual GitHub/npm checks. A first-class `outdated` command, with structured versions and pluggable update sources, makes refresh work systematic and keeps the inventory layer reusable for a future bump tool.

## What Changes

- Add CLI subcommand `outdated` that reports packages whose upstream version is newer than the newest local ebuild PV
- Introduce a dedicated ebuild version type (numeric components, optional revision, raw escape hatch) with parse, render, and PV comparison
- Resolve update sources via a small hardcoded map (e.g. grok-build Http) or Level-1 inference from ebuild text (GitHub tag/release URLs, npm registry, simple `${PN//-bin/}` expansion)
- Fetch latest versions from GitHub Releases (with tag fallback), npm registry, and plain HTTP version URLs
- Print outdated packages to stdout as `category/package vLOCAL -> vREMOTE`; soft failures (unconfigured, fetch/parse error, ahead) as per-package warnings on stderr; exit 0 when the check run succeeds
- **Non-goals**: writing or renaming ebuilds, Manifest/digests, vendor tarball rebuild, Portage slots, full PMS version grammar, config-file source maps, live-network tests in CI

## Capabilities

### New Capabilities
- `ebuild-version`: Structured ebuild version type, parsing from Gentoo-style version strings, pretty rendering with optional leading `v`, and PV comparison for update detection (revision ignored when comparing to upstream)
- `update-source`: Update source model (GitHub, npm, Http), hardcoded overrides, Level-1 ebuild inference, and fetching the latest upstream version
- `outdated-command`: CLI `outdated` subcommand: spine (config → path → validate → discover), per-package check, stdout/stderr policy, and exit codes

### Modified Capabilities
- `cli-help`: Help text and command enumeration must include the new `outdated` subcommand

## Impact

- **CLI**: `CLI.Parser` gains `Outdated`; `Main` dispatches the check pipeline
- **Library**: New modules for version, update types, inference, hardcoded sources, GitHub/npm/Http clients, and check aggregation; optional small helpers on existing `Overlay` types
- **Dependencies**: HTTP client and JSON (e.g. `http-client`/`req` + `aeson`); optional `GITHUB_TOKEN` from the environment for GitHub rate limits
- **Tests**: Hand-rolled pure tests for version/infer and injected fetcher; no live network in default `cabal test`
- **Overlay ebuilds**: Unchanged; inference reads them as text only
