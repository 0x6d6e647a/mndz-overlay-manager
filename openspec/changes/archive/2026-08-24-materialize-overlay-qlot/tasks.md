## 1. Policy and floors

- [x] 1.1 Add `dev-lisp/qlot` to `hardcodedPolicies` as `GitMvAndManifest` / GitHub `fukamachi/qlot` / empty tag prefix; tests for policy lookup and `outdated`
- [x] 1.2 Add optional `nfQlot` to `NeededFloors` (JSON `"qlot"`); union/satisfy; set it from overlay qlot PV when this prepare emerges SBCL
- [x] 1.3 Bump `materializeGeneratorId` to `mndz-overlay-manager-materialize-5`

## 2. Recipe and resolve

- [x] 2.1 Resolve overlay `dev-lisp/qlot` metas when `nfSbcl` is set; emerge spec `>=dev-lisp/qlot-<pv>::mndz` and `~arch` accept_keywords like bun-bin
- [x] 2.2 `TkSbcl` render: `ENV SBCL_HOME` then overlay-bind `RUN` emerging qlot; delete Quicklisp aria2c/quickstart `RUN`; bun-only omits qlot
- [x] 2.3 Tests: amd64/x86 recipes; no `beta.quicklisp.org`; overlay bind on qlot `RUN`; `::mndz ~amd64`; bun-only has no qlot/`SBCL_HOME`

## 3. Materialize invocation and overlay gates

- [x] 3.1 `qlotInstall` runs `qlot install` on image `PATH` with `HOME=/home/builder`; drop Autolith installer / `imageQuicklispSetup` production path; keep `sanitizeQlotConfs`
- [x] 3.2 Dirty-preflight overlay qlot when this recipe will emerge it; GitMv file work (rename, Manifest, egencache) before that `docker build`; qlot commit not delayed for ensure; Autolith not withheld on qlot
- [x] 3.3 Tests: wrap/install argv; dirty qlot fails before docker; newer recorded qlot miss rebuilds; qlot-only GitMv does not require ensure
- [x] 3.4 Progress: qlot Manifest wait visible when it happens; Autolith not “waiting on dev-lisp/qlot”

## 4. Docs and gates

- [x] 4.1 Update `README.md` runtime/materialize/`update` text (overlay qlot, dirty/Manifest gates, no Quicklisp wget)
- [x] 4.2 `openspec validate materialize-overlay-qlot --strict --type change`
- [x] 4.3 `hk check`
