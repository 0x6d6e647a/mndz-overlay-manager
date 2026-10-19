# Design

## Context

See `proposal.md` for why this change exists. `DepsAndAssets` is the update technique. Ecosystems today are `Go`, `NpmEco`, `Bun`, `Cargo`, and `Sbcl` (`Update.Types.EcosystemSpec`). `techniqueNeedsAssets` is already true for every `DepsAndAssets` value. Empty `policyLaneArches` already means all arches (`restrictCeilings []` returns the ceilings unchanged).

`publishPrepared` (`Update.Apply.OverlayWrite`) parameterizes the assets `SRC_URI`, sets `KEYWORDS`, then aligns one runtime field per ecosystem. Cargo's GitHub archive line is preserved from the donor. Go reconstructs `prefix ++ PV`. Neither is safe for `codex-as-mcp`, whose tags are `2026.2.2.1` and `v2026.6.29.1`. `stripAndParse` already accepts both: a configured prefix is stripped when the tag starts with it, and otherwise the raw tag is parsed.

The materialize image installs toolchains from Portage in `kindRank` order (`Update.Materialize.Recipe`). Rust is rank 0. `dev-python/uv` in gentoo builds with Rust, so uv must be emerged after Rust. Disk floors live in `Update.DiskSpace` (`floorGoTemp` 3 GiB, `floorCargoTemp` 1.5 GiB, `floorNpmBunTemp` 1.5 GiB, `floorSbclTemp` 2 GiB, `floorReuseTemp` 512 MiB). Full-path expansion factors are Go 5, Cargo 12, npm/Bun 4, Sbcl 10.

The seed lock at tag `2026.2.2.1` is stale against `pyproject.toml` (`uv lock --check` fails; `uv sync --frozen` succeeds). A hand-rolled marker walk mis-classifies markers that mention `PyPy`. The frozen Linux resolution is the closure authority. Windows-only distributions (`pywin32`, `pywin32-ctypes`, `colorama` on this lock) stay in the parsed lock and out of the tarball.

## Goals / Non-Goals

**Goals:**

- Add ecosystem `Uv` on the existing plan, materialize, adequacy, and overlay-write spine.
- Pack one `${PN}-${PV}-deps.tar.xz` of Linux sdists plus `cargo vendor` trees, using image `uv` and a frozen sync.
- Select one Python slot from `dev-lang/python` keywords, `requires-python`, and a frozen sync, and rewrite that slot atom, the venv interpreter path, and the real git tag.
- Seed `dev-util/codex-as-mcp` at `2026.2.2.1` so a later `update` can move it to `2026.6.29.1`.
- Keep new modules in `other-modules` unless a test import needs them exposed.

**Non-Goals:**

- A new CLI flag, a PV argument, or a second apply entry point.
- Authoring locks, other lock formats, manylinux wheels, or per-arch venvs.
- Changing Cargo or Go vendor layout. Naming Sbcl in the first-class apply sentence records behavior the code already has.

## Decisions

### 1. Ecosystem shape

`EcosystemSpec` gains `Uv { uvLockSubdir :: Maybe FilePath }`. `Nothing` is the repository root. `dev-util/codex-as-mcp` uses `Nothing`, GitHub `kky42/codex-as-mcp`, tag prefix `v`, and `policyLaneArches = []`.

Dispatch is a new branch on the existing `planDepsPackageWithProgress` case, the materialize class case, the image floor collector, and `publishPrepared`. Exhaustive compiler warnings are the checklist. Do not add a wildcard that drops future ecosystems.

`Update.Uv.Lock` is `other-modules`. Expose it only if the test suite must import it, the same justification `Update.Sbcl.Deps` already has. Do not grow weeder roots.

Alternative: a parallel "python vendor" technique. Rejected because adequacy, reuse, waves, and disk preflight already key off `DepsAndAssets`.

### 2. Tag retained beside the PV

Listing already sees the raw tag before `stripAndParse`. The Uv plan snapshot stores that raw tag on the PV. `publishPrepared` writes `archive/refs/tags/<raw-tag>.tar.gz` and leaves the assets URL on `${PV}` via `parameterizeAssetsSrcUriFor`. It does not call the Cargo archive preserver and does not build `v${PV}`.

Two raw tags that parse to one PV hard-fail that candidate. This package's two tags parse to different PVs.

The runtime field passed through the existing requirement channel is the chosen slot, used by `ensurePythonSlot`. That function rewrites `dev-lang/python:<slot>`, the `PYTHON_COMPAT` `python3_<slot>` token, and each `/usr/bin/python<major>.<minor>` path. It does not rewrite `IUSE` or `src_test`. The rest of `src_install` stays. A free-threaded token such as `python3_13t` stays. For `codex-as-mcp` the chosen slot is `3.13`.

### 3. Slot ceilings

Group non-live `dev-lang/python` ebuilds by `SLOT` (`3.14`, `3.15`). Gentoo writes `SLOT="${PYVER}"`. Regular ebuilds set `PYVER=$(ver_cut 1-2)`, which is the slot `major.minor`. Free-threaded ebuilds set `PYVER="$(ver_cut 2-3)t"` and are not ceiling slots. Ignore `_rc` and `9999`. Do not read `PYTHON_TARGETS`.

For each arch, the plain ceiling slot is the newest slot with a bare keyword on that arch. The tilde ceiling slot is the newest slot with a tilde or bare keyword. Compare slot `major.minor` only.

During planning, each tag is cloned once and probed with `uv sync --frozen`, `UV_PYTHON_DOWNLOADS=never`, and `--python <slot>`. Slots the specifier excludes are not probed. Order is newest satisfying bare slot first. The first bare success stops the probe. A tilde-only slot is probed only after every satisfying bare slot has failed. The recorded success is that one slot. A missing `python3.<slot>` hard-fails the plan. A non-zero sync when the interpreter exists rejects that slot. Do not run `uv lock`.

A candidate qualifies for a plain lane only when the plain ceiling slot itself is the recorded success. When a newer tag misses that slot and an older tag hits it, the plain lane keeps the older tag and the tilde lane takes the newer tag. That covers both a lock that builds only on an older slot (`3.14` to `3.13`) and a lock that builds only on a newer tilde slot (`3.14` to `3.15`). When no tag syncs on the plain ceiling, the plain lane has no target.

A candidate qualifies for a tilde lane when some recorded success is at or below the tilde ceiling. The tilde lane selects the newest such tag, at that tag’s chosen slot.

The ebuild slot is the newest bare-keyworded slot whose sync succeeded, else the newest tilde-only slot whose sync succeeded. One `PYTHON_COMPAT`. Two PVs when plain and tilde lanes select different tags. Both ebuilds stay `~arch`, so Portage still prefers the higher version. Candidates that share a chosen slot collapse to one PV.

Specifier parser: comma-separated `==`, `!=`, `>=`, `>`, `<=`, `<`, `~=` against `major.minor`. An unrecognized specifier makes that candidate ineligible and is not probed. `>=3.11` selects slot `3.14` when sync on `3.14` succeeds. When `3.14` fails and `3.13` succeeds, the chosen slot is `3.13` and plain lanes have no target. `>=3.15` with only tilde keywords on `3.15` has no plain target. `>=3.8,<3.14` against an inventory of only `3.14` and `3.15` selects nothing.

`KEYWORDS` are the usual tilde collapse, intersected with arches the chosen slot keywords. An empty allowlist does not add `-*`.

Lane labels use `dev-lang/python:<slot>` plus the existing arch/tier form.

### 4. Pack closure

Inside the existing full-path container, with `UV_PYTHON_DOWNLOADS=never` and `--python <slot>`:

1. `uv sync --frozen --all-groups --no-install-project` is the resolution authority. Do not run `uv lock` or fail the pack on `uv lock --check`.
2. Pack source distributions for that resolved set. A selected distribution with no sdist hard-fails the package. Do not pack wheels.
3. For a packed Rust sdist with no `vendor/` directory, run `cargo vendor` and keep the generated `.cargo/config.toml` inside that sdist.
4. Pack with the existing hermetic tar/xz helper. Layout is `sdists/<file>` after vendoring. The ebuild and the packer share that layout.
5. After the lock sdists are packed, read each sdist's top-level `pyproject.toml`. Resolve each distinct `build-system.requires` list on its own with `uv pip install --dry-run --no-binary :all:` against a fresh venv of the chosen slot. Keep only the `Would install` sdists. Verbose `Selecting:` lines also list candidates the resolver rejected. A missing `[build-system]` table resolves `setuptools` and `wheel`. Download those sdists, `cargo vendor` any new Rust sdist, and repeat until no new sdist appears. Do not pack wheels. Do not run `uv lock`. The requirements file, that venv, and the PyPI sdist-url script are created under the unit work directory. The materialize container bind-mounts that directory and does not see a host-only temporary directory.

Git and path dependencies are accepted by the parser. A selected git dependency is cloned during materialize (network is allowed there) and stored beside the sdists. This package has none.

Emerge installs the locked closure from the unpacked `sdists/` directory with no network. `uv sync --frozen` cannot: it selects the lock's manylinux wheel and checks the original sdist hash, and `cargo vendor` rewrites the Rust sdists. The ebuild runs `uv export --frozen --no-hashes --no-emit-project` and `uv pip install --offline --no-index --find-links <sdists> --no-binary :all: --python <venv>`. Build isolation stays on, so uv installs `build-system.requires` from those sdists. `--python` targets the image venv. The private venv is created with `uv venv` and does not see system site-packages. The pip install runs with `PYTHON` unset. Portage exports `PYTHON` to the system interpreter, and `pydantic-core`'s `build.rs` uses that variable to run `generate_self_schema.py`, which imports `typing_extensions`. The isolated build env has the module. maturin sets `PYO3_PYTHON` to that env, and the build script uses it only when `PYTHON` is unset. Rust builds set `CARGO_NET_OFFLINE=true`. `UV_CACHE_DIR` and `CARGO_HOME` stay under `${T}`. Portage `network-sandbox` is the emerge network boundary. PEP 517 backends are not Gentoo packages. The toolchain that stays a `BDEPEND` is the Python slot, `dev-python/uv`, and Rust, same as the Go and Cargo asset flows.

The installed image is a venv at `/usr/lib/codex-as-mcp` created without system site-packages. Dev-group distributions are installed only in the build/test environment. `src_test` runs `pytest tests/test_server.py` when that file exists and succeeds with an `einfo` when it does not. It does not collect `live_codex_smoke.py`. That pytest is installed into the test venv from the deps tarball. The ebuild does not `BDEPEND` on Gentoo `dev-python/pytest`.

`BDEPEND` is the Python slot, `dev-python/uv`, `|| ( dev-lang/rust-bin dev-lang/rust )`, plus `dev-libs/openssl` and `dev-libs/libffi` so the test phase can build `cryptography`. Those two C libraries are not `RDEPEND`. Hatchling, maturin, setuptools, and the other PEP 517 backends are sdists in the deps tarball. The ebuild does not depend on them and does not put the system `site-packages` on `PYTHONPATH`.

### 5. Image order and disk floor

New toolchain kinds `TkPython` and `TkUv`, ranks 7 and 8. Rust stays rank 0, so a Uv floor that also requests Rust still emerges Rust first. The Uv floor collector always requests Rust, the chosen slot (`dev-lang/python:<slot>`), and `dev-python/uv` (the existing `-bin`-then-source rule if a bin package exists). No python.org or astral tarball URLs.

`MaterializeClass` gains `FullUv`. `floorUvTemp = 1 GiB`. `factorUv = 4`. Reuse-without-size keeps the shared `floorReuseTemp` (512 MiB). The compressed closure is tens of megabytes; the floor covers the clone, the uv cache, and cargo vendor trees on the temp filesystem.

Uv ceilings come from gentoo, so the overlay-wave case that already returns no provider for Go/Npm/Cargo/Sbcl returns no provider for Uv. `codex-as-mcp` is not an image dependency.

### 6. Seed donor

The donor is handwritten once, then preserved. Inherit `python-single-r1`. For this package the planner’s slot is `3.13`, so the seed uses `PYTHON_COMPAT=( python3_13 )`, `dev-lang/python:3.13`, and `uv venv --python /usr/bin/python3.13`. `SLOT="0"`, `LICENSE="MIT"`, `IUSE="external-codex test"`, `RESTRICT="!test? ( test )"`, no `REQUIRED_USE`, no `bundled-codex`.

Archive URL: `https://github.com/kky42/codex-as-mcp/archive/refs/tags/2026.2.2.1.tar.gz -> ${P}.tar.gz`. Assets URL uses `${PV}`. `KEYWORDS` is the tilde form of every arch on slot `3.13`. Slot `3.13` keywords the same full arch set as slot `3.14` (`python-3.13.16` is `~arch` on every arch, and the tilde lanes cover those arches), so the keyword string matches the earlier `3.14` string. Plain lanes do not target this PV.

The wrapper `/usr/bin/codex-as-mcp` implements the `CODEX_PATH` rules in the seed spec. `pkg_postinst` warns about approvals and the sandbox bypass.

Write the seed body so a planner run treats `2026.2.2.1` as adequate. `update` then adds `2026.6.29.1` with archive tag `v2026.6.29.1` and does not need a content-fix of the seed solely for keywords, the slot, or the archive spelling.

There is no CLI to aim `update` at `2026.2.2.1`. Pack that tag with the same container packer before running `update`. Policy may land in the manager first: discovery only sees the package once the overlay ebuild exists.

### 7. Docs

`README.md` already says full-path materialize uses the image and does not require host `go` / `npm` / `bun` / `sbcl` / `pycargoebuild`. Extend that image tool list with Python, uv, and Rust, and name `Uv` next to Go, npm/Bun, Cargo, and Sbcl in the `DepsAndAssets` sentence. Do not add a host `uv` runtime.

Update the `openspec/config.yaml` context ecosystem list so it includes `Sbcl` and `Uv`. That string is planner context, not a living spec.

## Risks / Trade-offs

- [Seed lock is stale] → Frozen sync is the pack gate. Do not re-lock and do not fail on `uv lock --check`.
- [Marker strings are not a closure] → The image `uv sync --frozen` set decides what is packed. The parser still accepts Windows-only entries.
- [A transitive crate asks for a newer rustc than the image] → Packing hard-fails that PV. Do not lower the declared `rust-version` and do not fetch rustup.
- [Slot `3.15` later gains a bare keyword] → The next update rewrites the atom and the venv interpreter path when sync on that slot succeeds. The donor `IUSE` and test body stay.
- [A newer tag syncs on a different slot] → Plain keeps the older tag that syncs on the plain ceiling. Tilde takes the newer tag. Both ebuilds stay `~arch`, so Portage still prefers the higher version.
- [The probed interpreter is not installed] → Planning hard-fails. A missing `python3.<slot>` is not a failed sync, and the probe does not skip to an older slot.
- [`codex-as-mcp` syncs on `3.13` only] → One ebuild, tilde lanes, slot `3.13`. Plain lanes have no target. `outdated` prints no plain line. The bump from `2026.2.2.1` to `2026.6.29.1` does not move the slot.
- [`cryptography` needs OpenSSL at test time] → `BDEPEND` only. Default emerge does not install it into `/usr/lib/codex-as-mcp`.
- [Home filesystem is tight] → Clones, the uv cache, and image builds stay on the existing temp root and Docker volumes. Do not put them in the repo checkout.
- [`/var/tmp/portage` build logs are mode 0700] → The operator reads failed emerge logs. The agent does not.

## Migration Plan

1. Land the manager lane, policy entry, tests, and README. `just check` is the gate.
2. Ensure `mndz-overlay-manager/materialize:local` for slot `3.13` (recipe emerges `dev-lang/python:3.13` and `dev-python/uv`; this `docker build` retags `:local` and is not `docker commit`), then pack tag `2026.2.2.1` in that image and publish assets release `codex-as-mcp-2026.2.2.1`. This is not an `update`. Do not pack on `3.14`. If ensure refuses the build, stop.
3. Regenerate Manifest and md5-cache for the seed already in the worktree, and sign `dev-util/codex-as-mcp: 2026.2.2.1` with an empty body. No overlay push unless asked.
4. Operator emerges the seed. Success is `/usr/bin/codex-as-mcp --help`.
5. Operator runs `outdated`, then `update` on a TTY (pinentry). `outdated` shows `2026.2.2.1 -> 2026.6.29.1` on each tilde lane as `(dev-lang/python:3.13 ~<arch>)` and no plain-lane line.
6. Operator emerges the new ebuild with `USE=test` and `FEATURES=test`.

Rollback before step 5 is reverting the manager change and removing the unpushed overlay commit. After `update`, roll back by resetting the overlay and assets commits the operator made. No on-disk format migration.

The agent does not run `emerge`, `outdated`, or `update`, and does not sudo.
