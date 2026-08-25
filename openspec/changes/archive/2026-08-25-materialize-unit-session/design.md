## Context

See proposal.md for motivation. Full-path builders take an injectable `CommandRunner` (`mkVendorOps`, `mkCargoOps`, …). Spine today builds **one** `productionMaterializeRunner (rrPath tempRun)` that rewrites every `ExecCmd`/`ShellCmd` to `docker run --rm` with a **run-root** bind (`Update.Process.Docker.wrapMaterializeRequest`). Cargo `extractCrate` is one `tar -xzf` per registry package on that runner. Apply still opens a temp-workspace **unit** per PV (`ensureUnit`); that is the isolation atom. `--jobs` remains package-level; PVs inside a package job stay sequential (`materializeUntilFail`). Measured on the operator host (Docker 29.5.2, product image): `docker run --rm <image> true` ~25s p50; `docker exec` ~32ms p50.

Publish, GPG, SSH, overlay commits, and companion HTTP (`models.dev`) stay on the host and do not use the materialize runner.

## Goals / Non-Goals

**Goals:**

- Replace per-command `docker run` with a per-unit session: `create` + `start` + `exec` + `bracket rm -f`
- Bind only that unit’s `work/` and `out/` at the same absolute paths
- Keep builders unaware of Docker (same `CommandRunner` fakes)
- Ctrl-C / crash leftovers: labels + best-effort sweep; no detached-without-cleanup story
- Cargo chrome: `staging crates k/N` then `crates pack` without changing the seven-step budget

**Non-Goals:**

- Host-materialize CLI/product (unwrapped runner is a one-line alternate of the session factory later)
- Guest worker ELF, generated shell, `--init`, image/generator bump, shared GOCACHE binds, parallel PVs, xz thread policy

## Decisions

### 1. Session API: create / start / exec / rm -f

**Choice:** `docker create` (with `--rm`, name, labels, `--user`, forced env, two binds) → `docker start` → inspect until running → `docker exec` per command → `docker rm -f` in `bracket`. PID 1 is image `sleep infinity`. No restart policy. No `--init`.

**Why not `docker run -d`:** same daemon object, client exits immediately; cleanup is then only Haskell. Create/start is the API we own and records the name before start.

**Why not a foreground `docker run --rm sleep infinity` waiter:** better process-group SIGINT on paper, extra docker CLI per live unit, same ~25s start. Fallback if `bracket`+sweep leaks in the field.

**Ready:** after `start`, `docker inspect` until running (or unit hard-fail). Do not exec into created-but-not-running.

**Dead session:** exec failure because the container is not running is a unit hard-fail; do not open a replacement session for that unit.

**Stdin:** `docker exec -i` when `prStdin` is non-empty. `ShellCmd` remains `sh -c` as the exec argv.

### 2. Names, labels, sweep

**Name:** `mndz-mat-<runId>-<cat>-<pn>-<pv>` with `/` → `-` (Docker-legal).

**Labels:**

- `mndz.overlay-manager=1`
- `mndz.overlay-manager.run=<runId>`
- `mndz.overlay-manager.pid=<cliPid>` — do **not** parse pid out of run-id (`…-0700-<pid>.<rand>` is ambiguous)

**Sweep (best-effort, never hard-fail):**

- Start of mutate that will full-path: `docker ps -aq --filter label=mndz.overlay-manager=1`; `rm -f` those whose `.pid` is not a live overlay-manager process (dead pid, or `/proc/<pid>/exe` is not this CLI). Log removals.
- Do not remove a container whose labeled pid **is** a live overlay-manager (concurrent `update`).
- Unit `bracket` and end of mutate: `rm -f` this run-id / this session.

Failed units: keep host unit tree (`temp-workspace`); still remove the container.

### 3. `withUnitMaterializeSession` per PV, not one Spine runner

**Choice:** `Update.Process.Docker` exports a session factory, roughly `withUnitMaterializeSession cfg unitDirs (CommandRunner -> IO a) -> IO a`. `MaterializeDockerCfg` keeps image + uid:gid; **binds are `udWork` and `udOut`**, not `mdcBindPath` run root.

Spine resolves image/user once. `fullDepsPublishAndOverlay` / `materializeDistfiles` opens the session **after** `ensureUnit` and builds `mk*Ops` from the continuation runner. Sequential PVs ⇒ sequential sessions.

**No global “current container”** (`--jobs` would race).

**Host-materialize seam:** the factory’s alternate is `productionCommandRunner` with no Docker. This change does not add `--host-materialize` or relax “full path requires docker.”

Builders (`extractCrate`, `go mod download`, …) stay unchanged except cargo status callbacks.

### 4. Env: forced on create, per-request on exec

**Choice:** Reuse today’s `containerEnv` denylist (`secretMaterializeEnvKeys`, forced `HOME`/`XDG_*`/`PATH`/`SBCL_*`, `SSH_` prefix).

- **create:** `--user`, `--env HOME=/home/builder`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME=/tmp/builder-cache`. No host `PATH`, no secrets.
- **exec:** same `--user`, `--workdir` from `prCwd`, `-e` for `prEnv` after `dropKey` (keeps `GOMODCACHE`, `XZ_OPT`, …).

Network: default (clones, crates.io, npm). No `--network=host`.

### 5. Cargo progress without an eighth step

**Choice:** Keep `fullPathMaterializeSteps` at 7. During `stageAll`, `mhStatus` `staging crates k/N` (`N` = registry packages from the lock). When xz starts, `crates pack` as today (`cgpOnPackStart` / done). No `cli-activity` delta (step names are already free-form).

### 6. Tests and modules

**Choice:** Replace `wrapMaterializeRequest` coverage with create argv (binds, labels, name, `--rm`, `--user`, forced env, no secrets) and exec argv (inner cmd, workdir, `GOMODCACHE`, denylist). Fake inner `CommandRunner` still heats builders. Do not expand `exposed-modules`; keep session helpers as `other-modules` unless app/test must import a new name (prefer testing via existing `Update.Process.Docker` exports or `mk*Ops`). No weeder root change. No image generator bump.

Companion `models.dev` fetch stays host HTTP inside the same continuation (it does not use `CommandRunner`).

## Risks / Trade-offs

- **[Risk] `kill -9` leaves a running `sleep infinity`** → Mitigation: pid label + start-of-mutate sweep; `--rm` on create; `bracket rm -f`. Same class of leak as a killed foreground `docker run` client.
- **[Risk] Admit-pool threads ignore SIGINT** → Mitigation: session `bracket` on the unit thread; mutate-level sweep in the same Spine/Main teardown family as GPG/SSH. If that is insufficient, fallback is a foreground `docker run` waiter (decision 1).
- **[Risk] ~25s create × `--jobs` still contends containerd** → Mitigation: one create **per unit**, not per command. Overlapping creates remain bounded by package jobs. Image instantiate cost is out of scope.
- **[Risk] `docker exec` ~32ms × 1000 crates ≈ 34s** → Accepted; pycargo + `xz -9e -T1` dominate. Status `staging crates k/N` so this is not mistaken for hung pack.
- **[Risk] Name collision / illegal characters** → Mitigation: `/` → `-`; run-id already PATH-safe; unique run-id + pn + pv.
- **[Trade-off] Brain stays in the host process** → Accepted. A guest worker remains a later PID-1 swap on this session.
- **[Trade-off] No shared GOCACHE across units** → Accepted; per-session `/tmp/builder-cache` still warms within a unit.

## Migration Plan

1. Land session Docker module + unit binds + sweep + cargo status + tests + README.
2. Operators run `update` as before (`docker` + image). First full-path unit after upgrade uses named sessions; leftover per-command `--rm` containers from an interrupted old CLI are already gone or harmless.
3. Rollback: revert the change; wrap is again per-command `docker run` (slow Cargo). Published tarball identity unchanged.

## Open Questions

None that block specs or tasks. Exact `docker create` flag spelling is implementation.
