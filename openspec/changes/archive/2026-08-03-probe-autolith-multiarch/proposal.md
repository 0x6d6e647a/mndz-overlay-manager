## Why

After `seed-dev-util-autolith` ships `dev-util/autolith` at 0.17.2 on amd64, KEYWORDS also claim `~ppc ~ppc64 ~riscv ~x86`. Full emerge under QEMU on **riscv64** and **ppc64le** finds native (fff/cargo, ColorLisp, sandbox, SBCL cores) and packaging bugs before mndz-overlay-manager learns the package and automates bumps.

## What Changes

- Run **full** Portage emerges of the seeded `dev-util/autolith` (and required Gentoo deps such as `dev-lisp/sbcl[source]`) inside official Gentoo stage3 containers under QEMU for:
  - `linux/riscv64` (`~riscv`)
  - `linux/ppc64le` (`~ppc64`)
- Host prerequisites documented in `~/mndz-overlay-manager-docker-setup.md` (docker/podman, qemu binfmt, `gentoo/stage3` + `gentoo/portage`, disk/time).
- On failure: fix **overlay ebuild/deps only** (content fixes use `-rN`); re-run probe until green or human waiver.
- Smoke per arch: emerge succeeds and `autolith --version` reports the seeded PV.
- Optional arm64 canary is **out of default scope** (Gentoo `dev-lisp/sbcl` not keyworded for arm64).

## Non-goals

- No mndz-overlay-manager SBCL ecosystem or hardcoded policy (see `support-dev-util-autolith`).
- No bump to v0.18.0.
- No new seed of Autolith from scratch (depends on completed `seed-dev-util-autolith`).
- No adding `~arm64` KEYWORDS or overlay `dev-lisp/sbcl`.
- No permanent productized `testing` CLI in the manager (MNDZ.md idea remains future work); this change is a one-off probe runbook + fixes.
- No requirement to pass full upstream `script/check` under QEMU.

## Capabilities

### New Capabilities

- `autolith-multiarch-probe`: Requirements for full-emerge multiarch validation of seeded `dev-util/autolith` on riscv64 and ppc64le, smoke criteria, and allowed remediation.

### Modified Capabilities

- (none — this change does not alter manager product requirements)

## Impact

- **mndz-overlay**: possible `-rN` ebuild/deps fixes discovered under non-amd64.
- **mndz-overlay-assets**: only if deps tarball layout must change to fix multiarch builds.
- **mndz-overlay-manager**: planning artifacts only.
- **Operator / agent host**: Docker or Podman + QEMU binfmt; long wall-clock emerges.
- **Depends on**: completed `seed-dev-util-autolith` with published assets and human amd64 smoke.
- **Downstream**: gate before `support-dev-util-autolith`.
