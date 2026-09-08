## MODIFIED Requirements

### Requirement: Overlay bun-bin is emergeable before docker build

When ensure will `docker build` a recipe that `emerge`s `dev-lang/bun-bin::mndz`, the program SHALL NOT start that `docker build` until the overlay bun-bin package directory on disk has:

1. a non-live ebuild whose version equals the PV in that recipe’s bun-bin atom and whose `SLOT` is `0` (the unversioned `/usr/bin/bun` provider), and
2. a package `Manifest` with DIST checksum entries for the distfile names that ebuild’s `SRC_URI` will fetch for the host architecture, and
3. package-scoped Portage `egencache` metadata for that ebuild as specified by `md5-cache`.

The recipe bun-bin atom SHALL be slot-qualified `:0` (latest unversioned bun). The image SHALL NOT be required to emerge bun-bin pin slots (`SLOT="${PV}"` other than `0`) solely so `bun install` can run. Independent GitMv packages that the image does not emerge (`dev-util/grok-build-bin`, `dev-lang/deno-bin`) SHALL NOT be required to finish before that `docker build`. Overlay bind SHALL remain the configured overlay worktree (read-only at build); the program SHALL NOT require the bun-bin signed overlay commit to exist before `docker build`.

#### Scenario: Docker waits on bun-bin Manifest

- **WHEN** ensure will emerge `>=dev-lang/bun-bin-1.4.0:0::mndz` and overlay bun-bin latest `SLOT="0"` ebuild has been added as `bun-bin-1.4.0.ebuild` but Manifest DIST lines are still `bun-bin-1.3.14-*`
- **THEN** `docker build` does not start until `ebuild … manifest` (and package `egencache`) for that latest ebuild have succeeded

#### Scenario: Pin slot is not required in the image

- **WHEN** overlay bun-bin has pin `1.3.14:1.3.14` and latest `1.4.2:0` and ensure will emerge overlay bun-bin for a full-path opencode unit
- **THEN** the recipe emerges the `:0` latest atom and does not require emerging the pin slot for `bun install`

#### Scenario: grok-build-bin does not gate docker

- **WHEN** ensure will emerge overlay bun-bin and `dev-util/grok-build-bin` also needs GitMv work
- **THEN** grok-build-bin phase-1 may overlap `docker build`
- **AND** docker is not required to wait on grok-build-bin Manifest or commit

#### Scenario: Commit is not required before docker

- **WHEN** bun-bin `ebuild … manifest` and package `egencache` have succeeded for latest `SLOT="0"` PV `1.4.0` and the signed overlay commit has not yet been created
- **THEN** ensure MAY `docker build` emerging `dev-lang/bun-bin-1.4.0:0::mndz` from the worktree bind
