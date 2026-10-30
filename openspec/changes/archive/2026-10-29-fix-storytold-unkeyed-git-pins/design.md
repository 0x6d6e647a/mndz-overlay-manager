# Design

## Context

See proposal.md for why the twelve emerges die. The helper that dies is `mndz-cargo_rewrite_patch_git_pins` in the overlay eclass `/home/mndz/repos/com.github/0x6d6e647a/mndz-overlay/eclass/mndz-cargo.eclass`. It runs from `src_prepare` after `default`. `::gentoo` `cargo.eclass` calls `cargo_gen_config` from `cargo_src_unpack`, which is before `src_prepare`. That function overwrites `${ECARGO_HOME}/config.toml`, and `_cargo_gen_git_config` emits one `[patch.'<git-url>']` path line per `GIT_CRATES` key.

Two different Cargo inputs are in play:

```
manifest [patch.crates-io] git pin     workspace git = url, rev
        │                                      │
        ▼                                      ▼
rewrite the line to a path              config.toml [patch.'<git-url>']
(Cargo 1.97 ignores a config patch      (written from GIT_CRATES by
 for a pin written in the manifest)      cargo_gen_config)
```

`egui`, `eframe`, and the unused egui workspace members are manifest patch pins. `craft-update` is a workspace git dependency. The strip that dropped those keys is `stripWindowsOnlyGitCrates` in `src/Update/EbuildEdit.hs`. It treats every `TIgnore` name from `collectClassifiedDeps` as windows-only or wasm-only, including when another manifest in the same tree names that crate from a Linux dependency. `cfg(not(target_arch = "wasm32"))` is already `TActive` for Linux. `cfg(windows)` and `cfg(target_arch = "wasm32")` are `TIgnore`.

## Goals / Non-Goals

**Goals:**

- One eclass change makes the twelve already-published ebuilds able to pass `src_prepare` and resolve `craft-update` offline.
- The next Cargo GitTag rewrite keeps a lock git package that any non-windows, non-wasm edge of the active set names.
- Fail closed when a pin or a lock git package cannot be placed on exactly one fetched checkout.

**Non-Goals:**

- A second copy of the matcher in Haskell. The eclass stays the only prepare implementation.
- Editing the twelve ebuilds, their Manifests, or `::gentoo` `cargo.eclass`.
- Counting `[dev-dependencies]` as keep-edges. `collectClassifiedDeps` already skips them.
- Rewriting workspace git lines into path dependencies.

## Decisions

### 1. Resolve a missing patch pin from the archive already unpacked for that rev

Keep the current `(name, rev)` → `GIT_CRATES` directory rewrite. When that key is absent, search only the archive roots of `GIT_CRATES` entries with that same full commit. An archive root is `${WORKDIR}` plus the first path component of the entry's directory after `%commit%` is replaced. Find a `Cargo.toml` whose `[package].name` equals the pin name. Exactly one match: rewrite the pin to that file's directory, the same way a keyed pin is rewritten (`path`, keep `version` and `features`, drop `git` / `rev` / `branch` / `tag`). Zero matches, or two archive roots that both contain the package: die with the existing prepare failure. Do not insert a `GIT_CRATES` key for a pin that was rewritten to a path. The manifest path is what Cargo 1.97 reads, and a config `[patch]` line is the other mechanism.

Alternative considered: delete unused patch lines such as `egui_demo_lib`. Rejected. Those lines exist so a transitive crates.io crate cannot mix with the fork. A path into the already-unpacked tree keeps that pin offline.

Alternative considered: republish `GIT_CRATES` rows for every patch member. Rejected for these twelve ebuilds. The tarball is already fetched, and the next update still needs the prepare fallback whenever upstream lists a member the lock does not use.

### 2. Register a missing direct git package, then regenerate Cargo's config

After the manifest rewrite succeeds, scan `Cargo.toml` files under `${S}` only. A one-line `git` + `rev` dependency that is still a git pin was outside `[patch.*]`. For each such package, if `Cargo.lock` records it as a `git+` source at that full commit and `GIT_CRATES` has no key:

- Exactly one archive root for that commit contains the package's `Cargo.toml`: append a `GIT_CRATES` entry. Copy the git URL from a sibling entry of that commit. Set the directory to the package directory with the commit spelled `%commit%`, so `craft-update` becomes `craft-libs-%commit%/crates/update`.
- No such root, or more than one: die before `src_compile`. Leave the workspace line unchanged.
- The lock does not record the package: leave it unregistered. That is a Windows-only or wasm-only pin the Linux resolve did not select.

Then, only if at least one key was added, call `cargo_gen_config` again. Unpack already wrote `config.toml` without the new key, and `cargo_src_compile` does not write it again. `cargo_gen_config` replaces the file, so the second call is the whole config, not an appended `[patch]` table. Do not call it when no key was added.

Alternative considered: hand-add `craft-update` to the nine ebuilds. Rejected. The same strip will drop it on the next update, and the eclass backstop is what makes the published ebuilds merge.

### 3. Drop a git crate only when every edge is windows-only or wasm-only

Change `stripWindowsOnlyGitCrates`, not the MSRV active-set walk. Across every `Cargo.toml` body it already receives, take the `collectClassifiedDeps` edges. Drop a lock git name only when at least one edge is `TIgnore` and no edge is anything else (`TActive`, `TWatched`, or `TIncomplete`). A name that is `TIgnore` in `apps/*-web` or under `cfg(windows)` and `TActive` in `crates/ui-egui` stays. A name that appears only under `wasm32` or `cfg(windows)` is still dropped, which keeps the Codex `mxc` case.

`not(target_arch = "wasm32")` stays classified by the existing cfg evaluator. Do not add a second parser.

Alternative considered: per-file filtering inside `windowsOnlyDepNames` only. Rejected. `egui` and `craft-update` are Linux deps in one manifest and wasm or Windows deps in another. A per-file "only" list, unioned across files, still drops them.

### 4. Proof

Haskell tests in `test/Test/EbuildEdit.hs` cover the strip: the existing `mxc` case stays dropped, a crate named only from `wasm32` is dropped, and a crate named from both a Linux dependency and a wasm or Windows table stays, including across two manifests.

The eclass is proved by the operator emerging two atoms, with the agent not running `sudo`:

- `media-video/effectcraft-0.18.0` dies today on the `egui` pin and is one of the nine missing `craft-update`.
- `app-text/pdfcraft-0.15.0` already has `egui` in `GIT_CRATES` and dies on `egui_system_font_provider`, and it is also missing `craft-update` at the other craft-libs commit (`e11f9d9`).

The other ten atoms use the same helper. The operator can re-emerge them without a further code change. Archive waits on those two emerges, matching the earlier patch-pin change.

## Risks / Trade-offs

- [Second `cargo_gen_config` rewrites jobs, offline, and vendor paths] → Call it only after a successful rewrite and only when a key was added. It writes the same file unpack already wrote, plus the new patch lines.
- [A path patch and a config git patch for the same package] → Do not add `GIT_CRATES` keys for manifest pins that were rewritten to `path`. Reserve new keys for workspace lines that stay `git`.
- [Package name differs from the directory name] → Match `[package].name`, not the directory. `egui_system_font_provider` and `craft-update` (`crates/update`) both need that.
- [Search escapes into `${S}` or another repo] → Search only archive roots of entries with that commit. Two roots that both contain the package die.
- [The inline Python has no Haskell test] → The two operator emerges are the prepare/compile proof. The strip has unit tests.
- [`TIncomplete` keeps a crate] → An unparsed edge is not known to be windows-only or wasm-only, so the omit rule does not apply. That can fetch a crate the old strip dropped. Prefer that over dropping a Linux crate whose cfg we failed to read.

## Migration Plan

1. Edit the overlay eclass. Leave it uncommitted for the operator to sign.
2. Edit the manager strip and tests. `just check` is the manager gate.
3. The operator re-emerges EffectCraft and PdfCraft. Rollback is reverting the eclass and the strip. The published ebuilds and Manifests stay as they are, so rollback returns to the current prepare failure. No distfile or VDB migration.
