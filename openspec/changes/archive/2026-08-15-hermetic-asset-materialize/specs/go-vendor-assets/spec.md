## MODIFIED Requirements

### Requirement: Vendor tarball matches go-module.eclass

From the go.mod directory the program SHALL: (1) populate a `go-mod` directory via `GOMODCACHE` pointing at that directory and `go mod download -modcacherw`; (2) create a tarball named `{pn}-{pv}-vendor.tar.xz` whose top-level entry is `go-mod/`; (3) pack with the hermetic tar/xz rules specified by `hermetic-asset-materialize` (`XZ_OPT=-T1 -9e`, numeric owner `0/0`, sorted names, clamped mtimes); (4) after writing the final vendor tarball path, verify that the file is an xz-compressed stream and hard-fail the pack if it is plain tar or otherwise not xz. The tarball filename SHALL use package name PN and PV without a leading `v`. Full-path clone, `go mod download`, and pack SHALL run in the materialize container.

#### Scenario: Tarball name and layout

- **WHEN** vendor construction succeeds for package name `beads` at PV `1.0.5`
- **THEN** the output file is named `beads-1.0.5-vendor.tar.xz` and unpacking it yields a top-level `go-mod` directory

#### Scenario: Go vendor pack uses extreme multi-thread xz

- **WHEN** the manager packs a Go vendor tarball
- **THEN** the pack process uses `XZ_OPT` containing `-T1` and `-9e` (single-thread extreme; hermetic-asset-materialize) and member owners are numeric `0/0`

#### Scenario: Go vendor pack rejects non-xz body

- **WHEN** the final `{pn}-{pv}-vendor.tar.xz` path is not an xz-compressed stream after pack
- **THEN** materialize hard-fails before assets publish treats the file as successful

### Requirement: Host Go meets go.mod language version

After the temporary clone for `DepsAndAssets` Go and after locating `go.mod` in the configured subdirectory (or repository root), the program SHALL parse the module’s top-level `go` directive version and the materialize-image toolchain version from `go version` inside the container (or an equivalent injectable probe of that image toolchain). If both versions parse successfully and the image version is strictly older than the `go.mod` requirement, the program SHALL hard-fail that package **before** running `go mod download`, and SHALL NOT publish assets or mutate the overlay for that attempt. The error message SHALL name the image Go version and the required version and SHALL indicate that the materialize image must provide a newer `go` (the program SHALL NOT set `GOTOOLCHAIN=auto` or download a Go toolchain to work around the mismatch). If the image version is greater than or equal to the required version, vendor construction MAY proceed with `go mod download`. If `go.mod` has no parseable `go` directive, the program SHALL skip this gate and proceed to `go mod download`. If the image `go version` output cannot be parsed, the program SHALL hard-fail with an error that the image Go version could not be determined. The reuse path SHALL NOT require this Go gate. The program SHALL NOT require a host `go` binary for this gate.

#### Scenario: Host older than go.mod hard-fails before download

- **WHEN** the cloned `go.mod` contains `go 1.26.5` and the materialize image reports Go `1.26.4`
- **THEN** the package hard-fails without running `go mod download` and the error names both versions

#### Scenario: Host satisfies go.mod

- **WHEN** the cloned `go.mod` contains `go 1.26.4` and the materialize image reports Go `1.26.4` or newer
- **THEN** the program proceeds to `go mod download` for vendor construction

#### Scenario: No GOTOOLCHAIN auto workaround

- **WHEN** the image Go is older than the `go.mod` requirement
- **THEN** the program does not set `GOTOOLCHAIN=auto` on the vendor child process to bypass the failure
