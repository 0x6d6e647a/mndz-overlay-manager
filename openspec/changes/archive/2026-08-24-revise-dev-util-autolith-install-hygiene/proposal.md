## Why

Emerged Autolith still `cp -a`s the full source checkout plus `.qlot/` into `/usr/share/autolith`. That ships Nix CI, the release server, tests, contributor docs, ColorLisp `parser.c` (~141M, already linked into `libcolorlisp-tree-sitter.so`), and a fabricated `.git` full of sample hooks and loose objects. Packed `.qlot` confs also embed the materialize host’s `/home/...` qlot checkout, which is not valid at emerge or runtime. Hygiene after the FHS split; Autolith PV is unchanged.

## What Changes

- On the **live** Autolith PV (currently `0.32.2`; if PV has moved, apply `-rN` on that live atom): replace `autolith-<PV>-r2.ebuild` with `autolith-<PV>-r3.ebuild`. **Install set only.** Keep two dests, LICENSE, KEYWORDS, SBCL floor, and deps `SRC_URI`. Working tree has only `-r3` after the commit.
- Share dest keeps Autolith Lisp (`src/`, `autolith.asd`, `qlfile*`, `sbcl.version`), `.qlot/` needed at runtime, fabricated `.git` (gc + stat-less index, no sample hooks; fabricate **after** pruning tracked junk so HEAD matches the installed tree), launchers the wrapper execs, recovery scripts hashed into cores, `sbcl-source-releases.sha256`, synthetic `sbcl-source`.
- Share dest SHALL NOT install: `.github/`, `flake.nix`/`flake.lock`/`nix/`, `server/`, `bin/autolith-release`, `script/install`, `script/bootstrap`, `qlot-install.lisp`, `build-fff*`, `sbcl-source.sha256`, `native/fff/`, `tests/`, 0.32.2 human-only `docs/` (not a blanket `rm -rf docs` — later tags that load `docs/system-prompt.org` / `docs/request-context.org` must keep those files), packaged `AGENTS.md` / `AUTOLITH.org`.
- After `libcolorlisp-tree-sitter.so` is built, strip ColorLisp vendor C (`vendor/grammars`, `vendor/tree-sitter`, `native/colorlisp-tree-sitter.c`) from the **install**. Keep `languages/` queries, ColorLisp Lisp, and the C in the deps tarball for compile. Strip other agreed `.qlot` leaves (tmp, sandbox `build/` helper, bordeaux-threads `docs/`, ironclad `testing/`, cffi `doc/`/`tests`/`examples`, nested `.github/`). Keep local-time `zoneinfo/` and ironclad `doc/` (an `ironclad/core` component).
- Manager full-path Sbcl materialize: after `qlot install`, packed `.qlot/qlot.conf` and `source-registry.conf` SHALL contain **no `/home/` pathnames** (not operator, not `/home/builder`). Drop `:qlot-source-directory`, `:setup-file`, and the builder `:directory` entry; keep also-exclude. Do **not** rewrite those keys to a generic builder home.
- Manager fff pack: keep cargo workspace members needed for `cargo build --offline --locked -p fff-c` plus `vendor/` and `.cargo/`; omit neovim/lua/plugin/tests/`.github`/node `packages/` after an offline `fff-c` smoke.
- **Do not republish** `autolith-0.32.2-deps.tar.xz`. The live `-r3` image keeps today’s leaky confs and fat fff tarball until the **next Autolith PV** rematerializes. The ebuild SHALL NOT grow a 0.32.2-only conf rewrite.
- Delta `dev-util-autolith-seed`, `sbcl-deps-assets`, and `hermetic-asset-materialize`. Seed identity remains v0.17.2 archaeology. Apply still only rewrites KEYWORDS, SBCL floor atom, and deps `SRC_URI`.
- Operator smoke: emerge `=dev-util/autolith-<PV>-r3` and `autolith --version`.

## Non-goals

- No rename of `.qlot` (qlot/Autolith ABI).
- No deletion of the fabricated `.git` (recovery/active provenance and `self-git-command`).
- No ebuild rewrite of qlot confs; no forced rematerialize of the live deps tarball.
- No Autolith PV bump; no KEYWORDS / SBCL floor / LICENSE / FHS dest changes.
- No extra apply rewrite fields; no `USE=test` installing `tests/` (`src_test` stays the offline load/version check).
- No stripping ColorLisp C from the deps tarball; no deleting local-time `zoneinfo/` or ironclad `doc/`.

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `dev-util-autolith-seed`: installed share tree is a pruned private app (not `cp -a` of `${S}`); fabricated `.git` is packed and matches the installed tracked files; ColorLisp vendor C is compile-only.
- `sbcl-deps-assets`: packed `.qlot` confs have no `/home/` pathnames and omit builder qlot-source keys; `fff/` is the cargo workspace + vendor needed for offline `fff-c`, not the full upstream checkout.
- `hermetic-asset-materialize`: qlot conf rewrite MUST NOT substitute `/home/builder`; packed confs contain no `/home/` pathnames.

## Impact

- **mndz-overlay**: `autolith-<PV>-r3.ebuild`, Manifest, package md5-cache. One overlay commit.
- **mndz-overlay-assets**: none in this change (no 0.32.2 republish). Next Autolith PV’s deps tarball picks up manager hygiene.
- **mndz-overlay-manager**: Sbcl deps materialize (conf emit + fff strip), tests, seed/hermetic spec deltas.
- **Operator**: full emerge of `-r3` (rebuilds natives and both cores) then `autolith --version`. Installed qlot confs stay leaky until the next Autolith PV.
- **Downstream**: later Autolith PV bumps inherit the pruned `src_install` body; new deps tarballs come from the tightened materialize.
