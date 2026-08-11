## MODIFIED Requirements

### Requirement: Vendor tarball matches go-module.eclass

From the go.mod directory the program SHALL: (1) populate a `go-mod` directory via `GOMODCACHE` pointing at that directory and `go mod download -modcacherw`; (2) create a tarball named `{pn}-{pv}-vendor.tar.xz` whose top-level entry is `go-mod/`; (3) use xz compression with environment `XZ_OPT=-T0 -9e` (multi-threaded extreme) when invoking tar, or equivalent extreme multi-thread xz settings; (4) after writing the final vendor tarball path, verify that the file is an xz-compressed stream and hard-fail the pack if it is plain tar or otherwise not xz. The tarball filename SHALL use package name PN and PV without a leading `v`.

#### Scenario: Tarball name and layout

- **WHEN** vendor construction succeeds for package name `beads` at PV `1.0.5`
- **THEN** the output file is named `beads-1.0.5-vendor.tar.xz` and unpacking it yields a top-level `go-mod` directory

#### Scenario: Go vendor pack uses extreme multi-thread xz

- **WHEN** the manager packs a Go vendor tarball
- **THEN** the pack process uses `XZ_OPT` containing `-T0` and `-9e` (or equivalent extreme multi-thread settings)

#### Scenario: Go vendor pack rejects non-xz body

- **WHEN** the final `{pn}-{pv}-vendor.tar.xz` path is not an xz-compressed stream after pack
- **THEN** materialize hard-fails before assets publish treats the file as successful
