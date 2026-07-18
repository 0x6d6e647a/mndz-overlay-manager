## Context

TOML config today decodes two path keys with a `mndz-` prefix:

```toml
mndz-overlay-path = "…"          # required
mndz-overlay-assets-path = "…"   # optional
github-token = "…"               # optional (already unprefixed)
```

`Config.Types` maps those to `mndzOverlayPath` / `mndzOverlayAssetsPath`. The CLI already exposes `--overlay-path`. User-facing preflight/apply errors quote the old assets key name. Specs under `overlay-path-resolution`, `update-command`, and `github-auth` name the old keys.

This is a schema string rename plus internal field cleanup—no new behavior, no new dependencies.

## Goals / Non-Goals

**Goals:**

- TOML keys become `overlay-path` (required) and `assets-path` (optional).
- Hard cut: only the new keys decode successfully.
- Record fields become `overlayPath` / `assetsPath`; all call sites updated.
- Error messages and tests name the new keys so operators see what the file expects.
- Live specs match the new wire names.

**Non-Goals:**

- Dual-key / migration compatibility for old names.
- Renaming `github-token`, CLI flags, GitHub repository `mndz-overlay-assets`, or SRC_URI path markers.
- Changing XDG config file path or default layout.
- Auto-rewriting operator config files.

## Decisions

### 1. Hard cut on TOML keys (no dual-key support)

**Choice:** Decode only `overlay-path` and `assets-path`. Presence of only the old keys fails the same way as a missing required key.

**Rationale:** Single-operator tool; one config file. Dual-key support adds permanent complexity for a one-time rename.

**Alternatives considered:** Accept both keys with a deprecation warning; prefer new when both set. Rejected as unnecessary for this project’s scale.

### 2. Rename Haskell fields with the wire keys

**Choice:** `mndzOverlayPath` → `overlayPath`, `mndzOverlayAssetsPath` → `assetsPath`.

**Rationale:** Matches `githubToken` (no brand prefix on the field). Avoids long-lived mismatch between TOML and internal names.

**Alternatives considered:** Wire-only rename, keep old field names. Smaller diff, but leaves redundant branding in the type.

### 3. Error strings track the schema

**Choice:** Preflight/apply (and any decode-related) messages that currently say `mndz-overlay-assets-path` / `mndz-overlay-path` use `assets-path` / `overlay-path` instead.

**Rationale:** Operators edit the TOML; messages must name keys that exist.

### 4. Spec deltas only on live capabilities

**Choice:** Delta specs for `overlay-path-resolution`, `update-command`, and `github-auth`. Do not rewrite archived change artifacts.

**Rationale:** Archives are historical; main specs are the contract after apply/archive.

## Risks / Trade-offs

- **[Risk] Existing operator config breaks on first run after upgrade** → Mitigation: hard-cut is intentional; document the two renames in CHANGELOG / commit message; failure messages name the new required key so the fix is obvious.
- **[Risk] Incomplete field rename leaves compile errors** → Mitigation: rename at the type definition, fix call sites via compiler; run full `hk check`.
- **[Risk] Specs still reference old names after archive** → Mitigation: MODIFIED requirements include full updated text for every requirement that quotes the old keys.

## Migration Plan

1. Implement decode + field + error + fixture + test updates.
2. Update live specs via this change’s deltas (synced on archive).
3. Operator action: edit config file keys once before next non-help run.

Rollback: revert the change; operators who already renamed keys would need to put old keys back (same one-line edit).

## Open Questions

None—decisions settled during explore:

1. Hard cut: yes.
2. Rename internal fields: yes.
3. Update error messages: yes.
4. Other branded renames: no.
