## 1. Path resolution and config

- [x] 1.1 Add pure default path helpers: XDG cache base + `mndz/overlay-manager/distfiles`; unit-test with/without `XDG_CACHE_HOME`
- [x] 1.2 Add `distfilesPath :: Maybe FilePath` (`distfiles-path`) to `OverlayConfig` and parse tests/fixtures
- [x] 1.3 Add global CLI `--distfiles-path` and effective-path resolver (CLI → config → default)
- [x] 1.4 Implement `ensureDistfilesDir` creating missing dirs with mode `0700`
- [x] 1.5 Implement `isSystemDistfilesPath` (canonical `/var/cache/distfiles` and optional live Portage DISTDIR) with tests

## 2. Preflight probe and ebuild env

- [x] 2.1 Implement create-then-rename probe; wire into `update` preflight before package mutation
- [x] 2.2 Extend ebuild runner to merge full parent env with `DISTDIR=<effective>` and `GENTOO_MIRRORS=`
- [x] 2.3 Thread effective distfiles path from Main/update spine into `ApplyEnv` / production ebuild runner construction
- [x] 2.4 Map sticky/EPERM/`.__download__`/`.layout.conf` manifest stderr into actionable hard-fail text (class 8)
- [x] 2.5 Unit tests: env construction keys; message mapping on sample Portage stderr; probe success/fail in temp dirs

## 3. eclean command

- [x] 3.1 Add `eclean` work subcommand to parser and Main dispatch
- [x] 3.2 Implement clean: resolve path, refuse system DISTDIR (exit 1), delete manager cache contents, missing path = success
- [x] 3.3 Top-level and `eclean --help` text; tests for help catalog and refuse path

## 4. Docs and quality

- [x] 4.1 Update `README.md`: `distfiles-path`, default XDG path, `--distfiles-path`, private DISTDIR rationale, `eclean` example and system refuse
- [x] 4.2 Confirm cabal `exposed-modules`/`other-modules` for any new module; weeder roots only if needed
- [x] 4.3 Run `openspec validate private-distfiles-for-manifest --strict` (or project equivalent) and fix artifact issues
- [x] 4.4 Run full gate `hk check` and fix until green
