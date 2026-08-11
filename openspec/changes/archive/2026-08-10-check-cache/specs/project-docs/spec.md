## ADDED Requirements

### Requirement: README documents check cache config and refresh

Operator documentation in `README.md` SHALL document the optional `check-cache-ttl` config key (human duration, default five minutes, zero disables), the default XDG location pattern for check-cache files under `…/mndz/overlay-manager/check-cache/`, and the `--refresh` flag on both `outdated` and `update` for forcing live check or plan work. Examples SHALL use the real key and flag names.

#### Scenario: README names check-cache-ttl

- **WHEN** an operator reads configuration documentation in `README.md`
- **THEN** `check-cache-ttl` is documented with default and disable-via-zero behavior

#### Scenario: README names refresh on both commands

- **WHEN** an operator reads `outdated` and `update` usage in `README.md`
- **THEN** both commands document `--refresh`
