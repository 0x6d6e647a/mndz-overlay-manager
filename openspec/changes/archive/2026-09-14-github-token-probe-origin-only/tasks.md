## 1. Origin-only probe

- [x] 1.1 Remove extra-repo listing and extra `POST /releases` from `probeFineGrainedPat` (`listOwnedRepos` / `OwnedRepo` / `refuseExtraContentsWrite`); GET origin then empty-POST origin only; verify fake-HTTP success when `/user/repos` or extra `/releases` would 500 or 422
- [x] 1.2 Keep classic `ghp_` refusal, origin GET 404, and origin empty POST 403; remove extra-write 422-fail / extra 403-success cases

## 2. Docs and quality gate

- [x] 2.1 Update `README.md` so PAT instructions state GitHub’s always-on public-repository read does not fail `github-token`, and that Only-select plus Contents: write on the assets origin is operator guidance rather than an extra-repository API check; verify the `project-docs` scenarios
- [x] 2.2 `openspec validate github-token-probe-origin-only --strict` and `hk check`; fix format/lint/weeder without new unused exports or blanket weeder roots
