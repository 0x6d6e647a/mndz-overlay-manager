# Spec Delta

## MODIFIED Requirements

### Requirement: Pack xz threads follow resolved jobs

The in-flight DepsAndAssets tar/xz compression SHALL set `XZ_OPT` to `-T{N} -9e`, where `N` is the resolved `--jobs` value: an explicit positive `--jobs N`, otherwise the host processor count, and at least 1. When `N` is greater than 1, `XZ_OPT` SHALL also contain `--block-size=64MiB`. When `N` is 1, `XZ_OPT` SHALL contain `-T1` and SHALL NOT set a block size. The program SHALL NOT substitute `-T0` or a cap below `N`.

#### Scenario: Explicit jobs set the thread count

- **WHEN** `update` runs with `--jobs 4` and a DepsAndAssets pack compresses
- **THEN** that pack's `XZ_OPT` contains `-T4` and `-9e`
- **AND** that pack's `XZ_OPT` contains `--block-size=64MiB`

#### Scenario: One job stays single-thread

- **WHEN** `update` runs with `--jobs 1` and a DepsAndAssets pack compresses
- **THEN** that pack's `XZ_OPT` contains `-T1` and `-9e`
- **AND** that pack's `XZ_OPT` does not contain `--block-size`

#### Scenario: Omitted jobs uses the processor count

- **WHEN** `update` omits `--jobs`, the host reports 8 processors, and a DepsAndAssets pack compresses
- **THEN** that pack's `XZ_OPT` contains `-T8` and `-9e`
- **AND** that pack's `XZ_OPT` contains `--block-size=64MiB`

#### Scenario: Multi-thread block size does not depend on jobs

- **WHEN** the same staged tree is packed once with `--jobs 2` and once with `--jobs 8`
- **THEN** both packs' `XZ_OPT` contain the same `--block-size=64MiB`

### Requirement: Hermetic tar and xz

When packing any DepsAndAssets `*.tar.xz` distfile, the program SHALL invoke `tar` so that:

1. Archive members use owner `0`, group `0`, and numeric owner/group (no operator `uname`/`gname`).
2. Member names are sorted (`--sort=name` or equivalent).
3. Member mtimes are clamped to a fixed epoch (`--mtime` / `--clamp-mtime` or equivalent).
4. PAX atime/ctime extended headers are not stored when the tar implementation supports suppressing them.
5. Compression uses `XZ_OPT` as specified by the pack xz threads requirement (`-T{N} -9e`, plus `--block-size=64MiB` when `N` is greater than 1, where `N` is the resolved `--jobs` value), and the archive is forced to xz (`-J` or equivalent).
6. The final file is verified to be an xz stream as already required by ecosystem pack rules.

The program SHALL NOT record the operator username or uid in ustar `uname`/`gname`/`uid`/`gid` fields.

#### Scenario: Headers are root numeric

- **WHEN** a Go vendor, npm/Bun deps, cargo crates, or Sbcl deps tarball is packed
- **THEN** `tar --numeric-owner -t` lists members as `0/0` (or equivalent root/root) and not the operator username

#### Scenario: XZ is single-thread extreme

- **WHEN** the manager packs any of those tarballs
- **THEN** the pack process uses `XZ_OPT` containing `-T` equal to the resolved `--jobs` value and `-9e`
