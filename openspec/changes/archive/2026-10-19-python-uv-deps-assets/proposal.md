# Proposal

## Why

`codex-as-mcp` (`kky42/codex-as-mcp`) has no mndz-overlay package, and the manager has no uv `DepsAndAssets` lane, so `outdated` and `update` cannot follow its releases. The newest comparable tag is `v2026.6.29.1`. Seeding the predecessor `2026.2.2.1` makes the first automated update observable: `update` always selects the newest comparable tag and will not materialize an older seed once a newer tag exists.

## What Changes

- Add a `DepsAndAssets` ecosystem `Uv`. Each package version publishes one `${PN}-${PV}-deps.tar.xz` from the Linux closure of the committed `uv.lock` (runtime and dev groups), built from sdists, with `cargo vendor` for unvendored Rust sdists. Distributions whose only lock edges are Windows markers are omitted. A missing `uv.lock` hard-fails. Packing uses `uv sync --frozen` and does not run `uv lock`.
- Python runtime lanes take plain and tilde ceilings from `dev-lang/python` slots. Frozen `uv sync` filters the slots `requires-python` already allows. The ebuild slot is the newest bare-keyworded slot whose sync succeeds; a tilde-only slot is used only after every bare slot fails. The probe tries newest bare first and stops at the first success. A plain lane selects the newest tag that syncs on that lane’s plain ceiling slot. When a newer tag does not, the plain lane keeps an older tag that does, and the tilde lane takes the newer tag. When no tag syncs on the plain ceiling, the plain lane has no target. A missing interpreter hard-fails planning. One venv and one `PYTHON_COMPAT`. Overlay `KEYWORDS` stay tilde for every arch that slot keywords. An empty allowlist does not add `-*`.
- Add `dev-util/codex-as-mcp` to the canonical policy and GitHub source maps: GitHub `kky42/codex-as-mcp`, tag prefix `v`, `DepsAndAssets` `Uv`, lock at the repository root, empty arch allowlist. Seed `2026.2.2.1` by direct materialize of tag `2026.2.2.1` before policy can select only the newest tag. Each bump records the real tag string that parsed to that PV in the source archive URL (`2026.2.2.1` and `v2026.6.29.1` are different spellings).
- Ebuild `IUSE` is `external-codex` (default off) and `test`. Flag off: unversioned `RDEPEND` on `dev-util/codex`; the wrapper prefers `/usr/bin/codex`, and an already-set `CODEX_PATH` still wins. Flag on: no `dev-util/codex` dependency; when `CODEX_PATH` is set, prepend its directory, otherwise leave `PATH` alone. `src_test` runs pytest on `tests/test_server.py` when that file exists. The installed image is a private venv at `/usr/lib/codex-as-mcp` with system site-packages off. `pkg_postinst` warns that the server launches Codex with approvals and the sandbox bypassed.
- After the policy exists, `outdated` for this package reports `2026.2.2.1` -> `2026.6.29.1` on each tilde lane as `(dev-lang/python:3.13 ~<arch>)` and prints no plain-lane line, because neither tag syncs on the plain ceiling. `update` rewrites `SRC_URI`, `KEYWORDS`, the Python slot atom, and the `/usr/bin/python<major>.<minor>` interpreter path while keeping the donor `IUSE` and test body.
- The materialize image installs the chosen Python slot, Rust, and `dev-python/uv` after Rust, when a Uv floor needs them. Packing uses that image `uv` with CPython downloads disabled. Uv ceilings come from gentoo, so Uv does not create an overlay wait-edge. Disk preflight gains a documented Uv floor.

## Capabilities

### New Capabilities

- `uv-deps-assets`: `uv.lock` parsing, Linux-marker closure, sdist packing, cargo vendor of unvendored Rust sdists, frozen sync, missing-lock failure, and the per-PV source-archive tag spelling.
- `dev-util-codex-as-mcp-seed`: identity of the `2026.2.2.1` donor, USE and runtime dependencies, private venv, wrapper `PATH` / `CODEX_PATH` behavior, test gating, and wrapper smoke.

### Modified Capabilities

- `deps-assets`: `Uv` is a `DepsAndAssets` ecosystem; distfile suffix `-deps.tar.xz`; the assets-technique predicate includes it.
- `runtime-lanes`: Python slot ceilings from `dev-lang/python`, a frozen-sync probe on specifier-legal slots, one chosen slot, a plain lane that keeps an older tag or stays empty, and lane labels. Shared ecosystem lists name `Uv`.
- `update-apply`: canonical policy entry for `dev-util/codex-as-mcp`; first-class apply includes `Uv`.
- `update-source`: GitHub source `kky42/codex-as-mcp`, tag prefix `v`.
- `ensure-materialize-image`: the image installs the Python slot, Rust, and `dev-python/uv` through Portage when the Uv floor needs them.
- `hermetic-asset-materialize`: full-path Uv packing uses image `uv` and image Python.
- `overlay-apply-waves`: `Uv` is a gentoo-ceiling ecosystem and does not create an overlay wait-edge.
- `disk-space-preflight`: documented Uv ecosystem floor.
- `project-docs`: operator docs name `Uv` among `DepsAndAssets` ecosystems. Packing stays inside the materialize image.

## Impact

- Manager: policy map, lock parser, packer, image recipe, lane planner, overlay rewrite (archive tag, `KEYWORDS`, Python slot atom), and the disk floor. No new CLI flag or config key. Package targets stay `category/package` or an unambiguous bare name. PV is never a CLI argument.
- Overlay: `dev-util/codex-as-mcp/codex-as-mcp-2026.2.2.1.ebuild`, `metadata.xml`, Manifest, and md5-cache. Category `dev-util` already exists. Slot `0`, license MIT.
- Assets: release tag `codex-as-mcp-2026.2.2.1` containing `codex-as-mcp-2026.2.2.1-deps.tar.xz` with checksum sidecars. The following `update` publishes `2026.6.29.1` the same way, using archive tag `v2026.6.29.1`.
- Operator smoke after emerge of the seed is that `/usr/bin/codex-as-mcp` starts (`--help`). The newer ebuild is emerged with `USE=test` and `FEATURES=test` so pytest runs. The operator runs every emerge, `outdated`, and `update`. Packing the seed and the signed seed commit are agent work. The package is not a materialize-image dependency and not an overlay wait-edge provider.

## Non-goals

- `bundled-codex`, an npm `@openai/codex-linux-x64` companion distfile, parsing the README for a Codex version floor, sandbox or approvals USE flags, or an `mcp[cli]` USE flag.
- Using profile `PYTHON_TARGETS` to pick the slot, emitting one ebuild per slot in the `requires-python` range, or a Python-slot USE flag.
- Hermes Agent, `cmake-language-server`, `poetry.lock`, `pdm.lock`, `pylock.toml`, `requirements.txt`, or authoring pins with `uv lock`.
- Packing manylinux wheels, network access during emerge, per-arch prebuilt venvs, a managed `dev-python` graph, or multi-package Python workspaces.
- Running `tests/live_codex_smoke.py` inside Portage, a CLI version pin, or changing Cargo or Go vendor layouts.
- Shrinking `KEYWORDS` to `-* ~amd64` because `dev-util/codex` is amd64-only. Default USE fails closed off amd64; `external-codex` is the other-arch mode.
