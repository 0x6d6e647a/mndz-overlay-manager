# Tasks

## 1. codex-acp revision

- [x] 1.1 Add `dev-util/codex-acp/codex-acp-1.13.1-r1.ebuild` from the current `codex-acp-1.13.1.ebuild` and remove the unrevised file. Set `IUSE="bundled-codex test"` with no `+` on `bundled-codex`. Add `!bundled-codex? ( dev-util/codex )` on `RDEPEND` beside the nodejs atom. When `bundled-codex` is off, pass `--omit=optional` and replace `/usr/bin/codex-acp` with a wrapper that exports `CODEX_PATH=/usr/bin/codex` only when unset, then execs `node` on the adapter entrypoint. When the flag is on, keep the npm bin, `dostrip -x` the nested Codex ELF, and die if it is missing. Leave `QA_PREBUILT` unconditional. `src_test` passes `--omit=optional` only when the flag is off and still checks `--version` for `@agentclientprotocol/codex-acp ${PV}`. Verify the ebuild has no completion USE flags, does not install `/usr/bin/codex`, and does not depend on `dev-util/codex` outside the `!bundled-codex?` group.
- [x] 1.2 Describe `bundled-codex` in `dev-util/codex-acp/metadata.xml` as installing the Codex CLI bundled in the npm package. Verify the existing GitHub remote-id is unchanged.

## 2. claude-agent-acp revision

- [x] 2.1 Add `dev-util/claude-agent-acp/claude-agent-acp-0.81.2-r1.ebuild` from the current `claude-agent-acp-0.81.2.ebuild` and remove the unrevised file. Set `IUSE="bundled-claude test"` with no `+` on `bundled-claude`. Add `!bundled-claude? ( dev-util/claude-code )` on `RDEPEND` beside the nodejs atom. When `bundled-claude` is off, pass `--omit=optional` and replace `/usr/bin/claude-agent-acp` with a wrapper that exports `CLAUDE_CODE_EXECUTABLE=/opt/bin/claude` only when unset, then execs `node` on the adapter entrypoint. When the flag is on, keep the npm bin, `dostrip -x` the nested Claude ELF, and die if it is missing. Leave `QA_PREBUILT` unconditional. `src_test` passes `--omit=optional` only when the flag is off and still checks `--version` for `${PV}`. Verify the ebuild has no completion USE flags, does not install `/usr/bin/claude`, and does not depend on `dev-util/claude-code` outside the `!bundled-claude?` group.
- [x] 2.2 Describe `bundled-claude` in `dev-util/claude-agent-acp/metadata.xml` as installing the Claude CLI bundled in the npm package. Verify the existing GitHub remote-id is unchanged.

## 3. Overlay publish

- [x] 3.1 Regenerate package md5-cache for `dev-util/codex-acp-1.13.1-r1` and `dev-util/claude-agent-acp-0.81.2-r1`, and remove the unrevised cache files. Verify `Manifest` is unchanged. Verify `git status` in the overlay shows the two `-r1` ebuilds, the two removed unrevised ebuilds, both `metadata.xml` files, and the md5-cache updates.
- [x] 3.2 Operator: GPG-sign the overlay commit of that revision. Verify `git log --show-signature -1` in the overlay shows the signed commit.

## 4. Install smoke

- [x] 4.1 Emerge `=dev-util/codex-acp-1.13.1-r1` with default USE and the test USE flag. Verify `src_test` passes, `/usr/bin/codex-acp` is the wrapper, `codex-acp --version` prints `@agentclientprotocol/codex-acp 1.13.1`, and the nested Codex ELF is absent.
- [x] 4.2 Emerge `=dev-util/claude-agent-acp-0.81.2-r1` with default USE and the test USE flag. Verify `src_test` passes, `/usr/bin/claude-agent-acp` is the wrapper, `claude-agent-acp --version` prints `0.81.2`, and the nested Claude ELF is absent.
- [x] 4.3 Re-emerge each package with `bundled-codex` or `bundled-claude` enabled and the test USE flag. Verify the nested ELF is present and unstripped, the `/usr/bin` command is the npm bin, and `--version` still prints the same string.

## 5. Integration gate

- [x] 5.1 Run `openspec validate acp-bundled-harness-use --type change --strict` and confirm zero issues. Confirm the living seed Purpose lines name `bundled-codex` and `bundled-claude`, and that no delta-residue language ("in this change", "as today") is in the living specs.
- [x] 5.2 Run `hk check` and confirm it is green.
