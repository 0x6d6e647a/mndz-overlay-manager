## ADDED Requirements

### Requirement: README documents GitHub fetch auth, health, and rate-limit fail

Operator-facing `README.md` SHALL document, at operator depth:

1. That `outdated` and `update` use a GitHub token for live `api.github.com` version fetch when a token is available (`GITHUB_TOKEN`, then `GH_TOKEN`, then decrypted config `github-token`).
2. That an encrypted config envelope causes a wrap-password prompt when this run will call `api.github.com`, and that unattended `outdated` / `update` MUST set `GITHUB_TOKEN` or `GH_TOKEN` rather than relying on TTY decrypt.
3. That live unauthenticated GitHub fetch is allowed when no token is configured, is limited to 60 requests per hour per IP, and logs a warning.
4. That GitHub health (Statuspage API Requests, Git Operations before assets push, and `/rate_limit`) runs before live GitHub work, and that remaining `0`, HTTP 401, or API outage hard-fails the command with exit `1`.
5. That `gencache` does not use this GitHub health gate.

#### Scenario: README names unattended env token for outdated

- **WHEN** an operator reads how to run `outdated` without a controlling TTY
- **THEN** README states that `GITHUB_TOKEN` or `GH_TOKEN` must be set when a config envelope would otherwise need decrypt for live GitHub fetch

#### Scenario: README names rate-limit hard-fail

- **WHEN** an operator reads GitHub token or `outdated` / `update` usage
- **THEN** README states that GitHub rate-limit exhaustion and rejected tokens exit `1` rather than only warning per package
