## 1. Manager: probe exact pin vs minimum

- [x] 1.1 Extend the Bun `package.json` probe to return a minimum and, for compile-pin packages, an exact pin (`packageManager bun@X.Y.Z` if present, else bare `engines.bun` `X.Y.Z`); verify unit tests for ralph-style `>=1.3.6` (minimum only), opencode `packageManager bun@1.3.14` (minimum and exact `1.3.14`), and engines `>=1.2.0` plus `packageManager bun@1.3.14` (minimum `1.2.0`, exact `1.3.14`)
- [x] 1.2 Keep runtime-lane ceilings and the materialize-image Bun gate on the **minimum**; verify a compile-pin candidate still gates image bun against the floor, not the exact pin, when those differ

## 2. Manager: BDEPEND atoms

- [x] 2.1 Write compile-pin BDEPEND as `=dev-lang/bun-bin-<exact>` for InstallTree/`build.ts --compile` packages (opencode); verify rewrite tests insert/replace that exact atom and do not inject bun-bin into opencode `RDEPEND`
- [x] 2.2 Write floor BDEPEND as `>=dev-lang/bun-bin-<min>:0` for non-compile-pin Bun packages; when `RDEPEND="${BDEPEND}"` (ralph-tui), the runtime atom is the same `:0` floor; verify rewrite tests for insert, replace of unqualified `>=` with `:0`, and preservation of unrelated atoms

## 3. Manager: atom closure and GitMv bun-bin

- [x] 3.1 Treat `>=dev-lang/bun-bin-<min>:0` as satisfiable only by a retained bun-bin ebuild with `SLOT="0"` (or omitted slot) whose PV matches `>=`; `=dev-lang/bun-bin-<PV>` matches that PV any SLOT; a pin-slot ebuild MUST NOT satisfy `:0`; consumer atoms still hard-fail if they name a pin slot; verify tests for latest-satisfies-floor, pin-alone-does-not, and exact-pin-on-pin-slot
- [x] 3.2 When bun-bin GitMv would rename newest Old→New and a remaining compile-pin atom is `=dev-lang/bun-bin-Old`, add `bun-bin-New.ebuild` with `SLOT="0"`, rewrite Old to `SLOT="${Old}"`, manifest+egencache both, commit new ebuild + rewritten Old (not deletion of Old); verify a test that 1.3.14 stays and 1.4.2 is added
- [x] 3.3 When no remaining exact pin equals bun-bin newest, keep renaming newest as for other GitMv packages; usage/hk exact-pin rename-away still hard-fails; verify both paths

## 4. Manager: ensure image bun is `:0`

- [x] 4.1 Slot-qualify the materialize-image bun-bin emerge atom as `:0` (latest unversioned bun) and wait on that ebuild’s Manifest/egencache; do not require pin slots in the recipe; verify the ensure/recipe test or fixture atom includes `:0` and a pin-only tree is not sufficient for the image bun-bin wait

## 5. Overlay: bun-bin template and pins

- [x] 5.1 Update overlay `dev-lang/bun-bin` to one template: `SLOT="0"` installs `bun-${PV}` plus `bun`/`bunx` symlinks and completions; non-zero SLOT installs only `bun-${PV}`; debug USE still provides `bun-${PV}`; verify `ebuild … pretend`/`qlist` file lists for a SLOT=0 and a pin ebuild do not share `/usr/bin/bun`
- [x] 5.2 Keep current compile-pin PV `1.3.14` as `SLOT="1.3.14"` beside latest `SLOT="0"`; regenerate Manifest and md5-cache; verify both ebuilds exist and Portage can depend on `=dev-lang/bun-bin-1.3.14` and `>=dev-lang/bun-bin-1.4.2:0` together

## 6. Overlay: consumers

- [x] 6.1 Rewrite `dev-util/opencode` `BDEPEND` to `=dev-lang/bun-bin-<packageManager>` and `src_compile` to invoke `bun-<exact> --bun ./script/build.ts --single --skip-install`; verify the ebuild text and that `emerge` of the current PV under `network-sandbox` yields `opencode --version` equal to PV
- [x] 6.2 Rewrite `dev-util/ralph-tui` bun-bin atoms to `>=dev-lang/bun-bin-<min>:0` on BDEPEND and RDEPEND; verify ebuild text

## 7. Docs, specs merge, gates

- [x] 7.1 Update `README.md` bun-bin/`update` wording: bun-bin compile pins are added-and-kept (not rename-away hard-fail); GitMv-only usage pins still hard-fail; no false statements about a single bun-bin ebuild
- [x] 7.2 Merge this change’s spec deltas into `openspec/specs/` (`bun-deps-assets`, `update-apply`, `overlay-atom-closure`, `ensure-materialize-image`); scrub delta residue; verify `openspec validate --strict`
- [x] 7.3 `hk check` green over the manager change
