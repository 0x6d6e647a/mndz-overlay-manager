## 1. Config schema and fields

- [x] 1.1 In `src/Config/Types.hs`, rename TOML keys to `overlay-path` (required) and `assets-path` (optional); rename fields to `overlayPath` and `assetsPath`
- [x] 1.2 Update call sites: `app/Main.hs` (`overlayPath` / `assetsPath` accessors) and any other references to the old field names

## 2. Error messages

- [x] 2.1 Update `src/Update/Preflight.hs` messages that name `mndz-overlay-assets-path` to `assets-path`
- [x] 2.2 Update `src/Update/Apply.hs` messages that name `mndz-overlay-assets-path` to `assets-path`
- [x] 2.3 Grep for remaining user-facing old key strings in `src/` / `app/` and fix any stragglers (do not change GitHub repo / SRC_URI markers)

## 3. Tests and fixtures

- [x] 3.1 Update `test/fixtures/valid-config.toml` and `test/fixtures/full-config.toml` to use the new keys
- [x] 3.2 Update `test/Main.hs` field accessors and missing-key assertion that expects `mndz-overlay-path` to expect `overlay-path`
- [x] 3.3 Add or adjust a decode failure case so a config with only legacy `mndz-overlay-path` fails (hard cut)

## 4. Quality gate

- [x] 4.1 Run `hk fix` / format as needed, then `hk check` until green
