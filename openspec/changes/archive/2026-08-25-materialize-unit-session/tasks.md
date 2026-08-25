## 1. Session Docker module

- [x] 1.1 Replace per-command `docker run` wrap with session helpers: `docker create` (`--rm`, `--user`, forced `HOME`/`XDG_*`, labels, name, bind **unit** `work/` and `out/` only), `docker start`, inspect-until-running, `docker exec` (cwd / `prEnv` after the existing denylist, `-i` when stdin non-empty), `docker rm -f` in `bracket`; PID 1 `sleep infinity`; no restart policy, no `--init`. Verify unit tests assert create argv (not `run` per inner cmd) and exec argv for a sample `go version` request
- [x] 1.2 Name `mndz-mat-<runId>-<cat>-<pn>-<pv>` with `/` → `-`; labels `mndz.overlay-manager=1`, `.run=<runId>`, `.pid=<cliPid>`. Verify tests cover sanitization and label keys
- [x] 1.3 `withUnitMaterializeSession cfg unitDirs (CommandRunner -> IO a)`: create/start before the continuation, `rm -f` on success and exception; create/start failure is `Left`/hard-fail for that unit; exec into a non-running session is a hard-fail, not a silent new session. Verify fake-runner tests for the bracket and both failure paths

## 2. Apply wiring

- [x] 2.1 Stop building one `productionMaterializeRunner` on the run root in Spine. Resolve image + uid:gid once; open `withUnitMaterializeSession` after `ensureUnit` around `materializeDistfiles` and `mk*Ops` from that runner. Verify reuse-path and GitMv still do not start a session (tests: no `docker create` on reuse)
- [x] 2.2 Sequential PVs each get a new session. Verify a two-PV cargo/go fake records two create/rm pairs, not one shared container

## 3. Leftover sweep

- [x] 3.1 At start of mutate that will full-path, best-effort `docker ps -aq --filter label=mndz.overlay-manager=1` and `rm -f` containers whose `.pid` is not a live overlay-manager process; never hard-fail on sweep; never remove a container whose pid **is** live overlay-manager. Verify scripted CommandRunner tests for dead-pid remove, live-pid keep, and sweep error ignored

## 4. Cargo progress

- [x] 4.1 During crate staging, `mhStatus` `staging crates k/N`; when xz starts, `crates pack`. Keep `fullPathMaterializeSteps` at 7. Verify tests still expect seven materialize steps and a fake progress host sees the staging label

## 5. Docs and quality gate

- [x] 5.1 README: named `mndz-mat-…` containers for live `docker stats`/`exec`; removed when the unit ends; do not tell operators to keep failed containers. Verify the `project-docs` scenarios against the text
- [x] 5.2 `openspec validate materialize-unit-session --strict --type change` and `hk check` green; no weeder/stan weakening; no casual `exposed-modules` expansion; no image generator bump
