## 1. Manager: InstallTree packaging

- [x] 1.1 Add packaging mode (BunCache vs InstallTree); map `dev-util/opencode` → InstallTree, other Bun packages → BunCache
- [x] 1.2 Implement InstallTree pack after `bun install`: archive repo-relative `node_modules` trees into `{pn}-{pv}-deps.tar.xz` (not top-level `bun-cache/` only)
- [x] 1.3 Keep BunCache path for ralph-tui; ensure shared progress/host-gate/lockfile checks still apply
- [x] 1.4 Unit/integration tests: opencode InstallTree layout includes `node_modules`; ralph still produces `bun-cache/`

## 2. Overlay ebuild contract

- [x] 2.1 Rewrite `dev-util/opencode` `src_unpack`: unpack source archive; unpack deps install tree onto `${S}`; leave models JSON in DISTDIR
- [x] 2.2 Rewrite `src_compile`: remove `bun install`; keep models env + `build.ts --single --skip-install` (± webui)
- [x] 2.3 Avoid double-unpack of deps into both `work/` and `${T}/` for cache install
- [x] 2.4 `RESTRICT="strip"` so Portage does not corrupt the Bun-compiled binary (version must report PV, not host Bun)
- [x] 2.5 Sandbox-safe shell completions (`addwrite` ftrace before `opencode completion`)
## 3. Republish and verify

- [x] 3.1 Full-materialize or one-shot rebuild of current opencode PV deps as InstallTree; republish release asset(s) (deps + models pairing); update sidecars with signed assets commit
- [x] 3.2 Regenerate overlay Manifest + md5-cache; signed overlay commit
- [x] 3.3 Operator smoke: `emerge` opencode with default FEATURES including `network-sandbox` (no compile-time registry/GitHub dependency install)

## 4. Quality gates

- [x] 4.1 Keep delta specs aligned with implementation; `openspec validate` for the change
- [x] 4.2 Run full project gate (`hk check`) and fix failures
