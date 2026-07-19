# mndz-overlay-manager

Haskell CLI for managing a Gentoo overlay: list ebuilds, check for outdated packages, and apply updates with Manifest regeneration and GPG-signed commits.

## Prerequisites

### Build requirements

This project targets **GHC 9.10.x** and needs a matching **cabal-install**. The recommended way to install both is [GHCup](https://www.haskell.org/ghcup/): install GHCup, then select (or install) a 9.10 series GHC and Cabal so `ghc --version` reports 9.10.x before you build.

### Runtime requirements

| When | Tools on `PATH` |
|------|------------------|
| `update` (always) | `git`, `ebuild` (Portage), `gpg` |
| `update` of packages that publish Go vendor/deps assets | additionally `go`, `xz` |

`list` and `outdated` only need a readable overlay and a valid config; they do not require Portage or GPG. Help (`--help`) does not load configuration and needs no overlay.

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
| `overlay-path` | yes | Root of the Gentoo overlay (must be a git work tree for `update`) |
| `assets-path` | no | Git work tree for vendor/deps asset sidecars (required when `update` will publish assets) |
| `github-token` | no | GitHub API token for authenticated fetch / release publish |

**Token resolution order** (first non-empty wins): environment `GITHUB_TOKEN`, then `GH_TOKEN`, then `github-token` in the config. Prefer env vars in shared environments; the program never logs the raw token.

### Example

```toml
overlay-path = "/path/to/mndz-overlay"
assets-path = "/path/to/mndz-overlay-assets"
# github-token = "ghp_..."   # optional; prefer GITHUB_TOKEN / GH_TOKEN
```

## Commands

Global options apply **before** the subcommand (for example `mndz-overlay-manager --jobs 4 outdated`). Help-only paths do not require a config file.

### Global options

| Option | Purpose |
|--------|---------|
| `--config` / `-c FILE.toml` | Config path (overrides the XDG default) |
| `--overlay-path DIR` | Use this overlay root instead of `overlay-path` from config |
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

Compare each discovered package to its configured update source and report packages that have a newer upstream version. Outdated lines go to standard output; warnings (unmapped packages, fetch failures, local ahead of remote) go to the log on stderr. No subcommand-local flags. Soft failures do not by themselves force a non-zero exit; spine failures (missing config, invalid overlay, empty inventory) do.

```bash
cabal run mndz-overlay-manager -- outdated
cabal run mndz-overlay-manager -- -v --jobs 4 outdated
```

### `update`

Apply updates for packages that need work: rename or rewrite ebuilds, regenerate Manifests with Portage `ebuild`, and create GPG-signed git commits in the overlay. For packages that use Go vendor assets, it may also build vendor tarballs and publish checksums/releases under `assets-path` (requires a resolvable GitHub token and the extra runtime tools above).

**Targets:** zero or more package arguments as `category/package` or an unambiguous package name. With no arguments, every package that needs work is selected (outdated non-Go packages and Go packages with tree-lane gaps). Explicit targets that do not need work are soft-skipped.

```bash
# All packages that need work
cabal run mndz-overlay-manager -- update

# One or more packages
cabal run mndz-overlay-manager -- update dev-util/crush
cabal run mndz-overlay-manager -- update crush dolt

# Common operator flags
cabal run mndz-overlay-manager -- --jobs 2 -v update
cabal run mndz-overlay-manager -- --no-progress update category/package
```

Before mutating anything, `update` checks that required tools are on `PATH` and, when assets publish is needed, that `assets-path` is a git work tree and a GitHub token can be resolved. Overlay commits are signed; ensure the overlay (and assets) repos have `user.signingkey` configured for GPG.

## Development

Contributing, quality gates, and developer bootstrap: **[CONTRIBUTING.md](CONTRIBUTING.md)**.  
AI coding agents: **[AGENTS.md](AGENTS.md)**.

## License

See [LICENSE](LICENSE) (AGPL-3.0-or-later).
