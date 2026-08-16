## 1. Hermetic pack helper

- [x] 1.1 Update `Update.Pack.XzTar` to pass `--owner=0 --group=0 --numeric-owner --sort=name --mtime=@0 --clamp-mtime` (and PAX atime/ctime delete when GNU tar) and set `XZ_OPT=-T1 -9e`
- [x] 1.2 Unit-test a packed fixture: members are `0/0`, xz magic still verified, `XZ_OPT` contains `-T1` and `-9e`
- [x] 1.3 Update existing pack tests that assert `-T0` / multi-thread wording

## 2. Ecosystem pack filters

- [x] 2.1 Npm: empty userconfig under unit `work/`; delete `_logs/` and `_update-notifier*` before pack; tests that packed members omit those paths
- [x] 2.2 BunCache: rewrite absolute `bun-cache/` symlinks to relative in-tree targets; hard-fail if any absolute link remains; tests for unscoped and scoped (`@scope/name`) alias forms
- [x] 2.3 Sbcl: run qlot with non-operator `HOME`; scan/rewrite `.qlot/qlot.conf` and `source-registry.conf` so packed files contain no operator-home path; test with a fixture conf
- [x] 2.4 InstallTree (opencode) uses the shared hermetic tar only; no BunCache rewrite required

## 3. Materialize image

- [x] 3.1 Add in-repo Gentoo Dockerfile (e.g. `docker/materialize/Dockerfile`) with git, tar, xz, go, node/npm, bun, sbcl, image-local Quicklisp/qlot, cargo, pycargoebuild+Portage Python, aria2c/wget, and a writable `/home/builder`
- [x] 3.2 Document the image tag constant / `MNDZ_MATERIALIZE_IMAGE` override and `docker build` in README (task 6.1 may complete the prose)

## 4. Docker command runner and spine

- [x] 4.1 Add a production runner (or wrapper) that, for full-path materialize child processes, invokes `docker run --rm --user host-uid:host-gid --env HOME=/home/builder` with unit `work/`/`out/` bind-mounted at the same absolute paths
- [x] 4.2 Wire full-path ecosystem builders (Go, npm, Bun, Cargo, Sbcl) and their `tar`/`git clone`/`pycargoebuild` through that runner; reuse path stays on the host
- [x] 4.3 Image toolchain gates (`go version`, `node --version`, `bun --version`) probe the container, not the host PATH
- [x] 4.4 Do not pass `GITHUB_TOKEN` / `GNUPGHOME` / `SSH_AUTH_SOCK` into the materialize container; publish remains host-side after `out/` exists
- [x] 4.5 Injectable/fake runner so unit tests do not require a live Docker daemon

## 5. Preflight and config warn

- [x] 5.1 After classify, require `docker` + usable image when any unit is full path; do not require host `go`/`npm`/`bun`/`xz`/`pycargoebuild`/fetchers for that path
- [x] 5.2 Drop reuse-only cargo host `pycargoebuild`+fetcher hard requirement; stop emitting the host wget/aria2 advisory
- [x] 5.3 `Config.Loader`: warn when the loaded TOML mode is not `0600`; do not hard-fail; skip on help-only paths
- [x] 5.4 Tests for full-path missing docker (hard-fail), reuse-only without docker (ok), reuse-only cargo without pycargoebuild (ok), and config mode warn vs `0600`

## 6. Docs and gates

- [x] 6.1 Update `README.md` per `project-docs` delta (Docker full-path runtime, image build, host spine/GPG/SSH/Portage, config `0600` warning)
- [x] 6.2 `openspec validate --change hermetic-asset-materialize` (and `--strict` if project practice requires)
- [x] 6.3 `hk check` green; new modules stay off `exposed-modules` unless the executable or test-suite needs them; no casual weeder/`root-modules` widening
