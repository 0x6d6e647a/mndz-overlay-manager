# Proposal

## Why

`dev-util/claude-agent-acp` and `dev-util/codex-acp` can install the npm CLI or depend on the Gentoo harness (`dev-util/claude-code`, `dev-util/codex`). A work machine that must run a company-vendored Claude Code or Codex has neither choice: the default install pulls the Gentoo package, and `bundled-*` installs the npm CLI. The adapters already accept `CLAUDE_CODE_EXECUTABLE` and `CODEX_PATH`, so the ebuild can omit both copies and leave the path to the operator.

## What Changes

- Add a default-off local USE flag on each package: `external-claude` and `external-codex`. `metadata.xml` describes the flag, including the environment variable the operator sets.
- `REQUIRED_USE` allows at most one of `bundled-*` and `external-*`. Neither flag remains the Gentoo-harness install.
- Flag `external-*`: `npm install --omit=optional`, delete the transitive platform directory npm still extracts, leave the npm bin in place, and declare no harness atom. The ebuild does not export a default path and does not install a wrapper.
- Neither flag, and `bundled-*` enabled, stay as they are: the Gentoo wrapper plus unversioned harness atom, or the nested ELF with `dostrip -x` and no harness atom.
- Publish `claude-agent-acp-0.86.0-r1` and `codex-acp-2.1.1-r1` from the live ebuild bodies. No manager code change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `dev-util-claude-agent-acp-seed`: the live donor body gains default-off `external-claude`, mutually exclusive with `bundled-claude`. External mode omits the optional npm CLI, leaves the npm bin, and does not depend on `dev-util/claude-code`. The operator supplies `CLAUDE_CODE_EXECUTABLE`.
- `dev-util-codex-acp-seed`: the same split for default-off `external-codex`, `CODEX_PATH`, and no dependency on `dev-util/codex`.

## Non-goals

- A config file, `env.d` entry, or `PATH` lookup for the company binary. The operator or the ACP client sets the variable.
- Shrinking the deps tarball. `--omit=optional` changes the image, not the distfile.
- A versioned harness atom, a keyword change, or a manager rewrite of `IUSE` or `src_install`.
- Blocking `dev-util/claude-code` or `dev-util/codex` when the external flag is on. The packages may stay installed for another reason.
- A session smoke against a company binary. Acceptance is the install shape and `--version` with the variable unset.
- README, CONTRIBUTING, or AGENTS edits. This does not change the manager CLI or the quality pipeline.

## Impact

- Overlay ebuilds and `metadata.xml` for `dev-util/claude-agent-acp` and `dev-util/codex-acp`, plus regenerated md5-cache. Thin manifests stay, because distfiles do not change.
- Living seed specs `dev-util-claude-agent-acp-seed` and `dev-util-codex-acp-seed`.
- Atom closure still treats the nested `dev-util/codex` conditional as required while `external-codex` defaults off. `dev-util/claude-code` stays outside the overlay, so closure ignores it.
- The next `update` copies the `-r1` body. Asset URL, `KEYWORDS`, and the nodejs atom are the rewrites; the new flag survives without manager code.
