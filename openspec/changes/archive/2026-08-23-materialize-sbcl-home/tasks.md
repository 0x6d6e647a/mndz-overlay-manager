## 1. Recipe ENV and Quicklisp fetch

- [x] 1.1 Add a libdir helper from `raKeywords` (`lib64` vs `lib` per design D1) and emit `ENV SBCL_HOME` / `ENV SBCL_SOURCE_ROOT` after the sbcl emerge `RUN` and before the Quicklisp `RUN`
- [x] 1.2 Replace the Quicklisp installer `wget` with `aria2c --dir=/tmp --out=quicklisp.lisp --allow-overwrite=true`; keep `net-misc/wget` in the base emerge
- [x] 1.3 Tests: `x86_64` SBCL recipe has `ENV SBCL_HOME=/usr/lib64/sbcl` and `ENV SBCL_SOURCE_ROOT=/usr/lib64/sbcl/src` before `sbcl`; `i686` (or `armv7l`) uses `/usr/lib/sbcl`; bun-only recipe omits `SBCL_HOME`; installer URL uses `aria2c` not `wget`; base layer still emerges `net-misc/wget`

## 2. docker run env and generator

- [x] 2.1 Drop host `SBCL_HOME` and `SBCL_SOURCE_ROOT` in `wrapMaterializeRequest` the same way as `PATH` (do not `--env` them)
- [x] 2.2 Bump `materializeGeneratorId` to `mndz-overlay-manager-materialize-4`
- [x] 2.3 Tests: docker wrap with incoming `SBCL_HOME` / `SBCL_SOURCE_ROOT` does not forward them; generator mismatch still rebuilds (existing skip tests with updated id)

## 3. Quality gate

- [x] 3.1 `openspec validate --change materialize-sbcl-home --strict`
- [x] 3.2 `hk check` green; no weeder/stan weakening; no `exposed-modules` expansion
