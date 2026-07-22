## ADDED Requirements

### Requirement: README documents gencache and md5-cache tools

When this change is implemented, `README.md` SHALL document the `gencache` work subcommand (purpose, optional package targets, `--force`, and at least one example), SHALL list `egencache` among runtime tools required for `update` and `gencache`, and SHALL briefly describe the operator bootstrap/recovery sequence: ensure `cache-formats = md5-dict` in overlay `layout.conf`, run `gencache` for initial cache, use `update` for version bumps, and use `gencache` / `gencache --force` when `update` reports missing or mismatched md5-cache.

#### Scenario: README catalogs gencache

- **WHEN** an operator reads `README.md` after this change
- **THEN** the document describes `gencache` with an example invocation
- **AND** runtime requirements mention `egencache` for `update` and `gencache`
