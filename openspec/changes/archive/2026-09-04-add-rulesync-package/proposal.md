# Add dev-util/rulesync package

## Why

`rulesync` (dyoshikawa/rulesync) is an MIT Node.js CLI that generates AI-tool config files (rules, commands, MCP, subagents, skills) from a unified `.rulesync/` source of truth. The overlay should carry it, and the manager should maintain it like the other npm-ecosystem packages so version bumps are `outdated` / `update` work, not hand edits.

## What Changes

- Seed `dev-util/rulesync` at frozen PV **16.22.1** (upstream latest-minus-one at capture time; latest is 16.23.0). The seed follows the openspec packaging pattern: npm registry tarball + offline npm-cache deps tarball from `mndz-overlay-assets`. Because lane planning always targets the newest upstream PV, the seed PV's assets are materialized **manually** (materialize image container, hermetic tar rules) and published as release `rulesync-16.22.1` with checksum sidecars and a signed assets commit.
- Add the manager hardcoded policy: `dev-util/rulesync` → source `Npm "rulesync"`, technique `DepsAndAssets NpmEco` (no new machinery).
- Accept the single-PV policy consequence: the later manager-driven bump deletes the 16.22.1 ebuild (its assets release stays published), matching openspec behavior.
- Smoke the manager end-to-end: `outdated rulesync` reports the newer upstream PV, `update rulesync` runs full-path materialize (docker, assets publish, ebuild write + prune, Manifest, md5-cache, signed overlay+assets commits), then the bumped PV is emerged and tested offline.

## Capabilities

### New Capabilities

- `dev-util-rulesync-seed`: product truth for the manually seeded `dev-util/rulesync` overlay package at PV 16.22.1 — identity/version pin, metadata/license, manually materialized offline deps assets release, node floor BDEPEND atom, KEYWORDS, no-completions shape, offline `src_test`, and operator smoke acceptance. Overlay/seed truth, not manager runtime behavior.

### Modified Capabilities

- `npm-deps-assets`: add a `dev-util/rulesync` enablement requirement (npm DepsAndAssets end-to-end, like the existing `dev-util/openspec` enablement) and extend the Purpose line to name rulesync.

## Impact

- **Manager code**: one policy entry in `src/Update/Hardcoded.hs`; one policy assertion in `test/Test/Policy.hs`. No CLI, planning, materialize, or ebuild-edit changes — the existing `DepsAndAssets NpmEco` path covers rulesync (unscoped package, pure-JS deps, no platform-specific optionalDependencies, engines `>=22.0.0` parses under the existing requirement parser; materialize image node floor 22.22.2 already satisfies the host-node gate).
- **Overlay repo**: new `dev-util/rulesync/rulesync-16.22.1.ebuild`, `metadata.xml`, `Manifest`, `metadata/md5-cache/` entry; signed overlay commits.
- **Assets repo**: release `rulesync-16.22.1` (deps tarball) plus `dev-util/rulesync/` checksum sidecars; signed assets commit. Later, release `rulesync-16.23.0` via the manager's apply.
- **Specs**: new `dev-util-rulesync-seed`; delta on `npm-deps-assets`.
- **Docs**: no operator CLI/config/pipeline/agent-process change, so README/CONTRIBUTING/AGENTS are untouched (project-docs policy).

## Non-goals

- No new update technique or ecosystem; rulesync reuses `DepsAndAssets` with npm as-is.
- No support for rulesync's GitHub release single-binary assets (`install.sh` / prebuilt `rulesync-*` binaries); the npm registry tarball is the packaging source.
- No completion USE flags or `shell-completion` inherit (rulesync publishes no completion generator; verified at seed time, not spec'd).
- No CLI version pins: the frozen 16.22.1 pin is seed product truth only; PV selection stays planner-owned. Package targets remain `category/package` tokens.
- No change to single-PV prune policy, runtime-lane planning, or materialize-image floors.
- No bundling of rulesync's own agent-config outputs into other overlay packages.