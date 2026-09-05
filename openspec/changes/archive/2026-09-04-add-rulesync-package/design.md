# Design — add dev-util/rulesync package

## Context

rulesync is an exact structural twin of `dev-util/openspec` in packaging terms: unscoped npm package, pure-JS deps (no platform-specific `optionalDependencies`, no native modules), single `bin` entry, MIT, `engines.node >=22.0.0`. The existing `DepsAndAssets NpmEco` machinery (planning, materialize, assets publish/reuse, ebuild edit, manifest, md5-cache) covers it without new code paths — see proposal.md for scope.

The one mechanism that shapes this design is lane planning: `filterCandidateVersions` (locals ∪ upstream-newer) feeds per-lane `maxVersionUnder` selection, so with local 16.22.1 and upstream 16.23.0 the planner targets **only** 16.23.0 and schedules 16.22.1 for prune. The manager can therefore never bootstrap the seed PV's assets itself — that materialization is manual, and the manager's first real work on this package is the bump.

Environment facts verified at capture time: materialize image node floor recorded as 22.22.2 (satisfies the `>=22.0.0` host-node gate, no image rebuild expected); host has docker 29.5.2; upstream latest is 16.23.0 (non-prerelease release `v16.23.0`).

## Goals / Non-Goals

**Goals:**

- Seed PV 16.22.1 fully installable (ebuild + assets release + Manifest + md5-cache) with the manager-canonical ebuild shape so the later bump is a clean clone-plus-edits.
- Manager policy entry such that `outdated` / `update` treat rulesync exactly like openspec.
- One manager-driven full-path cycle (outdated → update → emerge → test) as end-to-end proof.

**Non-Goals:**

- No manager code beyond the policy entry and its test assertion; no planning/materialize/ebuild-edit changes.
- No GitHub-release (single-binary) packaging path; npm registry tarball only.
- No KEYWORDS expansion beyond the npm lane set; manager reconciliation at later PVs is expected, not resisted.
- No seeding of any other upstream version than the frozen 16.22.1 pin, even if upstream releases again mid-implementation (the bump smoke test simply targets whatever is newest then).

## Decisions

- **Update source `Npm "rulesync"`, technique `DepsAndAssets NpmEco`.** Alternative: GitHub source against `dyoshikawa/rulesync` releases — rejected: the ebuild consumes the npm tarball, and `npm-deps-assets` requires Npm source/technique pairing; a GitHub source would hard-fail apply.
- **Manual seed materialization inside the materialize image container**, mirroring the registry-only npm cache tarball steps (npm pack at the pinned version, npm cache population with empty userconfig, hermetic xz). Rationale: identical npm/cache layout to manager-produced tarballs and the cache is later consumed by host npm during emerge; the host node (26.x) would also work but the container removes toolchain drift. Alternative: host-side npm — rejected for consistency with the full-path contract.
- **Release publish via `gh release create` on `mndz-overlay-assets`** with the deps tarball as release asset and sidecars committed under `dev-util/rulesync/`; signed assets commit by the operator (GPG prompt stays host-side). Alternative: scripting the manager's internal publish code — rejected: not exposed as a command; hand steps are one-off.
- **Seed ebuild modeled on `dev-util/openspec`**, minus `shell-completion`: `S=${WORKDIR}/package`, deps tarball unpacked into `${T}`, offline global npm install into `${ED}/usr`, `src_test` offline temp-prefix install + `rulesync --help`. No completion USE flags (upstream has none at the pin; re-verify `rulesync --help` for a completion subcommand at seed time — if one appears, that is a content revision, not a spec change).
- **KEYWORDS = openspec's tilde set.** engines `>=22.0.0` may drop arches whose nodejs ceiling is below 22 on later rewrites; seeding with the openspec set keeps Portage usable immediately and lets the manager reconcile rather than hand-guessing portageq ceilings.
- **Spec home: enablement requirement in `npm-deps-assets` + dedicated `dev-util-rulesync-seed`.** The seed spec (autolith pattern) records the frozen pin and manual-assets provenance, which has no other home; the enablement requirement (openspec pattern) is the manager-side contract. Purpose line of the living `npm-deps-assets` spec is edited directly since delta Purposes for existing capabilities are ignored at archive.
- **Execution split:** agent writes all files, builds the deps tarball in the container, prepares release/manifest/gencache commands; operator runs `emerge` (root) and confirms GPG prompts for overlay and assets commits.

## Risks / Trade-offs

- [Upstream releases 16.24.0+ mid-implementation] → harmless: seed pin stays 16.22.1; `outdated`/`update` target the newest upstream PV at run time; the seed spec scenario "reports 16.22.1" is unaffected. If a release lands between plan and apply, re-run `outdated --refresh` (check-cache TTL is 5m by default) before `update`.
- [`rulesync` gains a completion subcommand before/at the pin] → seed-time verification; ebuild gains completion USE flags as a content revision; no spec change (the no-completions requirement is pinned-version-scoped).
- [npm cache layout drift between image npm and host npm] → already proven safe by openspec (cache built in image, consumed by host npm at emerge); seed mirrors the same producer/consumer split.
- [16.23.0 full-path unit fails (network, docker)] → hard-fail retains the unit `work/` directory for investigation; retry `update rulesync` after remediation; seed install is unaffected.
- [Sidecar/checksum mismatch on the manual seed] → the manager's reuse path verifies checksums before reuse; a mismatch surfaces as a hard-fail naming the release, fixable by re-publishing the 16.22.1 release.

## Migration Plan

1. Land manager policy + spec/test changes (`hk check` green) — inert until the seed exists.
2. Execute the seed (overlay ebuild + assets release + signed commits + `gencache`), emerge, operator smoke per `dev-util-rulesync-seed`.
3. Run the manager smoke (`outdated rulesync`, `update rulesync`), then emerge and offline-test the bumped PV.
4. Rollback: seed artifacts are additive; revert the seed commits in overlay/assets and `emerge -c` the package; the manager policy entry is harmless without an inventory match.

## Open Questions

None at capture time. (Deferred to seed execution, not blocking: whether `rulesync --help` exposes a completion subcommand at 16.22.1.)