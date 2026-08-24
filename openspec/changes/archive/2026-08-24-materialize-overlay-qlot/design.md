## Context

See `proposal.md` for motivation. Overlay `dev-lisp/qlot-1.8.4` is seeded (`/usr/share/qlot`, `/usr/bin/qlot`, release tarball, tilde KEYWORDS). Generator is `mndz-overlay-manager-materialize-4`. `TkSbcl` still `aria2c`s Quicklisp into `/home/builder/quicklisp`. `qlotInstall` prefers Autolith `script/qlot-install.lisp` when `qlSetup == imageQuicklispSetup`. `NeededFloors` has no qlot field. Hardcoded policy has no `dev-lisp/qlot`. Dirty-preflight always injects bun-bin; overlay-bind `RUN` exists only for bun.

Live qlot `qlot --version` prints the version then exits 255 (upstream `uiop:quit -1`). Materialize must not use that as a success probe.

## Goals / Non-Goals

**Goals:**

- SBCL image recipes emerge overlay qlot; Autolith full-path runs `qlot install` on `PATH`.
- Manager GitMv for qlot; image skip tracks overlay qlot PV.
- Dirty + Manifest-before-docker when this recipe emerges qlot; no Autolith wait-edge.

**Non-Goals:**

- Overlay ebuild edits; Autolith `DEPEND`; delayed qlot GPG commit; wait-edge Autolith → qlot.

## Decisions

### 1. Recipe: overlay qlot RUN after `ENV SBCL_HOME`

- Scan overlay `dev-lisp/qlot` metas (newest non-live PV, host-arch keywords). `rtEmergeSpec` `>=dev-lisp/qlot-<pv>::mndz`; `rtAcceptLine` `>=…::mndz ~<arch>` when not plain-visible.
- Emit `runCacheOverlay` after the SBCL `ENV` lines (qlot `src_compile` runs `sbcl`). Reuse bun overlay bind + repos.conf snippet (factor shared helper; bun stays last).
- Delete the aria2c Quicklisp `RUN`. Base layer still emerges wget and aria2.
- Bun-only / no `nfSbcl`: no qlot layer.
- **Alternative — fold into bun overlay RUN:** mixes qlot compile with bun wait-edges. Rejected.

### 2. `NeededFloors` gains optional `qlot`

- Add `nfQlot :: Maybe Text`. JSON key `"qlot"`, `.:?` so old sidecars decode as `Nothing`.
- When this prepare needs SBCL, set `nfQlot` to the overlay qlot PV that the recipe will emerge (after qlot GitMv file work if that precedes docker).
- `floorsSatisfy` / `unionFloors` include qlot (max PV). Missing recorded qlot while needed is a miss.
- Do **not** bump `imageSidecarSchemaVersion`; optional field is enough.
- Generator → `mndz-overlay-manager-materialize-5` (recipe text change).
- **Alternative — hard-code 1.8.4 in Haskell:** rejected (scan overlay).
- **Alternative — qlot PV not in satisfies:** rejected (3B).

### 3. `qlotInstall` is `qlot install`

- Production path: `ExecCmd "qlot" ["install"]` in the clone, `HOME=/home/builder`, image `PATH`.
- Remove the Autolith `script/qlot-install.lisp` special case and `imageQuicklispSetup` as the production default.
- Tests that stub `sdoQlotInstall` stay; production/integration tests assert `qlot` argv not `--load …/quicklisp/setup.lisp`.
- Do not treat `qlot --version` exit 255 as success/fail of materialize.

### 4. GitMv policy

- `hardcodedPolicies`: `"dev-lisp/qlot"` → `GitHub "fukamachi" "qlot" ""` + `GitMvAndManifest`.
- Empty prefix: tags are `1.8.4`, not `v1.8.4`. `SRC_URI` already uses `${PV}`.
- `overlayCeilingProvider` stays Bun-only. Autolith is not withheld on qlot.
- qlot GitMv commit-on-unit-success immediately after egencache (not bun-bin’s delay-until-ensure).

### 5. Overlay gates (bun-bin file-work pattern, not wait-edge)

- Dirty preflight: selected dirs **plus** overlay atoms **this recipe** will emerge (bun-bin if bun layer; qlot if qlot layer). Not “always qlot” on `update dolt` unless that image will emerge qlot.
- If qlot is selected and needs GitMv **and** this ensure will emerge qlot: rename + Manifest + egencache **before** `docker build` (worktree then has the PV being emerged).
- Progress: show that Manifest wait (cli-activity). Do not show Autolith waiting on qlot.

### 6. Tests and docs

- `Test.Ensure`: SBCL render has overlay qlot emerge, `SBCL_HOME` before `sbcl`/`qlot` compile, no `beta.quicklisp.org`; bun-only omits qlot; accept_keywords `::mndz`; overlay bind on the qlot `RUN`.
- `Test.Ecosystems`: docker wrap `qlot install`; no `imageQuicklispSetup`.
- Policy/outdated: qlot GitMv.
- README: overlay qlot; dirty/Manifest gates; runtime table not “Quicklisp wget”.

## Risks / Trade-offs

- **[Risk]** Old generator-4 images still have Quicklisp trees → **Mitigation:** generator-5 miss rebuilds.
- **[Risk]** Sidecar without `qlot` key while SBCL needed → **Mitigation:** `Nothing` vs `Just pv` fails satisfy.
- **[Risk]** `qlot install` network at materialize (allowed) vs emerge (offline bundle) → **Mitigation:** unchanged Autolith contract.
- **[Risk]** First container `qlot` compiles FASLs into `/home/builder/.cache` → **Mitigation:** `HOME` is chmod 0777; accepted.

## Migration Plan

1. Implement policy, floors, recipe, `qlotInstall`, gates, tests, README.
2. `hk check`.
3. Operator: full-path Autolith `update` rebuilds `:local`; `outdated qlot` can show a remote.

## Open Questions

- (none)
