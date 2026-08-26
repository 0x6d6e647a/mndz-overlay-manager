## ADDED Requirements

### Requirement: Overlay node-gyp is emergeable before docker build

When ensure will `docker build` a recipe that `emerge`s `dev-build/node-gyp::mndz`, the program SHALL NOT start that `docker build` until the overlay node-gyp package directory on disk has:

1. a non-live ebuild whose version equals the PV in that recipe’s node-gyp atom, and
2. a package `Manifest` with DIST checksum entries for the distfile names that ebuild’s `SRC_URI` will fetch, and
3. package-scoped Portage `egencache` metadata for that ebuild as specified by `md5-cache`.

Independent GitMv packages that the image does not emerge SHALL NOT be required to finish before that `docker build`. Overlay bind SHALL remain the configured overlay worktree (read-only at build). The program SHALL NOT require the node-gyp signed overlay commit to exist before `docker build`. The program SHALL NOT withhold opencode, ralph-tui, or other packages on node-gyp as an overlay wait-edge.

#### Scenario: Docker waits on node-gyp Manifest

- **WHEN** ensure will emerge `>=dev-build/node-gyp-13.0.1::mndz` and overlay node-gyp has been rewritten to `node-gyp-13.0.1.ebuild` but Manifest DIST lines are still `node-gyp-13.0.0-*`
- **THEN** `docker build` does not start until `ebuild … manifest` (and package `egencache`) for that ebuild have succeeded

#### Scenario: node-gyp commit is not required before docker

- **WHEN** node-gyp `ebuild … manifest` and package `egencache` have succeeded for PV `13.0.1` and the signed overlay commit has not yet been created
- **THEN** ensure MAY `docker build` emerging `dev-build/node-gyp-13.0.1::mndz` from the worktree bind

### Requirement: Node-gyp in the image is overlay node-gyp when bun or node is needed

When the generated recipe emerges overlay bun-bin **or** Gentoo Node to meet a floor, it SHALL also install `dev-build/node-gyp::mndz` from the configured overlay (bind-mounted read-only, same style as bun-bin and qlot). The PV SHALL be the newest non-live overlay node-gyp ebuild (after any node-gyp file work required before that `docker build`). The node-gyp `emerge` SHALL be a separate overlay-bind `RUN` after the Node layer and before later go/bun layers. When that overlay atom is not plain-visible on the host architecture, the build SHALL write package-level `package.accept_keywords` of the form `>=dev-build/node-gyp-<pv>::mndz ~<keywords-token>` and SHALL NOT set whole-image `ACCEPT_KEYWORDS` to `~arch` solely to install node-gyp. A recipe with neither bun nor node floors SHALL NOT be required to emerge node-gyp.

#### Scenario: Bun recipe emerges overlay node-gyp after node

- **WHEN** the host machine is `x86_64` and the recipe emerges overlay bun-bin and overlay node-gyp’s newest non-live PV is `13.0.0` keyworded `~amd64`
- **THEN** the recipe contains `>=dev-build/node-gyp-13.0.0::mndz`
- **AND** those emerge lines appear after the Node install `RUN`
- **AND** they appear before the bun-bin install `RUN`

#### Scenario: Go-only recipe omits node-gyp

- **WHEN** there is no previous image and this prepare’s full-path units are Go-only
- **THEN** the generated recipe is not required to emerge `dev-build/node-gyp`

## MODIFIED Requirements

### Requirement: Image satisfies the union of previous and this prepare’s floors

The program SHALL treat the materialize image as satisfying a prepare when every toolchain that prepare will use for full-path work is present in the image at a version greater than or equal to that prepare’s maximum required floor (Go from `go.mod`, Node from `engines.node`, Bun from `engines.bun` / overlay bun-bin including hypothetical working-plan floors for withheld Bun consumers, Rust and SBCL from their existing plan floors) **and**, when this prepare’s recipe will emerge overlay `dev-lisp/qlot`, the recorded image provides overlay qlot at a version greater than or equal to the PV that recipe would emerge **and**, when this prepare’s recipe will emerge overlay `dev-build/node-gyp`, the recorded image provides overlay node-gyp at a version greater than or equal to the PV that recipe would emerge. **This prepare’s** needed floors SHALL be the maximum requirement of classified **full-path** PV units only, including withheld hypo-planned Bun consumers as specified above. Reuse-path and GitMv units SHALL NOT contribute Go/Node/Bun/Rust/SBCL floors. The overlay qlot PV used for satisfy and for the recipe SHALL be the newest non-live overlay qlot ebuild (after qlot GitMv file work when that work must precede `docker build`). The overlay node-gyp PV used for satisfy and for the recipe SHALL be the newest non-live overlay node-gyp ebuild (after node-gyp file work when that work must precede `docker build`). Planned PVs of the same package that are not full-path in this prepare SHALL NOT raise language floors. When ensure must build, the resulting image SHALL satisfy the **union** of the previous image’s recorded satisfies (if any) and this prepare’s needed floors and qlot PV and node-gyp PV (monotonic; the program SHALL NOT drop a toolchain already paid for). When that union already holds and the recorded image id still exists, ensure SHALL NOT `docker build`. When overlay qlot PV is newer than the recorded image’s qlot, or overlay node-gyp PV is newer than the recorded image’s node-gyp, ensure SHALL `docker build` even if language floors and generator identity would otherwise satisfy.

#### Scenario: Already satisfies skips build

- **WHEN** `image.json` records Go 1.26.5 and this prepare’s full-path units need Go 1.26.4
- **THEN** ensure does not `docker build`

#### Scenario: First ralph-only run does not compile unused SBCL

- **WHEN** there is no previous image and this prepare’s full-path units are Bun-only
- **THEN** the built image is not required to include SBCL solely to preempt a later package
- **AND** a later prepare that needs SBCL may build again adding that toolchain

#### Scenario: Later prepare keeps prior Go

- **WHEN** the current image satisfies Go 1.26.5 and this prepare needs Bun 1.3 and not a newer Go
- **THEN** the image after ensure still provides Go at least 1.26.5

#### Scenario: Reuse sibling PV does not raise the floor

- **WHEN** a package has a full-path unit whose requirement is Go 1.24.0 and a reuse-path unit whose requirement is Go 1.26.5
- **THEN** this prepare’s Go floor is 1.24.0
- **AND** the generated recipe is not required to accept testing keywords solely for 1.26.5

#### Scenario: Newer overlay qlot rebuilds

- **WHEN** `image.json` records overlay qlot `1.8.4` and generator identity matches, language floors would satisfy, and overlay qlot’s newest non-live PV is `1.8.5`
- **THEN** ensure `docker build`s
- **AND** the new sidecar records qlot at least `1.8.5`

#### Scenario: Newer overlay node-gyp rebuilds

- **WHEN** `image.json` records overlay node-gyp `13.0.0` and generator identity matches, language floors would satisfy, and overlay node-gyp’s newest non-live PV is `13.0.1`
- **THEN** ensure `docker build`s
- **AND** the new sidecar records node-gyp at least `13.0.1`
