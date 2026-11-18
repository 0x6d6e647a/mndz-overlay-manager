# mndz-overlay-manager

Haskell CLI for managing a Gentoo overlay: list ebuilds, check for outdated packages, apply updates with Manifest regeneration and GPG-signed commits, maintain Portage `metadata/md5-cache`, and reclaim the manager’s private distfiles cache.

## Prerequisites

### Build requirements

This project targets **GHC 9.10.x** and needs a matching **cabal-install**. The recommended way to install both is [GHCup](https://www.haskell.org/ghcup/): install GHCup, then select (or install) a 9.10 series GHC and Cabal so `ghc --version` reports 9.10.x before you build.

The documented build and run commands use [just](https://just.systems/) **1.55 or newer** (a system install; the repo does not install it).

### Runtime requirements

| When | Tools on `PATH` |
|------|------------------|
| `outdated` | `git`, `gpg` (to sync and verify the [managed Gentoo tree](#managed-gentoo-tree)); no Portage and no Docker |
| `update` (always) | `git`, `gpg`, `docker` (`ebuild … manifest` and `egencache` run in the [Portage tools container](#portage-tools-container)); no host `ebuild`, `egencache`, or `portageq` |
| `update` when any package **needs work** | **Docker Engine 28.0 or newer with the containerd image store** for the [smoke gate](#gated-publishing) (the smoke image is built on first use), an SSH key named by `ssh-identity` for the overlay push, and overlay (and, for DepsAndAssets, assets) branches in sync with their upstreams |
| `gencache` | `git`, `gpg`, `docker` (`egencache` runs in the Portage tools container); no host `egencache` |
| `update` of packages that **need work** and use **full-path** DepsAndAssets materialize (new vendor/deps/crates tarballs) | a usable product Gentoo materialize image with the needed toolchains (host CPU architecture). The image provides `go`, `node`/`npm`, overlay `node-gyp` (`dev-build/node-gyp::mndz`), `bun`, `sbcl`, overlay `qlot` (`dev-lisp/qlot::mndz`), `cargo`, `pycargoebuild`, Python, uv, pdm, and Rust, plus `tar`, `xz`, `git`, and fetchers. Full-path Pdm packing runs in that image, which provides Python and pdm. Host `go` / `npm` / `bun` / `sbcl` / `pycargoebuild` / `xz` are **not** required for that path. |
| `update` that only **reuses** existing GitHub release assets | no toolchains in the image and no host language toolchains (download + verify stay on the host) |
| `smoke` | `git`, `gpg`, `docker`; **Docker Engine 28.0 or newer with the containerd image store** (image mounts need both). The first `smoke` builds its own [smoke image](#smoke) (minutes). No host Portage. |
| `outdated`, `update`, `gencache`, `smoke`, `eclean` (unless `--no-metrics`) | GNU time at `/usr/bin/time` (`sys-process/time`) for [run metrics](#run-metrics) |

`list` only needs a readable overlay and a valid config; it does not require Portage, GPG, or Docker. `outdated` also needs `git` and `gpg` for the managed Gentoo tree (plus GNU `/usr/bin/time` unless `--no-metrics`), and does not require Portage or Docker. No command runs `portageq` or reads the host's Gentoo tree or `repos.conf`. Help (`--help`) does not load configuration and needs no overlay.

GPG-signed overlay/assets commits, SSH `git push`, the GitHub token, the managed Gentoo tree sync, and overlay/assets worktrees stay on the **host**. `ebuild … manifest` and `egencache` run in a container from the materialize image family. No container receives `GITHUB_TOKEN`, `GNUPGHOME`, or `SSH_AUTH_SOCK`.

### Portage tools container

`update` and `gencache` run every Portage `ebuild … manifest` and `egencache` in one **Portage tools container** per run (`mndz-tools-<run-id>`), started on the first such call and removed when the command exits. It runs as your uid and gid, binds the [managed Gentoo tree](#managed-gentoo-tree) read-only at `/var/db/repos/gentoo`, and binds the overlay and the manager distfiles directory at their host paths, so `Manifest`, md5-cache files, and fetched distfiles are owned by you. Its repository configuration puts `gentoo` at that tree and `mndz` at the overlay; host `repos.conf` and profile are not used. A tool that exits non-zero fails the unit exactly as a host run would; a container that cannot start fails every unit that needs it, naming the container failure.

The container uses the image `image.json` records as current, or `MNDZ_MATERIALIZE_IMAGE` when set. On a host with no recorded image, the first `update` or `gencache` that needs a Portage tool first builds a **base-only** materialize image (stage3 and base packages, no toolchains; this takes minutes) and records it with no toolchain floors. Later full-path work builds on it as usual.

### Materialize image (full-path `update`)

When `update` has classified **full-path** DepsAndAssets work, it **ensures** the default Gentoo materialize image (`mndz-overlay-manager/materialize:local`): it reuses the current image when recorded floors still satisfy this prepare, otherwise it generates a Dockerfile from an official Gentoo `stage3` glibc OpenRC flavor for the host CPU architecture and `docker build`s it (after a free-space check on probed Docker/containerd storage). A host architecture with no such official flavor hard-fails ensure; host `go` / `npm` / `bun` / `sbcl` / `pycargoebuild` are not used instead. GitMv and reuse-path work may proceed while that ensure runs. There is no in-repo Dockerfile to `docker build`; a manual image build is **not** a prerequisite of `update`.

The image has **no Gentoo tree of its own**. Every Portage `RUN` of the generated recipe bind-mounts the [managed Gentoo tree](#managed-gentoo-tree) read-only at `/var/db/repos/gentoo` (passed as the `gentoo` build context, with `.git` excluded by a `.dockerignore`), so ensure chooses atoms from and builds against the same commit the run planned with; the recipe never runs `emerge-webrsync`. The base step upgrades Portage, then runs `emerge --update --deep --newuse @world` before any toolchain. `FROM` pins the stage3 tag by digest (`gentoo/stage3:<tag>@sha256:…`). When ensure runs and `materialize-base-check-interval` (default 3d) has passed since the last check, it asks the Docker Hub registry for the tag's current digest (a `HEAD` request, no pull): a different digest rebuilds the image, the same digest only resets the timer, and a failed request keeps the image, warns, and leaves the check due. `MNDZ_MATERIALIZE_IMAGE` skips that check. A tree sync alone never triggers a build, but every build re-runs all Portage layers when the tree changed since the last build (mostly reinstalling binary packages from the caches below). `image.json` also records the tree commit, the stage3 digest, and the last base check.

The generated image installs language toolchains via Portage: it prefers a Gentoo `-bin` package when one can meet the floor, accepts testing KEYWORDS per atom (`~arch`, `::gentoo` or `::mndz`) when the floor is not stable-visible, does not set whole-image `ACCEPT_KEYWORDS` to `~arch`, and reuses locally built binpkgs across image rebuilds.

Bun inside the image comes from overlay `dev-lang/bun-bin::mndz` (overlay bind-mounted read-only at build). When that image will emerge overlay bun-bin, `update` regenerates bun-bin’s Manifest and package cache **before** `docker build` so Portage can verify distfiles; bun-bin’s GPG-signed overlay commit happens after that ensure attempt when ensure ran. When the image installs SBCL, qlot comes from overlay `dev-lisp/qlot::mndz` (same overlay bind) rather than a live Quicklisp installer fetch; if qlot needs GitMv work, Manifest and package cache are regenerated **before** that `docker build`, and qlot’s signed overlay commit is **not** delayed for ensure. Autolith is not withheld on qlot. When bun or node is installed, `node-gyp` comes from overlay `dev-build/node-gyp::mndz` (same overlay bind). Full-path sessions set `npm_config_nodedir=/usr`, `npm_config_python=/usr/bin/python3`, and `PYTHON=/usr/bin/python3` (they do not set `npm_config_offline`) so lifecycle `node-gyp rebuild` uses image Node headers. If node-gyp needs overlay file work, Manifest and package cache are regenerated **before** that `docker build`; node-gyp’s signed overlay commit is **not** delayed for ensure. opencode and ralph-tui are not withheld on node-gyp. Image metadata lives under the XDG cache:

- `$XDG_CACHE_HOME/mndz/overlay-manager/materialize/` when `XDG_CACHE_HOME` is set and non-empty (`image.json` plus the last generated `Dockerfile`)
- otherwise `~/.cache/mndz/overlay-manager/materialize/`

Image Portage DISTDIR (`/var/cache/distfiles`), PKGDIR (`/var/cache/binpkgs`), and binhost fetch caches (`/var/cache/binhost`) live in Docker BuildKit, not as XDG binpkg trees under that overlay-manager cache path (except `image.json` and the last generated Dockerfile). A successful default-tag `docker build` runs Gentoo `eclean-pkg --deep` and `eclean-dist --deep` after toolchain install so those caches keep the exact installed versions. `docker builder prune` wipes them; ensure does not run it. Cache sizes appear in the ensure build log. Moving a warm cache to another machine means copying `image.json` together with the docker image, not copying a host directory of binpkgs.

Both generated images set the baked Portage `MAKEOPTS` default before the first emerge. If `nproc` reports N processors inside the Docker build, the image retains `-jN -l(N+1)` for direct launches.

Override with `MNDZ_MATERIALIZE_IMAGE` to an **existing** tag: the CLI inspects/satisfies that tag only and does not `docker build` or `docker rmi` it. The image must match the **host CPU architecture** (no qemu/foreign-arch materialize). While run metrics record, the image must also provide GNU time at `/usr/bin/time`; a full-path unit whose image lacks it hard-fails with an error naming the image and `--no-metrics`.

The operator-supplied image must let root update `/etc/portage/make.conf` inside the workload container. Smoke, materialize, and Portage tools containers set `MAKEOPTS="-jN -l(N+1)"` from the resolved `--jobs N` value at startup, including when reusing an image. With the flag omitted, the value defaults to the host processor count. Changing it leaves the image eligible for reuse.

The generated image installs `sys-process/time` so run metrics can measure commands inside the container. The recipe leaves Portage's `sandbox`, `usersandbox`, `userpriv`, `network-sandbox`, `ipc-sandbox`, and `pid-sandbox` features on; inside `docker build` Portage logs that it is unable to unshare the namespaces and continues. Images from an older recipe generator are rebuilt once on the next ensure.

Full-path materialize sessions also bind the managed tree read-only at `/var/db/repos/gentoo` (for example, `pycargoebuild` reads `metadata/license-mapping.conf` from it). While a **full-path** unit is running, `update` keeps one named Docker container for that unit (`mndz-mat-<run-id>-<category>-<package>-<pv>`, slashes replaced so the name is Docker-legal). `docker ps`, `docker stats`, and `docker exec` can target it **while the unit runs**. The container is removed when that unit ends (`--rm` / `docker rm`). Do not drop `--rm` or keep failed containers for debugging; a hard-fail retains the host unit `work/` directory (see temp workspace below) as the investigation artifact.

## Build and run

Short recipes use the dev build (unoptimized, with debug info).

```bash
just build
just run --help
```

Use `just run COMMAND --help` for subcommand help. Arguments after `just run` are the manager's own arguments, globals before the work command (`just run --jobs 4 outdated crush`).

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
| `github-token` | no | Encrypted (`mndz1.`) GitHub token envelope for authenticated fetch / release publish. A plaintext value hard-fails every command that loads config until you run `github-token --force`. |
| `distfiles-path` | no | Private Portage `DISTDIR` for `ebuild … manifest` during `update` (default: XDG cache path below) |
| `check-cache-ttl` | no | How long successful outdated-check / plan results are reused (human duration, default **5m**). Single unit: `s` / `m` / `h` / `d` (for example `30s`, `5m`, `1h`). **`0` or `0s` disables** the check cache (never read, never write) |
| `ssh-identity` | no | One private-key path for `update`'s `git push` and sync fetch of the overlay and the assets repository. A leading `~` is allowed. Required whenever `update` has work, because it then pushes the overlay |
| `gentoo-tree-max-age` | no | How long a [managed Gentoo tree](#managed-gentoo-tree) sync check stays fresh before `outdated`, `update`, or `gencache` syncs again (same duration syntax as `check-cache-ttl`, default **6h**; `0s` syncs on every run) |
| `materialize-base-check-interval` | no | How often ensure asks the registry whether the pinned `gentoo/stage3` digest moved (same duration syntax, default **3d**) |
| `smoke-compile-cache-max-size` | no | Size budget of the [smoke compile cache](#smoke-compile-cache): a byte count with an optional `KiB`, `MiB`, or `GiB` suffix (for example `512MiB`), default **3GiB**. An invalid or negative value is a configuration error |

**Token resolution order** (first non-empty wins): environment `GITHUB_TOKEN`, then `GH_TOKEN`, then the decrypted `github-token` envelope in the config. Using an environment token logs a warning (and an extra warning when that value is not a fine-grained PAT `github_pat_`). `outdated` and `update` use that token for live `api.github.com` version fetch when a token is available. If the winning source is the encrypted config envelope, they prompt for the wrap password on a controlling TTY when this run will call `api.github.com`. `outdated` does not prompt when every `api.github.com` read for the run is a valid check-cache hit, including when a cached plan still needs work. `update` still prompts when it will look up or publish an assets release. A cache miss or `--refresh` of a GitHub-source package also prompts. Unattended `outdated` / `update` **must** set `GITHUB_TOKEN` or `GH_TOKEN` rather than relying on TTY decrypt; without a controlling TTY the command exits `1` and does not fall back to unauthenticated fetch. Live unauthenticated fetch is still allowed when no token is configured, is limited to **60 requests per hour** per IP, and logs a warning. The program never logs the raw token, wrap password, or ciphertext.

When `outdated` or `update` will call `api.github.com`, they first check GitHub Statuspage (**API Requests**; **Git Operations** immediately before each assets or overlay `git push` and before the overlay and assets sync fetch, even when the run makes no `api.github.com` call) and `GET /rate_limit`. Remaining `0`, HTTP 401, a required component `partial_outage`/`major_outage`, or a `/rate_limit` fetch failure **hard-fails** the command with exit `1`. Rate-limit exhaustion and rejected tokens during package work also exit `1` (not per-package warnings). `gencache` does not use this GitHub health gate.

The persisted token **must** be a fine-grained PAT (`github_pat_`) limited to the assets GitHub repository with **Contents: write** (Metadata: read comes with that grant). GitHub always includes read-only access to public repositories on a fine-grained PAT, so `github-token` still accepts a PAT when you own other public repositories. **Only select repositories** is operator guidance; the setter does not fail the probe because other owned repositories exist. Store it with `github-token` (see below); do not put a live PAT in the TOML.

Work commands **hard-fail** (error-level log, exit `1`) when the config file is not exactly mode `0600` (owner read/write only), or when its mode cannot be read. Run `chmod 600` on that file (XDG default or `--config` path) before the next work command. Help-only paths do not load the file and do not emit this error.

### Manager distfiles (private DISTDIR)

By default, `update` runs Portage `ebuild … manifest` (in the [Portage tools container](#portage-tools-container), with this directory bound at the same path) with `DISTDIR` set to a **private, operator-owned cache** so fetches do not land in sticky system `/var/cache/distfiles` (where root/`portage` ownership and the sticky bit commonly cause `EPERM` rename failures mid-apply).

Default path (XDG cache):

- `$XDG_CACHE_HOME/mndz/overlay-manager/distfiles` when `XDG_CACHE_HOME` is set and non-empty
- otherwise `~/.cache/mndz/overlay-manager/distfiles`

Override with config key `distfiles-path` or global `--distfiles-path DIR` (CLI wins over config over the default). You *may* point this at the system Portage DISTDIR if you accept sticky/ownership risk; `eclean` will refuse that path.

### Example

```toml
overlay-path = "/path/to/mndz-overlay"
assets-path = "/path/to/mndz-overlay-assets"
# github-token = "mndz1...."  # set with: mndz-overlay-manager github-token
# distfiles-path = "/path/to/private-distfiles"  # optional; default is XDG cache
# check-cache-ttl = "5m"  # optional; default 5m; use "0s" to disable
# gentoo-tree-max-age = "6h"  # optional; default 6h
# materialize-base-check-interval = "3d"  # optional; default 3d
# smoke-compile-cache-max-size = "3GiB"  # optional; default 3GiB
ssh-identity = "~/.ssh/keys/shanty_github_id"
```

`ssh-identity` names the one private key used when `update` will `git push` the assets worktree. A leading `~` is expanded to your home directory. Any other relative path is rejected. `list`, `outdated`, `gencache`, and an `update` that will not push that worktree accept a config that omits the key. For an SSH assets push, when OpenSSH will offer only configured identity files, `ssh-identity` must be one of those files, and a mismatch fails before the passphrase prompt.

A reachable agent that already has the key is reused and does not prompt. Otherwise the run prompts once for that key and does not leave it in the desktop agent.

### Check cache (outdated / update)

`outdated` and `update` share an on-disk **check cache** of successful latest-version fetches and DepsAndAssets runtime-lane plans so a common inspect-then-apply workflow does not repeat upstream discovery within the TTL.

Default location (XDG cache):

- `$XDG_CACHE_HOME/mndz/overlay-manager/check-cache/` when `XDG_CACHE_HOME` is set and non-empty
- otherwise `~/.cache/mndz/overlay-manager/check-cache/`

One JSON file per overlay is named `<friendly>-<hash12>.json` (sanitized overlay directory basename plus a short hash of the absolute overlay path). Entries are invalidated when the package’s local non-live versions, update source, or ebuild/Manifest content change. DepsAndAssets Bun plans also fingerprint overlay `dev-lang/bun-bin` (a missing field is a miss). Every DepsAndAssets plan records the managed Gentoo tree commit it was planned against, so a tree sync to a new commit makes those plans miss once (latest-version entries are unaffected). Use `--refresh` on either command to ignore existing entries for reads and force live network work (fresh entries are still written when caching is enabled). `--refresh` also syncs the managed Gentoo tree.

### Managed Gentoo tree

The manager keeps its **own** Gentoo ebuild tree and never reads the host's (`/var/db/repos/gentoo`, `repos.conf`, or `portageq`). Lane ceilings, materialize image atoms and builds, materialize sessions, and Portage tool runs all read this one tree:

- `$XDG_CACHE_HOME/mndz/overlay-manager/gentoo` when `XDG_CACHE_HOME` is set and non-empty
- otherwise `~/.cache/mndz/overlay-manager/gentoo`

It is a shallow clone of the `stable` branch of the Gentoo git mirror (`https://github.com/gentoo-mirror/gentoo.git`), made and updated with host `git` (about 700 MB plus about 100 MB of `.git`; the first clone needs 1 GiB free on the cache filesystem). Every commit is verified with host `gpg` before checkout: the signature must be valid and made by the Gentoo repository-mirror key (primary fingerprint `EF9538C9E8E64311A52CDEDFA13D0EF1914E7A72`, built into the program). Verification uses an isolated keyring at `…/overlay-manager/gentoo-keyring/`, never your GnuPG home or agent. The key is fetched by Web Key Directory or from `keys.gentoo.org`, and refreshed from `keys.gentoo.org` on every sync. A commit that fails verification hard-fails the command and leaves the tree where it was.

A sync does not move to the mirror tip. It reads the `TIMESTAMP` of the host-architecture Gentoo binhost index and checks out the newest mirror metadata commit at least one hour older than that, so image builds resolve versions the binhost already carries. The tree therefore lags the tip by up to about a day.

`outdated`, `update`, `gencache`, and `smoke` sync when the tree is missing, when the last successful sync check is older than `gentoo-tree-max-age` (default 6h), or on `--refresh` (`smoke` has no `--refresh`). A check that finds no newer commit still counts as a successful check. `list`, `eclean`, and help never touch the tree. A run that reads the tree holds it until it exits, except `smoke`, which releases it as soon as its tree snapshot exists; a sync waits for those runs (and logs that it is waiting), and other runs wait for a sync to finish. The tree identity is its commit id.

When the binhost index or the mirror cannot be reached, or the binhost index appears stalled (no eligible commit within seven days), the command keeps the existing tree and logs a warning. On a host with no tree yet, a clone failure exits `1`; when only the binhost index is unavailable, the first clone uses the verified mirror tip and warns that image builds may compile from source. `eclean` does not delete the tree.

## Commands

Global options apply **before** the subcommand (for example `mndz-overlay-manager --jobs 4 outdated`). Help-only paths do not require a config file.

### Global options

| Option | Purpose |
|--------|---------|
| `--config` / `-c FILE.toml` | Config path (overrides the XDG default) |
| `--overlay-path DIR` | Use this overlay root instead of `overlay-path` from config |
| `--distfiles-path DIR` | Use this directory as the manager private Portage DISTDIR (overrides `distfiles-path` / XDG default) |
| `--jobs N` | Package job limit and runtime Portage build parallelism (default: host CPU count) |
| `-v` / `--verbose` | Increase log verbosity from warn (repeatable: `-v` → info, `-vv` → debug) |
| `--log-level LEVEL` | Set log level (`error` \| `warn` \| `info` \| `debug`); overrides `-v` when set |
| `--no-progress` | Disable interactive activity indicators (useful for CI or plain logs) |
| `--no-color` | Disable ANSI colors in logs and indicators (also honors non-empty `NO_COLOR`) |
| `--no-metrics` | Do not record [run metrics](#run-metrics) for this invocation (logs a warning; also skips the GNU time requirement) |

### `list`

Inventory every ebuild in the configured overlay. Prints one package atom per line in the form `category/package-version` to standard output. Useful for scripting or a quick check that the overlay path and discovery look right. There are no subcommand-local flags; empty inventory is an error.

```bash
just run list
just run --overlay-path /path/to/overlay list
```

### `outdated`

Compare discovered packages to their configured update sources and report packages that have a newer upstream version (or a runtime-lane gap for DepsAndAssets packages). Outdated lines go to standard output; warnings (unmapped packages, fetch failures other than GitHub rate-limit/401, local ahead of remote) go to the log on stderr. Soft failures do not by themselves force a non-zero exit; spine failures (missing config, invalid overlay, empty inventory, unknown/ambiguous package targets, GitHub health / rate-limit / rejected token) do.

Authenticated live fetch uses `GITHUB_TOKEN`, then `GH_TOKEN`, then a decrypted config `github-token`. `outdated` does not prompt when every `api.github.com` read is a valid check-cache hit, including when a cached plan still needs work. Unattended `outdated` without a controlling TTY must set `GITHUB_TOKEN` or `GH_TOKEN` when a config envelope would otherwise need decrypt. GitHub rate-limit exhaustion and rejected tokens exit `1` after emitting any completed outdated lines.

For each DepsAndAssets package, after the version-gap lines, `outdated` prints one `PV -> removed` line per non-live version that `update` of that package alone would delete. The line has no lane label and no assets marker. Several revisions of one PV are one line, with the revision stripped. A version is left off that list when another on-disk ebuild still requires it, including a compile pin that an on-disk ebuild still names. A keep-set read or parse failure reports an error for that package and does not guess a removal; gap lines and a refuse line are still printed when the displayed plan has them. GitMv packages do not print `-> removed` lines. An older `dev-lang/bun-bin` compile-pin ebuild stays beside the newest ebuild, and bun-bin’s own outdated line stays the unlabeled `LOCAL -> REMOTE` line.

Bun packages whose runtime ceiling comes from overlay `dev-lang/bun-bin` are previewed against the plan untargeted `update` would apply when a newer bun-bin would change that plan. When `dev-lang/bun-bin` is in the check set and its upstream latest is strictly newer than the on-disk bun-bin PV (GitMv-outdated), the consumer’s lines are that hypothetical plan: one gap line per lane, including `[assets reusable]` when that plan’s PV qualifies, then any `PV -> removed` lines. Those lines are not described as blocked on bun-bin, and there is no `category/package:` refuse line. When that hypothetical plan has no version gap and would delete nothing, the consumer prints nothing; bun-bin still prints its own unlabeled `LOCAL -> REMOTE` line when bun-bin itself is GitMv-outdated. When bun-bin is left out of the check and the plan would change, `outdated` prints those same hypothetical lines and exactly one `category/package:` line with the same refuse text `update` uses (`update dev-lang/bun-bin` or untargeted `update`). That report still exits successfully (`0`). `update` of only the consumer still exits `1`. If bun-bin’s upstream latest cannot be fetched, the consumer check fail-closes (error naming bun-bin) instead of omitting the package as current. When bun-bin is in the check set but is not itself GitMv-outdated, the consumer follows the on-disk plan.

**Targets:** zero or more package arguments as `category/package` or an unambiguous package name (same form as `update` / `gencache`). With no arguments, every discovered package is checked. With one or more targets, only the selected packages are checked.

**Flags:** `--refresh` forces live check/plan work (ignores the check cache for reads) and a managed Gentoo tree sync. `--exclude 'PACKAGE ...'` accepts a whitespace-separated list of package tokens in that same form. Quote multiple tokens as one shell argument. An unquoted second word is a positional target. Replace `--exclude a,b` with `--exclude 'a b'` or `--exclude a --exclude b`. Those tokens are subtracted from the positional targets, or from the whole inventory when none are given. A non-empty removal logs one warning. An empty selection is an error.

```bash
# All discovered packages
just run outdated
just run -v --jobs 4 outdated

# One or more packages
just run outdated dev-util/crush
just run outdated crush dolt
just run outdated caddy-analyzer

# Force live network checks and a Gentoo tree sync
just run outdated --refresh

# Skip one package
just run outdated --exclude 'dev-util/codex dev-util/crush'
```

### `update`

Apply updates for packages that need work: rename or rewrite ebuilds, regenerate Manifests with Portage `ebuild`, regenerate package-scoped Portage `egencache` md5-cache, and create GPG-signed git commits in the overlay (ebuild/Manifest and `metadata/md5-cache/` paths together). Each unit is [smoke-tested before it is published or committed](#gated-publishing), and each commit is [pushed](#overlay-push-and-sync-requirements). For packages under the **DepsAndAssets** technique (Go vendor, npm/Bun deps, Cargo crates, Sbcl/Autolith deps, Uv deps, or Pdm deps), it may also materialize cache/vendor/crates/deps tarballs and publish checksums/releases under `assets-path` (requires a resolvable GitHub token). **Full-path** materialize runs in the Gentoo Docker image; reuse of an existing assets release stays on the host and needs no toolchains in the image and no host `go`/`npm`/`bun`/`sbcl`/`pycargoebuild`. Manifests and md5-cache are generated in the [Portage tools container](#portage-tools-container). During a full-path unit a named `mndz-mat-…` container is visible to `docker ps` / `docker stats` and is removed when that unit finishes.

**Targets:** zero or more package arguments as `category/package` or an unambiguous package name. With no arguments, every inventory package is planned; packages that need work are mutated and others soft-skipped. Explicit targets that do not need work are soft-skipped.

**Flags:** `--refresh` forces live latest fetch / deps plan (ignores the check cache for reads) and a managed Gentoo tree sync. After a successful apply, the package’s cache entry is rewritten with the post-apply fingerprint when caching is enabled. `--exclude 'PACKAGE ...'` accepts a whitespace-separated list of package tokens (`category/package` or an unambiguous package name), subtracted from the positional targets, or from the whole inventory when none are given. A non-empty removal logs one warning. An empty selection is an error. `update` does not pull an excluded package back into the selection. `--exclude dev-lang/bun-bin` leaves bun-bin an unselected ceiling provider and does not add bun-bin back. A dirty ensure-emerge atom is still checked when the materialize recipe will emerge it.

```bash
# All packages that need work
just run update

# One or more packages
just run update dev-util/crush
just run update crush dolt
just run update net-analyzer/caddy-analyzer

# Common operator flags
just run --jobs 2 -v update
just run --no-progress update category/package
just run update --refresh

# Skip one package. bun-bin stays out of the selection.
just run update --exclude dev-util/codex
just run update --exclude dev-lang/bun-bin
```

`update` runs a **plan phase** first (using the check cache when enabled, same needs-work rules as `outdated` / apply), then an overlay **dirty preflight** on selected package directories and on overlay atoms the materialize image will emerge (`dev-lang/bun-bin` when the image installs overlay bun-bin, `dev-lisp/qlot` when the image installs overlay qlot, `dev-build/node-gyp` when the image installs overlay node-gyp): dirty, staged, untracked, or deleted paths there hard-fail with exit `1` before mutate or `docker build`. Restore or finish that tree relative to git HEAD (unrelated overlay-root files such as `README.md` do not fail this check). Then conditional assets/token checks for packages that need work, reuse vs full classification, materialize-image checks when any unit is full path, the free-space gate, then concurrent mutate/apply. Spine tools (`git`, `gpg`, `docker`), layout / manager-distfiles probes, and the managed Gentoo tree sync run before plan. When at least one package that needs work will attempt `DepsAndAssets`, it also checks that `assets-path` is a git work tree, that `origin` parses as `github.com/{owner}/{repo}` (SSH or HTTPS), and that a GitHub token can be resolved. GitHub Releases and assets `SRC_URI` use that origin `{owner}/{repo}` (not a hardcoded GitHub owner or repository name). Overlay commits are signed; ensure the overlay (and assets) repos have `user.signingkey` configured for GPG.

If the winning token is the encrypted config envelope, `update` prompts once on a controlling TTY for the wrap password when this run will call `api.github.com` (live latest fetch, `/rate_limit` health, or assets-repository release lookup/create/upload) and keeps the decrypted token for that run. A cached lane plan that still needs work still prompts, because that apply looks up or publishes an assets release. GitMv-only updates with a full check-cache hit and no assets GitHub access do not decrypt. Unattended `update` must set `GITHUB_TOKEN` or `GH_TOKEN`. GitHub rate-limit exhaustion and rejected tokens abort plan/mutate with exit `1`.

Untargeted `update` plans Bun consumers against the selected bun-bin **remote** when bun-bin needs work (hypothetical overlay ceilings), and applies those consumers after bun-bin’s signed overlay commit **without** rediscovering ceilings from disk in the same run. Independent packages (mise, beads, grok-build-bin, …) may overlap bun-bin under `--jobs`; a withheld consumer does not occupy a job slot while waiting. When the run will sign, the operator is prompted once before that signed work, including before the image build; a commit that overlaps the build does not prompt again. The GPG passphrase prompt appears as soon as that unlock starts and does not time out while the operator is away. When ensure ran, bun-bin’s signed overlay commit is created after that ensure attempt and its smoke gate have both finished (a failed ensure does not skip the commit; a failed gate does); GitMv-only bun-bin commits right after its gate. Withheld consumers are admitted after that commit, without waiting for its push. `update ralph-tui` while bun-bin is unselected **does not** pull bun-bin into the selection: if a newer bun-bin would change ralph’s plan (or bun-bin’s latest cannot be fetched), ralph hard-fails naming `dev-lang/bun-bin` with recovery `update bun-bin` or untargeted `update`.

After each signed overlay commit, retained overlay ebuilds’ dependencies on other overlay packages remain satisfiable (no consumer ebuild naming a provider PV the tree no longer has). DepsAndAssets prune of a provider will not drop a PV that a remaining consumer ebuild still requires. GitMv will not rename away the only PV that still satisfies a remaining consumer pin, except that overlay `dev-lang/bun-bin` **compile pins** (`~dev-lang/bun-bin-<PV>` from packages such as opencode; `=` also still add-keeps) are **added-and-kept**: latest is added as `SLOT="0"` (`/usr/bin/bun`) and the pin PV stays as `SLOT="${PV}"` (`/usr/bin/bun-<PV>` only). Other GitMv packages (for example usage exact pins required by hk) still hard-fail instead of copying the old ebuild aside. `update PACKAGE` of a consumer whose to-be-written ebuild is unsatisfied, while that overlay provider is unselected, hard-fails the consumer and names the provider; it does not pull the provider into the selection. This is distinct from overlay wait-edges: Bun consumers still wait on bun-bin for runtime-lane ceilings; Cargo packages such as hk and mise are not withheld on `dev-util/usage` as a runtime-lane wait-edge (they may still wait at overlay write if a usage atom would otherwise be unsatisfiable).

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
- A unit that **hard-fails** is **retained**; the error message includes the absolute unit path for investigation. A `pycargoebuild` hard-fail leaves `pycargoebuild.log` in that retained unit directory and names that path in the error. A crate staging hard-fail leaves `crate-staging.log` in that retained unit directory and names it in the error.
- If the whole run has **no hard-fail**, the run root is removed and empty `mndz/overlay-manager` / `mndz` brand directories under the temp root are pruned.
- Residuals after a hard-fail or process crash may be removed manually (for example `rm -rf "$TMPDIR/mndz/overlay-manager/<run-id>"`).

After planning which packages **need work**, and after classifying each heavy unit as **reuse** or **full path**, `update` estimates free-space need only for those heavy units—not a full-path estimate for every inventory package on bare `update`. Estimates use prior overlay **Manifest `DIST` sizes** and/or GitHub release asset **`size`**: reuse uses near-exact asset size (or Manifest/floor when size is missing); full path multiplies baseline by ecosystem expansion factors; both add a fixed **256 MiB** safety margin. Under `--jobs N` it requires free space for both the largest single unit and the sum of the up to **N** largest unit needs on each hard-check filesystem (temp and manager distfiles; merged when they share one device). Multiple sequential PVs within one package contribute the **largest single-PV** need to concurrent sum, not the sum of all PVs. Distfiles already present under the manager path do not add reservation. Prune-only work and plan/classify hard-fails do not contribute units.

If free space is insufficient for the planned needs-work units, `update` **hard-fails early** with the path, free vs need, and remediation hints (free space, set `TMPDIR` to roomier disk storage such as `$HOME/local/tmp`, or lower `--jobs`). That is intended to prevent mid-materialize `no space left on device` when the planned concurrent work already cannot fit.

When `update` will `docker build` the materialize image, it also checks free space where Docker keeps image layers and the BuildKit cache: the **Docker data-root**, or, when Docker uses a system **containerd** (not the engine-bundled one), containerd's data root, which then holds both. Those directories are discovered from live Docker/containerd configuration rather than a hardcoded `/var/lib/docker`. Insufficient space names the probed path(s), the role (**image layers** versus **build cache**), and free versus need. The overlay tree bind-mounted into the build is not part of that image-storage check.

```bash
# Prefer a disk-backed temp root when /tmp is a small tmpfs
TMPDIR=$HOME/local/tmp just run update

# Or reduce concurrent materialize pressure
just run --jobs 1 update
```

If md5-cache is **missing**, hard-fail recovery is `gencache category/package`. If `_md5_` **mismatches**, use `gencache --force category/package`, then retry `update`.

#### Gated publishing

Every unit that needs work (GitMv, and DepsAndAssets full and reuse path) is **smoke-tested before anything about it is published or committed**. There is no option to skip this gate. Per unit the order is:

1. build (materialize) or rename;
2. ebuild write, `ebuild … manifest` (from the locally built distfile), and package `egencache`;
3. **smoke gate**: the runs [`smoke`](#smoke) would plan for the unit's new PV alone, one per distinct lane ceiling it serves, with the package's smoke checks;
4. assets sidecars, assets commit, push, and GitHub release (full path only);
5. download of each published asset at the exact URL in the ebuild, compared with the Manifest's size and hashes (full path only);
6. signed overlay commit;
7. overlay `git push`.

Expect each `update` that does work to take noticeably longer: one smoke run per lane ceiling per unit. Gated runs go through one smoke lane, one at a time, in the order units reach their gates; a unit waiting for the lane, or for another selected package its new ebuild depends on (`DEPEND`/`BDEPEND`/`RDEPEND`/`IDEPEND`/`PDEPEND`), holds no `--jobs` slot. That dependency wait ends when the dependency commits, fails, or is held, and the gate then tests against whatever `HEAD` holds. Dependency cycles fail every unit in the cycle. A gate that fails (including a full container disk, or a PV not keyworded for the host) is not retried in the same run.

Each gated run sees the overlay's `HEAD` plus only its own unit's package directory and md5-cache entries, mounted read-only, never other units' unfinished work. Distfiles the unit built but has not yet published are served to the gate by a **fetch shim**: Portage still computes the exact `SRC_URI` an end user would, and its `FETCHCOMMAND`/`RESUMECOMMAND` call a small script that copies the staged file for a URL under the assets repository's `releases/download/` prefix, fails on such a URL that is not staged, and hands every other URL to Portage's stock `wget` command. Portage verifies every file against the Manifest as usual. Reuse-path units stage nothing and fetch their published release.

Whenever a package needs work, `update` needs **Docker Engine 28.0 or newer with the containerd image store**, builds or reuses the [smoke image](#smoke), takes one Gentoo tree snapshot, and runs the sandbox probe; this overlaps the first units' build work. If any of it fails, no further unit starts and units already in progress fail at their gate. Gated runs use the [smoke compile cache](#smoke-compile-cache); `update --no-compile-cache` runs them without it. Gate logs are under `smoke/logs/<run-id>/` like `smoke`'s.

```bash
# Gate without the per-package compile cache
just run update --no-compile-cache hk
```

#### Overlay push and sync requirements

`update` **pushes the overlay** after each unit's signed commit: only the current branch, to its configured upstream, without force, in commit order. Before any mutation in a run that has work, it fetches the overlay's upstream (and the assets worktree's, when a DepsAndAssets unit will run) and refuses to start, with exit `1`, when a branch is detached, has no upstream, or is ahead of, behind, or diverged from it. The error names the state and the commits involved. To recover, push or reconcile the branch (for example `git -C <overlay> push`, or `git pull --rebase` when behind), set an upstream with `git branch --set-upstream-to`, then run `update` again. The overlay's `origin` push URL must be a GitHub SSH or web URL; the overlay push and sync fetch use the same `ssh-identity` and session SSH agent as the assets push, so **`ssh-identity` is needed whenever there is work**, including GitMv-only runs.

If an overlay push fails (or GitHub Git Operations reports an outage right before it), that unit's commit is **kept** locally and **all further publishing in the run stops**: no assets commits, pushes, or releases, no overlay commits or pushes, and no new units. Units already in progress run their gate and are then held. The error names the `git push` to run once the cause is fixed. The run exits `1`.

#### Held units

A unit is **held** when it changed overlay files without committing and its gate fails, its published assets fail verification, the run is interrupted (Ctrl-C or SIGTERM), publishing halted, or it is in a dependency cycle. Holding saves the unit's work first and only then rolls its overlay paths back to `HEAD` (other packages' files are untouched). If saving fails, nothing is rolled back and the error names the unit's paths. A held unit does not get the "may be left dirty" warning. Failures before the gate (rename, `ebuild … manifest`, `egencache`) are not held and keep that warning.

Entries are written to `${XDG_CACHE_HOME:-$HOME/.cache}/mndz/overlay-manager/held/<run-id>/<category>/<pn>-<pv>/` and contain:

- `overlay.patch`: the unit's overlay changes against `HEAD` (`git diff --binary -M`, including renames, deletions, and md5-cache entries);
- `distfiles/`: every distfile the unit built for publishing;
- `logs/`: copies of its gated runs' logs;
- `held.json`: schema version, package, PV, technique, path (full or reuse), each gated run's lane and outcome, the reason (`gate`, `verify`, `interrupted`, `halted`, or `cycle`), the base `HEAD`, the planned release and whether each asset was published, run id, and time.

The logged error names the entry. To inspect or re-apply a held unit by hand:

```bash
entry=~/.cache/mndz/overlay-manager/held/<run-id>/dev-util/hk-2.13.0
jq . "$entry/held.json"
cd /path/to/overlay
git apply --check "$entry/overlay.patch" && git apply "$entry/overlay.patch"
# If HEAD moved since, check out the recorded base_head or try: git apply --3way
```

Held entries are **never removed** by the program, and `eclean` leaves them alone; delete an entry directory yourself when you no longer need it.

### `gencache`

Generate or repair Portage **md5-dict** cache under `metadata/md5-cache/` via `egencache` in the [Portage tools container](#portage-tools-container) (eclass checksums come from the managed Gentoo tree), then create **one** GPG-signed overlay commit of changed cache paths (message `metadata: regenerate md5-cache`). No empty commit when nothing changes.

**Targets:** zero or more package arguments as `category/package` or an unambiguous package name. With no arguments, every package that has at least one ebuild is selected. `--exclude 'PACKAGE ...'` accepts a whitespace-separated list of package tokens in that same form, subtracted from the positional targets, or from the whole inventory when none are given. A non-empty removal logs one warning. An empty selection is an error. `--force` regenerates only the packages that remain.

**Strict-strict policy:** without `--force`, missing cache is generated (bootstrap), matching packages are skipped, and `_md5_` mismatches hard-fail. With `--force`, every selected package is regenerated.

```bash
# Full-tree bootstrap / bulk regenerate
just run gencache

# One package
just run gencache dev-util/crush

# Overwrite mismatched or force-refresh after eclass bumps
just run gencache --force
just run gencache --force crush

# Skip one package
just run gencache --exclude dev-util/crush --exclude dev-util/codex
```

### `smoke`

Install every on-disk (non-live) version of each selected package in a fresh Docker container, with Portage's sandboxes on, and run the package's checks. The worktree is tested as it is, including uncommitted changes; nothing in the overlay is written and nothing is committed or published. No GitHub token, GPG key, or SSH agent is needed.

**Targets:** zero or more package arguments as `category/package` or an unambiguous package name; with none, every discovered package. `--exclude 'PACKAGE ...'` works as for `outdated`. Every selected package must have a smoke definition in the program (all packages with an update policy do); a package without one hard-fails the command before any Docker work, naming it, and `--exclude` skips it.

```bash
# Every package
just run smoke

# One or more packages
just run smoke crush deno-bin craft-fonts

# Skip one package
just run smoke --exclude dev-util/codex

# Empty crush's compile cache before testing it
just run smoke --reset-compile-cache crush

# Test without any compile cache
just run smoke --no-compile-cache crush
```

**Compile cache flags.** `--no-compile-cache` runs every run of the command without the [compile cache](#smoke-compile-cache): no cache volume is mounted, ccache is off, and Go, configure, and Zig results stay in Portage's per-build directories. `--reset-compile-cache` deletes the compile caches of the selected packages before the first run (also with `--no-compile-cache`); other packages' caches are kept. An unknown or ambiguous target fails the command before anything is deleted.

**Runs.** Packages outside runtime lanes (GitMv, Unsupported, Uv, Pdm) get one run per ebuild. A lane-gated DepsAndAssets ebuild (Go, Npm, Bun, Cargo, SBCL) is installed with its runtime (for example `dev-lang/go`) capped at each lane ceiling it serves on the host architecture, read from the managed tree (or the overlay, for Bun) and the ebuild's own runtime floor; equal plain and tilde ceilings collapse to one run. An ebuild not keyworded for the host is skipped. Runs happen one at a time in package, version, and lane order; `--jobs N` sets `MAKEOPTS="-jN -l(N+1)"` inside the container (one emerge job), not the number of runs.

**Output.** Each run prints one line to stdout, for example `dev-util/beads-1.3.4 (dev-lang/go ~amd64): pass`, `…: skip: <reason>`, or `…: fail: <stage>`, where the stage is `plan`, `dependencies`, `build`, or `check` followed by the failed check names. A failed run does not stop the command. The summary logs the counts, the log directory, and every package tested with uncommitted changes. The exit status is `1` when any run failed and `0` otherwise (skips do not fail).

**Environment.** Each run uses a new container (`mndz-smoke-<run-id>-…`) from the **smoke image** `mndz-overlay-manager/smoke:local`, which is separate from the materialize image and holds only a stage3, an updated `@world`, GNU time, and ccache. Packages the binhost lacks are compiled once into a BuildKit cache used only by smoke image builds, and later image builds install them from there. `MNDZ_MATERIALIZE_IMAGE` does not affect it. Its sidecar and last recipe live in `…/overlay-manager/smoke/` under the XDG cache. It is rebuilt when the recipe generator changes, the image is gone, or the stage3 digest moved; the base check uses the same `materialize-base-check-interval` as the materialize image. A rebuild is gated on Docker storage free space and removes the previous smoke image.

- Containers get `--cap-add SYS_ADMIN` and nothing more (not privileged, default seccomp), so Portage's network, IPC, and PID sandboxes stay on. Before the first run, a probe container checks that those namespaces can be created; when they cannot (for example under an AppArmor profile that denies them), `smoke` exits `1`.
- At start, the managed tree is copied (without `.git`) into a per-command image `mndz-overlay-manager/smoke-tree:<run-id>` (about 670 MB of Docker storage), mounted read-only at `/var/db/repos/gentoo` in every container, and deleted when the command ends. Snapshots left by a killed command are deleted by the next `smoke`.
- The overlay is bound read-only at `/var/db/repos/mndz`. Every `::mndz` package is accepted as `~arch`; other Gentoo packages stay on the stable keyword except the runtime cap, the Python slot of a Uv or Pdm ebuild, and atoms a definition names. USE flags follow the profile, plus any `package.use` lines a definition names (for example `x11-libs/libxkbcommon X` for the craft apps). All licenses are accepted.
- Dependencies install first, from the Gentoo binhost or the Docker volume `mndz-smoke-binpkgs`, with their distfiles in the volume `mndz-smoke-distfiles`. Overlay packages are always built from source and never stored as binary packages. The package under test is then built from source with an empty container-local `DISTDIR`, so a dead download URL fails the run. The manager never prunes the two volumes; remove them by hand (`docker volume rm mndz-smoke-binpkgs mndz-smoke-distfiles`) to reclaim space.
- The container is detached from the network after the installs. Checks run as an unprivileged `smoke` user (your uid) with the environment from `/etc/profile`. A definition may add that user to a package's group for its own runs (`witen-warden-bin` joins `witen-warden` to read its configuration). Each command has a 60-second limit unless the check sets another; a check that needs the network is attached for that check only.

#### Smoke compile cache

Builds keep compiler and configure results between `smoke` commands in one Docker volume, `mndz-smoke-compile-cache`, with one directory per package (`<category>/<package>/`). A run container mounts only its own package's directory, at `/var/cache/mndz-compile`, so a build can neither see nor change another package's cache; dependencies built from source during a run use the cache of the package under test. Inside a package directory:

- `ccache/`: C and C++ compiles (ccache, through Portage's `FEATURES=ccache`). ccache reads its settings only from `/etc/mndz-ccache.conf` in the container and its environment, never from a file in the cache. Per package it is limited to 1 GiB or the budget, whichever is smaller.
- `go/`: Go's build cache, with builds using `-trimpath` so results survive version and revision bumps.
- `autoconf/<category>/<package>/<plain|tilde|none>/<ABI>`: `econf` configure results per built package, lane, and ABI, without environment, library, or install program results. When a run fails in a configure phase that used this cache, its error says so; rerun with `--no-compile-cache` to rule the cache out.
- `zig/`: Zig's global cache for packages built with Portage's Zig support.
- `.last-used`: when a run last started with the cache (builds cannot write it).

**Go trim workaround (fragile).** Go deletes build cache entries unused for five days whenever it runs, which would empty the Go cache between infrequent `smoke` commands. Before each build phase, smoke writes the current time to `go/trim.txt`, which makes Go skip that trimming. `trim.txt` is an undocumented internal of the `go` command, not a supported interface, and a Go release may stop honoring it (Go's developers declined to support it, and Go 1.28 work makes trimming more aggressive). The first run with each Go version in a command checks inside the container that trimming is still suppressed, and the test suite runs the same check against the development machine's `go`. When the check fails, `smoke` logs a warning that Go cache trimming is not suppressed for that Go version. Builds still succeed and results are still correct; only Go cache reuse between commands is lost.

**Cleanup and budget.** Before the first run of every `smoke` command that uses the cache, a short-lived helper container (no network, only the program's own scripts) removes, in order: the caches of packages no longer in the overlay; caches unused for 30 days; then the least recently used caches until the volume fits the budget. In the caches it keeps, it deletes Go and Zig entries unchanged for 30 days. The budget is `smoke-compile-cache-max-size` (default `3GiB`), lowered so that at least 2 GiB stays free on the filesystem holding Docker volumes. A cache used within the last 24 hours is never removed for age or budget, so a concurrent `smoke` command keeps its caches; when only such caches are over budget, cleanup logs a warning. Two commands never clean at the same time (they take `…/overlay-manager/smoke/compile-cache.lock`). If inspecting or cleaning the cache fails, `smoke` logs a warning and runs the whole command without the compile cache.

After each run that used the cache, `smoke` logs one line with that run's atom and lane, its ccache hits and misses, the Go cache entries it added, and the Go trim check result when the run checked; the stdout result line is unchanged. The same numbers go into [run metrics](#run-metrics).

To reclaim space: `--reset-compile-cache PACKAGE` empties one package's cache; removing the whole volume is manual, with `docker volume rm mndz-smoke-compile-cache` (the next `smoke` recreates it). `eclean` never touches the volume.

**Logs.** Each emerge step and each check writes its full output under `…/overlay-manager/smoke/logs/<run-id>/<category>-<package>-<pvr>[-plain|-tilde]/`, for passing runs too; a failed run's error names its log file. Each `smoke` keeps the log directories of the ten most recent earlier commands and deletes older ones. `eclean` does not touch them.

### md5-cache bootstrap and recovery

1. In the overlay, ensure `metadata/layout.conf` contains `cache-formats = md5-dict` (and commit that change if you added it). The manager does **not** edit `layout.conf` for you.
2. Run `gencache` once for the full tree to populate `metadata/md5-cache/` and create a signed commit.
3. Day-to-day version bumps use `update`, which regenerates package cache and co-commits it with ebuild/Manifest changes.
4. When `update` reports missing cache, run `gencache category/package`. When it reports `_md5_` mismatch (or after major Gentoo eclass changes), run `gencache --force category/package` (or full-tree `--force`).

### `github-token`

Interactively store an encrypted GitHub token in the overlay-manager TOML. Prompts on a controlling TTY (no echo) for a **fine-grained PAT** (`github_pat_` only) scoped to the assets repository with Contents: write, probes GitHub, then prompts twice for a wrapping password. Writes a `mndz1.` ciphertext envelope into `github-token` (file mode stays `0600`). Secrets are not accepted as CLI flags.

Requires `assets-path` whose `origin` is a `github.com/{owner}/{repo}` URL. Does not validate the overlay. An existing `github-token` key (plaintext or envelope) is refused unless `--force` is given; use `--force` to migrate a leftover plaintext PAT or to rotate.

```bash
# First store
just run github-token

# Replace plaintext or rotate the wrapped PAT
just run github-token --force
```

Create the PAT on GitHub: **Fine-grained**, resource owner matching the assets repo, **Only select repositories** (that one assets repo), **Contents: write**. GitHub always grants read-only access to public repositories, so `github-token` does **not** fail the probe when you own other public repositories. **Only select repositories** plus Contents: write on the assets origin is operator guidance rather than an extra-repository API check.

### `eclean`

Delete the **manager private distfiles cache** used by `update` for Portage `ebuild … manifest` fetches (default under XDG cache `mndz/overlay-manager/distfiles`). This is **not** Gentoo `app-portage/eclean` and does **not** clean system Portage distfiles under `/var/cache/distfiles`. If the effective path is the system Portage DISTDIR (for example after `--distfiles-path /var/cache/distfiles`), the command refuses, logs an error, and exits `1`. A missing cache directory is a successful no-op. [Held entries](#held-units) are never touched, even when `distfiles-path` points at a directory that contains them.

```bash
# Clean the default (or config) manager distfiles cache
just run eclean

# Clean an explicit manager cache path
just run --distfiles-path /path/to/private-distfiles eclean
```

## Run metrics

`outdated`, `update`, `gencache`, `smoke`, and `eclean` record each run by default, so you can see where a run spent its time and compare runs across builds. `list` and `github-token` never record.

Each run writes one directory:

- `$XDG_STATE_HOME/mndz/overlay-manager/metrics/<run-id>-<command>/` when `XDG_STATE_HOME` is set and non-empty
- otherwise `~/.local/state/mndz/overlay-manager/metrics/<run-id>-<command>/`

The run id is the same one used for the temp workspace run root and the materialize container names. The directory holds `run.jsonl`: one JSON object per line, starting with a `run_start` header (build identity, host, invocation) and ending with a `run_end` footer (outcome, resource use, counters such as check-cache hits). Between them are timed spans for phases, package steps, subprocesses, HTTP requests, and slot waits, plus machine `sample` lines every 5 seconds. Subprocesses are measured with GNU time. Command arguments are recorded with the GitHub token and other known secrets replaced by `<redacted>`; environment variables are never recorded. A `time/` subdirectory holds per-process GNU time files only while they are being read (a file that cannot be parsed is kept there).

`smoke` measures each emerge step and check command in its containers like a materialize container command (an `.outer` result for the host `docker exec` and an `.inner` result for the command, under one span per container), records one span per run named by its atom and lane, and writes a `container` resource event before each container is removed. With the compile cache on, each run also writes a `compile-cache` event (its span and atom, ccache hits and misses, Go cache entries added, and the Go trim check result and Go version when that run checked), and each command writes one `compile-cache.cleanup` event (cache size before and after cleanup, the budget, and the packages removed). `--no-compile-cache` writes neither.

Runs are kept; the manager never prunes the metrics directory. Delete old run directories by hand when you no longer need them.

**GNU time is required.** Before loading configuration, a recording command checks that `/usr/bin/time` is GNU time and that the metrics directory can be created. If either fails, it exits with status 1 and the error names `/usr/bin/time` (or the directory) and `--no-metrics`. Install `sys-process/time`, or opt out:

```bash
just run --no-metrics outdated
```

`--no-metrics` logs a warning that metrics are disabled and changes nothing else about the run. On `list` and `github-token` it is accepted with a warning that it has no effect. There is no config key for metrics.

If writing metrics fails partway through a run (for example, a full disk), the manager logs one warning, stops recording, and the command continues with the same result.

## Development

Contributing, quality gates, and developer bootstrap: **[CONTRIBUTING.md](CONTRIBUTING.md)**.  
AI coding agents: **[AGENTS.md](AGENTS.md)**.

## License

See [LICENSE](LICENSE) (AGPL-3.0-or-later).
