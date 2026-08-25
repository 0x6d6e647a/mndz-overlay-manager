## Context

See `proposal.md` for motivation. Live overlay atom at proposal time is `dev-util/autolith-0.32.2-r2` (`LICENSE` inventory + two dests). Seed identity in `dev-util-autolith-seed` remains v0.17.2; apply already preserves template body and rewrites only KEYWORDS, SBCL floor atom, and deps `SRC_URI`.

Emerged `-r2` share is `cp -a "${S}/."`: GitHub tag + copied `.qlot/` + `git init`/`add --all`/`commit` on the full checkout (`.qlot/` gitignored). Deps tarball `autolith-0.32.2-deps.tar.xz` was packed before hermetic conf rules and still contains `/home/mndz/quicklisp/...` in `qlot.conf` / `source-registry.conf`. That tarball is **not** republished; `-r3` copies those confs as-is.

OpenSpec lives only in mndz-overlay-manager. Overlay implementation lands in mndz-overlay. Manager Haskell changes Sbcl materialize for the **next** Autolith PV.

## Goals / Non-Goals

**Goals:**

- One overlay commit: `-r2` → `-r3` on the live PV (install set, git pack, ColorLisp C strip after the `.so`).
- Manager: packed qlot confs with no `/home/` pathnames; slimmer `fff/` for offline `fff-c`.
- Seed + `sbcl-deps-assets` + `hermetic-asset-materialize` deltas so later apply copies the pruned body and later materialize emits clean confs.
- Operator smoke on `-r3`.

**Non-Goals:**

- Republishing `autolith-0.32.2-deps.tar.xz` or ebuild-rewriting leaky confs.
- Renaming `.qlot`; deleting `.git`; PV / KEYWORDS / LICENSE / FHS dest / apply-field changes.
- Installing `tests/` for `USE=test`.

## Decisions

### 1. Live PV is `-r3`, not a new PV

- Replace `autolith-0.32.2-r2.ebuild` with `autolith-0.32.2-r3.ebuild` (or `-rN` on whatever PV is live).
- One live ebuild per Autolith PV so exact-set prune stays correct.
- **Alternative — wait for the next Autolith tag:** rejected; install cruft is independent of upstream PV.

### 2. Prune before `git add`, then pack the repo

Tracked Autolith files (`tests/`, `docs/`, `server/`, `.github/`, flakes) must leave `${S}` **before** `git add --all`. Checkpoint `git status --porcelain` has no path limiter; deleting after the commit dirties HEAD. `.qlot/` is gitignored, so ColorLisp C and other `.qlot` leaves can be stripped after the commit without dirtying git.

After commit: `git gc --quiet --prune=now`; `rm .git/hooks/*.sample`; `rm .git/index` then `git read-tree HEAD` (Nix: stat-less index on a root-owned prefix). Recreate a loose `refs/heads/master` after gc so `.git/refs` is non-empty: Portage drops empty image dirs, and Git will not treat the tree as a repository without `refs/`. Wrapper already sets `GIT_OPTIONAL_LOCKS=0` and `safe.directory` to share.

- **Alternative — delete `.git`:** rejected; recovery/active identity and `self-git-command` need a repo.
- **Alternative — `git add` then prune:** dirty status at runtime.

### 3. Explicit install set, not `cp -a "${S}/."`

Copy the keep list (Lisp, pruned `.qlot`, packed `.git`, launchers, recovery/image scripts, `sbcl-source-releases.sha256`, synthetic `sbcl-source`). Do not copy the omit list in the seed spec.

`docs/`: omit 0.32.2 human-only org and `releases/`. Do **not** encode `rm -rf docs`. If a future tag has `docs/system-prompt.org` / `docs/request-context.org`, those files stay (prompt load in later Autolith).

`USE=test` / `src_test` stay the offline load/version check. `tests/` in `${S}` during `src_test` is unused today; they MUST NOT be installed.

### 4. ColorLisp C strip after the `.so`

Wrapper always sets `COLORLISP_NATIVE_LIBRARY` to the libdir `.so`. The `.so` embeds `tree_sitter_*`; Lisp reads `languages/*.scm` and passes query bytes into the `.so`. `parser.c` is never opened at runtime on that path.

Strip `vendor/grammars`, `vendor/tree-sitter`, `vendor/common`, and `native/colorlisp-tree-sitter.c` at install. Keep C in the deps tarball for `src_compile`. Direct `/usr/share/autolith/bin/autolith` without the wrapper remains unsupported (FHS).

- **Alternative — strip C from the tarball:** rejected; compile still needs it.

### 5. Qlot confs: drop builder keys, no home substitution

`qlot-99-setup.lisp` loads `source-registry.conf` first. Autolith launchers `load` `${source_root}/.qlot/setup.lisp`. Dist systems come from `.qlot/dists`; `autolith.asd` from the project walker. The builder `:directory` / `:qlot-source-directory` / `:setup-file` are qlot-the-tool checkout paths, invalid at emerge.

After `qlot install`, emit:

```lisp
(:source-registry
 :ignore-inherited-configuration
 (:also-exclude ".qlot")
 (:also-exclude ".bundle-libs"))
```

and drop `:qlot-source-directory` / `:setup-file` from `qlot.conf` (keep `:qlot-version` if present). Hard-fail if `/home/` remains. Do not replace operator home with `/home/builder`.

Existing `sanitizeQlotConfs` (operator home → `/home/builder`) is the wrong invariant; replace it.

Live 0.32.2 tarball is left leaky. Next Autolith PV rematerialize is the cleanup. Ebuild does not rewrite confs (would be a 0.32.2-only wart on the template apply copies).

- **Alternative — ebuild rewrite on unpack:** rejected; manager going forward, template stays clean.
- **Alternative — rewrite to `/home/builder`:** rejected; equally invalid at runtime.

### 6. Fff pack is workspace + vendor, not the git checkout

`cargo build --offline --locked -p fff-c` loads the workspace (`Cargo.toml` members including `fff-c`, `fff-core`, …). Keep those `Cargo.toml` trees, lockfile, `vendor/`, `.cargo/config.toml`. Omit `plugin/`, `lua/`, `tests/`, `.github/`, flakes, node `packages/` after a cargo smoke on the stripped tree. `fff/.git` already removed.

Takes effect on the next full-path Autolith materialize, not `-r3`.

### 7. Manager vs overlay sequencing

Overlay `-r3` does not depend on the Haskell landing first. Manager hygiene does not change `-r3`’s copied confs. Spec deltas live in mndz-overlay-manager; overlay files live in mndz-overlay.

Update living `dev-util-autolith-seed` Purpose (install-set pruning) when applying this change’s spec work; deltas do not replace Purpose.

## Risks / Trade-offs

- **[Risk]** `git status --porcelain` in the fabricated-git scenario needs `safe.directory` on a root-owned tree → **Mitigation:** wrapper already exports it; smoke can set `GIT_CONFIG_*` the same way.
- **[Risk]** Future Autolith tag adds `docs/system-prompt.org` → **Mitigation:** omit-list is named files / human-only docs, not `rm -rf docs`.
- **[Risk]** Unset `COLORLISP_NATIVE_LIBRARY` cannot rebuild the highlighter `.so` → **Mitigation:** accepted; product entrypoint is `/usr/bin/autolith`.
- **[Risk]** Cargo workspace membership changes and a stripped `fff/` fails `fff-c` → **Mitigation:** offline cargo smoke is a materialize hard-fail, not best-effort.
- **[Risk]** `-r3` image still has `/home/mndz/...` in qlot confs → **Mitigation:** accepted; next Autolith PV rematerialize.
- **[Risk]** `-r3` rebuild is long (natives + both cores) → **Mitigation:** expected; smoke is not Manifest-only.

## Migration Plan

1. Overlay: `autolith-<PV>-r3.ebuild` (pruned install, git pack, ColorLisp C strip), Manifest, package cache; delete `-r2` filename; one commit.
2. Manager: replace qlot conf sanitizer; strip unused fff trees; tests; spec deltas + Purpose line; `openspec validate` / `hk check`.
3. Operator: `emerge -av1 =dev-util/autolith-<PV>-r3` then `autolith --version`.
4. Next Autolith PV bump (separate change): full-path materialize produces a clean deps tarball; apply copies the `-r3` body.

## Open Questions

(none)
