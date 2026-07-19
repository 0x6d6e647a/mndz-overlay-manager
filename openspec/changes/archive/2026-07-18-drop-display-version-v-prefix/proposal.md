## Why

CLI and log output still pretty-print package versions with a leading `v` (`v1.2.3`), while ebuild PVs, commit messages, assets release tags, and Gentoo-style atoms already use bare numbers (`1.2.3`). That split is confusing and inconsistent with the rest of this tool and with official Gentoo ebuilds. Dropping the display-only prefix aligns human-facing strings with stored PV form.

## What Changes

- **BREAKING** (operator-facing only): `outdated` / `update` stdout lines and related version strings in logs no longer prefix versions with `v`. Example: `dev-db/dolt 2.1.6 -> 2.1.10` instead of `dev-db/dolt v2.1.6 -> v2.1.10`.
- Pretty-render (`prettyVersion`) becomes bare PV form (same as `renderPV`), including optional `-rN`.
- Specs and unit tests that pin display format are updated accordingly.
- No change to GitHub tag prefixes (`ghTagPrefix`), ebuild filenames, overlay/assets commit messages, or assets release naming.
- No changes required in `mndz-overlay` or `mndz-overlay-assets`.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `ebuild-version`: Display/pretty-render no longer adds a leading `v`; output is PV form with optional revision.
- `outdated-command`: Stdout and related version examples use bare PV (`1.2.3`, not `v1.2.3`).
- `update-command`: Success and lane stdout examples use bare PV.

## Impact

- **Code**: `Overlay.Version.prettyVersion`; call sites in `app/Main.hs` and `Update.Apply` keep working if the helper is redefined (optional cleanup to call `renderPV` directly).
- **Tests**: `testVersionRender` expected strings.
- **Specs**: Active main specs listed above (delta under this change); archived OpenSpec history left as-is.
- **Not affected**: `Update.Hardcoded` tag prefixes, `versionTag` / strip-on-parse, assets layout, sibling repos.
- **Operators**: Scripts that parse CLI stdout for `vN.N.N` must accept bare versions (or both).
