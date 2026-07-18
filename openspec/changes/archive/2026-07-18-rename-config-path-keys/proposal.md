## Why

TOML config keys still carry a redundant `mndz-` brand prefix (`mndz-overlay-path`, `mndz-overlay-assets-path`) while the CLI flag is already `--overlay-path` and `github-token` never used the prefix. Shortening the keys makes the schema consistent and easier to type without changing product behavior.

## What Changes

- **BREAKING**: Rename required TOML key `mndz-overlay-path` → `overlay-path`.
- **BREAKING**: Rename optional TOML key `mndz-overlay-assets-path` → `assets-path`.
- Hard cut: old key names are not accepted; no dual-key compatibility layer.
- Rename internal Haskell record fields `mndzOverlayPath` / `mndzOverlayAssetsPath` → `overlayPath` / `assetsPath`.
- Update user-facing error messages so they name the new keys.
- Leave `github-token`, CLI flags, GitHub repo names, and SRC_URI path markers unchanged.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `overlay-path-resolution`: Config decode keys and scenarios that name `mndz-overlay-path` / `mndz-overlay-assets-path` become `overlay-path` / `assets-path`.
- `update-command`: Preflight requirements and scenarios that refer to `mndz-overlay-assets-path` use `assets-path`.
- `github-auth`: Scenarios that mention the required overlay path key use `overlay-path`.

## Impact

- `src/Config/Types.hs` and all call sites of the renamed record fields.
- Error strings in preflight / apply that quote the assets config key.
- Test fixtures (`valid-config.toml`, `full-config.toml`) and config-related tests.
- Live OpenSpec requirements under the modified capabilities above.
- Operator config files (`~/.config/mndz/overlay-manager.toml` or equivalent) must be updated manually after upgrade.
