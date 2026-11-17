# Design

## Context

See proposal.md (Why) for motivation. Facts below were checked at `main` `bf9eeb7` and in explore-session spikes on 2026-11-13 to 2026-11-15, on Docker 29.8.1 (containerd image store, btrfs snapshotter), buildx 0.38.2.

- `Update.GentooTree` owns the managed tree. `resolveGentooTree` syncs when due and returns a `GentooTree` holding a shared `flock`; `gentooTreePath`, `gentooTreeCommit`, and `releaseGentooTree` are exported. `CLI.Parser.commandTreeSync` decides which commands resolve the tree.
- `Update.Runtime.Ceilings` computes per-arch plain and tilde ceilings from a tree path (`discoverGoCeilingsWith`, `discoverNodejsCeilingsWith`, `discoverRustUnionCeilingsWith`, `discoverSbclCeilingsWith`, `discoverBunBinCeilings`, `ceilingFor`). `Update.Uv.Python` inventories Python slots.
- Runtime floors can be read back from an ebuild only for Cargo (`parseRustMinVerFromEbuild`) and Bun (`bunAtomVersion`). Go, Node.js, and SBCL have writers and equality checks (`goBdependAtom`, `goBdependMatches`, …) but no reader. Python has `pythonCompatToken` (slot to token) only.
- `Update.Materialize.{Recipe,Ensure,Sidecar,Registry,ImageLayout}` render the materialize recipe, pin stage3 by digest, run the registry base check, gate on Docker storage free space, and prune the previous image. `Update.Process.Docker` has the create/exec session code, product/run/pid labels, and `sweepStaleMaterializeSessions`.
- `Update.Targets.selectExcluding` and `resolveCommandSelection` (`app/Main.hs`) implement targets and `--exclude`.
- The overlay has 50 ebuilds in 46 packages. All overlay ebuilds are `~arch`. Lane membership is not recorded on an ebuild.

Spike results that shaped the decisions:

| Probe | Result |
|---|---|
| `unshare` of net, ipc, pid, mount, uts, user inside `docker build` and default `docker run` | All denied (`EPERM`). |
| Same with `docker run --cap-add SYS_ADMIN` (default seccomp) | All allowed. |
| `emerge` of a probe ebuild, default `FEATURES`, managed tree bound read-only, `--cap-add SYS_ADMIN` | Build ran as uid 250 in fresh net/ipc/pid namespaces; network blocked in `src_compile`; exit 0. |
| Same without the capability, and in `docker build` | `Unable to unshare: EPERM`, network reachable, exit 0. |
| File-write sandbox in all three settings | A write outside the build directory was denied (`ACCESS DENIED`), as the portage user and as a root build. |
| `egencache` as uid 1000 with the image `FEATURES` cleared | No unshare warning: Portage only attempts namespaces as root. |
| `docker buildx build --allow security.insecure` | Refused by daemon configuration. |
| `tar … \| docker import` of the tree without `.git` | 13 s, 673 MB image, no build-cache record; deleting the image returned the space. |
| Same tree as a `docker build` `COPY` layer | 34 s cold, 5 s unchanged; deleting the tag freed nothing (layer stays in the build cache). |
| `docker run --mount type=image,source=<tree image>,target=/var/db/repos/gentoo` | Read-only; emerge with sandboxes worked; `docker create` time unchanged (about 9.5 s). |
| Docker documentation | Image mounts were added in Engine 28.0.0, are always read-only, and require the containerd image store. |

Verified on 2026-11-15 (tasks 1.1 to 1.4, same host):

| Probe | Result |
|---|---|
| `docker import --change 'LABEL k=v'` | Labels recorded on the image config (`docker image inspect`). |
| `docker images --filter label=<k> --filter reference='mndz-overlay-manager/smoke-tree:*'` | Lists exactly the labeled snapshot. |
| `--mount type=image` of the imported image | Contents visible; writes fail with `Read-only file system`. |
| `docker rmi` of the snapshot while a container mounts it | Refused (`conflict: … container … is using its referenced image`, exit 1). After the container is removed, `rmi` succeeds. |
| `tar` in a container from a stage3 image, piped to `docker import` (D4) | 32 s wall, 673 MB; `metadata/md5-cache` present, no `.git`, files owned `0:0`. |
| `docker network disconnect bridge` / `connect` on a running container | Detach removes `eth0` and name resolution fails; reattach restores reachability; a second detach blocks it again. |
| D3 recipe built by hand | 77 s with binhost hits. `portageq envvar FEATURES` includes all six sandbox features; GNU Time 1.10; no `go`, `node`, `bun`, `cargo`, `sbcl`, or `git`; no tree in the image. The stage3 itself ships `wget` (Portage's `FETCHCOMMAND`); the recipe adds no fetch tool. |
| D6 container + D8 steps for `dev-util/crush-0.101.0` at the tilde Go ceiling (`1.27.4`) | Dependencies step installed `dev-lang/go-bootstrap` and `dev-lang/go-1.27.4` (3 min); package step compiled with `-goversion go1.27.4` (2.5 min). The package's distfiles were only in `/var/tmp/smoke-distfiles`; none in the distfiles volume, and no overlay binary package in the binpkgs volume. `crush --version` ran as the check user with the network detached. |
| Same for `dev-lang/deno-bin-2.9.8` | Both steps exit 0; no `deno` distfile in the volume; `deno --version` runs as the check user. |
| Portage network sandbox with only `SYS_ADMIN` | Logs `Unable to configure loopback interface: Operation not permitted` (configuring `lo` needs `NET_ADMIN`) and continues; the build still runs in a fresh network namespace. Harmless for smoke because `src_test` is not run. |

No flag in D6 or D8 needed correcting.

Host runs after implementation (2026-11-16, same host):

| Run | Result |
|---|---|
| `smoke crush deno-bin craft-fonts` (task 10.2) | 10 min including the first smoke image build. `deno-bin-2.9.8`, `crush-0.101.0` `(dev-lang/go amd64)` and `(dev-lang/go ~amd64)`, `craft-fonts-0.0.0` and `-0.0.1`: all `pass`. No smoke container or snapshot image left; overlay `git status` unchanged. |
| `smoke cargo-outdated craft-fonts` with an uncommitted `die` in `craft-fonts-0.0.1` (task 10.3) | Both Rust lanes of `cargo-outdated-0.19.0` pass (the networked `outdated` check lists `libc`); `craft-fonts-0.0.1: fail: build`, its `build.log` holds the Portage `ERROR: … failed (compile phase)`; the summary names `media-fonts/craft-fonts` as uncommitted; exit status `1`. |
| `smoke hk`, exclusive `flock` on `gentoo.lock` while the package step runs (task 10.4, lock part) | The exclusive lock was taken without waiting while `emerge =dev-util/hk-2.12.0::mndz` was running; both Rust lanes passed afterwards. `outdated --refresh` itself was not run unattended (it needs the encrypted GitHub token's password). |
| `gencache --force dev-util/crush` with no recorded materialize image (task 2.2) | 3 min 6 s. The disk gate probed `/var/lib/containerd` (D15) and passed with `/var/lib/docker` at 4.3 GB free. The Portage `RUN` step ran uncached and logged `Unable to unshare: EPERM (for FEATURES="pid-sandbox")` and `(for FEATURES="ipc-sandbox network-sandbox pid-sandbox")` (4 lines, from `docker buildx history logs`), then emerged its 15 packages and finished. `image.json` records `mndz-overlay-manager-materialize-11`. Overlay `git status` unchanged. |
| `smoke mise` with `outdated --refresh` in another terminal (task 10.4) | `outdated --refresh` started at 17:45:48, 18 s into the plain lane's package step (`emerge =dev-util/mise-2026.11.8::mndz`, unpack at 17:45:30). Its tree phase took 3.3 s with no lock wait: mirror fetch, binhost `Packages` read (10:35 UTC), and the aligned target was the current `3b8ba04` (09:15 UTC), so `HEAD` stayed. The newer fetched commit (00:16 UTC) is past the cutoff. The emerge kept compiling. Smoke finished in 43 min 31 s with both Rust lanes `pass`, exit 0, no smoke container or snapshot image left, overlay `git status` unchanged. |
| Full `smoke`, no targets (task 10.5) | 7 h 24 min wall (`real 443m40s`), 83 items: 47 pass, 36 fail, 0 skip. Per-package results below. |
| `smoke witen-warden-bin autolith claude-agent-acp grok-bot-bin kiro-ide-bin` and the 9 craft apps, after the USE lines, the warden group, and the `/etc/profile` wrapper (task 8.5) | 5 h 32 min wall (`real 332m20s`), 25 items: 23 pass, 2 fail. None fails in dependencies or in `check validate`. Both `autolith` lanes now install and fail at `check version` on an overlay defect (below). Source builds in the dependency steps were only the packages whose USE changed (`libxkbcommon`, `mesa`, the pulseaudio stack, `sbcl`, `claude-code`, `nodejs`) and the overlay's `craft-fonts`; each built once and was reused as a binary package. |

Full-run results (task 10.5). "Both" means both runtime lanes; lane-less packages have one run per ebuild.

| Package | Result | Cause | Disposition |
|---|---|---|---|
| `node-gyp`, `badger`, `beads` (3 runs), `biodiff`, `cargo-outdated`, `cargo-update`, `crush`, `hk`, `mise`, `openspec`, `rulesync`, `usage`, `caddy-analyzer` (both lanes each), `deno-bin`, `grok-build-bin`, `kiro-cli-bin`, `opencode`, `craft-fonts` (2), `bun-bin-1.4.4`, `cadcraft`, `lightcraft`, `photocraft`, `soundcraft` | pass | | |
| `bun-bin-1.3.14`, `bun-bin-1.4.2-r1` | fail: check version | Slotted versions install `bun-<PV>`, only slot 0 adds `bun`. | Definition fixed (`bun-<PV> --version`); all three pass on rerun. |
| `qlot` | fail: check version | `Can't find sbcl.core`: `SBCL_HOME` comes from `/etc/env.d`, which `docker exec` does not read. | Checks now source `/etc/profile` (D9); passes on rerun. |
| `cmake-language-server` | fail: dependencies | `dev-python/pdm` and five of its dependencies are `~amd64` only in Gentoo. | Named in the definition's accepted keywords; passes on rerun. |
| 9 craft apps in one or both lanes (`deckcraft`, `designcraft`, `gridcraft`, `wordcraft`, `pdfcraft`, `figcraft`, `vectorcraft`, `effectcraft`, `filmcraft`) | fail: dependencies | `USE=X` needs `x11-libs/libxkbcommon[X]`, not in the default profile. Lanes differ only by which binary package the resolver tried first. | Per-definition USE lines added (`sdPackageUse`, operator decision 2026-11-16). |
| `grok-bot-bin`, `kiro-ide-bin` | fail: dependencies | Need `media-libs/libpulse[X]` and `media-plugins/alsa-plugins[pulseaudio]`. | Same. |
| `autolith` (both) | fail: dependencies; after the fix, fail: check version | Needs `dev-lisp/sbcl[source]`. Once installed, `autolith --version` fails: `src_install` does not copy `VERSION`, which `autolith.asd` reads with `(:read-file-line "VERSION")`, and the recovery image's `git clone /usr/share/autolith/` is refused by git 2.56 as dubious ownership (root-owned repository, unprivileged user). Same on the host install. | USE line added (operator decision 2026-11-16); the check failure is an overlay defect. |
| `claude-agent-acp` (both) | fail: dependencies | `dev-util/claude-code` requires `CPU_FLAGS_X86="avx avx2"`; the container's `make.conf` sets none. | Same, as a `package.use` line for `dev-util/claude-code`. |
| `dolt` (both); `gastown` (both, depends on dolt) | fail: build | cgo needs `unicode/uregex.h`; the ebuild lacks `dev-libs/icu` in `DEPEND`. | Overlay defect. |
| `codex` (both); `codex-acp` (both), `codex-as-mcp` (depend on codex) | fail: build | rusty_v8 `gn gen` needs `glib-2.0` through pkg-config; the ebuild lacks `dev-libs/glib` and `virtual/pkgconfig`. | Overlay defect. |
| `cargo-llvm-cov` (`~amd64` lane) | fail: check version, coverage | `rust-bin-1.99.0` uses LLVM 23; the unslotted `RDEPEND="llvm-core/llvm"` installed another slot, so `/usr/lib/llvm/23/bin/llvm-cov` is missing. | Overlay defect. |
| `ralph-tui` | fail: check version | `Cannot find package 'react'`; Bun tries to download it at runtime. | Overlay defect (dependency not bundled). |
| `witen-warden-bin` | fail: check validate | `/etc/witen/warden.toml` is readable by root and the `witen-warden` group only; checks run as the unprivileged user. | The check user joins `witen-warden` in that package's containers only (`sdCheckGroups`, operator decision 2026-11-16). |

## Goals / Non-Goals

**Goals:**

- Planning is pure and Docker-free: given ceilings and ebuild texts, it returns the ordered list of runs, skips, and plan failures. It is unit-tested without a daemon.
- All Docker I/O goes through the injectable `CommandRunner`, as in `Update.Process.Docker`, so the container adapter and the check interpreter are tested with fakes.
- Reuse what the tree change built: tree resolver, ceiling discovery, stage3 digest pin and registry check, image disk gate, labels and leftover sweep, metrics wrapping.
- Adding a package means adding one definition value; the unit test fails until it exists.

**Non-Goals:**

- Sharing one image-ensure engine between materialize and smoke. The smoke image has no floors, no overlay binds, and no union logic; a small separate module is clearer than parameterizing `ensureDefault`.
- A general "container test" DSL. The check type covers commands, expectations, timeouts, and a network flag, and nothing else.
- Recovering a half-finished smoke command. Every command starts over.

## Decisions

### D1. Module layout and command pipeline

New top-level namespace `Smoke.*` (smoke is not part of `update`):

- `Smoke.Floors`: runtime floor readers per ecosystem.
- `Smoke.Plan`: pure run planning.
- `Smoke.Recipe`, `Smoke.Image`: recipe render, sidecar, build decision.
- `Smoke.Tree`: per-command tree snapshot image.
- `Smoke.Container`: create, exec, network, user, Portage configuration, removal.
- `Smoke.Check`: check types, combinators, interpreter.
- `Smoke.Definitions`: the `Map PackageKey SmokeDef`.
- `Smoke.Run`: orchestration, result lines, logs, summary.

Pipeline, in order, each step hard-failing the command:

1. Parse, config, overlay validation, discovery (shared spine helpers).
2. Preflight: `git`, `gpg`, `docker` on `PATH`; overlay is a git work tree; Docker version and image store (D11).
3. Selection with `resolveCommandSelection`; then fail when a selected key has no definition.
4. `resolveGentooTree` (sync when due; shared lock).
5. Plan runs (D2). Print nothing yet.
6. Sweep leftovers (D12); ensure the smoke image (D3).
7. Snapshot the tree (D4); `releaseGentooTree`.
8. Sandbox probe (D7).
9. Runs, one at a time (D5 to D9). Plan failures and skips emit their result lines in order with the runs.
10. Summary; delete the snapshot; exit status.

Planning comes before the image so that a missing definition or an unreadable ebuild fails in seconds, not after a build.

### D2. Run planning from ceilings and on-disk floors

`Smoke.Plan` takes the host arch (`lookupRecipeArch` on `uname -m`, as ensure does), the selected packages' ebuilds, their policies, and ceilings, and returns `[PlannedItem]` where an item is a run (atom, optional lane, cap), a skip, or a plan failure. Rules are in the `smoke-command` spec. Ceiling sources are the existing `discover*CeilingsWith` functions with the managed tree path, and the overlay for Bun.

Floor readers (`Smoke.Floors`), all pure over ebuild text:

| Ecosystem | Floor read from | Notes |
|---|---|---|
| Go | `>=dev-lang/go-<v>` in the ebuild | New reader; inverse of `goBdependAtom`. |
| Npm | `>=net-libs/nodejs-<v>` | New reader; inverse of `nodejsBdependAtom`. A bare major (`22`) compares as `22`. |
| Bun | `dev-lang/bun-bin` atom | Existing `bunAtomVersion`; a compile pin (`~…`) is its exact version. |
| Cargo | `RUST_MIN_VER` | Existing `parseRustMinVerFromEbuild`. |
| Sbcl | `>=dev-lisp/sbcl-<v>` | New reader; inverse of `sbclBdependAtom`. |
| Uv, Pdm | `PYTHON_COMPAT=( python3_NN )` | New reader, inverse of `pythonCompatToken`. Gives the slot to accept, not a cap. |

An ebuild with no readable floor qualifies under every ceiling (spec). Uv and Pdm ebuilds name one slot and get one unlabeled run: the lane choice was made when the ebuild was written, so there is nothing to cap.

Alternative considered: ask Portage in a container (`emerge --pretend` with the runtime capped at each ceiling). No parsers, but planning then needs Docker, costs seconds per ebuild per ceiling, and the run list is not known before work starts. Rejected by the operator in favor of host readers.

Each DepsAndAssets ecosystem has exactly one runtime id, so there is no cross product of caps. Cargo's union runtime (`dev-lang/rust|rust-bin`) is one ceiling applied to both packages.

### D3. Smoke image

`Smoke.Recipe.renderSmokeDockerfile :: RecipeArch -> Text -> Text` renders:

```
# syntax=docker/dockerfile:1
FROM gentoo/stage3:<tag>@<digest>
ENV FEATURES="getbinpkg"
ENV EMERGE_DEFAULT_OPTS="--quiet-build=y --with-bdeps=n --usepkg"
RUN --mount=type=bind,from=gentoo,target=/var/db/repos/gentoo \
    --mount=type=cache,id=mndz-smoke-build-binhost,target=/var/cache/binhost \
    --mount=type=cache,id=mndz-smoke-build-distfiles,target=/var/cache/distfiles \
    (command -v getuto >/dev/null && getuto || true) \
 && emerge --oneshot sys-apps/portage \
 && emerge --update --deep --newuse @world \
 && emerge -n sys-process/time
```

The image `ENV` lines are build-time conveniences; run containers set their own `make.conf` (D6). No sandbox feature is removed.

`Smoke.Image` keeps its own sidecar type (`id`, `tag`, `generator`, `stage3_digest`, `tree_commit`, `built_at`, `last_base_check`) under `<cache>/mndz/overlay-manager/smoke/`, with generator identity `mndz-overlay-manager-smoke-1`. Build decision per the `smoke-image` spec. It reuses, by exporting or lifting small helpers out of `Update.Materialize.Ensure`: `stage3DigestWith`, the base-check decision, `inspectImageId`, the Docker storage disk gate with the add-toolchain bounds (6 GiB layers, 2 GiB cache), and the previous-image removal. `docker build` passes `--build-context gentoo=<managed tree>`; the tree's `.dockerignore` already excludes `.git`.

The base check interval reuses `materialize-base-check-interval`. A second key would add a knob with no use; the README states it applies to both images.

Alternative considered: the materialize base step, which would share a cached layer. Rejected: it ships `git`, `wget`, `aria2`, `unzip`, and gentoolkit, which can hide an undeclared dependency of a package under test.

### D4. Tree snapshot as a per-command imported image

`Smoke.Tree` runs, under the shared tree lock:

```
docker run --rm --network none --mount type=bind,src=<tree>,dst=/t,readonly \
    mndz-overlay-manager/smoke:local \
    tar -C /t --exclude=./.git --exclude=./.dockerignore --owner=0 --group=0 -c . \
  | docker import --change 'LABEL <product>' --change 'LABEL <run>=<id>' --change 'LABEL <pid>=<pid>' \
      - mndz-overlay-manager/smoke-tree:<run-id>
```

and removes the image in a `finally` at command end. Containers mount it with `--mount type=image,source=…,target=/var/db/repos/gentoo`.

`tar` runs in a container from the smoke image, so the host needs no `tar`; the host tools stay `git`, `gpg`, and `docker`. The spike measured 13 s with host `tar` and 32 s for the container form (task 1.2). The pipe runs through `sh -c` on the host; the `tar` container is named and labeled (no `--rm`), and its exit code is read with `docker inspect` after the pipe ends, so a failed `tar` fails the snapshot even though `sh` reports only the last command's status. `docker rmi` refuses to delete the snapshot while any container mounts it (task 1.1), so the final removal runs after the last run container is gone.

| Option | Disk between commands | Disk during a command | Time | Notes |
|---|---|---|---|---|
| Worktree per command | none | about 600 MB on the cache filesystem | about 2 s | Adds worktree state to the managed clone; untested against the shallow sync. |
| Built image per commit, kept | about 670 MB plus a build-cache copy | same | 34 s, then 5 s | Deleting the tag frees nothing. |
| **Imported image per command (chosen)** | none | about 670 MB in Docker storage | 13 s | No git state, no prune rule. |
| Imported image per commit, kept | about 670 MB | same | 13 s once per commit | Needs a prune rule and in-use tracking. |

A reflink copy would be near-free on btrfs or XFS but is unavailable on ext4, which is what holds the cache on the development host.

### D5. Tree lock

`smoke` calls `releaseGentooTree` right after the snapshot import returns. Planning (step 5) and the image build (step 6) read the managed tree before that, under the lock. Nothing reads `gentooTreePath` afterwards; `Smoke.Run` receives only the commit id and the snapshot image name, so a later read cannot be written by accident.

Alternatives considered: hold the lock for the whole command (other commands' syncs stall for hours behind a full smoke), or take it per ebuild (a command could span two commits). Both rejected by the operator.

### D6. Container

Create arguments (via the injectable runner):

```
docker create --name mndz-smoke-<run-id>-<cat>-<pn>-<pvr>[-plain|-tilde]
  --label <product> --label <run>=<id> --label <pid>=<pid>
  --cap-add SYS_ADMIN
  --mount type=image,source=mndz-overlay-manager/smoke-tree:<run-id>,target=/var/db/repos/gentoo
  --mount type=bind,src=<overlay>,dst=/var/db/repos/mndz,readonly
  --mount type=volume,src=mndz-smoke-binpkgs,dst=/var/cache/binpkgs
  --mount type=volume,src=mndz-smoke-distfiles,dst=/var/cache/distfiles
  [--mount type=bind,src=<metrics time dir>,dst=<same>]
  mndz-overlay-manager/smoke:local sleep infinity
```

No `--rm` is needed beyond what sessions use today; removal is explicit in a `finally` and the leftover sweep covers crashes. No token, GPG, or SSH variables are passed.

After start, one root `docker exec` writes Portage configuration:

- `repos.conf/mndz.conf`: `[mndz] location=/var/db/repos/mndz, masters=gentoo, auto-sync=no`.
- `make.conf` additions: `MAKEOPTS="-j<N> -l<N+1>"`, `FEATURES="getbinpkg buildpkg"`, `ACCEPT_LICENSE="*"`.
- `package.accept_keywords/smoke`: `*/*::mndz ~<arch>`, the cap lines (D2: `<=<runtime>-<ceiling> ~<arch>` for each runtime package), the Python slot line, and the definition's extra atoms.
- `package.mask/smoke`: `><runtime>-<ceiling>` for each runtime package of a capped run.

Then `useradd --create-home --uid <operator uid> --user-group smoke` creates the check user. The operator's uid is used so that GNU time files written by check commands into the bound metrics directory are owned by the operator; when the operator is uid 0, uid 1000 is used. Emerge runs as root, so its time files are root-owned but readable.

Alternative considered: `--privileged`. Strictly more access, no gain in the spike. User-namespace remapping would confine container root properly but is a daemon-wide host setting.

### D7. Sandbox probe

Once per command, before the first run:

```
docker run --rm --cap-add SYS_ADMIN --network none mndz-overlay-manager/smoke:local \
  sh -c 'unshare --net true && unshare --ipc true && unshare --pid --fork true'
```

A non-zero exit hard-fails the command. This is the guard against a host (for example one with an AppArmor profile on containers) where the capability alone is not enough; there Portage would warn, build unsandboxed, and exit 0.

### D8. Emerge steps

With `O` = the overlay's `category/package` names (from discovery), passed as plain atoms:

1. Dependencies: `emerge --oneshot --onlydeps --jobs=1 --quiet-build=n --usepkg --usepkg-exclude "<O>" --buildpkg-exclude "<O>" "=<cat>/<pn>-<pvr>::mndz"`.
2. Package: `DISTDIR=/var/tmp/smoke-distfiles emerge --oneshot --jobs=1 --quiet-build=n --usepkg=n --buildpkg=n "=<cat>/<pn>-<pvr>::mndz"`.
3. Extra atoms of the definition, when any: `emerge --oneshot --jobs=1 --usepkg <atoms>`.

Excluding by name keeps overlay packages out of the binary-package volume in both directions without relying on repository-qualified wildcards in emerge options. A Gentoo package that shares a name with an overlay package is then also built from source, which is harmless.

Step 2 uses a container-local, initially empty `DISTDIR`, so nothing of the package under test reaches the distfiles volume. This replaces the earlier idea of deleting the package's files from the volume before the emerge: same effect, no Manifest parsing, and the two steps give the `dependencies` versus `build` distinction in results for free.

Whether Portage would reuse a stale binary package after an in-place ebuild edit was not tested. The rule above does not depend on the answer.

Stdout and stderr of each step stream to the run's log file on the host; the last lines are attached to the failure log message.

### D9. Checks

```haskell
data SmokeDef = SmokeDef
  { sdChecks :: NonEmpty Check,
    sdExtraAtoms :: [Text],        -- installed after the package
    sdAcceptKeywords :: [Text],    -- extra Gentoo atoms accepted as testing
    sdPackageUse :: [Text],        -- package.use lines (atom and flags)
    sdCheckGroups :: [Text] }      -- groups the check user joins, this package only

data Check = Check
  { ckName :: Text,
    ckNetwork :: Bool,             -- default False
    ckTimeout :: Seconds,          -- default 60, per command
    ckSteps :: NonEmpty Step }

data Step = Step
  { stCommand :: CheckCtx -> Command,          -- argv or shell, optional stdin/env/cwd
    stExpect :: CheckCtx -> Outcome -> Either Text () }

data CheckCtx = CheckCtx { ccKey :: PackageKey, ccVersion :: EbuildVersion, ccPv :: Text }
data Outcome = Outcome { oExit :: Int, oStdout :: Text, oStderr :: Text }
```

Combinators cover the common cases: `versionCheck prog args` (exit 0, output contains PV), `helpCheck prog`, `filesExist paths`, `exitsWith`, `outputContains`, `outputLacks`, `firstLineIs`, and `allOf`. Expectations are ordinary Haskell functions evaluated on the host over the captured outcome, so anything a seed spec asks for (qlot's status 255, kiro's first line, JSON shape for caddy-analyzer) is expressible.

The interpreter runs each step as `docker exec --user smoke --workdir /home/smoke <container> timeout --kill-after=5 <limit> sh -c '. /etc/profile && exec "$@"' sh <command>`. `docker exec` does not read `/etc/profile`, so without the wrapper variables a login shell gets from `/etc/env.d` are missing (the full run in task 10.5 found `qlot` failing with `Can't find sbcl.core` because `SBCL_HOME` was unset). `timeout` exit 124 or 137 becomes "stopped after N seconds". It takes the exec function and the network attach/detach functions as arguments, so tests drive it with fakes.

USE and groups: `sdPackageUse` lines are written to `/etc/portage/package.use/smoke` by the setup script. The default profile leaves some flags off that overlay packages need from Gentoo dependencies (task 10.5 found `libxkbcommon[X]` for the craft apps, `libpulse[X]` and `alsa-plugins[pulseaudio]` for the pulseaudio stack, `sbcl[source]` for autolith, and AVX CPU flags for `claude-code`). `sdCheckGroups` runs `usermod --append --groups <groups> smoke` as root after the installs and before the network detach; `docker exec --user smoke` reads the container's group database at each exec, so later checks have the membership. A failure is stage `check groups`. Only `witen-warden-bin` uses it, so `warden validate` can read its root:witen-warden 0640 configuration.

Network: the container is created on the default bridge. After the installs, `docker network disconnect bridge <container>`. A network check is bracketed by `connect` and `disconnect`. Task 1.3 confirmed that detach removes the interface and blocks name resolution, and that reattach restores it.

Definitions for the current overlay. "Seed" means the checks come from that package's capability spec; "floor" means a version or help check only. The exact version flag of each floor program is confirmed against the installed program while writing the definition.

| Package(s) | Program | Source of checks |
|---|---|---|
| 13 craft apps (`deckcraft`, `designcraft`, `gridcraft`, `wordcraft`, `pdfcraft`, `cadcraft`, `figcraft`, `lightcraft`, `photocraft`, `vectorcraft`, `soundcraft`, `effectcraft`, `filmcraft`) | `<name>`, `<name>-cli` | Seed (`storytold-craft-apps`, `media-gfx-photocraft-seed`): both `--version`, no display. One shared helper. |
| `media-fonts/craft-fonts` | none | Floor: files under `/usr/share/craft-fonts/fonts`. |
| `dev-build/node-gyp`, `dev-db/badger`, `dev-lisp/qlot`, `dev-util/autolith`, `dev-util/biodiff`, `dev-util/cargo-llvm-cov`, `dev-util/cargo-outdated`, `dev-util/cargo-update`, `dev-util/claude-agent-acp`, `dev-util/cmake-language-server`, `dev-util/codex`, `dev-util/codex-acp`, `dev-util/codex-as-mcp`, `dev-util/gastown`, `dev-util/grok-bot-bin`, `dev-util/kiro-cli-bin`, `dev-util/kiro-ide-bin`, `dev-util/rulesync`, `net-analyzer/caddy-analyzer`, `net-analyzer/witen-warden-bin` | per spec | Seed: the smoke requirement of each `*-seed` spec. `cargo-outdated` needs network. `gastown` and `autolith` set their own timeouts. |
| `dev-db/dolt` (`dolt`), `dev-lang/bun-bin` (`bun-<PV>`: only slot 0 installs `bun`), `dev-lang/deno-bin` (`deno`), `dev-util/beads` (`bd`), `dev-util/crush` (`crush`), `dev-util/grok-build-bin` (`grok`), `dev-util/hk` (`hk`), `dev-util/mise` (`mise`), `dev-util/opencode` (`opencode`), `dev-util/openspec` (`openspec`), `dev-util/ralph-tui` (`ralph-tui`), `dev-util/usage` (`usage`) | as named | Floor. |

A seed requirement that names host actions (`sudo emerge`, "after seed publish") is read for its commands and expected results only. Seed specs are not edited.

Alternative considered: shell scripts in the overlay. Rejected by the operator: adding a package already needs a manager release, and Haskell checks are type-checked and unit-testable.

### D10. Results, logs, progress

`Smoke.Run` folds over the planned items, emitting each result line to stdout as the item finishes (spec format). Logs go to `<cache>/mndz/overlay-manager/smoke/logs/<run-id>/<cat>-<pn>-<pvr>[-<lane>]/{dependencies,build,check-<name>}.log`. At start, all but the ten most recent earlier run directories are removed.

Progress uses the existing step progress on stderr: one line with the item index, atom, lane, and stage (`dependencies`, `build`, `check <name>`). Uncommitted packages come from one `git status --porcelain -- <pkgdir>` per tested package at start, through the existing git runner.

### D11. Docker preflight

`docker version --format '{{.Server.Version}}'` must parse to 28.0 or newer. The image store check reuses `parseDockerInfoJson` (`difUsesSnapshotter`), which already reads `docker info --format '{{json .}}'` for the disk gate. Both failures name the requirement and exit 1. These checks apply to `smoke` only; `update` and `gencache` keep working on older engines and classic storage drivers.

### D12. Leftover sweep

Smoke containers carry the same product, run, and pid labels as materialize sessions, so `sweepStaleMaterializeSessions` already removes those whose pid is not a live overlay-manager. Image labels work on `docker import` (task 1.1), so no record-file fallback is needed. `Smoke.Tree` adds the same rule for images: `docker images --filter label=<product> --filter reference='mndz-overlay-manager/smoke-tree:*'`, read the pid label, `docker rmi` when the pid is dead. `smoke` runs both sweeps at step 6.

### D13. Materialize recipe FEATURES

`Update.Materialize.Recipe` line 100 becomes `ENV FEATURES="getbinpkg buildpkg -news"`, and `materializeGeneratorId` moves to `…-materialize-11`, which rebuilds the image once. During `docker build` Portage then logs `Unable to unshare: EPERM` and continues, as the spike showed. The tools container and materialize sessions run as the operator's uid, where Portage does not attempt namespaces, so they are unaffected.

### D14. Metrics

`commandName` and `invocationFor` gain `smoke`. `Smoke.Container` wraps exec requests with the same inner/outer GNU time wrapping as `wrapMaterializeExecRequest`, binds the run's `time/` directory, and takes the cgroup snapshot before removal (`Metrics.Container`). Each run is a span named by atom and lane label; the snapshot import, image build, and probe are spans too.

### D15. Image disk gate on a system containerd

`imageStoreLayout` put the BuildKit cache on the Docker data-root whenever image layers were in a system (not engine-bundled) containerd. On that layout BuildKit stores its cache as snapshots in containerd, and the Docker data-root holds only its metadata, volumes, and container configs. Task 2.2 hit it: the gate failed with `build cache /var/lib/docker free: 4.9G need: 6G` while `docker system df` reported a 12 GB build cache on an 8 GB `/var/lib/docker` with 3.3 GB used. A probe build of a 1 GiB `RUN` layer on the host (Docker 29.8.1, system containerd, both btrfs) grew `/var/lib/containerd` by 3.1 GB and `/var/lib/docker` by 0. With a system containerd, cache paths are now containerd's root, the same as layers, so the gate applies one combined bound there. Classic and bundled layouts are unchanged. A snapshotter `root_path` override still replaces the top-level root for both roles; content blobs that stay under the top-level root on another filesystem are not probed, which this change does not address.

### Assumptions recorded for review

These were not asked and are stated in the specs; each is a one-line change if the operator prefers otherwise.

- Run logs: the ten most recent earlier commands are kept.
- Licenses: the container accepts every license.
- Keywords: every `mndz` package is accepted as testing; any other testing-only Gentoo dependency must be named in the package's definition.
- USE: the profile's defaults apply; a flag a package needs on a Gentoo dependency is named in that package's definition. Host `CPU_FLAGS_X86` are not copied into the container.
- The base check interval is shared with the materialize image.
- A runtime with no ceiling on the host architecture, or a floor above every ceiling, is a plan failure, not a skip.
- Live ebuilds are not tested.

## Risks / Trade-offs

- **`smoke` needs Docker 28.0+ with the containerd image store.** Hosts on a classic storage driver cannot run it. → Preflight names the requirement; other commands are unaffected. A worktree bind is the fallback design if this proves too narrow.
- **Container root holds `CAP_SYS_ADMIN`.** It is not strongly confined from the host. → Only Portage and `pkg_*` phases run as root, the same code previously run with `sudo emerge` on the host. Build phases run as the portage user, checks as an unprivileged user, the default seccomp profile stays, and the overlay and tree are read-only.
- **A full command takes hours.** Fifty source builds, one at a time. → Targets and `--exclude`; the pass cache is the planned follow-up.
- **Testing-keyword runtimes compile from source the first time.** For example `net-libs/nodejs` at a tilde ceiling has no binhost package. → The binary-package volume keeps the result for later commands.
- **Network failures fail runs.** Every command fetches the distfiles of every package under test. → The result stage (`build`) and the log show the fetch error; a rerun of that package is cheap to target.
- **Build space is not estimated.** A large Rust build can fill Docker storage. → The run fails with its log and the command continues (spec).
- **Volumes grow without bound.** → README names them; pruning belongs to the pass-cache change.
- **Root-owned GNU time files in the operator's metrics directory.** → Readable and removable by the directory owner; `--no-metrics` avoids them.
- **Unverified Docker and emerge behaviors** (labels on import, label filters, network detach on a running container, the two-step emerge flags). → Tasks 1.1 to 1.4 run them before dependent code is written. Fallbacks: a small record file per snapshot (tag and pid) under the smoke cache directory in place of image labels, and attaching a user-defined network instead of `bridge`. If a spike result forces a behavior the specs do not describe, the specs and this design are updated before the dependent task starts.
- **A crash between import and exit leaves a 670 MB image.** → Removed by the next `smoke`.
- **Hosts with AppArmor on containers** may deny namespaces despite the capability. → The probe hard-fails with a clear message; adding `apparmor=unconfined` is a later decision for a host that needs it.

## Migration Plan

1. After upgrade, the first ensure rebuilds the materialize image once (generator identity).
2. The first `smoke` builds the smoke image (minutes) and creates the two volumes.
3. Rollback: reinstall the previous manager. Remove `mndz-overlay-manager/smoke:local`, the two `mndz-smoke-*` volumes, and `<cache>/mndz/overlay-manager/smoke/` by hand if wanted; the previous manager ignores them and rebuilds its own materialize image.

## Open Questions

- Whether `smoke` should later add `apparmor=unconfined` automatically on hosts that need it. No such host is in use; the probe reports the condition.
