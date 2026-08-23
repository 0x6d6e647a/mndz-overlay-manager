## Context

See `proposal.md` for motivation. `renderMaterializeDockerfile` emits `FROM gentoo/stage3:` plus `unRecipeArch`. `hostRecipeArch` maps `x86_64`/`amd64` → `amd64`, `aarch64`/`arm64` → `arm64`, else the raw `uname -m` string. That single token is also `~arch` in bun-bin `package.accept_keywords`. `ensureMaterializeImage` skips `docker build` when sidecar floors satisfy and the recorded id still exists; it does not compare generator identity. Override (`ecOverrideTag`) is inspect-only and never calls the renderer. `Main` always loads `hostRecipeArch` into `EnsureConfig` before ensure.

Hub: `gentoo/stage3:amd64` last pushed 2021-08-20; current default is `amd64-openrc` (same digest as `latest`’s amd64 slice). `latest`’s s390x slice has been stale.

## Goals / Non-Goals

**Goals:**

- One closed `uname -m` → (KEYWORDS token, OpenRC Hub tag) map used by the recipe.
- Unmapped generate path hard-fails before `docker build`; override path still inspect-only.
- Generator id `mndz-overlay-manager-materialize-2`; mismatch is a miss.
- Pure tests cover `FROM` / keywords split and unmapped miss; no live Gentoo `docker build` in `hk check`.

**Non-Goals:**

- Host-path materialize (`host-materialize-fallback`).
- Changing ensure timing, bun-bin bind-mount, floors union, prune, or override rmi rules.
- Dated Hub tag pins; `docker build --platform`.
- Expanding `exposed-modules` or weeder `root-modules`.

## Decisions

### D1: Host map type, not a second use of KEYWORDS as Hub tag

Replace the single `RecipeArch` string used for both `FROM` and `~arch` with a small record (or two fields): keywords token + stage3 Hub tag. `renderMaterializeDockerfile` takes that record. `FROM gentoo/stage3:` uses only the Hub tag.

- *Alternative — `FROM gentoo/stage3:latest`:* Rejected; fat manifest, stale s390x slice, does not pin glibc OpenRC.
- *Alternative — `<arch>-openrc` string concat from KEYWORDS:* Fails for `ppc64le` (keywords `ppc64`), `riscv64` (`rv64_lp64d-openrc`), `s390x`, `i686`, ARM microarch tags.

### D2: Closed table from `uname -m`

| `uname -m` | KEYWORDS | Hub tag |
|------------|----------|---------|
| `x86_64` | `amd64` | `amd64-openrc` |
| `aarch64` | `arm64` | `arm64-openrc` |
| `ppc64le` | `ppc64` | `ppc64le-openrc` |
| `riscv64` | `riscv` | `rv64_lp64d-openrc` |
| `s390x` | `s390` | `s390x-openrc` |
| `i686`, `i386` | `x86` | `i686-openrc` |
| `armv7l` | `arm` | `armv7a_hardfp-openrc` |
| `armv6l` | `arm` | `armv6j_hardfp-openrc` |

Keep mapping `amd64`/`arm64` uname aliases if they appear. Unknown `uname` is a miss (no `other -> T.pack other`).

- *Alternative — hard-fail 32-bit ARM:* Rejected; Hub has those tags; include them.
- *Alternative — `ppc64` BE → `ppc64le-openrc`:* Rejected; wrong endianness; unmapped.

### D3: Unmapped miss only on the generate path

`inspectOnly` (override) does not need a Hub tag. Failing in `Main` at `hostRecipeArch` would break a usable `MNDZ_MATERIALIZE_IMAGE` on sparc/loong. Resolve the map when `ensureDefault` is about to render/build. Override + unmapped → inspect-only as today. Default tag + unmapped → `Left` naming `uname`, no `docker build`.

Error text: names the machine arch and that there is no official `gentoo/stage3` OpenRC flavor; does **not** mention host-path fallback.

### D4: Generator `mndz-overlay-manager-materialize-2` is part of satisfy

In `ensureDefault`, skip build only when id matches **and** floors satisfy **and** `isGenerator == materializeGeneratorId`. Bump the constant. Existing sidecars with `-1` rebuild once.

- *Alternative — floors-only skip:* Rejected; a future recipe change would keep a stale image.
- *Alternative — bump sidecar schema version:* Unnecessary; generator is already a sidecar field.

### D5: Tests stay fake-docker

Extend `Test.Ensure` (and recipe cases): `FROM gentoo/stage3:amd64-openrc` present, `FROM gentoo/stage3:amd64` absent; bun-bin `~amd64` still present; ppc64le split; unmapped ensure does not log `docker build`; generator mismatch runs build. No live Hub pull in `hk check`.

### D6: README in the same change

Materialize section: official OpenRC stage3 for the host arch; unsupported arch hard-fails; still no host language tools. Do not document the Hub tag catalog in full.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Gentoo renames `amd64-openrc` | Same class as any Hub tag; explicit flavor is still better than the 2021 fossil |
| First `update` after this change rebuilds a long image | Intended; generator miss; GitMv/reuse still overlap ensure |
| Operator on sparc/loong is bricked for full-path | Specified hard-fail; follow-up `host-materialize-fallback` |
| `uname -m` variants (`armv7l` vs `armv7hl`) | Closed table; unknown → hard-fail rather than a bad `FROM` |
| Override on unmapped skipped if map is resolved too early | D3: map only on generate |

## Migration Plan

- Operators with a satisfying `-1` sidecar: next full-path `update` rebuilds (`-2`).
- `MNDZ_MATERIALIZE_IMAGE` users: unchanged.
- Unsupported-arch operators: ensure error until host-path follow-up or a homemade override image.
- Rollback: revert; fossil `FROM` returns.

## Open Questions

None. Flag spelling and host-path behavior live in wiki `host-materialize-handoff.md`.
