## ADDED Requirements

### Requirement: Reuse existing vendor release when materializing a PV

When materializing a planned `GoVendorAndAssets` PV that needs work, the program SHALL first determine whether the assets repository already has a GitHub release whose tag is `{pn}-{pv}` (PV without `-rN`) and whose assets include a file named `{pn}-{pv}-vendor.tar.xz`. If that release and asset exist, the program SHALL take the **reuse path**: it SHALL NOT clone upstream for vendor construction, SHALL NOT run `go mod download` or build a new vendor tarball, SHALL NOT commit or push assets-repo sidecars, and SHALL NOT create a new GitHub release or re-upload the asset for that PV. If the release or expected asset is absent, the program SHALL use the existing full vendor-and-publish path for that PV.

#### Scenario: Existing release skips vendor and publish

- **WHEN** planned PV `0.84.0` for package name `crush` needs overlay work and release `crush-0.84.0` already has asset `crush-0.84.0-vendor.tar.xz`
- **THEN** apply does not rebuild the vendor tarball and does not call create-release for that tag

#### Scenario: Missing release uses full path

- **WHEN** planned PV `0.85.0` needs work and no release tag `crush-0.85.0` with the expected vendor asset exists
- **THEN** apply uses the full clone, vendor, assets publish, and release upload path for that PV

### Requirement: Heavy verify on reuse path

On the reuse path the program SHALL download the existing vendor release asset, compute digests for the downloaded bytes (including SHA-512), rewrite or ensure the overlay ebuild for that PV (assets SRC_URI parameterization, planned KEYWORDS, Go BDEPEND from that tag’s `go.mod` requirement obtained without a vendor clone), run `ebuild … manifest`, and hard-fail if the Manifest SHA512 for `{pn}-{pv}-vendor.tar.xz` does not equal the SHA512 of the downloaded asset. When assets-repo sidecar files for that tarball basename exist and their SHA512 disagrees with the download, the program SHALL hard-fail with an error indicating assets-repo and GitHub release are out of sync. The reuse path SHALL NOT require the host Go version gate used before `go mod download` on the full path.

#### Scenario: Manifest matches downloaded asset

- **WHEN** reuse downloads the vendor asset, overlay rewrite succeeds, and `ebuild … manifest` produces a vendor DIST SHA512 equal to the download
- **THEN** that PV’s materialization may succeed

#### Scenario: Manifest mismatch hard-fails

- **WHEN** after reuse download and `ebuild … manifest` the Manifest vendor SHA512 differs from the downloaded asset SHA512
- **THEN** the package hard-fails for that PV

#### Scenario: Host Go not gated on reuse

- **WHEN** the reuse path runs and the host Go is older than the package’s `go.mod` requirement
- **THEN** the program does not hard-fail solely for that host vs go.mod mismatch on the reuse path

### Requirement: Manifest incompleteness is needs-work

For a planned `GoVendorAndAssets` PV that already has a local non-live ebuild, the program SHALL treat the PV as still needing materialization (not fully satisfied / not soft-skippable solely for “already matches plan”) when the package `Manifest` lacks a DIST entry for `{pn}-{pv}-vendor.tar.xz`, in addition to existing content-fix rules (assets SRC_URI parameterization, Go BDEPEND, planned KEYWORDS). Soft-skip of a package as fully matching the tree-lane plan SHALL require that every planned PV is present with adequate ebuild content **and** a Manifest vendor DIST entry for that PV’s vendor tarball name.

#### Scenario: Good ebuild missing vendor Manifest is not pure soft-skip

- **WHEN** local ebuild for planned PV `0.84.0` has parameterized assets SRC_URI, correct BDEPEND, and correct KEYWORDS, but Manifest has no DIST line for `crush-0.84.0-vendor.tar.xz`
- **THEN** the program does not soft-skip the package solely as “already matches Go tree-lane plan” and still schedules materialization for that PV

#### Scenario: Complete PV set with Manifest is soft-skippable

- **WHEN** every planned PV has a local ebuild with adequate content and Manifest contains the corresponding vendor DIST lines
- **THEN** the package may soft-skip as already matching the plan (subject to prune-only extras rules)

### Requirement: Same-PV revision bump may reuse one release

When the reuse path applies a same-PV content or Manifest fix that requires an overlay `-rN` bump, the program SHALL still reuse the release tag and asset named by PV without revision (`{pn}-{pv}`), and SHALL NOT create a separate release for the revision suffix.

#### Scenario: r1 bump reuses unversioned-revision release

- **WHEN** local is `dolt-2.1.6.ebuild`, remote planned PV is `2.1.6`, release `dolt-2.1.6` already has the vendor asset, and content fix requires `-r1`
- **THEN** apply reuses that release asset and may write `dolt-2.1.6-r1.ebuild` without creating `dolt-2.1.6-r1` as a release tag
