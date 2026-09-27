# Design — add `dev-util/codex-acp`

## Context

See proposal.md for why. The package is the npm CLI `@agentclientprotocol/codex-acp`, packaged as `dev-util/codex-acp`. Its install pulls a linux-x64 Codex tree through an npm optional dependency of `@openai/codex` (about 369 MB unpacked at `0.156.1-linux-x64`, 46 files, `os: linux`, `cpu: x64`). `DepsAndAssets Npm` already packs a registry tarball, fills an npm cache, publishes `{pn}-{pv}-deps.tar.xz`, and rewrites `KEYWORDS` plus the nodejs atom.

Capture-time facts:

- npm `latest` is `1.13.1`. `preview` is `1.13.2-preview.5`. No stable release from `0.0.38` through `1.13.1` publishes `engines`. `1.13.0` depends on `@openai/codex` `^0.155.1` and `@agentclientprotocol/sdk` `^1.5.0`. `1.13.1` keeps that SDK range and moves Codex to `^0.156.1`. A `0.x` caret stays inside that minor (`^0.155.1` is `>=0.155.1 <0.156.0`).
- `fetchNpmEnginesNode` returns `missing engines.node` when the field is absent, and `planNpm` turns that into `PlanProbeFailed`. `maxVersionUnder` only selects candidates whose requirement is present, so returning no requirement drops the version and planning ends in `PlanZeroPlannedPVs`.
- The published `1.13.1` entrypoint prints `@agentclientprotocol/codex-acp` plus the version and exits when argv contains `--version`, before it spawns Codex. Any other argv, including `--help` and `-v`, starts the ACP server. The default Codex launch resolves `@openai/codex/bin/codex.js` from the install and runs it with the same Node. `CODEX_PATH` is the only override, and it spawns that path's `app-server` directly.
- Overlay `dev-util/codex` is the from-source Rust package at `0.153.4` and installs `/usr/bin/codex`. A global npm install of this adapter links only the top-level bin `codex-acp`.
- Materialize image `mndz-overlay-manager/materialize:local` runs Node 26.3.0. Sidecar `satisfies.node` is `22.22.2`, so a donor floor of `22` does not rebuild the image.
- Cargo already reads a donor floor from the highest non-live ebuild during content assessment (`selectHighestNonLive`). That read is too late for npm: the lane probe has to return a version or the candidate never becomes a target.

## Goals / Non-Goals

**Goals:**

- Seed PV `1.13.0` installable from the overlay, with an ebuild body the later bump can copy (`QA_PREBUILT`, `dostrip -x`, `src_test`, `SRC_URI` parameterized by `${PV}`).
- One policy row so `outdated` / `update` treat the package as npm `DepsAndAssets` on amd64 only.
- Absent `engines.node` resolves to the donor nodejs atom and the candidate stays selectable. A published parseable `engines.node` still wins.
- One full-path cycle (`outdated` → `update` → emerge → `--version`) as the acceptance test.

**Non-Goals:**

- Changing the shared lane selector so a missing requirement means "fits every ceiling". Go and Sbcl use a missing requirement to skip a version.
- A per-package hardcoded Node floor in policy. The donor ebuild is the floor.
- Rebuilding the materialize image, or prefetching non-linux-x64 `@openai/codex` optional packages.

## Decisions

- **Source `Npm "@agentclientprotocol/codex-acp"`, technique `DepsAndAssets Npm`, `policyLaneArches` `["amd64"]`.** Same shape as `dev-util/claude-agent-acp`. Alternative: GitHub source plus `tsc` — the registry tarball already contains `dist/index.js`, and npm apply hard-fails when the source is not npm. Alternative: keyword every nodejs arch — the cache built on the glibc image contains the linux-x64 optional package only.
- **The npm probe returns the donor floor as a real requirement.** When registry metadata and the packed `package.json` omit `engines.node`, read `>=net-libs/nodejs-<version>[npm]` from the highest local non-live ebuild and return that `<version>` (for the seed, `22`). Lane selection then treats it like any other floor. A present parseable `engines.node` is returned unchanged, so a later release that adds the field replaces the donor atom. A present unparseable value still hard-fails, with no donor fallback. No donor atom still hard-fails. Alternative: return no requirement — `maxVersionUnder` skips it and the plan has zero targets. Alternative: invent `22` inside the parser for every npm package — a package that used to declare engines and then drops the field would silently keep moving; the donor atom makes that omission visible as "preserve what the ebuild already says," and a missing atom still fails.
- **Apply keeps using the planned requirement.** `ensureNodejsBdepend` already writes `>=net-libs/nodejs-<ver>[npm]` from the plan. Once planning supplies `22`, the `(NpmEco, Nothing)` hard-fail stays for a plan that never resolved a version. The `(NpmEco, Just ver)` branch rewrites the atom, including the no-op that leaves a donor `22` in place.
- **Manual seed materialization inside the materialize image**, using the registry-only steps (empty userconfig, `npm pack` of `@agentclientprotocol/codex-acp@1.13.0`, `npm --cache install`, hermetic `XZ_OPT=-T1 -9e`, drop `_logs/` and `_update-notifier*`). Install that cache once before freezing `QA_PREBUILT`. The glob matches the ELF under `usr/lib*/node_modules/@agentclientprotocol/codex-acp/node_modules/` and contains no Codex version, so the `^0.155.1` → `^0.156.1` bump can copy the line. `src_install` `dostrip -x`s that path and dies if the file is missing. `QA_PREBUILT` only suppresses the pre-stripped QA notice.
- **Ebuild body modeled on `dev-util/claude-agent-acp`.** Scoped `SRC_URI` rename (`…/codex-acp-${PV}.tgz -> ${P}.tgz`). `S=${WORKDIR}/package`. Deps unpack into `${T}`. Offline `npm --global --prefix` install. `src_test` repeats that install into a temp prefix and checks `codex-acp --version` prints `@agentclientprotocol/codex-acp ${PV}`. `IUSE` is `test` only. The seed spike confirms the `1.13.0` bundle prints that string before the test is frozen.
- **Spec homes.** Seed pin, manual assets, `QA_PREBUILT`, and the `--version` smoke live in `dev-util-codex-acp-seed`. The donor-floor rule and enablement live in `npm-deps-assets` as modified probe/BDEPEND requirements plus an added enablement requirement. The amd64 allowlist is an added `runtime-lanes` requirement, leaving the existing `dev-util/codex` requirement text alone. The living `npm-deps-assets` Purpose line names `dev-util/codex-acp` directly, because a delta Purpose is ignored at archive.
- **Execution split.** The agent writes the policy, the donor-floor behavior, the ebuild, and metadata, runs the container materialize, and prepares release, manifest, and gencache commands. The operator emerges (root) and confirms GPG prompts for the overlay and assets commits. The GitHub token wrap and the signing-key passphrase need a controlling terminal.

## Risks / Trade-offs

- [npm `latest` moves past `1.13.1` before the smoke] → seed pin stays `1.13.0`. `outdated` / `update` target the newest comparable version. Re-run `outdated --refresh` if a release lands inside the check-cache window.
- [The nested Codex path embeds `0.155.1` or changes layout at `0.156.x`] → the copied `QA_PREBUILT` line misses the ELF on the bump and `src_install` fails. Widen the glob to the version-free path observed at seed install before publishing `1.13.0`. The first bump is exactly this Codex-pin change, so the smoke is the check.
- [Optional dependency missing from the cache] → offline `npm install` omits the ELF and `src_install` dies. The seed install is the gate that the ELF is on disk before `update` runs. `--version` does not spawn Codex, so it is not that gate.
- [xz of a cache dominated by a ~369 MB optional package is slow under `-T1 -9e`] → expected. Disk preflight already covers the unit. GitHub release limits are far above this asset.
- [The linux-x64 ELF is a static musl binary, or already stripped] → `dostrip -x` still applies. The seed install records `file` / `ldd` output so the ebuild comment matches the binary. A musl Gentoo emerge is outside the amd64 glibc image that built the cache.
- [`1.13.0` `--version` text differs from the `1.13.1` entrypoint] → adjust the seed `src_test` expected string to the spike output before emerge, and correct the seed spec in the same change. The shape stays "name, space, PV" unless the spike shows otherwise.
- [Full-path unit fails in docker] → the existing hard-fail keeps the unit work directory. The seed install stays in place. Retry `update codex-acp`.

## Migration Plan

1. Land the policy entry, the donor-floor probe, and their tests. `hk check` green. The entry is inert until the overlay has the package.
2. Materialize and publish `codex-acp-1.13.0`, write the ebuild from the observed ELF path, manifest, and md5-cache, sign, emerge, and pass the seed `--version` smoke.
3. Run `outdated codex-acp` and `update codex-acp`, then emerge the bumped PV and check `--version` prints `@agentclientprotocol/codex-acp` plus that PV.
4. Rollback before the bump: revert the overlay and assets commits and `emerge -c` the package. The policy row does nothing when the inventory has no match. After the bump, the `1.13.0` assets release is still published if the old ebuild has to be restored by hand.
