# Spec Delta

## ADDED Requirements

### Requirement: One DepsAndAssets compression at a time

During one `update`, at most one DepsAndAssets tar/xz compression SHALL run at a time. That includes Go vendor, npm deps, Bun deps, Cargo crates, a rusty_v8 snapshot, SBCL deps, uv deps, and Pdm deps packs. Clone, fetch, install, and per-crate extraction MAY still overlap up to the resolved `--jobs` limit.

#### Scenario: A second pack waits

- **WHEN** two full-path units in one `update` both reach tar/xz compression
- **THEN** the second compression does not start until the first has exited

#### Scenario: Other unit work still overlaps

- **WHEN** one unit is inside tar/xz compression and another admitted unit is cloning, fetching, or installing
- **THEN** that other work MAY proceed, still subject to the resolved `--jobs` package limit

### Requirement: Pack xz threads follow resolved jobs

The in-flight DepsAndAssets tar/xz compression SHALL set `XZ_OPT` to `-T{N} -9e`, where `N` is the resolved `--jobs` value: an explicit positive `--jobs N`, otherwise the host processor count, and at least 1. When `N` is 1, `XZ_OPT` SHALL contain `-T1`. The program SHALL NOT substitute `-T0` or a cap below `N`.

#### Scenario: Explicit jobs set the thread count

- **WHEN** `update` runs with `--jobs 4` and a DepsAndAssets pack compresses
- **THEN** that pack's `XZ_OPT` contains `-T4` and `-9e`

#### Scenario: One job stays single-thread

- **WHEN** `update` runs with `--jobs 1` and a DepsAndAssets pack compresses
- **THEN** that pack's `XZ_OPT` contains `-T1` and `-9e`

#### Scenario: Omitted jobs uses the processor count

- **WHEN** `update` omits `--jobs`, the host reports 8 processors, and a DepsAndAssets pack compresses
- **THEN** that pack's `XZ_OPT` contains `-T8` and `-9e`

## MODIFIED Requirements

### Requirement: Hermetic tar and xz

When packing any DepsAndAssets `*.tar.xz` distfile, the program SHALL invoke `tar` so that:

1. Archive members use owner `0`, group `0`, and numeric owner/group (no operator `uname`/`gname`).
2. Member names are sorted (`--sort=name` or equivalent).
3. Member mtimes are clamped to a fixed epoch (`--mtime` / `--clamp-mtime` or equivalent).
4. PAX atime/ctime extended headers are not stored when the tar implementation supports suppressing them.
5. Compression uses `XZ_OPT=-T{N} -9e` as specified by the pack xz threads requirement, where `N` is the resolved `--jobs` value, and the archive is forced to xz (`-J` or equivalent).
6. The final file is verified to be an xz stream as already required by ecosystem pack rules.

The program SHALL NOT record the operator username or uid in ustar `uname`/`gname`/`uid`/`gid` fields.

#### Scenario: Headers are root numeric

- **WHEN** a Go vendor, npm/Bun deps, cargo crates, or Sbcl deps tarball is packed
- **THEN** `tar --numeric-owner -t` lists members as `0/0` (or equivalent root/root) and not the operator username

#### Scenario: XZ is single-thread extreme

- **WHEN** the manager packs any of those tarballs
- **THEN** the pack process uses `XZ_OPT` containing `-T` equal to the resolved `--jobs` value and `-9e`
