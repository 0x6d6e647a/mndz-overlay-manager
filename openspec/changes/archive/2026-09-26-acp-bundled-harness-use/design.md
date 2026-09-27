# Design — optional bundled harness for the ACP adapters

## Context

See proposal.md for why. The live ebuilds are `dev-util/codex-acp/codex-acp-1.13.1.ebuild` and `dev-util/claude-agent-acp/claude-agent-acp-0.81.2.ebuild`. Both install the optional npm CLI unconditionally and die if that ELF is missing. `codex-acp` resolves `@openai/codex/bin/codex.js` unless `CODEX_PATH` is set. `claude-agent-acp` resolves the SDK platform ELF unless `CLAUDE_CODE_EXECUTABLE` is set. Gentoo `dev-util/claude-code` installs `/opt/bin/claude`. Overlay and guru `dev-util/codex` both install `/usr/bin/codex`.

`overlay-test-use` already requires a `-rN` when ebuild content changes and `PV` does not. `selectHighestNonLive` picks the highest PV, then the highest revision, as the donor the next bump copies. `setKeywords`, `ensureNodejsBdepend`, and `parameterizeAssetsSrcUriFor` do not rewrite `IUSE` or `src_install`.

## Goals / Non-Goals

**Goals:**

- Default emerge of each adapter runs the system harness through a wrapper and does not install the optional npm CLI.
- `USE=bundled-codex` or `USE=bundled-claude` restores the current install, including the ELF check and `dostrip -x`.
- The `-r1` body is the donor a later upstream bump copies, so the flag survives without manager code.

**Non-Goals:**

- Teaching materialize to pass `--omit=optional`. The deps tarball already contains the optional package, and a flag-off install skips it at emerge time.
- A versioned harness atom, an `env.d` file, or a keyword change.

## Decisions

- **Flag names `bundled-codex` and `bundled-claude`, default off.** `IUSE="bundled-codex test"` and `IUSE="bundled-claude test"` with no `+`. Same polarity as `bundled-jdk` and `bundled-libs`: the flag names the upstream copy, and the off state depends on the replacement. `metadata.xml` `<flag name="bundled-codex">` (and `bundled-claude`) says that enabling it installs the CLI bundled in the npm package.
- **Off state.** `npm install` gains `--omit=optional`. npm 11 `--global` still extracts the matching transitive optional platform package (`@openai/codex-linux-x64`, `@anthropic-ai/claude-agent-sdk-linux-x64`), because `--omit=optional` only drops optional dependencies of a project root. After that install, delete that platform directory, remove the npm symlink at `/usr/bin/<pn>`, and install a shell wrapper. The wrapper exports the harness variable only when it is unset, then `exec`s `node` on the adapter's `dist/index.js`. Codex uses `CODEX_PATH=/usr/bin/codex`. Claude uses `CLAUDE_CODE_EXECUTABLE=/opt/bin/claude`. `RDEPEND` gains `!bundled-codex? ( dev-util/codex )` or `!bundled-claude? ( dev-util/claude-code )` beside the existing nodejs atom. `BDEPEND="${RDEPEND}"` may keep expanding that atom. The harness is not required to build `--version`, and Portage installing it before the merge is harmless.
- **On state.** Omit the extra npm flag, leave the npm bin, run the existing ELF loop with `dostrip -x`, and do not emit the harness atom. `QA_PREBUILT` stays a static assignment in both states. An absent match is not a QA failure.
- **`src_test` follows the flag for `--omit=optional` only.** It keeps calling `--version` on the temporary-prefix bin. That command does not spawn the harness, so the test does not need the wrapper or a present ELF when the flag is off. `--help` and `-v` stay invalid smoke commands.
- **Revision files.** Publish `codex-acp-1.13.1-r1.ebuild` and `claude-agent-acp-0.81.2-r1.ebuild`. Delete the unrevised live files. Distfiles are unchanged, so thin-manifest `Manifest` stays. Regenerate md5-cache so the cache names are `codex-acp-1.13.1-r1` and `claude-agent-acp-0.81.2-r1`, and remove the unrevised cache files. One GPG-signed overlay commit.
- **No manager edit.** The next `update` copies this body, rewrites `KEYWORDS`, the nodejs atom, and `${PV}` inside asset URLs, and writes an unrevisioned ebuild for the new PV. The conditional `RDEPEND` is not a nodejs atom, so the nodejs rewrite leaves it alone.

## Risks / Trade-offs

- [The published deps tarball stays large] → expected. `--omit=optional` changes the image, not the distfile.
- [Atom closure counts `dev-util/codex` while `bundled-codex` defaults off] → the atom is unversioned, and overlay `codex-0.153.4` satisfies it, so a later bump is not blocked. A future minimum version would block until overlay Codex matches.
- [System Codex or Claude Code speaks an older app protocol than the adapter] → `--version` will not show that. A session will. The flag-on state is the escape hatch back to the npm CLI the adapter was published with.
- [`BDEPEND="${RDEPEND}"` pulls the harness into the build dependency] → the package still builds. Splitting `BDEPEND` back to only nodejs is unnecessary for the revision.
