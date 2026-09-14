## 1. Probe extra-repo Contents: write

- [x] 1.1 Parse `/user/repos` items as `full_name` plus optional `permissions.push` in `Update.GitHubToken` and treat `push == false` as public-read (ignore); verify fake-HTTP success when extras have `push: false` and origin empty `POST /releases` is 422
- [x] 1.2 For extra names with `push == true` or omitted `permissions`/`push`, empty-POST `/releases` on that extra repo: HTTP 403 accepts, HTTP 422 hard-fails as extra Contents: write; verify fakes for extra 422 fail, extra 403 success, origin 403 still fail, origin GET 404 still fail, and classic `ghp_` still refused

## 2. Docs and quality gate

- [x] 2.1 Update `README.md` so PAT instructions state GitHub’s always-on public-repository read does not fail `github-token`, and that Contents: write must be limited to the assets origin; verify the `project-docs` scenarios
- [x] 2.2 `openspec validate github-token-probe-contents-write --strict` and `hk check`; fix format/lint/weeder without new unused exports or blanket weeder roots
