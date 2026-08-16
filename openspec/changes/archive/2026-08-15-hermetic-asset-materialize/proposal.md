## Why

Full-path DepsAndAssets packs run language tools on the operator host and archive whatever those tools write: GNU tar records `uname`/`uid`, npm packs `_logs` that name `$HOME` and the host kernel, qlot writes `/home/…/quicklisp` into Autolith `.qlot` configs, and BunCache stores absolute `/tmp/…` alias symlinks. Operators also have to install Go, Node/npm, Bun, SBCL/Quicklisp, and `pycargoebuild` on the Gentoo box. We need new packs to be identity-poor and language work to run in one pinned Gentoo image, while signing, `git push`, GitHub publish, and `ebuild … manifest` stay on the host.

## What Changes

- **Full-path materialize runs in Docker** (host CPU arch only). One Gentoo materialize image provides `go`, `node`/`npm`, `bun`, `sbcl`+Quicklisp, `cargo`, `pycargoebuild`, fetchers, `tar`, `xz`, and `git`. The Haskell CLI, Portage (`ebuild`/`egencache`/`portageq`), GPG, and SSH stay on the host.
- **Reuse path stays on the host** (download existing GitHub assets). No Docker, no language toolchains.
- **Docker is mandatory** when any classified unit is full-path. No host-toolchain fallback (that would reintroduce `~/.npmrc` / `~/quicklisp`).
- Container process identity: `HOME=/home/builder`. Bind-mounted unit `work/`/`out/` are written as the **operator uid/gid** (`docker run --user "$(id -u):$(id -g)"`).
- **Hermetic pack** in the shared tar helper and ecosystem post-steps (applies to every full-path pack, including inside the image):
  - `tar --owner=0 --group=0 --numeric-owner --sort=name --mtime` (clamped) plus PAX atime/ctime strip
  - `XZ_OPT=-T1 -9e` (extreme xz, single-thread for stable bytes) replacing `-T0`
  - npm: empty userconfig; **omit** `_logs/` and `_update-notifier*` from the tarball
  - SBCL/qlot: no operator-home pathnames in packed `.qlot` (unit/container `HOME` + rewrite if needed)
  - BunCache: rewrite absolute cache alias symlinks to relative targets before pack (or hard-fail if any remain)
  - Language tools see a generic `HOME` / empty npm userconfig (not the operator home)
- Work commands that load the overlay-manager TOML **warn** (do not hard-fail) when the file mode is not `0600`. Token presence/shape is unchanged.
- README documents Docker as the full-path runtime, the image, and the config-mode warning.

**Not BREAKING** for overlay consumers of already-published releases (go-forward packs only). **BREAKING** for operators: full-path `update` requires `docker` and the materialize image; host `go`/`npm`/`bun`/`sbcl`/`pycargoebuild` are no longer sufficient or required for that path.

### Non-goals

- Non-Gentoo Linux or macOS / Docker Desktop as supported operator hosts
- Qemu / foreign-arch asset creation or emerge smokes (later; same image MAY be a `FROM` base)
- Running the Haskell CLI, `ebuild … manifest`, `egencache`, GPG signing, or `git push` inside the container
- Host-toolchain fallback when Docker is missing
- Replacing historical GitHub release bytes (including `ralph-tui-0.12.0`); that one-off is a wiki handoff after this change is archived
- `--force-full-assets` / mass republish CLI
- Changing GitHub token resolution or forbidding `github-token` in the TOML
- Migrating ralph-tui from BunCache to InstallTree
- Per-arch opencode/bun native optional-deps contract

## Capabilities

### New Capabilities

- `hermetic-asset-materialize`: Full-path DepsAndAssets materialize runs in a host-arch Gentoo Docker image with generic `HOME` and operator-uid bind-mounts; reuse, publish, GPG, SSH, and Manifest stay on the host; shared hermetic pack rules (tar owners/mtime/sort, `XZ_OPT=-T1 -9e`, npm log omit, qlot path isolation, BunCache relative symlinks)
- `config-file-permissions`: Work commands that load the overlay-manager TOML warn when the file mode is not `0600` (not a hard failure; token policy unchanged)

### Modified Capabilities

- `update-command`: After classify, full-path units require `docker` (and a usable materialize image) instead of host `go`/`npm`/`bun`/`pycargoebuild`/fetchers; reuse-only cargo no longer requires host `pycargoebuild`; `xz` on the host is not required solely to pack (image provides it)
- `go-vendor-assets`: Full-path clone/download/pack runs in the materialize container; host Go gate applies to the **image** `go`; pack uses hermetic-asset-materialize rules (`-T1`, numeric-owner)
- `npm-deps-assets`: Full-path npm work in the container; empty userconfig; packed tree omits `_logs` / `_update-notifier*`; image Node gate
- `bun-deps-assets`: Full-path bun work in the container; BunCache absolute alias symlinks rewritten relative before pack; image Bun gate
- `cargo-crates-assets`: Full-path `pycargoebuild`/fetch/pack in the image; reuse-only cargo does not require those tools on the host
- `sbcl-deps-assets`: Full-path qlot/fff/pack in the image; Quicklisp is not required at the operator `~/quicklisp/setup.lisp`; packed `.qlot` MUST NOT contain operator-home pathnames
- `temp-workspace`: Full-path unit `work/` and `out/` are bind-mounted into the container at the **same absolute paths** the host disk gate measured
- `project-docs`: README runtime table and `update` docs describe Docker + image for full-path materialize, host spine/GPG/SSH/Portage, and the config `0600` warning

## Impact

- **Code**: `Update.Process` / materialize spine invoke `docker run` for full-path ecosystem builders; new image definition in-repo; `Update.Pack.XzTar` hermetic flags; npm pack filter; qlot path isolation/rewrite; BunCache symlink rewrite; `Config.Loader` mode warn; preflight swaps language tools for `docker`; tests for pack metadata, filters, preflight, and injectable docker runner
- **Operator**: Must install Docker and build/pull the materialize image before any full-path `update`; may drop host Go/Node/Bun/SBCL/Quicklisp/`pycargoebuild` for this product; config files not mode `0600` get a warning
- **Docs**: README (project-docs) in the same change
- **Out of tree**: Ralph 0.12.0 republish remains the wiki handoff, not this change’s tasks
