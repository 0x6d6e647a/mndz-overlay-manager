## Why

Non-root `update` runs `ebuild … manifest`, which fetches into Portage’s system `DISTDIR` (typically sticky `/var/cache/distfiles`). Files created under root `FEATURES=userfetch` are owned by `portage`; the operator cannot replace them under the sticky bit, so manifest fails mid-apply with `EPERM` on rename (often `.layout.conf.<mirror>`). That leaves half-applied ebuilds and can leave assets already published. The manager should isolate manifest fetches in a private, operator-owned distfiles cache by default.

## What Changes

- **Default private DISTDIR** for `ebuild … manifest`: `${XDG_CACHE_HOME:-$HOME/.cache}/mndz/overlay-manager/distfiles` (mode `0700`), parallel to config at `${XDG_CONFIG_HOME:-$HOME/.config}/mndz/overlay-manager.toml`.
- **Config + CLI override**: optional `distfiles-path` in TOML and global `--distfiles-path DIR` (same resolution style as overlay path).
- **Preflight probe**: before package mutation, create + atomic-rename a probe file in the resolved DISTDIR; hard-fail with a sticky/ownership-oriented message if the directory is not usable for non-root fetch.
- **Ebuild child environment**: set `DISTDIR` to the resolved path; disable Portage mirrors for that child via `FEATURES` (exact form pinned in design after a same-change spike) so layout/mirror side-fetches are avoided for absolute `SRC_URI`.
- **Operator-facing error mapping**: when manifest stderr matches sticky/EPERM/distfiles rename failure, augment the hard-fail message with guidance (private distfiles path, avoid sharing system sticky DISTDIR).
- **New work command `eclean`**: delete the resolved manager distfiles cache; refuse when the path is the system Portage DISTDIR (`/var/cache/distfiles` or equivalent).
- **Docs / help**: README config keys and paths, `eclean`, global option; top-level and command help catalog `eclean`.

### Non-goals

- Changing host `make.conf`, system DISTDIR policy, or Portage `userfetch`/`userpriv` defaults.
- Running `ebuild` as root or `portage`, or auto-`chown`/`rm` of system distfiles.
- Cleaning system Portage distfiles (that remains `app-portage/eclean` / operator host tools).
- Hardlinking or syncing from system DISTDIR into the private cache (optional future optimization).
- Fixing already half-applied overlay trees from past failed runs (operator restores / re-runs `update`).

## Capabilities

### New Capabilities

- `manager-distfiles`: resolve private DISTDIR (default XDG cache path, config/CLI override), ensure directory mode, preflight probe, ebuild-runner env (`DISTDIR` + mirror-off FEATURES), sticky/EPERM message mapping, and the `eclean` work command with system-DISTDIR refusal.

### Modified Capabilities

- `update-command`: preflight includes DISTDIR usability before package mutation; manifest uses private DISTDIR env.
- `update-apply`: ebuild manifest invocations use resolved DISTDIR / FEATURES; failure messages may include sticky/distfiles guidance.
- `cli-help`: top-level catalog and per-command help for `eclean` and `--distfiles-path`.
- `project-docs`: README documents `distfiles-path`, default cache path, `--distfiles-path`, `eclean`, and why private DISTDIR exists.

## Impact

- **CLI**: new global option `--distfiles-path`; new subcommand `eclean`.
- **Config**: optional `distfiles-path` key on `OverlayConfig`.
- **Code**: config loader/types; CLI parser; update spine preflight; `Update.Apply.Env` ebuild runner env merge; new eclean command path; tests for resolution, probe, env, refusal.
- **Operator disk**: second distfile cache under XDG (grows with fetched SRC_URI); reclaim via `eclean`.
- **Behavior change**: by default manifests no longer write to system `/var/cache/distfiles` (may re-download distfiles already present only on the host cache).
