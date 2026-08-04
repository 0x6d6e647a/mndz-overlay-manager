## Context

`seed-dev-util-autolith` produces `dev-util/autolith-0.17.2` with KEYWORDS  
`~amd64 ~ppc ~ppc64 ~riscv ~x86`. Seed smoke is human emerge on the host (typically amd64). Non-amd64 risk is concentrated in cargo/fff, C natives, bubblewrap, SBCL cores, and qemu-slow full dependency graphs.

Official images: `gentoo/stage3` + `gentoo/portage` ([gentoo-docker-images](https://github.com/gentoo/gentoo-docker-images)). Host prep: `~/mndz-overlay-manager-docker-setup.md`.

Gentoo `dev-lisp/sbcl` is keyworded for riscv and ppc64 (among others) but **not** arm/arm64, despite upstream SBCL shipping arm bootstrap binaries—keywording gap, not “SBCL has no ARM.”

## Goals / Non-Goals

**Goals:**

- Prove full emerge + `autolith --version` on **riscv64** and **ppc64le** under QEMU.
- Land only necessary ebuild/deps fixes in mndz-overlay (and assets if required).
- Document runbook outcomes so support phase starts on a known base.

**Non-Goals:**

- Manager code.
- Arm64 as a required probe (optional canary only with force-keyword sbcl).
- Productizing multiarch CI in the manager binary.

## Decisions

### 1. Required arches

| Platform | Gentoo keyword | Required |
|----------|----------------|----------|
| `linux/riscv64` | `~riscv` | **Yes** |
| `linux/ppc64le` | `~ppc64` | **Yes** |
| `linux/arm64` | (SBCL unkeyworded) | No (optional canary) |
| `linux/amd64` | `~amd64` | Already covered by seed smoke |

### 2. Container recipe

1. Docker or Podman with qemu-user binfmt for the platform.
2. `gentoo/stage3` matching platform (prefer glibc openrc variants).
3. `gentoo/portage` volume → `/var/db/repos/gentoo`.
4. Bind-mount mndz-overlay → e.g. `/var/db/repos/mndz`; enable in `repos.conf`.
5. Accept testing keywords as needed for sbcl ≥ 2.6.4 and autolith.
6. Network allowed for Gentoo distfiles; Autolith deps come from published deps tarball.
7. `emerge -av1 =dev-util/autolith-0.17.2` (or live `-rN`).
8. `autolith --version`.

### 3. Remediation policy

- Prefer fixing packaging (paths, cargo offline, KEYWORDS honesty, deps layout).
- Content-only ebuild edits → `-rN` (never silent overwrite without revbump).
- If an arch is fundamentally unsupportable, drop that KEYWORD from the ebuild and document waiver—do not leave a lying KEYWORDS line.

### 4. Time and resources

- Expect multi-hour runs per arch under QEMU.
- Agent may background long emerges; human monitors disk and failures.

### 5. Sequential arches (policy)

Required arches run **strictly sequential** — never co-schedule full emerges for riscv64 and ppc64le.

| Order | Platform | Gate |
|-------|----------|------|
| 1st | `linux/riscv64` | Complete (green or waived) before starting ppc64le |
| 2nd | `linux/ppc64le` | Starts only after riscv64 leg is closed |

**Rationale:** save disk and compute under QEMU (one stage3 root + one Portage build graph peak at a time; no interleaved failure attribution). Total wall-clock is the sum of both legs; that trade-off is accepted.

**Between arches:** reclaim per-arch containers and build volumes after the first leg. Safe to retain across legs: shared DISTDIR (prefer Docker storage LV), `gentoo/portage` tree volume, and the mndz-overlay bind-mount (so any `-rN` from riscv carries into ppc64le). Do not keep two half-emerged stage3 roots.

**Re-runs:** after a packaging fix, re-probe the arch currently under test; re-run an earlier arch only if the fix could regress it and that arch was already green.

### 6. Success / waiver

- **Success:** both required arches emerge + `--version` green.
- **Waiver:** human explicitly accepts residual risk on one arch (document in tasks notes); support may still proceed.

## Risks / Trade-offs

- **[Risk]** QEMU too slow / OOM → **Mitigation:** large disk; optional binhost; **sequential arches** (decision §5) with reclaim between legs.
- **[Risk]** stage3 tag lacks riscv/ppc64le digest → **Mitigation:** pin tags from Hub inventory (`stage3-rv64_*`, `stage3-ppc64le-*`).
- **[Risk]** SBCL bootstrap on riscv forces `system-bootstrap` → **Mitigation:** profile already forces it; ensure clisp/ecl/sbcl bootstrap available or binary path works.
- **[Risk]** Probe finds design-level seed flaws → **Mitigation:** fix before support; re-seed asset if deps layout wrong.

## Migration Plan

1. Confirm host checklist in `~/mndz-overlay-manager-docker-setup.md`.
2. Run riscv64 full probe; fix; re-run if needed.
3. Run ppc64le full probe; fix; re-run if needed.
4. Record results; archive change when gates pass or waived.
5. Start `support-dev-util-autolith`.

## Open Questions

- Exact stage3 tags to pin (refresh from Docker Hub at implement time).
- Whether to keep optional arm64 canary after riscv/ppc64le—default **no**.
