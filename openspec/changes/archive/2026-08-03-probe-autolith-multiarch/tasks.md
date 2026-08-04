## 1. Host readiness

- [x] 1.1 Confirm host checklist in `~/mndz-overlay-manager-docker-setup.md` (container engine, qemu binfmt, disk)
  - Docker 29.1.3 OK; binfmt enabled with qemu-riscv64 + qemu-ppc64le; Docker root `/var/lib/docker` on 80G LV (~79.5G free); host DISTDIR `/var/cache/distfiles` ~42G free.
- [x] 1.2 Verify `uname -m` under `--platform linux/riscv64` and `linux/ppc64le` for chosen stage3 tags
  - Pin: `gentoo/stage3:latest` → `riscv64` and `ppc64le` both OK. Portage: `gentoo/portage:latest`.
- [x] 1.3 Confirm seed package + deps asset are published and mndz-overlay path is bind-mountable
  - Overlay: `/home/mndz/repos/com.github/0x6d6e647a/mndz-overlay` (seed was `autolith-0.17.2.ebuild`; post-probe live is `autolith-0.17.2-r1.ebuild`).
  - DISTDIR has matching `autolith-0.17.2.tar.gz` + `autolith-0.17.2-deps.tar.xz` (SHA512 OK vs Manifest).

## 2. riscv64 full probe

Policy: run arches **strictly sequential** (riscv64, then ppc64le). Do not start §3 until §2 is green or waived. Reclaim per-arch containers/build volumes between legs; shared DISTDIR + portage tree + overlay bind-mount may persist (see design §5).

- [x] 2.1 Start gentoo stage3 + portage volume + mndz overlay for `linux/riscv64`
  - Container `autolith-probe-riscv64` on `gentoo/stage3:latest` (`default/linux/riscv/23.0/rv64/lp64d`); portage volume `autolith-probe-portage`; overlay + DISTDIR mounted. Runner: `run-probe.sh`. Logs: `logs/riscv64.log`.
- [x] 2.2 Emerge `=dev-util/autolith-0.17.2` (or live `-rN`) with required deps
  - **FAILED** (2026-08-03 ~20:52 local). Full dep graph + natives + **recovery core** succeeded; **active core** failed.
  - Root cause: SBCL on riscv has stub `alien-callback-assembler-wrapper` → `(error "please implement")` in `src/compiler/riscv/c-call.lisp`. Loading `cl+ssl` (via ASDF for active image) needs alien callbacks.
  - Not fixable in overlay packaging without implementing SBCL riscv callbacks (upstream gap).
- [x] 2.3 Run `autolith --version` successfully
  - **N/A** — package did not install; smoke not reachable.
- [x] 2.4 On failure: fix overlay/assets, revbump if needed, re-run until green or document waiver
  - **Remediation:** revbump to `autolith-0.17.2-r1`, drop `~riscv` from KEYWORDS (honest KEYWORDS). Residual risk: Autolith not keyworded for riscv until SBCL implements riscv alien callbacks.
  - Container reclaimed. ppc64le proceeds on `-r1` (ppc64 has real alien-callback implementation).

## 3. ppc64le full probe

- [x] 3.1 Start gentoo stage3 + portage volume + mndz overlay for `linux/ppc64le`
  - Container `autolith-probe-ppc64le` (`default/linux/ppc64le/23.0`); atom `=dev-util/autolith-0.17.2-r1`. Logs: `logs/ppc64le.log`.
  - Note: host sticky DISTDIR blocked Portage layout/mirror cache renames under userpriv; worked around with container-local `DISTDIR=/var/cache/distfiles-local`.
- [x] 3.2 Emerge `=dev-util/autolith-0.17.2` (or live `-rN`) with required deps
  - **FAILED under QEMU** (2026-08-03 ~21:42). `dev-lisp/sbcl-2.6.7` compile dies during host bootstrap: qemu-user memory faults (`Memory fault at (nil)`, `maximum interrupt nesting depth (1024) exceeded`, LDB). Uses ppc64le binary bootstrap (`sbcl-*-ppc64le-linux-binary`), not system-bootstrap/ECL.
  - **Interpretation:** QEMU user-mode limitation for SBCL runtime, **not** an overlay packaging defect. SBCL `ppc64` alien-callback VOPs exist (unlike riscv). Residual risk until real ppc64le hardware (or system-qemu full-system) smoke.
- [x] 3.3 Run `autolith --version` successfully
  - **N/A** — SBCL never installed under QEMU; smoke not reachable.
- [x] 3.4 On failure: fix overlay/assets, revbump if needed, re-run until green or document waiver
  - **Waiver (human/agent, residual risk):** keep `~ppc64` KEYWORDS. Do **not** drop `~ppc64` solely due to qemu-user SBCL crash. Follow-up: native ppc64le emerge + `autolith --version` when hardware is available.

## 4. Close-out

- [x] 4.1 Record results (pass/fail/waiver) for both required arches

| Arch | Result | Notes |
|------|--------|-------|
| `linux/riscv64` | **Fail → KEYWORD dropped** | SBCL alien callbacks unimplemented; active core cannot load cl+ssl. `autolith-0.17.2-r1` KEYWORDS omit `~riscv`. |
| `linux/ppc64le` | **Waiver** | QEMU user-mode cannot bootstrap SBCL; packaging not implicated. Residual risk on real hardware until proven. |

- [x] 4.2 Ensure KEYWORDS still honest relative to what actually works
  - Live ebuild: `dev-util/autolith-0.17.2-r1` with `KEYWORDS="~amd64 ~ppc ~ppc64 ~x86"` (no `~riscv`). Comment in ebuild documents the SBCL riscv gap.
- [x] 4.3 Mark change complete only when both arches pass or waivers are explicit
  - Complete: riscv remediated (honest KEYWORDS); ppc64le waived with residual risk explicit above.
