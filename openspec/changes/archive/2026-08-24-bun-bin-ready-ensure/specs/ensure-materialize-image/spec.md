## ADDED Requirements

### Requirement: Overlay bun-bin is emergeable before docker build

When ensure will `docker build` a recipe that `emerge`s `dev-lang/bun-bin::mndz`, the program SHALL NOT start that `docker build` until the overlay bun-bin package directory on disk has:

1. a non-live ebuild whose version equals the PV in that recipe’s bun-bin atom, and
2. a package `Manifest` with DIST checksum entries for the distfile names that ebuild’s `SRC_URI` will fetch for the host architecture, and
3. package-scoped Portage `egencache` metadata for that ebuild as specified by `md5-cache`.

Independent GitMv packages that the image does not emerge (`dev-util/grok-build-bin`, `dev-lang/deno-bin`) SHALL NOT be required to finish before that `docker build`. Overlay bind SHALL remain the configured overlay worktree (read-only at build); the program SHALL NOT require the bun-bin signed overlay commit to exist before `docker build`.

#### Scenario: Docker waits on bun-bin Manifest

- **WHEN** ensure will emerge `>=dev-lang/bun-bin-1.4.0::mndz` and overlay bun-bin has been renamed to `bun-bin-1.4.0.ebuild` but Manifest DIST lines are still `bun-bin-1.3.14-*`
- **THEN** `docker build` does not start until `ebuild … manifest` (and package `egencache`) for that ebuild have succeeded

#### Scenario: grok-build-bin does not gate docker

- **WHEN** ensure will emerge overlay bun-bin and `dev-util/grok-build-bin` also needs GitMv work
- **THEN** grok-build-bin phase-1 may overlap `docker build`
- **AND** docker is not required to wait on grok-build-bin Manifest or commit

#### Scenario: Commit is not required before docker

- **WHEN** bun-bin `ebuild … manifest` and package `egencache` have succeeded for PV `1.4.0` and the signed overlay commit has not yet been created
- **THEN** ensure MAY `docker build` emerging `dev-lang/bun-bin-1.4.0::mndz` from the worktree bind

### Requirement: This prepare’s floors include hypo-planned withheld Bun full-path units

When Bun consumers are withheld on a selected bun-bin that needs work, **this prepare’s** needed floors for the t0 ensure SHALL include classified **full-path** PV units from those consumers’ hypothetical working plans, even though those consumers are not yet admitted to mutate. Reuse-path and GitMv units still SHALL NOT contribute floors. The program SHALL NOT omit those Bun floors solely because the consumers are withheld.

#### Scenario: First ensure includes ralph hypo bun floor

- **WHEN** untargeted `update` withholds ralph-tui on bun-bin needs-work, ralph-tui’s hypothetical plan has a full-path unit requiring bun `1.4.0`, and a Go package is also full-path
- **THEN** t0 ensure’s bun floor is at least `1.4.0`
- **AND** the generated recipe emerges overlay bun-bin at that PV

## MODIFIED Requirements

### Requirement: GitMv and reuse overlap ensure; full-path waits

Ensure SHALL NOT occupy a package `--jobs` slot. Packages that do not need the image (independent GitMv such as `grok-build-bin`, reuse-path DepsAndAssets) MAY start phase-1 while ensure runs. When the recipe will emerge overlay bun-bin, bun-bin GitMv **file** work (rename, `ebuild … manifest`, package `egencache`) SHALL complete before that `docker build` as specified above; bun-bin’s signed overlay commit SHALL follow `update-apply` (after ensure finishes when ensure ran). Full-path units SHALL NOT start language materialize until ensure has succeeded for their needed floors **and** any overlay wait-edge predecessor that was needs-work has a signed overlay commit as specified by `overlay-apply-waves`. Waiting on ensure SHALL NOT count as an in-flight package job.

#### Scenario: bun-bin overlaps first image build

- **WHEN** untargeted `update` needs work on `dev-lang/bun-bin` and on a full-path Cargo or Go package, and the materialize image is missing
- **THEN** bun-bin rename, Manifest, and egencache complete before a bun-layer `docker build`
- **AND** the full-path package does not start container materialize until ensure succeeds
- **AND** bun-bin’s signed overlay commit MAY be delayed until ensure finishes as specified by `update-apply`

#### Scenario: bun-bin file work precedes bun-layer docker

- **WHEN** untargeted `update` needs work on `dev-lang/bun-bin` and on a full-path Go package, and the materialize image recipe will emerge overlay bun-bin
- **THEN** bun-bin rename, Manifest, and egencache complete before that `docker build`
- **AND** the Go package does not start container materialize until ensure succeeds

#### Scenario: grok-build-bin overlaps first image build

- **WHEN** untargeted `update` needs work on `dev-util/grok-build-bin` and on a full-path Go package, and the materialize image is missing
- **THEN** grok-build-bin phase-1 may run while ensure builds the image
- **AND** the full-path package does not start container materialize until ensure succeeds

#### Scenario: Ensure does not take the only job

- **WHEN** `--jobs 1` and bun-bin needs work while a full-path package waits on ensure
- **THEN** bun-bin may occupy the job slot for its file work
- **AND** waiting on ensure does not occupy that slot

### Requirement: Re-ensure after overlay wait-edge provider commit

After an overlay wait-edge provider in this run creates a successful signed overlay commit, the program SHALL NOT `docker build` again **solely** because that provider committed when t0 ensure already used the consumers’ hypothetical bun floors. If newly admitted consumers still need an image that does not satisfy their floors (for example `MNDZ_MATERIALIZE_IMAGE` inspect-only miss, or t0 ensure was skipped because no full-path unit existed yet), ensure SHALL run as specified for a prepare. Ensure failure or missing `docker` at that admit SHALL hard-fail the affected consumers and SHALL NOT roll back the provider’s overlay commit.

#### Scenario: Second ensure after bun-bin commit

- **WHEN** untargeted `update` commits a newer `dev-lang/bun-bin` and hypo-planned `dev-util/ralph-tui` needs full-path work whose Bun floor was already included in t0 ensure
- **THEN** ensure does not `docker build` again solely because bun-bin committed
- **AND** ralph-tui uses the t0 image after bun-bin’s signed overlay commit

#### Scenario: Failed re-ensure keeps bun-bin commit

- **WHEN** bun-bin has committed and ralph-tui full-path still needs a usable image that is missing
- **THEN** ralph-tui hard-fails
- **AND** the bun-bin overlay commit remains

#### Scenario: No second docker build after bun-bin commit

- **WHEN** t0 ensure already emerged overlay bun-bin `1.4.0` for hypo-planned ralph-tui full-path floors and bun-bin then commits `1.4.0`
- **THEN** ensure does not `docker build` again solely because bun-bin committed
- **AND** ralph-tui may start container materialize against that image after bun-bin’s signed commit

#### Scenario: Failed ensure after bun-bin commit keeps the commit

- **WHEN** bun-bin has committed and ralph-tui full-path still needs a usable image that is missing (`docker` not on `PATH` at admit)
- **THEN** ralph-tui hard-fails
- **AND** the bun-bin overlay commit remains

### Requirement: Image satisfies the union of previous and this prepare’s floors

The program SHALL treat the materialize image as satisfying a prepare when every toolchain that prepare will use for full-path work is present in the image at a version greater than or equal to that prepare’s maximum required floor (Go from `go.mod`, Node from `engines.node`, Bun from `engines.bun` / overlay bun-bin including hypothetical working-plan floors for withheld Bun consumers, Rust and SBCL from their existing plan floors). **This prepare’s** needed floors SHALL be the maximum requirement of classified **full-path** PV units only, including withheld hypo-planned Bun consumers as specified above. Reuse-path and GitMv units SHALL NOT contribute floors. Planned PVs of the same package that are not full-path in this prepare SHALL NOT raise the floor. When ensure must build, the resulting image SHALL satisfy the **union** of the previous image’s recorded satisfies (if any) and this prepare’s needed floors (monotonic; the program SHALL NOT drop a toolchain already paid for). When that union already holds and the recorded image id still exists, ensure SHALL NOT `docker build`.

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

### Requirement: Bun in the image is overlay bun-bin only

When ensure must provide Bun, the image SHALL install `dev-lang/bun-bin::mndz` from the configured overlay (bind-mounted or otherwise visible to the build without copying the overlay git tree into an image layer as the package source). Portage in the build SHALL write distfiles and binpkgs to image cache locations, not into the overlay work tree. When that overlay atom is not plain-visible on the host architecture, the build SHALL write package-level `package.accept_keywords` of the form `>=dev-lang/bun-bin-<pv>::mndz ~<keywords-token>` and SHALL NOT set whole-image `ACCEPT_KEYWORDS` to `~arch` solely to install bun-bin. The PV in that atom SHALL be the bun floor for this prepare (hypothetical remote when bun-bin is selected and needs work).

#### Scenario: Ralph uses overlay bun-bin in the image

- **WHEN** ensure runs for full-path ralph-tui whose hypothetical bun floor is overlay bun-bin `1.4.0` after bun-bin Manifest regeneration
- **THEN** the image Bun comes from emerging `dev-lang/bun-bin::mndz` at PV `1.4.0` from the overlay worktree bind
- **AND** the overlay git tree is not used as Portage DISTDIR or PKGDIR

#### Scenario: bun-bin accept_keywords names repo and version

- **WHEN** the host machine is `x86_64` and ensure installs overlay bun-bin at PV `1.2.21` that is testing-keyworded
- **THEN** the recipe contains `>=dev-lang/bun-bin-1.2.21::mndz ~amd64`
