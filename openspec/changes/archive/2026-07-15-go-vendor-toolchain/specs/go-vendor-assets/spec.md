## ADDED Requirements

### Requirement: Host Go meets go.mod language version

After the temporary clone for `GoVendorAndAssets` and after locating `go.mod` in the configured subdirectory (or repository root), the program SHALL parse the module’s top-level `go` directive version and the host toolchain version from `go version` (or an equivalent injectable probe). If both versions parse successfully and the host version is strictly older than the `go.mod` requirement, the program SHALL hard-fail that package **before** running `go mod download`, and SHALL NOT publish assets or mutate the overlay for that attempt. The error message SHALL name the host version and the required version and SHALL indicate that the operator must install a newer `dev-lang/go` (the program SHALL NOT set `GOTOOLCHAIN=auto` or download a Go toolchain to work around the mismatch). If the host version is greater than or equal to the required version, vendor construction MAY proceed with `go mod download` as today. If `go.mod` has no parseable `go` directive, the program SHALL skip this gate and proceed to `go mod download`. If the host `go version` output cannot be parsed, the program SHALL hard-fail with an error that the host Go version could not be determined.

#### Scenario: Host older than go.mod hard-fails before download

- **WHEN** the cloned `go.mod` contains `go 1.26.5` and the host reports Go `1.26.4`
- **THEN** the package hard-fails without running `go mod download` and the error names both versions

#### Scenario: Host satisfies go.mod

- **WHEN** the cloned `go.mod` contains `go 1.26.4` and the host reports Go `1.26.4` or newer
- **THEN** the program proceeds to `go mod download` for vendor construction

#### Scenario: No GOTOOLCHAIN auto workaround

- **WHEN** the host Go is older than the `go.mod` requirement
- **THEN** the program does not set `GOTOOLCHAIN=auto` on the vendor child process to bypass the failure

### Requirement: Ebuild BDEPEND matches go.mod Go version

When applying overlay ebuild changes for a `GoVendorAndAssets` package after a successful assets publish (or as part of the same overlay mutation that would rewrite assets `SRC_URI`), the program SHALL ensure the ebuild declares a build dependency atom `>=dev-lang/go-<version>:=` where `<version>` is the `go` directive from that package’s cloned `go.mod` (for example `1.26.5` or `1.26`). The program SHALL insert such a `BDEPEND` if no `dev-lang/go` atom is present, or replace an existing `dev-lang/go` atom so it matches the required version. The program SHALL NOT remove unrelated dependency atoms. The `toolchain` directive in `go.mod`, if present, SHALL NOT be used as the BDEPEND version source. If the ebuild already at the target PV lacks a correct Go `BDEPEND` while remote PV is unchanged, the program SHALL treat that as needing an overlay content fix (including revision bump when required by existing same-PV fix rules) rather than soft-skipping solely because the version string matches remote.

#### Scenario: Insert BDEPEND when missing

- **WHEN** the ebuild inherits `go-module` and has no `dev-lang/go` BDEPEND atom and `go.mod` requires `go 1.26.5`
- **THEN** after overlay rewrite the ebuild contains `>=dev-lang/go-1.26.5:=` in `BDEPEND`

#### Scenario: Replace outdated Go BDEPEND

- **WHEN** the ebuild has `BDEPEND=">=dev-lang/go-1.24.11:="` (or another older go atom) and `go.mod` requires `go 1.26.5`
- **THEN** after overlay rewrite the go atom is `>=dev-lang/go-1.26.5:=`

#### Scenario: Same PV missing BDEPEND is not a pure soft-skip

- **WHEN** local and remote PV are equal, assets SRC_URI is already parameterized, but the ebuild lacks the required `>=dev-lang/go-…` atom for the cloned `go.mod`
- **THEN** the program does not soft-skip solely for “already at latest” and applies a content fix (including `-rN` bump when same-PV rules require it)
