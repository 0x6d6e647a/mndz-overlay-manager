## ADDED Requirements

### Requirement: Depends on seeded package

The multiarch probe SHALL target the live seeded `dev-util/autolith` package produced by `seed-dev-util-autolith` (PV `0.17.2` or a content revision `-rN` of that PV), including its published deps asset. The probe SHALL NOT invent a different upstream version solely for multiarch testing.

#### Scenario: Seed PV under test

- **WHEN** the probe runs
- **THEN** it emerges the same major seed atom line (`0.17.2` or `0.17.2-rN`) present in mndz-overlay

### Requirement: Required platforms

The probe SHALL perform a full Portage emerge of `dev-util/autolith` (with its declared dependencies) on both:

- `linux/riscv64` (Gentoo `~riscv`)
- `linux/ppc64le` (Gentoo `~ppc64`)

using official Gentoo stage3-class containers under QEMU (or native hardware if available) with a Gentoo ebuild tree and the mndz overlay configured.

#### Scenario: Both arches attempted

- **WHEN** the probe change is executed without a human waiver
- **THEN** both riscv64 and ppc64le full emerges are attempted and results recorded

### Requirement: Smoke criterion

For each required platform, after a successful emerge, the probe SHALL run `autolith --version` and require a successful exit reporting the seeded Autolith version.

#### Scenario: Version smoke

- **WHEN** emerge of autolith succeeds on a required platform
- **THEN** `autolith --version` exits 0 and reports version `0.17.2` (or the seeded PV)

### Requirement: Remediation scope

Failures SHALL be remediated by changes to mndz-overlay (and mndz-overlay-assets if the deps layout is wrong), not by manager feature work. Content-only ebuild fixes SHALL use Portage revision bumps (`-rN`).

#### Scenario: Content fix revision

- **WHEN** a multiarch failure is fixed only by ebuild content without changing upstream PV
- **THEN** the live ebuild is published as the next `-rN` for that PV

### Requirement: Optional arm64 not required

The probe SHALL NOT require a successful arm64 emerge. An arm64 canary MAY be run only with explicit force-keyword of Gentoo `dev-lisp/sbcl` and SHALL NOT alone gate completion.

#### Scenario: Complete without arm64

- **WHEN** riscv64 and ppc64le are green
- **THEN** the probe may be marked complete without arm64 results

### Requirement: Explicit waiver

If a required arch cannot be completed, a human MAY waive that arch with a written note in the change tasks. A waiver SHALL state the residual risk. Without waiver, both required arches MUST pass.

#### Scenario: Waiver recorded

- **WHEN** a required arch is waived
- **THEN** tasks or an equivalent note records which arch and why
