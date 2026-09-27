# Design

## Context

See `proposal.md` for why Gas Town is being added. Beads and Dolt are already `DepsAndAssets` Go packages. Atom closure already waits or hard-fails on an unsatisfied overlay `RDEPEND`, and reverse-dep keep already retains a provider PV named by a `~` or `=` atom. Gas Town's own source, not `go.mod`, decides the Dolt floor and the Beads version gate. Tags `v1.1.0` and `v1.2.1` only declare `MinBeadsVersion = "0.57.0"`. Tag `v1.2.0` declares an equal min and max of `1.0.4` and hard-fails newer `bd`, and that tag is not the lane target.

## Goals / Non-Goals

**Goals:**

- Seed Gas Town `1.1.0` and Beads `1.0.4` so a throwaway `gt install` succeeds with the system Dolt, then let `update` move Gas Town to `1.2.1` without dropping the pin.
- Reuse atom closure for the Dolt floor and for keeping Beads `1.0.4`.
- Fail the Gas Town apply when the Beads gate source no longer matches the two shapes this design accepts.

**Non-Goals:**

- A second keep implementation beside reverse-dep keep.
- Automatic removal of the pin, the window comment, or `beads-1.0.4.ebuild`.
- Building `v1.2.0` or enabling CGO for `gt`.

## Decisions

### 1. Two Beads ebuilds, one installed `bd`

`dev-util/beads` stays `SLOT="0"`. The tree holds `beads-1.0.4.ebuild` and the `1.3.0` tip. Gas Town `RDEPEND`s on `~dev-util/beads-1.0.4`. Portage installs one `/usr/bin/bd`. Emerging Gas Town replaces `1.3.0`.

The Beads `1.0.4` ebuild follows the tip's build: `CGO_ENABLED=1` and `-tags gms_pure_go`, `BDEPEND` `>=dev-lang/go-1.26.2:=`, vendor tarball from a manual seed (same layout as other Go packages). Future Beads bumps keep using the **tip** ebuild as the donor. `1.0.4` is not the newest file, so it is not copied forward. It stays because of the pin.

Alternative considered: install a private `bd` from the Gas Town ebuild and leave `/usr/bin/bd` at `1.3.0`. Rejected. `gt` looks up the command named `bd`, and a wrapper plus a second vendor build is the cruft this pin is meant to avoid until the gate itself moves.

### 2. Gas Town compiles with `CGO_ENABLED=0` and installs `gt` only

`v1.2.0` with `CGO_ENABLED=1` links ICU and embeds a Dolt engine (about 180 MB). `CGO_ENABLED=0` is a static ~54 MB `gt` on `1.1.0`, `1.2.0`, and `1.2.1`. `gms_pure_go` drops ICU on `1.2.0` and still embeds that engine. The ebuild forces `CGO_ENABLED=0`, ldflags `-X github.com/steveyegge/gastown/internal/cmd.Version=${PV}` and `BuiltProperly=1`, and `dobin`s `gt` only.

Policy is one hardcoded entry: GitHub `gastownhall/gastown`, tag prefix `v`, `DepsAndAssets` Go, no go.mod subdirectory. Gas Town is not a materialize-image package and not a wait-edge provider.

The first vendor tarball is published by hand for `1.1.0`, the same way Badger was seeded. The first `update` would otherwise skip to `1.2.1` and never install the seed. `outdated` after the policy lands should show `1.1.0 -> 1.2.1`. `update` then vendors `1.2.1`, preserves the body (pin, USE, `CGO_ENABLED=0`, short tests), and rewrites the Dolt floor and the recorded window.

### 3. Dolt floor is a rewritten atom; closure does the catch

After the tag is cloned, read `const MinDoltVersion = "<dotted>"` from `internal/deps/dolt.go`. Replace the `dev-db/dolt` atom in `RDEPEND` with `>=dev-db/dolt-<version>`. Missing or non-numeric text hard-fails before mutation.

That write happens before atom closure evaluates the to-be-written ebuild. No new wait rule. A floor newer than every retained Dolt PV hard-fails unless Dolt is selected and its planned PVs would satisfy it, in which case Gas Town waits. `>=` does not keep old Dolt ebuilds; the tip satisfies a floor it is above.

Seed value is `>=dev-db/dolt-1.82.4` because that is `v1.1.0`. The `1.2.1` apply rewrites it to `>=dev-db/dolt-2.0.7`. Dolt `2.3.5` satisfies both.

### 4. Beads gate parser is a closed grammar

Parse only `internal/deps/beads.go` plus the command file that switches on the gate result (`internal/cmd/beads_version.go`, and `root.go` when a "too new" status is returned to the command).

| Accepted shape | Evidence | Effect on `RDEPEND` |
|---|---|---|
| Floor | `MinBeadsVersion` string, older-than-min comparison, no `MaxBeadsVersion`, no too-new arm | Do not replace `~dev-util/beads-1.0.4` |
| Ceiling | both constants equal the same version, older-than-min and newer-than-max comparisons, command returns too-new as a hard failure | If that version is `1.0.4`, leave the pin. Any other version hard-fails |

Anything else (renamed constant, moved file, min ≠ max, extra status, version taken from `go.mod`) hard-fails the Gas Town unit with a message that the gate moved and a plain update is not enough. No overlay commit for that unit.

A floor whose minimum is strictly newer than `1.0.4` hard-fails the same way: the kept `bd` would be too old for Gas Town's own check. A floor number that stays at or below `1.0.4` does not rewrite the pin. In particular, `0.57.0` on `1.1.0` and `1.2.1` must not become `>=dev-util/beads-0.57.0`.

The ebuild records the window in one line:

```ebuild
# gastown-beads-window: min=0.57.0 max=none
```

After a successful apply, if the parsed window differs from that line, stdout gets one notice naming `dev-util/gastown`, both windows, and that `~dev-util/beads-1.0.4` was kept, and the comment is updated. The `1.1.0` → `1.2.1` bump parses the same window, so it prints no notice. A second apply of an unchanged tag is also silent. The notice is extra stdout. It does not replace lane success lines, and the unit still exits 0.

Removing the cruft later is an operator edit: delete the parser acceptance of a shape that no longer exists, delete the pin and the comment, and let the next Beads update prune `1.0.4`. This design does not do that edit.

### 5. USE and tests

`IUSE="bash-completion fish-completion +tmux test zsh-completion"`, `RESTRICT="!test? ( test )"`. Completions come from `gt completion {bash,zsh,fish}` with no town. `src_test` is `ego test -short ./...`. Upstream e2e stays in its container and is not the Portage test phase.

## Risks / Trade-offs

- [Risk] The gate parser breaks when upstream renames a constant. → That hard-fail is the signal to reassess. Do not widen the grammar to keep `update` green.
- [Risk] `bd init` with a newer Beads still fails even though the floor gate accepts it. → The pin stays until an operator, after an install smoke, removes it. The parser will not notice that `bd init` started working.
- [Risk] Emerging Gas Town downgrades the host `bd` from `1.3.0` to `1.0.4`. → Call that out in the seed smoke. Rollback is unmerging Gas Town and re-emerging the Beads tip.
- [Risk] A Beads update runs before `beads-1.0.4.ebuild` exists and before Gas Town has the pin. → Seed Beads `1.0.4` and commit it before any Beads `update`. Keep cannot invent a missing PV.
- [Risk] `v1.2.1` is not a descendant of `v1.2.0`. → The lane target is still `1.2.1`. The body copied forward is the `1.1.0` seed, which already has `CGO_ENABLED=0` and the pin.

## Migration Plan

1. Publish `beads-1.0.4-vendor.tar.xz` and add `beads-1.0.4.ebuild` without removing `1.3.0`. Commit that overlay revision on its own, before Gas Town.
2. Publish `gastown-1.1.0-vendor.tar.xz` and add the Gas Town ebuild with the pin, the `1.82.4` Dolt floor, and the window comment. Emerge `=dev-util/gastown-1.1.0` (this selects Beads `1.0.4`) and run the throwaway `gt install` smoke.
3. Land the manager policy and the gate step. `outdated gastown` shows `1.1.0 -> 1.2.1`. `update gastown` vendors `1.2.1`, rewrites the Dolt atom to `>=dev-db/dolt-2.0.7`, keeps the pin, and prints no window notice.
4. Emerge the new Gas Town and repeat `gt version` and a throwaway `gt install`.

Rollback is reverting the overlay commits and the assets releases are left as unused tags. The manager commit reverts independently. No on-disk migration beyond Portage's normal downgrade of `bd`.
