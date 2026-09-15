## Context

See proposal.md for motivation. Overlay `dev-util/opencode` is a donor-template ebuild: apply git-mvs PV and rewrites KEYWORDS / BDEPEND / SRC_URI. It does not invent monorepo `src_compile` bodies. Upstream 2.x moved the CLI to `packages/cli`, renamed the web-UI skip flag, replaced yargs completions with Effect `--completions`, and bundled the models catalog. Spikes: `+webui` compile succeeded offline in docker `--network=none` with `bun-1.4.2`; `--completions bash|zsh|fish` emit scripts; `src_test` is 246–247 pass / 16–17 fail (ACP subprocess stdout is not pure JSON-RPC).

Installed `bun-bin-1.4.2` on some hosts still matches the pre-slot `doexe bun` layout because commit `e0f6d16` edited that PV in place without `-r1`.

## Goals / Non-Goals

**Goals:**

- Human-owned v2 donor ebuild at `opencode-2.0.3-r1` that compile/install/test under `network-sandbox`.
- Manager keeps `bun-<exact>` in the ebuild body in sync with the probed pin on later bumps.
- Fail closed when the donor compile cwd or `script/build.ts` is missing from the cloned tag.
- Stop models companion production; reuse existing 2.0.3 deps tarball.
- Revbump `bun-bin-1.4.2` so `bun-1.4.2` exists after emerge.

**Non-Goals:**

- Auto-rewriting compile cwd names.
- Patching `updater.run()` or making ACP tests pass.
- Assets republish or GitHub asset deletion.
- Changing BunCache (ralph-tui) packaging.

## Decisions

### D1 — Donor ebuild is the v2 contract; manager rewrites bun-exact only

**Choice:** Hand-edit overlay `opencode-2.0.3-r1` for paths, flags, completions, wrapper, channel, models SRC_URI drop. Manager apply continues to rewrite BDEPEND and **also** rewrites `bun-<digits>` command tokens to `bun-<exact>` (compile and test). Do not parse or rewrite `cd packages/…`.

**Why:** Original non-goal was inventing `src_compile` bodies. The bun pin mismatch is mechanical and already spec’d as a contract. Cwd names are convention, not data.

**Alternative:** Full ebuild codegen — rejected; too much monorepo knowledge in the manager.

### D2 — Fail-closed cwd + build.ts after clone

**Choice:** After the existing GitHub clone on the full path, require the ebuild’s `src_compile` `cd` target and `script/build.ts` under it. Hard-fail with the missing path. No guessed rename.

**Why:** Would have blocked publishing 2.0.3. Cheap; clone already happens for InstallTree.

**Alternative:** Also require ebuild flags to appear in `build.ts` `process.argv.includes` — deferred; easy to overfit.

### D3 — Wrapper for autoupdate, not a source patch

**Choice:** Install the compiled ELF under `/usr/libexec` (or equivalent) and `/usr/bin/opencode` as a shell wrapper that exports `OPENCODE_DISABLE_AUTOUPDATE=1` and execs the ELF. Completions run the wrapper (env is set). Do not export `OPENCODE_DISABLE_MODELS_FETCH` from the wrapper. Portage phases MAY set that env for sandbox. Comment that Gentoo updates are `emerge`, not `opencode upgrade --method curl`.

**Why:** First-class upstream env; Nixpkgs `wrapProgram --set`; covers TUI and background-service `updater.run()` call sites. Gentoo `make_wrapper` cannot set env.

**Alternative:** Patch `default.ts` — misses `server-process.ts`; bitrots.

### D4 — Completions are Effect `--completions`

**Choice:** `opencode --completions bash|zsh|fish`; add opt-in `IUSE=fish-completion`; keep `addwrite /sys/kernel/debug/tracing`. Never `opencode completion` (parsed as TUI directory, exits 0 after error).

**Why:** Spiked on source and compiled ELF. `newfishcomp` exists in `shell-completion.eclass`.

### D5 — Drop models companion; keep InstallTree deps

**Choice:** Remove opencode from Adequacy extras / `materializeCompanionAssets`. Required basenames = deps tarball only. Ebuild `-r1` drops models `SRC_URI`. Do not republish 2.0.3 deps. Leave GitHub `opencode-2.0.3-models.json` unused.

**Why:** v2 compile uses bundled snapshot; spike compile did not need the distfile.

### D6 — bun-bin-1.4.2-r1

**Choice:** Copy/revbump the current SLOT=0 template to `bun-bin-1.4.2-r1.ebuild` (same `newbin bun-${PV}` + symlinks). Satisfies `overlay-test-use` mandatory `-rN` for content that already landed in-place.

**Why:** Compile-pin invocation is `bun-1.4.2`. Stale 1.4.2 installs lack that name until rebuild.

### D7 — Keep live src_test

**Choice:** `cd packages/cli`; `bun-<exact> test --timeout 30000 --only-failures`; `IUSE=test`; `RESTRICT="strip !test? ( test )"`. Do not exclude failing files.

**Why:** Default emerge does not run tests. `FEATURES=test` users see the real suite (ACP subprocess fail). Operator chose not to squelch.

### D8 — Channel `prod`, binary `opencode`, `+webui` default

**Choice:** `OPENCODE_CHANNEL=prod` at compile (Nixpkgs / upstream release CI). Install `/usr/bin/opencode` (wrapper). `IUSE=+webui`; `-webui` passes `--skip-web-ui`. `NODE_OPTIONS=--max-old-space-size=4096` in `src_compile`.

**Why:** Spiked; official tagged builds use `prod`. Nix store PATH wrap for ripgrep is not needed (`RDEPEND=sys-apps/ripgrep`).

## Risks / Trade-offs

- **[Risk] FEATURES=test emerge fails** → Accepted; default USE=-test. Comment in ebuild.
- **[Risk] bun-exact rewrite hits comments** (`e.g. 1.3.14`) → Restrict rewrite to command tokens (`bun-X.Y.Z` as a word in `src_compile`/`src_test`), not free text in comments.
- **[Risk] Wrapper breaks `opencode --version` argv0** → Exec the ELF with `"$@"`; spike `--version` on the ELF already works. Verify wrapper after install.
- **[Risk] Next upstream cwd rename** → Clone-time guard hard-fails instead of shipping a broken ebuild; human updates the donor.
- **[Risk] Completions still open trace_marker** → Keep `addwrite`.
- **Trade-off:** Extra unused models.json on the 2.0.3 assets tag vs deleting it. Leave it.

## Migration Plan

1. Manager: bun-exact body rewrite, cwd/`build.ts` guard, drop models companion, tests, spec merge.
2. Overlay: `bun-bin-1.4.2-r1`; `opencode-2.0.3-r1` (Manifest without models DIST); md5-cache; signed commits.
3. Operator: `emerge -u =dev-lang/bun-bin-1.4.2-r1 =dev-util/opencode-2.0.3-r1`; `opencode --version` → `2.0.3`; `which bun-1.4.2`.
4. Rollback: revert overlay `-r1` files and manager commit; 2.0.3 donor remains broken to emerge.

## Open Questions

None. Spikes and operator choices (wrapper, live tests, bun-bin `-r1`, leave orphan models.json, fail-closed cwd+build.ts) are locked.
