# Design — add `dev-util/claude-agent-acp`

## Context

See proposal.md for why. The package is the npm CLI `@agentclientprotocol/claude-agent-acp`, packaged as `dev-util/claude-agent-acp`. Its install pulls a glibc x86-64 Claude ELF through an npm optional dependency. `DepsAndAssets Npm` already packs a registry tarball, fills an npm cache, publishes `{pn}-{pv}-deps.tar.xz`, and rewrites `KEYWORDS` plus the nodejs atom. Lane planning still selects only the maximum candidate under the node ceiling, so a local `0.81.1` with upstream `0.81.2` makes the manager's first job the bump. The seed assets are manual.

Capture-time facts, from the registry and a host spike of `0.81.1`:

- npm `latest` is `0.81.2`. `preview` is `0.81.3-preview.1`. Versions containing `-preview` parse as raw strings and drop out of `filterCandidateVersions`. Stable tips are `0.81.0`, `0.81.1`, `0.81.2`, all with `engines.node` `>=22` and the same direct deps (`zod` 4.6.5, `@agentclientprotocol/sdk` 1.5.0, `@anthropic-ai/claude-agent-sdk` 0.3.280).
- `parseEnginesMinimum ">=22"` yields `22`, so the nodejs atom the bump will write is `>=net-libs/nodejs-22[npm]`.
- Host spike (empty userconfig, then offline `--global` install): pack tarball 278 KB; npm cache about 135 MB; 105 packages; `claude-agent-acp --version` printed `0.81.1`. `--help` with stdin closed exited 0 and printed nothing, because the process opens an ACP session.
- The native file is an unstripped, dynamically linked x86-64 ELF (about 223 MB) that needs only glibc. Install path: `usr/lib64/node_modules/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude`.
- Materialize image `mndz-overlay-manager/materialize:local` (`sha256:42ae89977aff…`) runs Node 26.3.0. Sidecar `satisfies.node` is `22.22.2`, so this package's floor does not rebuild the image.

## Goals / Non-Goals

**Goals:**

- Seed PV `0.81.1` installable from the overlay, with an ebuild body the later bump can copy (QA_PREBUILT, `src_test`, `SRC_URI` parameterized by `${PV}`).
- One policy row so `outdated` / `update` treat the package as npm `DepsAndAssets` on amd64 only.
- One full-path cycle (`outdated` → `update` → emerge → `--version`) as the acceptance test.

**Non-Goals:**

- No edits to npm pack, cache install, engines parsing, or lane machinery. The allowlist field already exists.
- No second deps tarball per architecture.
- No seed of any PV other than `0.81.1`. If `latest` moves past `0.81.2` before the smoke, the bump targets whatever comparable version is newest then.

## Decisions

- **Source `Npm "@agentclientprotocol/claude-agent-acp"`, technique `DepsAndAssets Npm`, `policyLaneArches` `["amd64"]`.** Same shape as the codex allowlist, on the npm ecosystem. Alternative: GitHub source plus `tsc` — rejected. The registry tarball already contains `dist/`, and `npm-deps-assets` hard-fails when the technique is npm and the source is not npm. Alternative: keyword every nodejs arch — rejected. The cache built on the glibc image contains `@anthropic-ai/claude-agent-sdk-linux-x64` only; an arm64 offline install would miss its optional package.
- **Manual seed materialization inside the materialize image**, using the registry-only steps (empty userconfig, `npm pack` of `@agentclientprotocol/claude-agent-acp@0.81.1`, `npm --cache install`, hermetic `XZ_OPT=-T1 -9e`, drop `_logs/` and `_update-notifier*`). Alternative: host npm — the spike already proved the cache layout, and the image is what `update` will use for `0.81.2`, so the seed uses that producer too.
- **Ebuild body modeled on `dev-util/rulesync`**, with the scoped `SRC_URI` rename used by `dev-util/openspec` (`…/claude-agent-acp-${PV}.tgz -> ${P}.tgz`). `S=${WORKDIR}/package`. Deps unpack into `${T}`. Offline `npm --global --prefix` install. `src_test` repeats that install into a temp prefix and checks `claude-agent-acp --version` prints `${PV}`. `QA_PREBUILT` uses a `usr/lib*` glob so `lib` and `lib64` both match the nested `claude` ELF. `IUSE` is `test` only.
- **Installed command is `claude-agent-acp`.** That is the upstream bin and the package name. The ebuild does not add `/usr/bin/claude`.
- **Spec homes.** Seed pin, manual assets, `QA_PREBUILT`, and the `--version` smoke live in `dev-util-claude-agent-acp-seed`. Manager enablement lives in `npm-deps-assets`. The amd64 allowlist lives in `runtime-lanes` as an added requirement, leaving the existing codex requirement text alone. The living `npm-deps-assets` Purpose line names `dev-util/claude-agent-acp` directly, because a delta Purpose is ignored at archive.
- **Execution split.** The agent writes the policy, ebuild, metadata, and sidecars, runs the container materialize, and prepares release, manifest, and gencache commands. The operator emerges (root) and confirms GPG prompts for the overlay and assets commits.

## Risks / Trade-offs

- [npm `latest` moves past `0.81.2` before the smoke] → seed pin stays `0.81.1`. `outdated` / `update` target the newest comparable version. Re-run `outdated --refresh` if a release lands inside the check-cache window.
- [A later SDK bump renames `@anthropic-ai/claude-agent-sdk-linux-x64` or the `claude` filename] → emerge QA or a missing binary fails the bumped PV. Fix the donor `QA_PREBUILT` line on that ebuild. The `0.81.1` → `0.81.2` deps pin is the same SDK `0.3.280`, so the first bump keeps the path.
- [Optional dependency missing from the cache] → offline `npm install` warns or omits the ELF, and a real session cannot find it. The host spike installed it. The seed `src_test` checks `--version`, which imports the SDK; the emerge of `0.81.1` is the gate that the ELF is on disk before `update` runs.
- [xz of a ~135 MB cache is slow under `-T1 -9e`] → expected. Disk preflight already covers the unit. GitHub release limits are far above this asset.
- [musl amd64 still matches `~amd64`] → the cache has the glibc ELF. Musl is out of scope. A musl emerge would fail the optional package lookup offline.
- [Full-path unit fails in docker] → the existing hard-fail keeps the unit work directory. The seed install stays in place. Retry `update claude-agent-acp`.

## Migration Plan

1. Land the policy entry and its test. `hk check` green. The entry is inert until the overlay has the package.
2. Materialize and publish `claude-agent-acp-0.81.1`, write the ebuild, manifest, and md5-cache, sign, emerge, and pass the seed `--version` smoke.
3. Run `outdated claude-agent-acp` and `update claude-agent-acp`, then emerge the bumped PV and check `--version`.
4. Rollback before the bump: revert the overlay and assets commits and `emerge -c` the package. The policy row does nothing when the inventory has no match. After the bump, the `0.81.1` assets release is still published if the old ebuild has to be restored by hand.
