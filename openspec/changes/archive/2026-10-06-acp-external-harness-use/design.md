# Design — external harness for the ACP adapters

## Context

See proposal.md for why. The live ebuilds are `dev-util/claude-agent-acp/claude-agent-acp-0.86.0.ebuild` and `dev-util/codex-acp/codex-acp-2.1.1.ebuild`. Each is a DepsAndAssets Npm package. `bundled-*` defaults off. Off installs with `--omit=optional`, deletes the transitive platform directory npm 11 still extracts, and replaces the npm bin with a wrapper. The wrapper exports `CLAUDE_CODE_EXECUTABLE=/opt/bin/claude` or `CODEX_PATH=/usr/bin/codex` when that variable is unset. `RDEPEND` carries `!bundled-claude? ( dev-util/claude-code )` or `!bundled-codex? ( dev-util/codex )`. On keeps the npm bin, requires the nested ELF, and calls `dostrip -x`.

Claude Code 0.86.0 returns `CLAUDE_CODE_EXECUTABLE` when that variable is non-empty, and otherwise resolves the SDK optional binary. `--version` and `-v` print the package version and exit before that lookup. Codex 2.1.1 spawns `CODEX_PATH` for a session and otherwise resolves `@openai/codex/bin/codex.js`. It does not search `PATH`. `--version` exits before that spawn.

`overlay-test-use` requires a `-rN` when ebuild content changes and `PV` does not. `selectHighestNonLive` picks the highest PV, then the highest revision, as the donor the next bump copies. `setKeywords`, `ensureNodejsBdepend`, and `parameterizeAssetsSrcUriFor` do not rewrite `IUSE`, `REQUIRED_USE`, or `src_install`. Atom closure treats a USE group as required and walks nested groups the same way.

## Goals / Non-Goals

**Goals:**

- `USE=external-claude` or `USE=external-codex` omits the npm CLI and does not depend on the Gentoo harness.
- Default USE and `USE=bundled-*` keep their current install results.
- The `-r1` body is the donor a later bump copies, so the flag survives without manager code.

**Non-Goals:**

- A wrapper, config file, or `PATH` search in the external state.
- Splitting `BDEPEND` away from `RDEPEND`.
- Teaching materialize to pass `--omit=optional`.

## Decisions

- **Flag names `external-claude` and `external-codex`, default off.** `IUSE="bundled-claude external-claude test"` and `IUSE="bundled-codex external-codex test"`, with no `+`. `REQUIRED_USE="?? ( bundled-claude external-claude )"` and the matching Codex line. `??` allows neither flag and rejects both. A default-on `system-*` flag would make existing `package.use` lines that set only `bundled-*` fail `REQUIRED_USE`. `package.provided` can hide the harness atom, and it tells every other consumer the Gentoo package is installed. `metadata.xml` describes `external-claude` as using a Claude Code executable supplied outside Portage via `CLAUDE_CODE_EXECUTABLE`, and `external-codex` as using a Codex executable supplied outside Portage via `CODEX_PATH`. The bundled-flag descriptions stay.
- **External state.** Pass `--omit=optional` whenever `bundled-*` is off, including external mode. After install, delete the same platform directory the default state deletes (`@anthropic-ai/claude-agent-sdk-linux-x64` or `@openai/codex-linux-x64`). Leave the npm bin. Do not write a wrapper and do not export either variable. `src_install` succeeds with the nested ELF absent and does not call `dostrip -x`.
- **Harness atom.** Nest the existing atom: `!bundled-claude? ( !external-claude? ( dev-util/claude-code ) )` and `!bundled-codex? ( !external-codex? ( dev-util/codex ) )`. `BDEPEND="${RDEPEND}"` stays, so external mode also drops the harness from the build dependencies. The atom stays unversioned.
- **Default and bundled states.** The neither-flag branch keeps the current wrapper and the Gentoo path. The bundled branch keeps the ELF check and `dostrip -x`. `QA_PREBUILT` stays a static assignment in every state.
- **`src_test`.** Pass `--omit=optional` when `bundled-*` is off, which covers external mode. Keep the `--version` check. That command does not read the harness variable, so the phase passes with the variable unset. `--help` stays an invalid smoke command. Codex also keeps `-v` invalid.
- **Revision files.** Publish `claude-agent-acp-0.86.0-r1.ebuild` and `codex-acp-2.1.1-r1.ebuild`. Delete the unrevised live files. Distfiles are unchanged, so the thin-manifest `Manifest` stays. Regenerate md5-cache for the `-r1` names, remove the unrevised cache files, and include the cache in the same overlay commit as the ebuilds. One GPG-signed overlay commit. Do not use manager `gencache` for that commit: `gencache` writes its own cache-only commit.
- **No manager edit.** The next `update` copies this body and rewrites `KEYWORDS`, the nodejs atom, and `${PV}` inside asset URLs. The nested harness atom is not a nodejs atom, so that rewrite leaves it alone.

## Risks / Trade-offs

- [Codex with `CODEX_PATH` unset fails by failing to resolve `@openai/codex`] → accepted with the env-var-only choice. Claude names `CLAUDE_CODE_EXECUTABLE` in its own error. An empty value is treated as unset by both adapters, so the variable has to be a real path.
- [A client spawned with a scrubbed environment does not see a shell export] → the ACP client config sets the variable. This design does not add a file the wrapper could read.
- [The deps tarball stays large] → expected. `--omit=optional` changes the image, not the distfile.
- [Atom closure still counts `dev-util/codex` while `external-codex` defaults off] → the nested group is still a USE group, and the unversioned overlay atom still satisfies closure.
- [The living seed requirement names the `-r1` file as the live ebuild] → the next upstream bump copies the body into an unrevisioned newer PV and this pin goes stale, which is the same shape as the bundled-flag requirement.

## Migration Plan

Operators who want the company binary add `external-claude` or `external-codex` to `package.use` and set `CLAUDE_CODE_EXECUTABLE` or `CODEX_PATH` in the session or the ACP client. Existing `bundled-*` lines stay valid. Machines that set neither new flag keep the Gentoo wrapper after they pick up the `-r1`.

Rollback is reverting that overlay commit, which restores the unrevised ebuilds, metadata, and md5-cache.
