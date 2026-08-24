## ADDED Requirements

### Requirement: Overlay qlot is emergeable before docker build

When ensure will `docker build` a recipe that `emerge`s `dev-lisp/qlot::mndz`, the program SHALL NOT start that `docker build` until the overlay qlot package directory on disk has:

1. a non-live ebuild whose version equals the PV in that recipe’s qlot atom, and
2. a package `Manifest` with DIST checksum entries for the distfile names that ebuild’s `SRC_URI` will fetch, and
3. package-scoped Portage `egencache` metadata for that ebuild as specified by `md5-cache`.

Independent GitMv packages that the image does not emerge SHALL NOT be required to finish before that `docker build`. Overlay bind SHALL remain the configured overlay worktree (read-only at build). The program SHALL NOT require the qlot signed overlay commit to exist before `docker build`. The program SHALL NOT withhold Autolith or other packages on qlot as an overlay wait-edge.

#### Scenario: Docker waits on qlot Manifest

- **WHEN** ensure will emerge `>=dev-lisp/qlot-1.8.5::mndz` and overlay qlot has been renamed to `qlot-1.8.5.ebuild` but Manifest DIST lines are still `qlot-1.8.4.tar.gz`
- **THEN** `docker build` does not start until `ebuild … manifest` (and package `egencache`) for that ebuild have succeeded

#### Scenario: qlot commit is not required before docker

- **WHEN** qlot `ebuild … manifest` and package `egencache` have succeeded for PV `1.8.5` and the signed overlay commit has not yet been created
- **THEN** ensure MAY `docker build` emerging `dev-lisp/qlot-1.8.5::mndz` from the worktree bind

### Requirement: Qlot in the image is overlay qlot only

When the generated recipe emerges SBCL to meet a floor, it SHALL also install `dev-lisp/qlot::mndz` from the configured overlay (bind-mounted read-only, same style as bun-bin). The PV SHALL be the newest non-live overlay qlot ebuild (after any qlot GitMv file work required before that `docker build`). The recipe SHALL NOT fetch `https://beta.quicklisp.org/quicklisp.lisp` or run Quicklisp quickstart into `/home/builder/quicklisp`. The qlot `emerge` SHALL be a separate overlay-bind `RUN` after `ENV SBCL_HOME` / `ENV SBCL_SOURCE_ROOT` and before later node/go/bun layers. When that overlay atom is not plain-visible on the host architecture, the build SHALL write package-level `package.accept_keywords` of the form `>=dev-lisp/qlot-<pv>::mndz ~<keywords-token>` and SHALL NOT set whole-image `ACCEPT_KEYWORDS` to `~arch` solely to install qlot. A bun-only (or otherwise SBCL-less) recipe SHALL NOT be required to emerge qlot.

#### Scenario: SBCL recipe emerges overlay qlot

- **WHEN** the host machine is `x86_64` and the recipe emerges `dev-lisp/sbcl` and overlay qlot’s newest non-live PV is `1.8.4` keyworded `~amd64`
- **THEN** the recipe contains `>=dev-lisp/qlot-1.8.4::mndz`
- **AND** it contains `>=dev-lisp/qlot-1.8.4::mndz ~amd64`
- **AND** those emerge lines appear after `ENV SBCL_HOME=`
- **AND** the recipe does not fetch `beta.quicklisp.org`

#### Scenario: bun-only recipe omits qlot

- **WHEN** there is no previous image and this prepare’s full-path units are Bun-only
- **THEN** the generated recipe is not required to emerge `dev-lisp/qlot`

## MODIFIED Requirements

### Requirement: Image satisfies the union of previous and this prepare’s floors

The program SHALL treat the materialize image as satisfying a prepare when every toolchain that prepare will use for full-path work is present in the image at a version greater than or equal to that prepare’s maximum required floor (Go from `go.mod`, Node from `engines.node`, Bun from `engines.bun` / overlay bun-bin including hypothetical working-plan floors for withheld Bun consumers, Rust and SBCL from their existing plan floors) **and**, when this prepare’s recipe will emerge overlay `dev-lisp/qlot`, the recorded image provides overlay qlot at a version greater than or equal to the PV that recipe would emerge. **This prepare’s** needed floors SHALL be the maximum requirement of classified **full-path** PV units only, including withheld hypo-planned Bun consumers as specified above. Reuse-path and GitMv units SHALL NOT contribute Go/Node/Bun/Rust/SBCL floors. The overlay qlot PV used for satisfy and for the recipe SHALL be the newest non-live overlay qlot ebuild (after qlot GitMv file work when that work must precede `docker build`). Planned PVs of the same package that are not full-path in this prepare SHALL NOT raise language floors. When ensure must build, the resulting image SHALL satisfy the **union** of the previous image’s recorded satisfies (if any) and this prepare’s needed floors and qlot PV (monotonic; the program SHALL NOT drop a toolchain already paid for). When that union already holds and the recorded image id still exists, ensure SHALL NOT `docker build`. When overlay qlot PV is newer than the recorded image’s qlot, ensure SHALL `docker build` even if language floors and generator identity would otherwise satisfy.

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

## REMOVED Requirements

### Requirement: Quicklisp bootstrap fetch uses aria2c

**Reason:** Image qlot comes from overlay `dev-lisp/qlot::mndz`. The unpinned `beta.quicklisp.org` installer fetch is deleted.

**Migration:** SBCL recipes emerge overlay qlot after `ENV SBCL_HOME` as specified under “Qlot in the image is overlay qlot only.” Base layer may still emerge `net-misc/aria2` and `net-misc/wget` for other tools.
