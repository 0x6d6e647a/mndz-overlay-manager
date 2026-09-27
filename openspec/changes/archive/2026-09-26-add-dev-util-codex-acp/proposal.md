# Proposal: add `dev-util/codex-acp`

## Why

ACP clients need the Codex adapter (`@agentclientprotocol/codex-acp`) as an overlay package the manager can bump. The published npm tarball is the packaging source. It installs `codex-acp` and, on linux x64, a bundled `@openai/codex` whose optional platform package is about 369 MB unpacked. Every stable release omits `engines.node`, and npm lane planning hard-fails that omission today, so a policy row alone cannot report or apply an update. Seed one stable release behind latest so `outdated` and `update` are the acceptance test.

## What Changes

- Seed `dev-util/codex-acp` at frozen PV **1.13.0** (npm `latest` is **1.13.1**; registry `preview` versions such as `1.13.2-preview.5` are not comparable PVs). Packaging matches the other npm packages: registry tarball plus an offline npm-cache deps tarball from `mndz-overlay-assets`. Lane planning always targets the newest eligible upstream PV, so the 1.13.0 deps tarball is materialized manually in the materialize image and published as release `codex-acp-1.13.0` with checksum sidecars and a signed assets commit.
- Add the manager policy: `dev-util/codex-acp` → source `Npm "@agentclientprotocol/codex-acp"`, technique `DepsAndAssets Npm`, with an amd64-only runtime-lane arch allowlist so planned `KEYWORDS` stay `-* ~amd64`. The existing npm cache install already fetches the host's optional `@openai/codex` linux-x64 package. No new pack or cache machinery.
- When registry metadata and the packed `package.json` omit `engines.node` entirely, npm planning and BDEPEND alignment SHALL use the Node version already declared by the donor ebuild's `net-libs/nodejs` atom. The seed ebuild declares `>=net-libs/nodejs-22[npm]`. A candidate that publishes a parseable `engines.node` still uses that probed minimum, including replacing the donor atom. Unparseable `engines.node` values (`*`, `<`, hyphen ranges, empty, and other unsupported combinators) still hard-fail planning.
- The seed ebuild installs `/usr/bin/codex-acp`, sets `QA_PREBUILT` and `dostrip -x` on the nested prebuilt Codex ELF from the linux-x64 optional package, and offers only `IUSE=test`. `src_test` and the operator smoke run `codex-acp --version` and require stdout `@agentclientprotocol/codex-acp` plus the PV. `src_install` fails if that nested ELF is missing. The ebuild does not install `/usr/bin/codex` and does not depend on overlay `dev-util/codex`.
- Accept the single-PV consequence: the later manager bump deletes the 1.13.0 ebuild. The 1.13.0 assets release stays published.
- Smoke the manager: `outdated codex-acp` reports 1.13.1, `update codex-acp` runs the full npm path, then the bumped PV is emerged and `codex-acp --version` prints `@agentclientprotocol/codex-acp 1.13.1`.

PV selection stays planner-owned. The frozen 1.13.0 pin is seed product truth only. Package targets remain `category/package` tokens.

## Capabilities

### New Capabilities

- `dev-util-codex-acp-seed`: seeded overlay package truth for `dev-util/codex-acp` at PV 1.13.0 — identity, scoped npm `SRC_URI`, manual deps-assets release, donor node floor atom, amd64-only `KEYWORDS`, `QA_PREBUILT` for the bundled linux-x64 Codex CLI, `IUSE=test` with an offline `--version` smoke, and operator acceptance. Overlay/seed truth, distinct from `dev-util-codex-seed`.

### Modified Capabilities

- `npm-deps-assets`: absent `engines.node` uses the donor ebuild's existing `net-libs/nodejs` atom for lane selection and BDEPEND alignment; add a `dev-util/codex-acp` enablement requirement (npm `DepsAndAssets` end-to-end, scoped registry package `@agentclientprotocol/codex-acp`) and extend the living Purpose line to name the package.
- `runtime-lanes`: policy for `dev-util/codex-acp` allowlists `amd64` only, so planned `KEYWORDS` are `-* ~amd64`. The existing `dev-util/codex` allowlist requirement stays as written.

## Impact

- **Manager code**: one policy entry with an amd64 arch allowlist in `src/Update/Hardcoded.hs`; engines-absent handling in the npm probe, lane plan, and ebuild rewrite; policy and engines tests. No CLI, pack, or cache-layout changes. The materialize image runs Node 26.3.0 and its sidecar already satisfies node `22.22.2`, so the donor floor does not rebuild the image.
- **Overlay repo**: `dev-util/codex-acp/codex-acp-1.13.0.ebuild`, `metadata.xml`, `Manifest`, md5-cache; signed overlay commits. The bump replaces the ebuild with `1.13.1`. `dev-util/codex` is untouched.
- **Assets repo**: release `codex-acp-1.13.0` (deps tarball dominated by the linux-x64 Codex optional package, on the order of a few hundred MB before or after xz) plus `dev-util/codex-acp/` checksum sidecars; signed assets commit. `update` publishes `codex-acp-1.13.1`.
- **Specs**: new `dev-util-codex-acp-seed`; deltas on `npm-deps-assets` and `runtime-lanes`.
- **Docs**: no operator CLI, config, quality-pipeline, or agent-process change, so README, CONTRIBUTING, and AGENTS stay as they are.

## Non-goals

- No new update technique or ecosystem. The package reuses `DepsAndAssets` with npm as-is.
- No TypeScript build from the GitHub archive, and no install of the bun-compiled `dist/bin/codex-acp-x64-linux` standalone. The registry tarball's `dist/index.js` is the source.
- No `RDEPEND` on overlay `dev-util/codex` and no wrapper that sets `CODEX_PATH`. Upstream launches the bundled `@openai/codex/bin/codex.js` unless that variable is set. Overlay `dev-util/codex` stays the from-source Rust package at its own PV.
- No `/usr/bin/codex` from this package. The installed command is `codex-acp`.
- No shell-completion USE flags and no `shell-completion` inherit. The published file set is `dist/index.js`, `package.json`, `README.md`, and `LICENSE`.
- No multi-arch prefetch of the other `@openai/codex` platform packages, and no musl-versus-glibc split beyond what the linux-x64 optional package contains. The seed cache contains the package npm installs on the materialize image.
- No tracking of the npm `preview` dist-tag. Preview versions stay incomparable and drop out of the candidate set.
- No CLI version pins. The 1.13.0 pin is seed product truth only.
- No change to single-PV prune, the engines parser's handling of present-but-unparseable values, or materialize-image floors.
- No session-level ACP smoke. `--version` does not spawn Codex; proving the ELF is on disk is the install-time check.
