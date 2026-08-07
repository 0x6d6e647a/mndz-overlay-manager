## 1. Cargo.lock pack inputs

- [x] 1.1 Add a focused parser (or module) for registry packages in `Cargo.lock`: name, version, checksum (ignore path/git packages without registry checksums)
- [x] 1.2 Unit tests for lock fixtures covering multiple packages, missing checksum, and non-registry sources

## 2. Manager crate pack

- [x] 2.1 Implement stage layout: extract each `{name}-{version}.crate` from distdir into `cargo_home/gentoo/{name}-{version}/` under the cargo temp tree
- [x] 2.2 Write `.cargo-checksum.json` with lock `package` checksum and empty `files` object
- [x] 2.3 Create archive via system `tar -acf` (or equivalent) of `cargo_home` with `XZ_OPT=-T0 -9e`; atomic temp + rename to final `{pn}-{pv}-crates.tar.xz`
- [x] 2.4 Hard-fail with a distinct pack error when a lock-listed registry `.crate` is missing or `tar`/`xz` fails
- [x] 2.5 Unit/fixture tests for checksum JSON paths and pack error cases (no network)

## 3. Wire full-path cargo materialize

- [x] 3.1 Pass `--no-write-crate-tarball` from `runPycargoebuild` / `CargoOps` while keeping `-c`, path, prefix, `-d`, `-i`, `-M`, `-f`
- [x] 3.2 After successful pycargoebuild, call pack before requiring the tarball to exist; plumb lock root path into pack
- [x] 3.3 Progress/status: surface a pack step (alongside pycargoebuild) where materialize progress already reports cargo steps
- [x] 3.4 Extend FullCargo (or equivalent) disk headroom checks for stage extract + output tarball when practical
- [x] 3.5 Update `CargoOps` / tests: mocks expect `--no-write-crate-tarball`; pack injectable or exercised with tiny fixture distdir

## 4. Reuse and integration tests

- [x] 4.1 Confirm reuse path still skips pycargoebuild **and** does not invoke pack
- [x] 4.2 Update cargo/materialize tests that assert pycargo args or tarball production for full path
- [x] 4.3 Keep ebuild post-processing (SRC_URI, empty CRATES on reuse, MSRV) behavior covered

## 5. Specs, docs, quality

- [x] 5.1 Ensure change delta matches implementation; `openspec validate --change cargo-crates-tarball-pack` (or project equivalent) is clean
- [x] 5.2 README/operator docs only if they falsely claim pycargoebuild alone writes the crates distfile—fix without expanding AGENTS
- [x] 5.3 `hk check` green before marking the change done
