## Context

See `proposal.md` for motivation. `renderMaterializeDockerfile` emits a cache-mounted `emerge` of resolved `dev-lisp/sbcl`, then a separate `RUN` that `wget`s `quicklisp.lisp` and invokes `sbcl --non-interactive --no-userinit --no-sysinit`. `RecipeArch` has `raKeywords` and `raHubTag` only. `materializeGeneratorId` is `mndz-overlay-manager-materialize-3`. `wrapMaterializeRequest` forces `HOME` / XDG, drops secrets and `PATH` (image `PATH` wins), and otherwise forwards `prEnv` — including host `SBCL_HOME` when `qlotInstall` passes `getEnvironment`. Base layer already emerges `net-misc/aria2` and `net-misc/wget`.

Gentoo `dev-lisp/sbcl` writes `/etc/env.d/50sbcl` (`SBCL_HOME=/usr/$(get_libdir)/sbcl`). Docker `RUN` and `docker run` exec form do not source `/etc/profile`. Host reproduction: `env -i PATH=/usr/bin:/bin sbcl …` → `Can't find sbcl.core`; the same command with `SBCL_HOME=/usr/lib64/sbcl` starts.

## Goals / Non-Goals

**Goals:**

- Image `ENV` so `sbcl` finds its core in both the Quicklisp `RUN` and later `docker run`.
- Libdir from the existing KEYWORDS token (`lib64` vs `lib`).
- Quicklisp installer via `aria2c`; generator `…-4`; host `SBCL_*` not forwarded.
- Pure recipe / docker-wrap tests; no live `docker build` in `hk check`.

**Non-Goals:**

- `USER builder`, login `SHELL`, `USE=source` on image SBCL.
- Overlay qlot/Quicklisp ebuild (wiki `quicklisp-ebuild-handoff.md`).
- Dropping base-layer `wget`; changing floors, atoms, bun-bin bind, prune, or override inspect-only.

## Decisions

### D1: `ENV` between emerge and Quicklisp, libdir from `raKeywords`

The two SBCL steps are already separate `RUN`s. Insert:

```
ENV SBCL_HOME=/usr/<libdir>/sbcl
ENV SBCL_SOURCE_ROOT=/usr/<libdir>/sbcl/src
```

after the emerge `RUN` and before the Quicklisp `RUN`. Helper from `raKeywords` (do not widen `RecipeArch` unless tests need it):

| KEYWORDS | libdir |
|----------|--------|
| `amd64`, `arm64`, `ppc64`, `riscv`, `s390` | `lib64` |
| `x86`, `arm` | `lib` |

`ENV` persists into subsequent layers and `docker run` image config.

- *Alternative — `SHELL ["bash","-lc"]`:* Only affects build `RUN`; `docker run image sbcl` still misses `SBCL_HOME`. Profile.d is a shotgun.
- *Alternative — source `/etc/env.d/50sbcl` only in the Quicklisp `RUN`:* Build passes; `docker run` still fails unless host `SBCL_HOME` leaks.
- *Alternative — `/usr/local/bin/sbcl` wrapper:* Works but extra PATH machinery; `ENV` is the Docker contract.

### D2: Drop host `SBCL_HOME` / `SBCL_SOURCE_ROOT` like `PATH`

Add both names to `forcedEnvKeys` **without** putting them on the `forced` `--env` list. Image `ENV` applies. `qlotInstall` may still put them in `prEnv`; the wrap drops them.

- *Alternative — set `--env SBCL_HOME=/usr/lib64/sbcl` in wrap:* Duplicates libdir in two modules; image `ENV` is enough if not overridden.
- *Alternative — keep forwarding host `SBCL_HOME`:* Works on this Gentoo amd64 box; wrong prefix or missing host SBCL breaks Autolith.

### D3: Quicklisp `wget` → `aria2c`

Replace the installer fetch only:

```
aria2c --dir=/tmp --out=quicklisp.lisp --allow-overwrite=true <url>
```

Keep `emerge … net-misc/wget` in `baseCmds`. `--allow-overwrite` so a retried layer is dumb.

- *Alternative — drop wget from the image:* Rejected; cargo fetcher contract is wget **or** aria2c.

### D4: Generator `mndz-overlay-manager-materialize-4`

Existing skip requires matching generator. Bump so `:local` sidecars rebuild even when floors would satisfy.

### D5: Tests stay fake-docker

`Test.Ensure` SBCL render: `ENV SBCL_HOME=/usr/lib64/sbcl` and `SOURCE_ROOT` on `x86_64`; `/usr/lib/sbcl` on `i686` (or `armv7l`); `aria2c` present and the Quicklisp URL not fetched with `wget`; base layer still names `net-misc/wget`. `Test.Ecosystems` docker wrap: incoming `SBCL_HOME` is not on argv. No Hub/`emerge`/`sbcl` in `hk check`.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Official stage3 uses a different libdir than the table | Table matches glibc OpenRC `get_libdir` for mapped tags; unmapped arches already hard-fail generate |
| First `update` after this change rebuilds a long image | Intended generator miss; GitMv/reuse still overlap ensure |
| Quicklisp/qlot fails after the core loads (`--no-sysinit` / ASDF / writes) | New error, not `sbcl.core`; keep `--no-userinit --no-sysinit` |
| Host without aria2c | Image provides it; host advisory already suppressed for full-path |

## Migration Plan

1. Land recipe `ENV` + aria2c fetch + wrap drop + generator `…-4` + tests.
2. Operator `update` with any full-path unit rebuilds `:local` once.
3. Rollback: revert the change; old generator sidecars remain valid only if someone re-tags an old image (default path will miss generator and rebuild anyway until revert).

## Open Questions

None.
