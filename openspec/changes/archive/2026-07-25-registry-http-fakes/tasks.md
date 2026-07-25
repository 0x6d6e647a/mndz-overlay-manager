## 1. GitHub HttpLbs duals

- [x] 1.1 Add HttpLbs-style duals for GitHub fetch/list production paths; wire thin Manager wrappers
- [x] 1.2 Unit: fetch success via latest release; fallback to max tag; non-GitHub source error; HTTP/decode errors
- [x] 1.3 Unit: list versions single-page success + error matrix
- [x] 1.4 Unit: list versions multi-page pagination (full page then short page per product rules)
- [x] 1.5 Unit: auth header present/absent for token cases as product implements

## 2. npm registry HTTP only

- [x] 2.1 Add HttpLbs duals for `listNpmVersions` / `fetchNpmEnginesNode` (and parsers as needed)
- [x] 2.2 Unit: registry list success + error; engines fetch success + error
- [x] 2.3 Explicitly do not scope pack/install/tar process bodies in this change

## 3. go.mod HTTP

- [x] 3.1 Add HttpLbs dual for fetch-at-tag / httpGetText production path
- [x] 3.2 Unit: success body, HTTP error, network/decode error; token header edge if applicable

## 4. Quality gate

- [x] 4.1 `./scripts/coverage` green (floor-free)
- [x] 4.2 `hk check` green
- [x] 4.3 Confirm no live network in new tests
