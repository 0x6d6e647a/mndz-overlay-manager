# Proposal: add `dev-util/claude-agent-acp`

## Why

ACP clients need the Claude Agent SDK adapter (`@agentclientprotocol/claude-agent-acp`) as an overlay package the manager can bump. The published npm tarball is the packaging source. It installs the command `claude-agent-acp` and, on glibc amd64, an optional native Claude CLI of about 223 MB. Seed one stable release behind latest so `outdated` and `update` are the acceptance test.

## What Changes

- Seed `dev-util/claude-agent-acp` at frozen PV **0.81.1** (npm `latest` is **0.81.2**; registry `preview` versions such as `0.81.3-preview.1` are not comparable PVs). Packaging matches the other npm packages: registry tarball plus an offline npm-cache deps tarball from `mndz-overlay-assets`. Lane planning always targets the newest eligible upstream PV, so the 0.81.1 deps tarball is materialized manually in the materialize image and published as release `claude-agent-acp-0.81.1` with checksum sidecars and a signed assets commit.
- Add the manager policy: `dev-util/claude-agent-acp` → source `Npm "@agentclientprotocol/claude-agent-acp"`, technique `DepsAndAssets Npm`, with an amd64-only runtime-lane arch allowlist so planned `KEYWORDS` stay `-* ~amd64`. The existing npm cache install already fetches the host's optional `@anthropic-ai/claude-agent-sdk-linux-x64` package. No new materialize machinery.
- The seed ebuild installs `/usr/bin/claude-agent-acp`, declares `>=net-libs/nodejs-22[npm]` (parsed minimum of `engines.node` `>=22`), sets `QA_PREBUILT` on the nested native `claude` ELF, and offers only `IUSE=test`. `src_test` and the operator smoke run `claude-agent-acp --version` and require it to print the PV.
- Accept the single-PV consequence: the later manager bump deletes the 0.81.1 ebuild. The 0.81.1 assets release stays published.
- Smoke the manager: `outdated claude-agent-acp` reports 0.81.2, `update claude-agent-acp` runs the full npm path, then the bumped PV is emerged and `claude-agent-acp --version` prints that PV.

PV selection stays planner-owned. The frozen 0.81.1 pin is seed product truth only. Package targets remain `category/package` tokens.

## Capabilities

### New Capabilities

- `dev-util-claude-agent-acp-seed`: seeded overlay package truth for `dev-util/claude-agent-acp` at PV 0.81.1 — identity, scoped npm `SRC_URI`, manual deps-assets release, node floor atom, amd64-only `KEYWORDS`, `QA_PREBUILT` for the glibc x86-64 Claude CLI, `IUSE=test` with an offline `--version` smoke, and operator acceptance. Overlay/seed truth, not manager runtime behavior.

### Modified Capabilities

- `npm-deps-assets`: add a `dev-util/claude-agent-acp` enablement requirement (npm `DepsAndAssets` end-to-end, scoped registry package `@agentclientprotocol/claude-agent-acp`) and extend the living Purpose line to name the package.
- `runtime-lanes`: policy for `dev-util/claude-agent-acp` allowlists `amd64` only, so planned `KEYWORDS` are `-* ~amd64`.

## Impact

- **Manager code**: one policy entry with an amd64 arch allowlist in `src/Update/Hardcoded.hs`; one policy assertion in `test/Test/Policy.hs`. No CLI, planning, materialize, or ebuild-edit changes. A host spike of 0.81.1 already showed offline `npm install` from that cache succeeds and `claude-agent-acp --version` prints `0.81.1`. The materialize image runs Node 26.3.0 and its sidecar already satisfies node `22.22.2`, so this package's floor does not rebuild the image.
- **Overlay repo**: `dev-util/claude-agent-acp/claude-agent-acp-0.81.1.ebuild`, `metadata.xml`, `Manifest`, md5-cache; signed overlay commits. The bump replaces the ebuild with `0.81.2`.
- **Assets repo**: release `claude-agent-acp-0.81.1` (deps tarball, on the order of 135 MB before xz) plus `dev-util/claude-agent-acp/` checksum sidecars; signed assets commit. `update` publishes `claude-agent-acp-0.81.2`.
- **Specs**: new `dev-util-claude-agent-acp-seed`; deltas on `npm-deps-assets` and `runtime-lanes`.
- **Docs**: no operator CLI, config, quality-pipeline, or agent-process change, so README, CONTRIBUTING, and AGENTS stay as they are.

## Non-goals

- No new update technique or ecosystem. The package reuses `DepsAndAssets` with npm as-is.
- No TypeScript build from the GitHub archive. The registry tarball's `dist/` is the source.
- No shell-completion USE flags and no `shell-completion` inherit. The adapter publishes no completion generator.
- No `/usr/bin/claude`. The installed command is `claude-agent-acp`, the same name as the package.
- No multi-arch prefetch of the other `@anthropic-ai/claude-agent-sdk-*` optional packages, and no musl binary. The seed cache contains the glibc `linux-x64` CLI built on the materialize image.
- No tracking of the npm `preview` dist-tag. Preview versions stay incomparable and drop out of the candidate set.
- No CLI version pins. The 0.81.1 pin is seed product truth only.
- No change to single-PV prune, the engines parser, or materialize-image floors.
