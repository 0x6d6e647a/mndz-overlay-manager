# Tasks

## 1. Beads 1.0.4 provider

- [x] 1.1 Build `beads-1.0.4-vendor.tar.xz` from tag `v1.0.4` of `gastownhall/beads` (top-level `go-mod/`) and publish it on mndz-overlay-assets release `beads-1.0.4`. Verify the release asset name and that unpacking yields `go-mod/`.
- [x] 1.2 Add `dev-util/beads/beads-1.0.4.ebuild` without removing `beads-1.3.0.ebuild`: `go-module`, `CGO_ENABLED=1`, `-tags gms_pure_go`, `BDEPEND` `>=dev-lang/go-1.26.2:=`, `${PV}` assets `SRC_URI`, `IUSE` including `test`, `RESTRICT="!test? ( test )"`, `SLOT="0"`, install `/usr/bin/bd`. Run `ebuild manifest` and package `egencache`. Verify both ebuilds are present and `bd version` after `emerge =dev-util/beads-1.0.4` reports `1.0.4`.
- [x] 1.3 Commit only that Beads overlay revision, signed, before any Gas Town ebuild and before a Beads `update`. Verify the commit contains `beads-1.0.4.ebuild` and still contains the `1.3.0` ebuild.

## 2. Gas Town 1.1.0 seed

- [x] 2.1 Build `gastown-1.1.0-vendor.tar.xz` from tag `v1.1.0` of `gastownhall/gastown` and publish assets release `gastown-1.1.0`. Verify the asset name and a top-level `go-mod/`.
- [x] 2.2 Add `dev-util/gastown/gastown-1.1.0.ebuild`: `CGO_ENABLED=0`, ldflags for `${PV}` and `BuiltProperly=1`, `dobin gt` only, `IUSE="bash-completion fish-completion +tmux test zsh-completion"`, `RESTRICT="!test? ( test )"`, `src_test` runs `ego test -short ./...`, `RDEPEND` `~dev-util/beads-1.0.4`, `>=dev-db/dolt-1.82.4`, `dev-vcs/git`, and `tmux? ( app-misc/tmux )`, completions from `gt completion`, and the comment `# gastown-beads-window: min=0.57.0 max=none`. Verify `ldd` on the built `gt` does not list ICU libraries.
- [x] 2.3 Manifest, `egencache`, metadata, and a signed overlay commit of the Gas Town package. Verify the ebuild path is `gastown-1.1.0.ebuild` and the assets URL uses `gastown-${PV}`.
- [x] 2.4 Emerge `=dev-util/gastown-1.1.0` and run `gt version`, `gt completion bash`, and `gt install` of an empty throwaway directory with `bd` 1.0.4 and system Dolt on `PATH`. Verify version text contains `1.1.0`, completion emits a script, `gt install` exits 0, and `gt status` in that directory names the town and Dolt. Stop the throwaway Dolt server afterward.

## 3. Policy entry

- [x] 3.1 Add `dev-util/gastown` to `hardcodedPolicies` as GitHub `gastownhall/gastown`, tag prefix `v`, `DepsAndAssets` Go with no subdirectory. Verify `lookupPolicy` in `test/Test/Policy.hs` expects that source and technique, and the policy test passes.

## 4. Dependency gates

- [x] 4.1 Parse `MinDoltVersion` and the Beads gate from a tag checkout, with unit fixtures for `v1.1.0` (Dolt floor `1.82.4`, Beads floor `0.57.0`), `v1.2.1` (Dolt floor `2.0.7`, same Beads floor), `v1.2.0` (equal min/max `1.0.4` ceiling), and a renamed-constant fixture. Verify the recognized fixtures parse and the renamed fixture is a hard failure that names an unrecognized gate.
- [x] 4.2 On Gas Town apply, rewrite the Dolt `RDEPEND` atom from the parsed floor, leave `~dev-util/beads-1.0.4` in place for a floor at or below `1.0.4`, and update `# gastown-beads-window:` only when the window changes, printing one stdout notice in that case. Verify a `1.1.0` → `1.2.1` fixture writes `>=dev-db/dolt-2.0.7`, still contains `~dev-util/beads-1.0.4`, does not contain `>=dev-util/beads-0.57.0` as the pin replacement, and emits no window notice.
- [x] 4.3 Hard-fail the Gas Town unit before overlay mutation when the gate shape is unrecognized, when a ceiling version is not `1.0.4`, when the Beads floor is strictly newer than `1.0.4`, or when `MinDoltVersion` is missing. Verify those cases produce no success stdout line and do not write the ebuild.

## 5. Update smoke

- [x] 5.1 Run `outdated` for `gastown` against the `1.1.0` seed. Verify a line reports `dev-util/gastown` `1.1.0` → `1.2.1` on a `dev-lang/go` lane.
- [x] 5.2 Run `update` for `gastown`. Verify assets release `gastown-1.2.1` exists, the overlay ebuild is `gastown-1.2.1.ebuild` with `>=dev-db/dolt-2.0.7` and `~dev-util/beads-1.0.4`, the window comment is unchanged, stdout has no Beads window notice, and `beads-1.0.4.ebuild` is still present.
- [x] 5.3 Emerge the updated Gas Town and repeat `gt version` plus a throwaway `gt install` with `bd` 1.0.4. Verify version text contains `1.2.1` and `gt install` exits 0. Stop the throwaway Dolt server afterward.

## 6. Gates

- [x] 6.1 Run `openspec validate --change add-dev-util-gastown --strict` and `hk check`. Verify both exit 0.
