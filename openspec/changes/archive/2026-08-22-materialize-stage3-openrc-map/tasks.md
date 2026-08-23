## 1. Host map and Dockerfile render

- [x] 1.1 Replace the single `RecipeArch` Hub/KEYWORDS token with a closed `uname -m` map to (KEYWORDS token, OpenRC Hub tag) per design D1–D2; unknown `uname` is a miss (no `other → raw string`)
- [x] 1.2 `renderMaterializeDockerfile` uses the Hub tag in `FROM gentoo/stage3:` and the KEYWORDS token only in bun-bin `package.accept_keywords`
- [x] 1.3 Pure tests: `x86_64` recipe contains `FROM gentoo/stage3:amd64-openrc` and not `FROM gentoo/stage3:amd64`; still has `dev-lang/bun-bin::mndz ~amd64`; `ppc64le` is `FROM gentoo/stage3:ppc64le-openrc` with `~ppc64`

## 2. Ensure skip/fail paths

- [x] 2.1 Bump `materializeGeneratorId` to `mndz-overlay-manager-materialize-2`; default-tag skip requires matching generator as well as floors and image id
- [x] 2.2 Default-tag ensure with unmapped `uname` hard-fails before `docker build` and names the machine arch (no host language fallback; no fossil `FROM`)
- [x] 2.3 Override inspect-only still skips generate/build when `MNDZ_MATERIALIZE_IMAGE` is set, including on an unmapped `uname`
- [x] 2.4 Tests: generator mismatch runs `docker build` even when floors satisfy; unmapped default tag does not invoke `docker build`; override + unmapped does not invoke `docker build` and does not fail solely for the map miss

## 3. Docs and quality gate

- [x] 3.1 README materialize section: official Gentoo OpenRC stage3 for the host CPU architecture; unsupported host arch hard-fails ensure; host `go`/`npm`/`bun` still not used for that path
- [x] 3.2 `openspec validate --change materialize-stage3-openrc-map --strict`
- [x] 3.3 `hk check` green; no weeder/stan weakening; no `exposed-modules` expansion unless the test-suite requires it
