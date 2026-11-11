# Proposal

## Why

Full-path `update` packs each DepsAndAssets tarball with `tar --sort=name` and a single-thread `xz -9e`. `--jobs` starts that many packs at once. Each pack opens a huge number of small files in name order, so the RAID array saturates on IOPS while the sequential bandwidth of the drives sits unused. One compression at a time, using the resolved `--jobs` count as `xz` threads, keeps a single name-order walk and spends the cores on that stream.

## What Changes

- At most one DepsAndAssets tar/xz compression runs at a time during an `update`. Clone, fetch, install, and per-crate extraction still overlap up to `--jobs`.
- That compression sets `XZ_OPT=-T{N} -9e`, where `N` is the resolved `--jobs` value (explicit positive `N`, otherwise the host processor count, minimum 1). `--jobs 1` stays `-T1` (the single-thread encoder). `--jobs` greater than 1 uses the multi-thread encoder. There is no extra thread cap.
- Tar owner, name sort, and mtime rules stay. The final file is still checked to be an xz stream.
- Already published assets stay recognized by release tag and filename. Reuse still downloads those bytes and compares them to an existing `.sha512` sidecar. This change does not republish existing releases.
- Ecosystem requirements that hard-code `XZ_OPT=-T1 -9e` follow the shared rule.

## Non-goals

- No new CLI flag, and no change to what `--jobs` means for package admission, planning, or commits.
- No cap below the resolved job count, and no `-T0` / "all cores" setting.
- No change to reuse, sidecar checks, or the hard-fail when a release tag exists but is incomplete.
- The host `tar -xJOf` extract of `v8/DEPS` from an existing rusty_v8 snapshot stays as it is.
- Crate `tar -xzf` staging, image-build `emerge`, and Portage doc compression stay as they are.
- No mass republish of historical tarballs.

## Capabilities

### New Capabilities

- None.

### Modified Capabilities

- `hermetic-asset-materialize`: One pack compression at a time; `XZ_OPT=-T{N} -9e` from the resolved `--jobs` value.
- `go-vendor-assets`: Go vendor pack uses that shared compression rule instead of a fixed `-T1`.
- `npm-deps-assets`: npm deps pack uses that shared compression rule instead of a fixed `-T1`.
- `bun-deps-assets`: BunCache and opencode InstallTree packs use that shared compression rule instead of a fixed `-T1`.
- `cargo-crates-assets`: Crates tarball pack uses that shared compression rule instead of a fixed `-T1`.
- `sbcl-deps-assets`: SBCL deps pack uses that shared compression rule instead of a fixed `-T1`.

## Impact

- `Update.Pack.XzTar` is the only compress launch. Go, npm, Bun, Cargo crates, the rusty_v8 snapshot pack, SBCL, uv, and Pdm all go through it. uv and Pdm have no separate `-T1` requirement text; they follow the hermetic rule.
- Tests that assert the exact string `-T1 -9e` learn `-T{N} -9e`, including `-T1 -9e` when the job count is 1.
- New full-path packs with `--jobs` greater than 1 differ in bytes from a `-T1` pack of the same tree. Published releases are left in place. A one-job pack still uses the single-thread encoder.
- `xz` at `-9e` uses on the order of 1.25 GiB per thread. The resolved job count is the thread count, including the default processor count.
