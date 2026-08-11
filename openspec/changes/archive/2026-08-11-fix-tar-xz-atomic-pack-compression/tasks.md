## 1. Shared xz pack + verify

- [x] 1.1 Add a small internal helper for xz magic verification (header check) that hard-fails with a clear non-xz / plain-tar message
- [x] 1.2 Add shared tar+xz pack helper(s): set `XZ_OPT=-T0 -9e`, force xz compression (explicit `-J`/`--xz` and/or archive path ending in `.xz`), optional atomic temp+rename in the same directory as the final path
- [x] 1.3 Unit-test verify rejects a plain tar written under a `.tar.xz` name and accepts a real xz stream (tiny fixture)

## 2. Cargo atomic pack fix

- [x] 2.1 Rewire `createArchiveAtomic` / Cargo pack to use the shared helper so atomic temp cannot disable compression (no bare `.tmp` auto-compress footgun)
- [x] 2.2 Assert post-pack xz verification on the final crates path before success
- [x] 2.3 Tests: scripted `CommandRunner` records tar argv/env — `XZ_OPT` contains `-T0` and `-9e`; archive path ends with `.xz` and/or `-J` present
- [x] 2.4 Tool-gated or production-runner test: pack a tiny `cargo_home` stage to `*.tar.xz` and assert file magic is xz (would fail under old `.tmp` behavior)

## 3. Uniform `-9e` + verify on other ecosystems

- [x] 3.1 Go vendor pack: `XZ_OPT=-T0 -9e` + post-pack xz verify
- [x] 3.2 Npm deps pack: `XZ_OPT=-T0 -9e` + post-pack xz verify
- [x] 3.3 Bun BunCache and InstallTree packs: `XZ_OPT=-T0 -9e` + post-pack xz verify
- [x] 3.4 Sbcl/Autolith deps pack: `XZ_OPT=-T0 -9e` + post-pack xz verify
- [x] 3.5 Tests: at least one non-Cargo pack path asserts `XZ_OPT` includes `-T0` and `-9e` (scripted runner)

## 4. Quality gate

- [x] 4.1 `hk check` green (format, hlint, build, tests, stan, weeder, coverage as required by CONTRIBUTING)
- [x] 4.2 Confirm no remaining `XZ_OPT=…-9` (non-`e`) in DepsAndAssets pack sites under `src/Update/`
