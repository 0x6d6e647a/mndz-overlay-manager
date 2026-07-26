## Context

`dev-util/opencode` is `DepsAndAssets Bun` with multi-asset publish (deps + models). Full materialize currently runs `bun install --frozen-lockfile --cache-dir …` on the manager host, then packs **only** top-level `bun-cache/` into `{pn}-{pv}-deps.tar.xz`. The ebuild unpacks that cache under `${T}` and runs `bun install` again during Portage compile under `FEATURES=network-sandbox`.

That second install fails: Bun still contacts the registry and `github:` URLs (notably `ghostty-web@github:anomalyco/ghostty-web#…`) even when cache entries exist. Offline emerge is required; permanent `RESTRICT="network-sandbox"` / FEATURES hacks are rejected.

ralph-tui remains a smaller package that historically packs `bun-cache/` only; this design **scopes install-tree packaging to opencode** unless shared helpers make dual mode trivial.

## Goals / Non-Goals

**Goals:**

- Opencode deps distfile is sufficient for **zero-network** `src_compile` under default Portage sandboxes.
- Manager full materialize still performs networkful `bun install` once on the operator host; Portage only consumes frozen assets.
- Keep release tag/basename `{pn}-{pv}-deps.tar.xz` and models multi-asset pairing.
- Overlay ebuild stops calling `bun install`; keeps `build.ts --single --skip-install` (+ models env + webui USE).

**Non-Goals:**

- Permanent sandbox disable on the ebuild.
- Changing npm/Cargo/Go packaging.
- Necessarily rewriting ralph-tui to install-tree in this change (optional shared helper only).
- Shipping Electron/desktop products or multiarch beyond current KEYWORDS.

## Decisions

### D1 — Install-tree packaging for opencode deps tarball

**Choice:** After successful `bun install` in the cloned tag tree, create `{pn}-{pv}-deps.tar.xz` whose contents are the **install tree relative to the repo root**: every `node_modules` directory (and Bun workspace link layout required to build), **not** a bare `bun-cache/` top-level only.

**Layout sketch (illustrative):**

```text
node_modules/…
packages/opencode/node_modules/…   # if present
packages/…/node_modules/…          # as produced by bun for this lockfile
```

Optional: also include Bun’s package manager metadata under the repo if required for `build.ts` (only if proven necessary). Do **not** include `.git/`.

**Alternatives:** (1) cache-only + `RESTRICT=network-sandbox` — rejected; (2) ship full clone+install as one tarball — larger and duplicates source archive; (3) filter workspaces during install — may still leave `github:` edges.

**Rationale:** Matches “approach A”; Portage never re-resolves deps.

### D2 — Package-specific packaging mode

**Choice:** Small table / branch: `dev-util/opencode` → **InstallTree**; other Bun packages (e.g. ralph-tui) → **BunCache** (existing top-level `bun-cache/`). Prefer one helper that accepts a packaging mode rather than a fourth ecosystem kind.

**Rationale:** Fixes the failing package without forcing multi-GB install trees on simple packages.

### D3 — Ebuild contract

**Choice:**

```text
src_unpack:
  unpack ${P}.tar.gz into work (source only; do not rely on default_src_unpack for deps)
  cd ${S}; unpack ${P}-deps.tar.xz   # overlays node_modules onto source tree
  # models JSON stays in DISTDIR (not unpacked)

src_compile:
  MODELS_DEV_API_JSON=${DISTDIR}/${PN}-${PV}-models.json
  OPENCODE_DISABLE_MODELS_FETCH=1
  OPENCODE_VERSION / OPENCODE_CHANNEL as today
  # NO bun install
  cd packages/opencode
  bun --bun ./script/build.ts --single --skip-install [+ --skip-embed-web-ui if -webui]

src_install:
  dobin packages/opencode/dist/.../opencode
  # Bun --compile embed is corrupted by strip → bare bun / host bun --version
  RESTRICT="strip" (package-level)
  # completion generation may open_wr ftrace trace_marker under sandbox
  addwrite /sys/kernel/debug/tracing before SHELL=… opencode completion
```

**Rationale:** Compile uses only local tree + BDEPEND bun-bin for the bundler; network-sandbox safe. Install must not strip the Bun-compiled binary (strip turns it into bare Bun reporting the host Bun version) and must allow ftrace writes when generating shell completions under `sandbox`.

### D4 — Same asset basename; content replace for current PV

**Choice:** Keep `opencode-${PV}-deps.tar.xz` and release tag `opencode-${PV}`. For already-published PVs (e.g. 1.18.5), **republish** install-tree content: delete/recreate the GitHub release (or replace assets) and rewrite overlay Manifest checksums; use `-rN` only if Portage revision is needed for operator migration.

**Rationale:** Operators should not learn a second filename; multi-asset models pairing unchanged.

### D5 — Manager materialize steps

**Choice:** For InstallTree mode:

1. Host Bun gate (unchanged).
2. Clone tag; require root `bun.lock`.
3. `bun install --frozen-lockfile` (manager host has network); cache-dir optional for speed.
4. Collect install-tree paths under clone; `tar -acf` → deps tarball.
5. Models fetch + multi-asset publish/reuse (unchanged).

Reuse path: download install-tree deps + models; no host bun install required for reuse (still may probe engines for BDEPEND rewrite).

### D6 — Tests

**Choice:** Unit/integration with fakes: InstallTree pack produces a tarball whose listing includes `node_modules` (or agreed root entries) and does **not** claim success for cache-only layout for opencode; ebuild-contract-oriented tests if present stay lightweight. Optional offline smoke remains operator-side emerge.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Install-tree tarball much larger than bun-cache | Accept for opencode; xz -T0 -9; only this package mode |
| Hardlinks / absolute paths in node_modules | Prefer packing after install with relative paths; use tar options that store relative members; avoid copying host absolute symlinks out of tree |
| Bun linker layout changes across versions | Pin via packageManager/engines probe already; smoke emerge on operator host |
| Lifecycle scripts during manager install need network/git | Full materialize already allows network; fail hard if install fails |
| Double-unpack regressions | Explicit src_unpack without default deps unpack |
| Same-PV asset replace leaves stale DISTDIR | Document wipe/refetch; Manifest SHA mismatch hard-fail already protects wrong bytes |
| Portage strip corrupts Bun `--compile` binary | `RESTRICT="strip"`; smoke `opencode --version` equals PV |
| `opencode completion` sandbox ACCESS DENIED on `trace_marker` | `addwrite /sys/kernel/debug/tracing` before completion generation |

## Migration Plan

1. Implement InstallTree packaging + tests; update delta specs.
2. Change overlay ebuild for current opencode PV(s).
3. Republish deps (and ensure models still paired) for current PV; regenerate Manifest/md5-cache; signed commits.
4. Operator: `emerge =dev-util/opencode-<PV>` with default FEATURES including network-sandbox.
5. Rollback: revert ebuild + manager; restore previous cache-based assets only if still published (prefer forward fix).

## Open Questions

None blocking. Optional later: migrate ralph-tui to InstallTree for uniformity; generalize “extra packaging mode” table.
