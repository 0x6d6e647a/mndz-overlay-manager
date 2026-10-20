# Design

## Context

See proposal.md for why this lane exists. `EcosystemSpec` ends at `Uv {uvLockSubdir}`. Python slot inventory, `slotsInProbeOrder`, `chooseSlot`, and `planUvFromCandidates` already live in `Update.Uv.Python`. The Uv probe is the only caller of `uv python find`, and that call hard-fails a missing host interpreter before `uv sync`. `techniqueNeedsAssets` is already true for every `DepsAndAssets` value.

The materialize recipe orders toolchains rust, sbcl, qlot, node, node-gyp, go, bun, python (`TkPython` rank 7), uv (`TkUv` rank 8). Python slots are a union on the image floor. The image sidecar tolerates a missing toolchain field.

`dev-util/cmake-language-server` is absent from the overlay. Upstream tag `v0.1.11` is the newest release. `v0.1.10` and `v0.1.11` share one `pdm.lock`. The seed has to be packed and emerged before `update`, because once both tags are candidates the lane math selects only `0.1.11`. That is the same shape as the codex-as-mcp donor: pack the seed outside `update`, then let `update` publish the bump.

## Goals / Non-Goals

**Goals:**

- One `Pdm` constructor and one Python lane implementation shared with Uv.
- `outdated` plans a slot from `requires-python` and the Gentoo python ebuilds.
- The image packer publishes one file per selected locked distribution, plus the project backend and the sdist backends.
- The seed ebuild's `IUSE`, `src_test`, and install body survive a later slot rewrite.
- The operator can emerge `0.1.10`, see `outdated` report `0.1.11`, and have `update` publish that bump.

**Non-Goals:**

- Renaming `UvCandidate` or the Uv probe.
- A pack-only CLI. The seed pack is a direct packer invocation, as the Uv donor was.
- Resolving unpinned build backends with `uv`.
- Teaching `pdm sync` a new group that selects only `cmakelang` and `six`.

## Decisions

### 1. Pdm is a sibling constructor

Add `Pdm { pdmLockSubdir :: Maybe FilePath }` to `EcosystemSpec`, with `Nothing` meaning `pdm.lock` at the repository root. Thread it through plan, materialize class, image floors, publish, and overlay-wave classification. Do not add a wildcard case. Policy for `dev-util/cmake-language-server` is GitHub `regen100/cmake-language-server`, tag prefix `v`, `DepsAndAssets (Pdm Nothing)`, empty arch allowlist.

Alternative considered: generating a `uv.lock` constrained to the PDM pins. A fresh resolve installs `pygls` 2.x, and the server cannot import `LanguageServer` from that major. Keeping the committed lock is the point of the new constructor.

### 2. Planning reuses the Uv candidate record and skips the probe

`planPdm` uses the Uv walk: list tags, `filterCandidateVersions`, fetch `pdm.lock`, then `requires-python` (lock, else `pyproject.toml`). The recorded slot is the head of `slotsInProbeOrder` for that specifier. Store it as `ucSynced = singleton slot` and call `planUvFromCandidates`. For each candidate, the plain ceiling is the newest bare slot on that arch that its specifier admits, and the tilde ceiling is the newest admitted slot of either keyword class. Plain eligibility requires the recorded slot to be that admitted plain ceiling. Tilde eligibility requires it to be at or below the admitted tilde ceiling. A newer tree slot the specifier excludes is not a ceiling for that candidate. `chooseSlot` then returns the recorded slot.

Do not call `probeOrdered`, `productionProbeUvSync`, or `uv python find`. A host without `/usr/bin/python3.12` still records slot `3.12`.

On this Gentoo tree the tree-wide plain ceiling is slot `3.14` (`python-3.14.7` has bare `amd64`) and the tilde ceiling is `3.15`. `>=3.8,<3.13` records `3.12` and fills plain and tilde at that slot. `>=3.8,<3.14` records `3.13` and fills plain and tilde at that slot. With both PVs as candidates the planned set is `0.1.11` at slot `3.13`. A Uv candidate whose specifier still admits `3.14` but whose frozen sync succeeded only on `3.13` keeps `3.14` as its plain ceiling and stays off the plain lane.

Alternative considered: a copied lane module. The eligibility rules would drift the first time a ceiling case is fixed for one ecosystem.

### 3. The image owns the first pdm sync

Add `TkPdm` at rank 9, after python and after uv. A Pdm floor emerges `dev-python/pdm` from Gentoo and adds the chosen slot to the existing `pythonSlots` union. It does not set the uv or Rust floor. `dev-python/pdm` is `~arch` here, so the recipe writes package-level `package.accept_keywords` and does not set image-wide `ACCEPT_KEYWORDS`. The 2026-10-19 image build also stopped on `dev-python/dep-logic`, and `hishel` and `unearth` are `~amd64` with no stable ebuild, so the pdm emerge passes `--autounmask=y --autounmask-continue=y` and accepts those dependencies at package level inside the image. Old sidecars omit the new field and still parse; ensure rebuilds when a Pdm floor appears.

Packing runs `pdm sync -G dev --dry-run` in the container, with `pdm use -f` aimed at the image interpreter for the chosen slot, and without `--auto-install-*`. The dry-run names the default-plus-dev set. The packer then downloads each locked filename from the PyPI JSON API and keeps the file whose hash matches the lock. It does not run `pdm lock`, `pdm export`, or a PyPI `pdm sync` to obtain the bytes. A PyPI sync would prefer a platform wheel for `coverage`.

Alternative considered: installing `dev-python/pdm` on the host before the seed exists. `outdated` does not need it, and the ebuild `BDEPEND` installs it when the operator emerges the seed.

### 4. One file per locked distribution

For each dry-run distribution, if the lock lists a `py3-none-any` or `py2.py3-none-any` wheel, pack that wheel. Otherwise pack the sdist and no wheel. For this lock that is twelve pure wheels plus the `coverage` `7.4.4` sdist.

Also pack one artifact for each direct `build-system.requires` of a packed sdist, and for the project's `pdm-backend`. Use the same pure-wheel-or-sdist rule. A wheel stops the walk, so `setuptools` and `pdm-backend` do not pull their own builders. An unpinned name takes the newest PyPI release that publishes a pure wheel and whose `requires-python` allows the slot. The tarball directory is `dists/`. The ebuild points the source named `pypi` at that directory with `type = "find_links"`.

Build isolation stays on. The ebuild does not `BDEPEND` on `dev-python/pdm-backend` or `dev-python/setuptools`.

### 5. The ebuild installs with pdm, and format uses the venv pip

`src_install` creates the virtualenv at `/usr/lib/cmake-language-server` and never moves it. `pdm use -f` is given that virtualenv's interpreter. Passing the bare slot interpreter makes PDM create `${S}/.venv` and sync into it, and Portage then discards that tree. `PDM_BUILD_SCM_VERSION=${PV} pdm sync --prod --no-editable` installs the project into the image virtualenv. An editable install would import from the work directory after the merge. Symlink `/usr/bin/cmake-language-server` at the virtualenv script. `src_test` points `pdm use` at its `${T}` virtualenv the same way before `pdm sync -G dev`. The 2026-10-19 emerge finished the install and then failed the sandbox summary: `pdm` runs the venv interpreter as `python -EsS` on the host `pdm` tree, and `-E` ignores `PYTHONDONTWRITEBYTECODE`, so that process tries to write `.pyc` files under the system site-packages. `src_install` and `src_test` call `addpredict` on that directory. The writes stay denied, and the summary does not fail the merge.

`IUSE="+format"`. When the flag is on, after the prod sync, the virtualenv `pip` installs `cmakelang==0.6.13` and `six==1.16.0` with `--no-index --find-links` on `dists/`, and the ebuild symlinks `/usr/bin/cmake-format`. When the flag is off, that pip install and that symlink are skipped. No dependency group selects those two alone; a synthetic group was not proven against this lock.

`src_prepare` writes `cmake_language_server/version.py` as `__version__ = "${PV}"` so pytest can import the source tree. `src_test` uses a virtualenv under `${T}`, runs `pdm sync -G dev` with the same version variable, prepends that environment's `bin` to `PATH`, and deselects `test_parse_variables`, `test_parse_modules`, and the `find_package(` / `Boost` trigger-character case. The `GoogleTest` and `PROJECT_VERSION` cases stay. `src_test` does not pass `-d` and does not depend on USE `format`.

`RDEPEND` and `BDEPEND` include `dev-build/cmake`. `BDEPEND` includes `dev-python/pdm`. `PYTHON_COMPAT` is the one chosen slot. The seed donor uses `python3_12` and `/usr/bin/python3.12`. The existing slot rewriter, called from Pdm publish, rewrites the atom, `PYTHON_COMPAT`, and the interpreter path, and leaves `IUSE`, `src_test`, and the rest of `src_install` in place.

### 6. Seed pack, then the bump

Implementation packs tag `v0.1.10` at slot `3.12` with the Pdm packer and publishes assets release `cmake-language-server-0.1.10` with the tarball and `b3`, `sha256`, and `sha512` sidecars. That publish is not `update`. The overlay commit is the seed ebuild, `metadata.xml`, Manifest, and md5-cache. `update` stays unused until the operator has emerged `0.1.10` and `outdated` has reported `0.1.11`. `update` then packs `v0.1.11` at slot `3.13`, rewrites the donor, and drops the seed ebuild because it is no longer a planned PV.

The agent does not sudo and does not emerge. Those steps wait on the operator. Nothing is pushed unless the operator asks.

## Risks / Trade-offs

- [Gentoo `dev-python/pdm` pulls a large `RDEPEND` onto the host at the seed emerge] → Accepted. The alternative was installing that closure before the ebuild existed. The image pays the same cost earlier, only inside the container.
- [An unpinned `setuptools` wheel may be too new to build `coverage` `7.4.4`] → The test emerge is the check. If isolation fails, pin that artifact to a wheel that builds this sdist and keep the one-file rule.
- [`pdm sync --dry-run` warns that the lock is old and still installs locked versions] → Packing treats the warning as noise and does not relock. A hash mismatch or a dry-run that does not list the dev set fails the pack.
- [The first `update` deletes the `0.1.10` ebuild] → Expected once `0.1.11` is the only planned PV. The seed assets release stays. Do not run `update` to create the seed.
- [Image ensure rebuilds when the sidecar has no pdm floor] → Same rebuild the uv floor already causes. A Pdm-only ensure does not emerge Rust or uv.
- [`version.py` written in `src_prepare` can be overwritten by the build] → `PDM_BUILD_SCM_VERSION` writes the same PV. Pytest imports `${S}` after that write.

## Migration Plan

1. Land the manager, with tests, before any overlay commit.
2. Ensure the materialize image for Python `3.12` plus `dev-python/pdm`.
3. Pack and publish the `0.1.10` assets release. Commit the seed in the overlay. Do not push.
4. The operator emerges `=dev-util/cmake-language-server-0.1.10` and runs `outdated`.
5. The operator runs `update` on a TTY. That publishes `0.1.11` and rewrites the ebuild to slot `3.13`.
6. The operator emerges and tests `0.1.11`.

Rollback before push is a local reset of the overlay and assets commits. The image can be rebuilt from the previous sidecar by leaving the Pdm floor unused. No existing package changes technique.

## Open Questions

None. The slot probe, the artifact rule, the install, and the seed-then-bump order are fixed by the specs.
