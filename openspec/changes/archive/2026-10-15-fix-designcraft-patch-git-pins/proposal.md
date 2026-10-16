# Proposal

## Why

`app-office/designcraft-0.8.0` dies in `src_compile` because Cargo 1.97 does not apply the `cargo.eclass` git patch to crates the workspace itself pins under `[patch.crates-io]`. The ebuild already fetches those checkouts, then Cargo tries to clone them again with the network turned off. Installed DesignCraft is still 0.6.0.

## What Changes

- Add `src_prepare` to `designcraft-0.8.0.ebuild` that rewrites each one-line `[patch.*]` git pin whose name and `rev` match a `GIT_CRATES` entry to that entry's unpacked directory.
- Die when a matching pin's `GIT_CRATES` entry, manifest line, or unpacked `Cargo.toml` is missing.
- Leave direct workspace git dependencies (`craft-print`, `craft-ui`) on the eclass patch.
- Keep the ebuild at `designcraft-0.8.0` (no `-r1`). The 0.8.0 commit is local only, and 0.8.0 is not installed.

## Capabilities

### New Capabilities

### Modified Capabilities

- `storytold-craft-apps`: DesignCraft's ebuild rewrites `[patch.*]` git pins from `GIT_CRATES` onto unpacked paths before compile, and fails closed when a pin cannot be rewritten.

## Impact

- Overlay file `app-office/designcraft/designcraft-0.8.0.ebuild`.
- The next `emerge =app-office/designcraft-0.8.0` is the compile check. The operator runs emerge.
- Manager Haskell, `pycargoebuild`, `cargo.eclass`, and README / CONTRIBUTING / AGENTS stay unchanged. `pycargoebuild` keeps phase functions, so a later DesignCraft bump carries this `src_prepare` forward.

## Non-goals

- Teaching the manager to emit this rewrite for every Cargo package.
- Rewriting `craft-print` or `craft-ui`, or hardcoding crate names or commit ids.
- A `-r1` revision.
- The deferred DesignCraft 0.6.0 Arabic `src_test` failure. This emerge is default USE, without `test`.
- Other craft apps. Their `GIT_CRATES` entries are direct git dependencies, which the eclass patch already satisfies.
