# Proposal: optional bundled harness for the ACP adapters

## Why

`dev-util/codex-acp` and `dev-util/claude-agent-acp` always install the optional npm CLI (a static-pie Codex binary, or the glibc Claude ELF). Operators who already have `dev-util/codex` or gentoo `dev-util/claude-code` still download and install a second copy. The adapters already honor `CODEX_PATH` and `CLAUDE_CODE_EXECUTABLE`, so the default install can point at the system harness and keep the npm copy as an opt-in.

## What Changes

- Revise the live ebuilds in place as content-only fixes, per `overlay-test-use`: `codex-acp-1.13.1-r1.ebuild` and `claude-agent-acp-0.81.2-r1.ebuild`. No new upstream PV. Distfiles stay the same, so `Manifest` is unchanged under thin manifests. Regenerate package md5-cache. GPG-sign the overlay commit.
- Add a default-off local USE flag on each package: `bundled-codex` and `bundled-claude`. `metadata.xml` describes the flag.
- Flag off (the default): `npm install --omit=optional`, no nested ELF, and a wrapper at the adapter's `/usr/bin` path. `codex-acp` sets `CODEX_PATH=/usr/bin/codex` and `RDEPEND` includes unversioned `dev-util/codex`. `claude-agent-acp` sets `CLAUDE_CODE_EXECUTABLE=/opt/bin/claude` and `RDEPEND` includes unversioned `dev-util/claude-code`. The wrapper sets the variable only for that process.
- Flag on: today's install. The nested ELF is required, `dostrip -x` runs, there is no wrapper, and there is no harness `RDEPEND`. `QA_PREBUILT` stays unconditional.
- `src_test` uses the same USE state for its offline install. `--version` remains the smoke command in both states.
- The ebuild body is what the next `update` copies onto a newer PV. No manager code, policy, or materialize change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `dev-util-codex-acp-seed`: the live ebuild body gains default-off `bundled-codex`. Flag off omits the optional npm CLI, wraps `codex-acp` with `CODEX_PATH=/usr/bin/codex`, and `RDEPEND`s on `dev-util/codex`. Flag on keeps the nested ELF, `dostrip -x`, and no harness dependency. `IUSE` is `bundled-codex` and `test`.
- `dev-util-claude-agent-acp-seed`: the same split for default-off `bundled-claude`, `CLAUDE_CODE_EXECUTABLE=/opt/bin/claude`, and `RDEPEND` on `dev-util/claude-code`.

`overlay-test-use` already requires a `-rN` for non-PV ebuild edits. This change follows that requirement and does not alter it.

## Impact

- **Overlay repo**: replace `codex-acp-1.13.1.ebuild` with `codex-acp-1.13.1-r1.ebuild` and `claude-agent-acp-0.81.2.ebuild` with `claude-agent-acp-0.81.2-r1.ebuild`. Update each `metadata.xml` and the package md5-cache. One signed overlay commit. No assets release.
- **Manager**: no Haskell, policy, or planning change. A later bump copies the `-r1` body (highest non-live donor) into the new PV's unrevisioned ebuild, including `IUSE`, the wrapper, and the conditional `RDEPEND`.
- **Atom closure**: `!bundled-codex? ( dev-util/codex )` is an overlay atom inside a USE conditional, so closure treats it as required even while the flag defaults off. Overlay `dev-util/codex-0.153.4` satisfies the unversioned atom, so a later `codex-acp` bump is not blocked. `dev-util/claude-code` is not an overlay package, so closure ignores it and Portage still pulls the gentoo package.
- **Docs**: no operator CLI, config, quality-pipeline, or agent-process change. README, CONTRIBUTING, and AGENTS stay as they are.
- **Specs**: deltas on the two seed specs. Living Purpose lines gain the default-off flag, because a delta Purpose is ignored at archive.

## Non-goals

- No second deps tarball and no `--omit=optional` at materialize time. The published cache stays fat. The flag changes the installed image, not the download.
- No version bound on `dev-util/codex` or `dev-util/claude-code`.
- No `env.d` entry. The variable is set only by the adapter wrapper.
- No change to `KEYWORDS`, the amd64 allowlist, or the nodejs atom.
- No manager special case for these flags. The copied ebuild body is the whole mechanism.
- No session-level ACP smoke. `--version` does not start the harness.
