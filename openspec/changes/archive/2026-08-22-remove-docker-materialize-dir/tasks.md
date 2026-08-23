## 1. Remove in-repo materialize docker tree

- [x] 1.1 Delete `docker/materialize/` (and empty `docker/` parent if nothing else remains)
- [x] 1.2 Drop `extra-source-files` from `mndz-overlay-manager.cabal` if it only named that pointer file
- [x] 1.3 `README.md`: keep auto-ensure / sidecar / override as the operator home; state there is no in-repo Dockerfile to `docker build` (`project-docs`)

## 2. Quality gate

- [x] 2.1 Keep tests that assert operator copy does not mention `docker/materialize/Dockerfile`; do not add a live `docker build`
- [x] 2.2 `openspec validate remove-docker-materialize-dir --strict` clean
- [x] 2.3 `hk check` green
