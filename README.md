# mndz-overlay-manager

Haskell CLI for managing a Gentoo overlay: list ebuilds, check for outdated packages, apply updates with Manifest regeneration and GPG-signed commits, maintain Portage `metadata/md5-cache`, and reclaim the manager’s private distfiles cache.

## Prerequisites

### Build requirements

This project targets **GHC 9.10.x** and needs a matching **cabal-install**. The recommended way to install both is [GHCup](https://www.haskell.org/ghcup/): install GHCup, then select (or install) a 9.10 series GHC and Cabal so `ghc --version` reports 9.10.x before you build.

### Runtime requirements

| When | Tools on `PATH` |
|------|------------------|
| `update` (always) | `git`, `ebuild` (Portage), `egencache` (Portage), `gpg` |
| `gencache` | `git`, `egencache`, `gpg` |
| `update` of packages that **need work** and use **full-path** DepsAndAssets materialize (new vendor/deps/crates tarballs) | `docker` on `PATH` and a usable product Gentoo materialize image (host CPU architecture). The image provides `go`, `node`/`npm`, `bun`, `sbcl`+Quicklisp/qlot, `cargo`, `pycargoebuild`, `tar`, `xz`, `git`, and fetchers. Host `go` / `npm` / `bun` / `sbcl` / `pycargoebuild` / `xz` are **not** required for that path. |
| `update` that only **reuses** existing GitHub release assets | no Docker and no host language toolchains (download + verify stay on the host) |

`list` and `outdated` only need a readable overlay and a valid config; they do not require Portage, GPG, or Docker. Help (`--help`) does not load configuration and needs no overlay.

GPG-signed overlay/assets commits, SSH `git push`, the GitHub token, `ebuild` / `egencache`, and overlay/assets worktrees stay on the **host**. The materialize container does not receive `GITHUB_TOKEN`, `GNUPGHOME`, or `SSH_AUTH_SOCK`.

### Materialize image (full-path `update`)

Build the in-repo Gentoo image once (or whenever engines/`go.mod` outgrow it). The CLI does **not** `docker build` as a side effect of `update`; a missing image is a preflight hard-fail.

```bash
docker build -t mndz-overlay-manager/materialize:local -f docker/materialize/Dockerfile .
```

The CLI uses that tag by default. Override with `MNDZ_MATERIALIZE_IMAGE` if you retag or pull a different name. The image must match the **host CPU architecture** (no qemu/foreign-arch materialize).

## Build and run

```bash
cabal build all
cabal run mndz-overlay-manager -- --help
```

Use `cabal run mndz-overlay-manager -- COMMAND --help` for subcommand help. After a successful build you can also run the installed binary name the same way if you have it on `PATH` via Cabal.

## Configuration

Default config path (XDG):

- `$XDG_CONFIG_HOME/mndz/overlay-manager.toml` when `XDG_CONFIG_HOME` is set
- otherwise `~/.config/mndz/overlay-manager.toml`

Override with `--config FILE.toml`. Work subcommands always load the config file; `--overlay-path` overrides only the overlay root after load.

### Keys

| Key | Required | Purpose |
|-----|----------|---------|
| `overlay-path` | yes | Root of the Gentoo overlay (must be a git work tree for `update` and `gencache`) |
| `assets-path` | no | Git work tree for vendor/deps asset sidecars (required when `update` will publish assets) |
| `github-token` | no | GitHub API token for authenticated fetch / release publish |
| `distfiles-path` | no | Private Portage `DISTDIR` for `ebuild … manifest` during `update` (default: XDG cache path below) |
| `check-cache-ttl` | no | How long successful outdated-check / plan results are reused (human duration, default **5m**). Single unit: `s` / `m` / `h` / `d` (for example `30s`, `5m`, `1h`). **`0` or `0s` disables** the check cache (never read, never write) |

**Token resolution order** (first non-empty wins): environment `GITHUB_TOKEN`, then `GH_TOKEN`, then `github-token` in the config. Prefer env vars in shared environments; the program never logs the raw token.

Work commands **warn** (and continue) when the loaded config file is not mode `0600` (owner read/write only). Token resolution is unchanged; this is not a hard failure. Help-only paths do not load the file and do not emit the warning.

### Manager distfiles (private DISTDIR)

By default, `update` runs Portage `ebuild … manifest` with `DISTDIR` set to a **private, operator-owned cache** so fetches do not land in sticky system `/var/cache/distfiles` (where root/`portage` ownership and the sticky bit commonly cause `EPERM` rename failures mid-apply).

Default path (XDG cache):

- `$XDG_CACHE_HOME/mndz/overlay-manager/distfiles` when `XDG_CACHE_HOME` is set and non-empty
- otherwise `~/.cache/mndz/overlay-manager/distfiles`

Override with config key `distfiles-path` or global `--distfiles-path DIR` (CLI wins over config over the default). You *may* point this at the system Portage DISTDIR if you accept sticky/ownership risk; `eclean` will refuse that path.

### Example

```toml
overlay-path = "/path/to/mndz-overlay"
assets-path = "/path/to/mndz-overlay-assets"
# github-token = "ghp_..."   # optional; prefer GITHUB_TOKEN / GH_TOKEN
# distfiles-path = "/path/to/private-distfiles"  # optional; default is XDG cache
# check-cache-ttl = "5m"  # optional; default 5m; use "0s" to disable
```

### Check cache (outdated / update)

`outdated` and `update` share an on-disk **check cache** of successful latest-version fetches and DepsAndAssets runtime-lane plans so a common inspect-then-apply workflow does not repeat upstream discovery within the TTL.

Default location (XDG cache):

- `$XDG_CACHE_HOME/mndz/overlay-manager/check-cache/` when `XDG_CACHE_HOME` is set and non-empty
- otherwise `~/.cache/mndz/overlay-manager/check-cache/`

One JSON file per overlay is named `<friendly>-<hash12>.json` (sanitized overlay directory basename plus a short hash of the absolute overlay path). Entries are invalidated when the package’s local non-live versions, update source, or ebuild/Manifest content change. Use `--refresh` on either command to ignore existing entries for reads and force live network work (fresh entries are still written when caching is enabled).

## Commands

Global options apply **before** the subcommand (for example `mndz-overlay-manager --jobs 4 outdated`). Help-only paths do not require a config file.

### Global options

| Option | Purpose |
|--------|---------|
| `--config` / `-c FILE.toml` | Config path (overrides the XDG default) |
| `--overlay-path DIR` | Use this overlay root instead of `overlay-path` from config |
| `--distfiles-path DIR` | Use this directory as the manager private Portage DISTDIR (overrides `distfiles-path` / XDG default) |
| `--jobs N` | Max concurrent package jobs (default: host CPU count); mainly affects `outdated` and `update` |
| `-v` / `--verbose` | Increase log verbosity from warn (repeatable: `-v` → info, `-vv` → debug) |
| `--log-level LEVEL` | Set log level (`error` \| `warn` \| `info` \| `debug`); overrides `-v` when set |
| `--no-progress` | Disable interactive activity indicators (useful for CI or plain logs) |
| `--no-color` | Disable ANSI colors in logs and indicators (also honors non-empty `NO_COLOR`) |

### `list`

Inventory every ebuild in the configured overlay. Prints one package atom per line in the form `category/package-version` to standard output. Useful for scripting or a quick check that the overlay path and discovery look right. There are no subcommand-local flags; empty inventory is an error.

```bash
cabal run mndz-overlay-manager -- list
cabal run mndz-overlay-manager -- --overlay-path /path/to/overlay list
```

### `outdated`

Compare discovered packages to their configured update sources and report packages that have a newer upstream version (or a runtime-lane gap for DepsAndAssets packages). Outdated lines go to standard output; warnings (unmapped packages, fetch failures, local ahead of remote) go to the log on stderr. Soft failures do not by themselves force a non-zero exit; spine failures (missing config, invalid overlay, empty inventory, unknown/ambiguous package targets) do.

**Targets:** zero or more package arguments as `category/package` or an unambiguous package name (same form as `update` / `gencache`). With no arguments, every discovered package is checked. With one or more targets, only the selected packages are checked.

**Flags:** `--refresh` forces live check/plan work (ignores the check cache for reads).

```bash
# All discovered packages
cabal run mndz-overlay-manager -- outdated
cabal run mndz-overlay-manager -- -v --jobs 4 outdated

# One or more packages
cabal run mndz-overlay-manager -- outdated dev-util/crush
cabal run mndz-overlay-manager -- outdated crush dolt

# Force live network checks
cabal run mndz-overlay-manager -- outdated --refresh
```

### `update`

Apply updates for packages that need work: rename or rewrite ebuilds, regenerate Manifests with Portage `ebuild`, regenerate package-scoped Portage `egencache` md5-cache, and create GPG-signed git commits in the overlay (ebuild/Manifest and `metadata/md5-cache/` paths together). For packages under the **DepsAndAssets** technique (Go vendor, npm/Bun deps, Cargo crates, or Sbcl/Autolith deps), it may also materialize cache/vendor/crates/deps tarballs and publish checksums/releases under `assets-path` (requires a resolvable GitHub token). **Full-path** materialize runs in the Gentoo Docker image (`docker` + image on `PATH`); reuse of an existing assets release stays on the host and does not require Docker or host `go`/`npm`/`bun`/`sbcl`/`pycargoebuild`.

**Targets:** zero or more package arguments as `category/package` or an unambiguous package name. With no arguments, every inventory package is planned; packages that need work are mutated and others soft-skipped. Explicit targets that do not need work are soft-skipped.

**Flags:** `--refresh` forces live latest fetch / deps plan (ignores the check cache for reads). After a successful apply, the package’s cache entry is rewritten with the post-apply fingerprint when caching is enabled.

```bash
# All packages that need work
cabal run mndz-overlay-manager -- update

# One or more packages
cabal run mndz-overlay-manager -- update dev-util/crush
cabal run mndz-overlay-manager -- update crush dolt

# Common operator flags
cabal run mndz-overlay-manager -- --jobs 2 -v update
cabal run mndz-overlay-manager -- --no-progress update category/package
cabal run mndz-overlay-manager -- update --refresh
```

`update` runs a **plan phase** first (using the check cache when enabled, same needs-work rules as `outdated` / apply), then conditional assets/token checks for packages that need work, then reuse vs full classification, then `docker` + materialize-image checks when any unit is full path, then the free-space gate, then concurrent mutate/apply. Spine tools (`git`, `ebuild`, `egencache`, `gpg`) and layout / manager-distfiles probes run before plan. When at least one package that needs work will attempt `DepsAndAssets`, it also checks that `assets-path` is a git work tree and a GitHub token can be resolved. Overlay commits are signed; ensure the overlay (and assets) repos have `user.signingkey` configured for GPG.

#### Free space, `TMPDIR`, and concurrent materialize

Heavy `DepsAndAssets` work (clone, language package download, tarball pack) and reuse downloads write under a **product temporary workspace** on the effective temp root — **`TMPDIR` when set and usable**, otherwise the system default (often `/tmp`, which may be a small tmpfs). Free-space checks still measure that root’s filesystem (not a separate device for the workspace subdirectory). Manager distfile fetches for `ebuild … manifest` write under the effective manager distfiles path (XDG cache by default), not under the temp workspace.

Layout (one run root per `update` process that opens heavy temp work). Run ids are ISO 8601 **basic** local time with numeric offset, pid, and a short hex suffix — for example `20260810T154207-0700-4242.a8f3` (no `:`, so POSIX `PATH` walks stay valid):

```text
$TMPDIR/mndz/overlay-manager/<run-id>/
  <category>/<package>/<pv>-full|reuse/
    out/    # staged distfiles / downloaded assets
    work/   # clones, language caches, pack stages
```

Lifecycle:

- A unit that **succeeds** or **soft-skips** is deleted immediately (so concurrent `--jobs` reclaim space as packages finish).
- A unit that **hard-fails** is **retained**; the error message includes the absolute unit path for investigation.
- If the whole run has **no hard-fail**, the run root is removed and empty `mndz/overlay-manager` / `mndz` brand directories under the temp root are pruned.
- Residuals after a hard-fail or process crash may be removed manually (for example `rm -rf "$TMPDIR/mndz/overlay-manager/<run-id>"`).

After planning which packages **need work**, and after classifying each heavy unit as **reuse** or **full path**, `update` estimates free-space need only for those heavy units—not a full-path estimate for every inventory package on bare `update`. Estimates use prior overlay **Manifest `DIST` sizes** and/or GitHub release asset **`size`**: reuse uses near-exact asset size (or Manifest/floor when size is missing); full path multiplies baseline by ecosystem expansion factors; both add a fixed **256 MiB** safety margin. Under `--jobs N` it requires free space for both the largest single unit and the sum of the up to **N** largest unit needs on each hard-check filesystem (temp and manager distfiles; merged when they share one device). Multiple sequential PVs within one package contribute the **largest single-PV** need to concurrent sum, not the sum of all PVs. Distfiles already present under the manager path do not add reservation. Prune-only work and plan/classify hard-fails do not contribute units.

If free space is insufficient for the planned needs-work units, `update` **hard-fails early** with the path, free vs need, and remediation hints (free space, set `TMPDIR` to roomier disk storage such as `$HOME/local/tmp`, or lower `--jobs`). That is intended to prevent mid-materialize `no space left on device` when the planned concurrent work already cannot fit.

Live **system Portage DISTDIR** (when it differs from the manager path) is **warn-only** if free space there looks tight; it does not hard-fail the command by itself.

```bash
# Prefer a disk-backed temp root when /tmp is a small tmpfs
TMPDIR=$HOME/local/tmp cabal run mndz-overlay-manager -- update

# Or reduce concurrent materialize pressure
cabal run mndz-overlay-manager -- --jobs 1 update
```

If md5-cache is **missing**, hard-fail recovery is `gencache category/package`. If `_md5_` **mismatches**, use `gencache --force category/package`, then retry `update`.

### `gencache`

Generate or repair Portage **md5-dict** cache under `metadata/md5-cache/` via `egencache`, then create **one** GPG-signed overlay commit of changed cache paths (message `metadata: regenerate md5-cache`). No empty commit when nothing changes.

**Targets:** zero or more package arguments as `category/package` or an unambiguous package name. With no arguments, every package that has at least one ebuild is selected.

**Strict-strict policy:** without `--force`, missing cache is generated (bootstrap), matching packages are skipped, and `_md5_` mismatches hard-fail. With `--force`, every selected package is regenerated.

```bash
# Full-tree bootstrap / bulk regenerate
cabal run mndz-overlay-manager -- gencache

# One package
cabal run mndz-overlay-manager -- gencache dev-util/crush

# Overwrite mismatched or force-refresh after eclass bumps
cabal run mndz-overlay-manager -- gencache --force
cabal run mndz-overlay-manager -- gencache --force crush
```

### md5-cache bootstrap and recovery

1. In the overlay, ensure `metadata/layout.conf` contains `cache-formats = md5-dict` (and commit that change if you added it). The manager does **not** edit `layout.conf` for you.
2. Run `gencache` once for the full tree to populate `metadata/md5-cache/` and create a signed commit.
3. Day-to-day version bumps use `update`, which regenerates package cache and co-commits it with ebuild/Manifest changes.
4. When `update` reports missing cache, run `gencache category/package`. When it reports `_md5_` mismatch (or after major Gentoo eclass changes), run `gencache --force category/package` (or full-tree `--force`).

### `eclean`

Delete the **manager private distfiles cache** used by `update` for Portage `ebuild … manifest` fetches (default under XDG cache `mndz/overlay-manager/distfiles`). This is **not** Gentoo `app-portage/eclean` and does **not** clean system Portage distfiles under `/var/cache/distfiles`. If the effective path is the system Portage DISTDIR (for example after `--distfiles-path /var/cache/distfiles`), the command refuses, logs an error, and exits `1`. A missing cache directory is a successful no-op.

```bash
# Clean the default (or config) manager distfiles cache
cabal run mndz-overlay-manager -- eclean

# Clean an explicit manager cache path
cabal run mndz-overlay-manager -- --distfiles-path /path/to/private-distfiles eclean
```

## Development

Contributing, quality gates, and developer bootstrap: **[CONTRIBUTING.md](CONTRIBUTING.md)**.  
AI coding agents: **[AGENTS.md](AGENTS.md)**.

## License

See [LICENSE](LICENSE) (AGPL-3.0-or-later).
