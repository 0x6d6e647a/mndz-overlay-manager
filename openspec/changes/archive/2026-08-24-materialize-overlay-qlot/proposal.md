## Why

The materialize image still fetches an unpinned Quicklisp installer at `docker build` and Haskell still loads `/home/builder/quicklisp/setup.lisp`. Overlay `dev-lisp/qlot-1.8.4` now exists (`dev-lisp-qlot-seed`). The image should `emerge` that atom and Autolith materialize should run `qlot install` on `PATH`. The manager also has no policy for qlot, so `outdated`/`update` cannot see upstream bumps.

## What Changes

- When the generated recipe emerges SBCL, it SHALL also `emerge` overlay `dev-lisp/qlot::mndz` (PV scanned from the overlay package directory; `package.accept_keywords` `>=…::mndz ~<arch>` as for bun-bin). Own overlay-bind `RUN` after `ENV SBCL_HOME`. Drop the Quicklisp installer `RUN`. Keep `net-misc/wget` / `net-misc/aria2` in the base layer.
- Full-path Autolith materialize invokes **`qlot install`** on image `PATH`. Stop using Autolith `script/qlot-install.lisp` and `/home/builder/quicklisp/setup.lisp`. `sanitizeQlotConfs` stays.
- Hardcoded policy: `dev-lisp/qlot` is `GitMvAndManifest` with GitHub `fukamachi/qlot` and empty tag prefix. `outdated`/`update` can bump it. Autolith is **not** withheld on qlot (no wait-edge).
- Overlay qlot PV is part of image **satisfies**. A newer overlay qlot than the recorded image is an ensure miss (rebuild), not a silent skip.
- When this run’s recipe will emerge overlay qlot: dirty-preflight that package dir; complete GitMv file work (rename, Manifest, egencache) **before** `docker build` if qlot needs work. qlot’s signed commit is **not** delayed for ensure (no wait-edge consumers).
- Generator identity `mndz-overlay-manager-materialize-5`.
- README: image qlot is overlay `::mndz`; dirty/Manifest-before-docker names qlot when the recipe emerges it.

## Non-goals

- Overlay ebuild layout (`/usr/share/qlot`); that is `dev-lisp-qlot-seed`.
- Autolith `DEPEND` on qlot; Autolith FHS/LICENSE (`autolith-split-handoff.md`).
- Overlay wait-edge Autolith → qlot; bun-bin-style delayed GPG commit for qlot.
- `dev-lisp/quicklisp` client package; Roswell; host-path materialize.
- Treating `qlot --version` process status 255 as a packaging/materialize failure (upstream prints the version then `uiop:quit -1`).

## Capabilities

### New Capabilities

- (none)

### Modified Capabilities

- `ensure-materialize-image`: SBCL recipes emerge overlay qlot after `SBCL_HOME`; drop Quicklisp installer fetch; qlot PV in satisfies/skip; Manifest-before-docker for qlot; generator `…-5`
- `hermetic-asset-materialize`: full-path Sbcl uses image `qlot` on `PATH`, not a Quicklisp tree under `HOME`
- `sbcl-deps-assets`: image tool for `.qlot/` is overlay qlot CLI; still not operator `~/quicklisp`
- `update-apply`: hardcoded policy includes `dev-lisp/qlot` as `GitMvAndManifest`; qlot file work before a qlot-layer `docker build` when that recipe will emerge it
- `update-command`: dirty preflight includes overlay qlot when the recipe will emerge it
- `project-docs`: README materialize/update text matches overlay qlot and the dirty/Manifest gates
- `cli-activity`: qlot Manifest-before-docker is visible when that wait happens

## Impact

- **Code:** `Update.Hardcoded`; `Update.Materialize.{Recipe,Resolve,Floors,Ensure,Sidecar}`; `Update.Sbcl.Deps` (`qlotInstall`); dirty-preflight / bun-bin-before-docker sequencing generalized to overlay atoms this recipe emerges; tests (`Test.Ensure`, `Test.Ecosystems`, policy/outdated).
- **Overlay:** no ebuild edits (seed already landed).
- **Operator:** first full-path Sbcl `update` rebuilds `:local`. `outdated`/`update` can list and bump `dev-lisp/qlot`.
