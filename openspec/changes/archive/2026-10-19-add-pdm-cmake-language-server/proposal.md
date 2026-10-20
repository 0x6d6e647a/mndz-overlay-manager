# Proposal

## Why

`dev-util/cmake-language-server` (GitHub `regen100/cmake-language-server`) ships a committed `pdm.lock` that this manager cannot pack. Turning that lock into a `uv.lock` resolves `pygls` 2.x and breaks the server. A PDM `DepsAndAssets` lane keeps the lock pins, and a v0.1.10 seed makes the v0.1.11 bump the first thing `outdated` and `update` can show.

## What Changes

- Add ecosystem `Pdm` (optional lock subdirectory; unset means `pdm.lock` at the repository root) beside `Uv`. Share Python slot ceilings, lane eligibility, one slot per PV, tilde `KEYWORDS`, and `dev-lang/python:<slot>` labels. Do not run a host sync probe and do not hard-fail a missing host interpreter.
- Planning reads `requires-python` and records the slot the specifier allows (newest bare-keyworded slot, else newest tilde-keyworded slot). A missing `pdm.lock` hard-fails. The program does not run `pdm lock` or `pdm export`.
- Full-path packing runs in the materialize image. The image gains the chosen `dev-lang/python` slot and `dev-python/pdm`. A PDM-only image does not need Rust or uv. The container uses that `pdm` and does not download CPython.
- The deps tarball is `{pn}-{pv}-deps.tar.xz`. For each locked distribution in the default and `dev` groups, pack the pure `py3-none-any` or `py2.py3-none-any` wheel when the lock has one, otherwise the sdist. Also pack the build backend the packed sdist needs and `pdm-backend` for the project. Omit every other file for that distribution, including platform wheels for a package that was packed as an sdist.
- Seed `dev-util/cmake-language-server` at PV `0.1.10` (tag `v0.1.10`, slot 3.12) with `IUSE="+format"`, a private venv at `/usr/lib/cmake-language-server`, `dev-build/cmake`, and tests that skip the three known CMake 4 failures. Policy is GitHub `regen100/cmake-language-server`, tag prefix `v`, empty arch allowlist. The first automated bump target is `0.1.11` (slot 3.13).
- README names the `Pdm` ecosystem and states that full-path packing uses the image. Host `pdm` is not an operator tool for that packing; the ebuild `BDEPEND` on `dev-python/pdm` is what installs it when the package is emerged.

## Non-goals

- Generating a `uv.lock`, re-resolving pins, or regenerating `pdm.lock`.
- Packing the `lint` group, or selecting groups with `-d`.
- A `dev-python/cmakelang` ebuild, a `::guru` `pygls` dependency, or a patch to the CMake help scraper.
- A host `pdm` or host Python 3.12 install as a prerequisite of `outdated`.
- Poetry-era tags (`0.1.6` and older) as seed candidates.
- Changing the Uv frozen-sync probe or its missing-interpreter hard-fail.
- CLI version pins. Package targets stay `category/package` or an unambiguous bare name. PV selection stays with the runtime lanes.

## Capabilities

### New Capabilities

- `pdm-deps-assets`: PDM lock intake, parse-only slot probe, wheel-or-sdist packing, and the offline `pdm sync` install the ebuild rewrite must preserve.
- `dev-util-cmake-language-server-seed`: Seed identity, source archive tag spelling, deps asset, venv install, `format` USE flag, CMake dependency, and the deselected CMake 4 tests.

### Modified Capabilities

- `deps-assets`: Ecosystem `Pdm` is a `DepsAndAssets` value, publishes assets, and uses `{pn}-{pv}-deps.tar.xz`.
- `runtime-lanes`: `Pdm` uses the Python slot ceilings and the same plain/tilde selection as `Uv`. The recorded slot comes from the specifier and the Gentoo slot inventory. The frozen-sync probe and the missing-interpreter hard-fail stay `Uv`-only.
- `ensure-materialize-image`: A full-path `Pdm` unit emerges the chosen Python slot and `dev-python/pdm` from Portage. Rust and uv are not required for that unit.
- `hermetic-asset-materialize`: Full-path `Pdm` packing runs image `pdm` and does not download CPython or use a host `pdm`.
- `update-apply`: `Pdm` is a first-class apply ecosystem, and `dev-util/cmake-language-server` has a policy entry.
- `update-source`: `dev-util/cmake-language-server` maps to GitHub `regen100/cmake-language-server` with tag prefix `v`.
- `overlay-apply-waves`: `Pdm` ceilings come from gentoo `dev-lang/python` and create no overlay wait-edge.
- `project-docs`: README names the `Pdm` ecosystem and the image-backed pack path.

## Impact

- Manager: `EcosystemSpec`, policy map, Python lane planning, materialize recipe and floors, packer, ebuild rewrite, progress labels, and tests.
- Image: `dev-python/pdm` and whichever `dev-lang/python` slot the planned PV needs, including 3.12 for the seed.
- Overlay and assets: `dev-util/cmake-language-server` ebuild, `metadata.xml`, Manifest, and the `0.1.10` deps release. `update` later publishes `0.1.11`.
- Operator: emerging the package installs `dev-python/pdm` through the ebuild `BDEPEND`. `outdated` stays read-only. `update` still needs a TTY to sign.
