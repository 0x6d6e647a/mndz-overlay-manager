## MODIFIED Requirements

### Requirement: GoVendorAndAssets technique

The library SHALL support Go packages under the update technique `DepsAndAssets` with ecosystem `Go` and an optional go.mod subdirectory relative to the upstream repository root (`Nothing` means repository root). Apply logic SHALL use this subdirectory when running Go module download after clone. The former technique name `GoVendorAndAssets` SHALL NOT remain as a separate technique constructor.

#### Scenario: Root go.mod package

- **WHEN** policy for `dev-util/beads` uses `DepsAndAssets` with ecosystem `Go` and no subdirectory
- **THEN** vendor construction runs in the cloned repository root where `go.mod` is present

#### Scenario: Subdirectory go.mod package

- **WHEN** policy for `dev-db/dolt` uses `DepsAndAssets` with ecosystem `Go` and subdirectory `go`
- **THEN** vendor construction runs in the `go/` directory of the clone

### Requirement: Hardcoded Go packages use GoVendorAndAssets

The hardcoded policy map SHALL set `DepsAndAssets` with ecosystem `Go` for `dev-db/dolt` (subdir `go`), `dev-util/beads` (root), and `dev-util/crush` (root), each with their existing GitHub update sources. Those packages SHALL NOT remain `Unsupported` solely for vendor assets.

#### Scenario: dolt technique

- **WHEN** policy is resolved for `dev-db/dolt`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go` and go.mod subdirectory `go`

#### Scenario: crush technique

- **WHEN** policy is resolved for `dev-util/crush`
- **THEN** the technique is `DepsAndAssets` with ecosystem `Go` and go.mod at repository root

### Requirement: Temp clone at release tag

For `DepsAndAssets` Go apply of a given target PV (including each runtime-lane planned PV), the program SHALL clone the package’s GitHub source into a system temporary directory, check out the tag formed by the source tag prefix plus that target PV (for example prefix `v` and PV `0.76.0` → tag `v0.76.0`), and remove the temporary clone when that PV’s apply attempt finishes (success or failure). The program SHALL NOT require a pre-existing long-lived checkout of the upstream project.

#### Scenario: Clone uses version tag

- **WHEN** updating `dev-util/crush` to PV `0.77.0` with tag prefix `v`
- **THEN** the clone targets tag `v0.77.0` in a temporary directory

#### Scenario: Clone uses target PV tag

- **WHEN** the planned target PV is `0.82.0` and the tag prefix is `v`
- **THEN** the temporary clone checks out tag `v0.82.0`

### Requirement: Vendor and BDEPEND for each planned PV

When materializing a runtime-lane target PV for `DepsAndAssets` Go, the program SHALL clone the tag formed by the source tag prefix plus that PV, run the existing host Go vs `go.mod` gate, build and publish the vendor tarball for that PV, and ensure the overlay ebuild for that PV has BDEPEND `>=dev-lang/go-<go.mod go version>:=` and assets SRC_URI parameterization as already specified for Go vendor packages. Host Go sufficiency remains evaluated per clone/PV and SHALL NOT select which PV the planner chooses. Lane planning and KEYWORDS assembly for Go SHALL follow `runtime-lanes` (including all arches present on gentoo `dev-lang/go`).

#### Scenario: Lower PV still vendors when host satisfies its go.mod

- **WHEN** planned PV `0.82.0` has `go 1.26.3` and host Go is `1.26.4`
- **THEN** vendor construction for `0.82.0` may proceed under the host gate

#### Scenario: Planner not driven by host

- **WHEN** host Go is newer than the Gentoo tilde ceiling
- **THEN** planned target PVs remain bounded by tree ceilings, not by host Go

### Requirement: Overlay KEYWORDS for multi-PV Go packages

For ebuilds written or updated under Go runtime-lane apply, KEYWORDS SHALL match the planned per-arch bare/`~` membership for that PV as defined by `runtime-lanes` over all arches present on the Go runtime package (plain lane → bare arch; tilde-only → `~arch`; bare covers plain and tilde consumers on that arch). The program SHALL set or replace the KEYWORDS line (or equivalent) so it matches the plan for that PV. The program SHALL NOT force tilde-only KEYWORDS when a plain lane targets the PV. The program SHALL NOT limit KEYWORDS assembly to a hard-coded amd64/arm64-only set when other arches appear on `dev-lang/go`.

#### Scenario: Dual-arch single PV with plain lanes

- **WHEN** one PV serves both amd64 and arm64 plain lanes (and any corresponding tilde lanes that select the same PV)
- **THEN** that ebuild’s KEYWORDS include bare `amd64` and bare `arm64`

#### Scenario: Tilde-only arch on overlay write

- **WHEN** a planned PV has tilde-only membership for amd64 and no plain amd64 membership
- **THEN** that ebuild’s KEYWORDS include `~amd64` and do not include bare `amd64`

### Requirement: Host Go meets go.mod language version

After the temporary clone for `DepsAndAssets` Go and after locating `go.mod` in the configured subdirectory (or repository root), the program SHALL parse the module’s top-level `go` directive version and the host toolchain version from `go version` (or an equivalent injectable probe). If both versions parse successfully and the host version is strictly older than the `go.mod` requirement, the program SHALL hard-fail that package **before** running `go mod download`, and SHALL NOT publish assets or mutate the overlay for that attempt. The error message SHALL name the host version and the required version and SHALL indicate that the operator must install a newer `dev-lang/go` (the program SHALL NOT set `GOTOOLCHAIN=auto` or download a Go toolchain to work around the mismatch). If the host version is greater than or equal to the required version, vendor construction MAY proceed with `go mod download` as today. If `go.mod` has no parseable `go` directive, the program SHALL skip this gate and proceed to `go mod download`. If the host `go version` output cannot be parsed, the program SHALL hard-fail with an error that the host Go version could not be determined. The reuse path SHALL NOT require this host Go gate.

#### Scenario: Host older than go.mod hard-fails before download

- **WHEN** the cloned `go.mod` contains `go 1.26.5` and the host reports Go `1.26.4`
- **THEN** the package hard-fails without running `go mod download` and the error names both versions

#### Scenario: Host satisfies go.mod

- **WHEN** the cloned `go.mod` contains `go 1.26.4` and the host reports Go `1.26.4` or newer
- **THEN** the program proceeds to `go mod download` for vendor construction

#### Scenario: No GOTOOLCHAIN auto workaround

- **WHEN** the host Go is older than the `go.mod` requirement
- **THEN** the program does not set `GOTOOLCHAIN=auto` on the vendor child process to bypass the failure

### Requirement: Reuse existing vendor release when materializing a PV

When materializing a planned `DepsAndAssets` Go PV that needs work, the program SHALL first determine whether the assets repository already has a GitHub release whose tag is `{pn}-{pv}` (PV without `-rN`) and whose assets include a file named `{pn}-{pv}-vendor.tar.xz`. If that release and asset exist, the program SHALL take the **reuse path**: it SHALL NOT clone upstream for vendor construction, SHALL NOT run `go mod download` or build a new vendor tarball, SHALL NOT commit or push assets-repo sidecars, and SHALL NOT create a new GitHub release or re-upload the asset for that PV. If the release or expected asset is absent, the program SHALL use the existing full vendor-and-publish path for that PV.

#### Scenario: Existing release skips vendor and publish

- **WHEN** planned PV `0.84.0` for package name `crush` needs overlay work and release `crush-0.84.0` already has asset `crush-0.84.0-vendor.tar.xz`
- **THEN** apply does not rebuild the vendor tarball and does not call create-release for that tag

#### Scenario: Missing release uses full path

- **WHEN** planned PV `0.85.0` needs work and no release tag `crush-0.85.0` with the expected vendor asset exists
- **THEN** apply uses the full clone, vendor, assets publish, and release upload path for that PV
