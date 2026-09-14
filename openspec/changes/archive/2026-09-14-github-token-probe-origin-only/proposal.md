## Why

The extra-repository Contents: write probe still refuses a correctly scoped fine-grained PAT. Empty `POST /releases` on a public extra the operator owns returns HTTP 422 even when GitHub’s UI grants Contents: write only on the assets origin (live miss: `0x6d6e647a/advent-of-code-2021`). That 422 is not token-scoped write; GitHub always lists public owned repos and may schema-validate the body using owner identity. The documented PAT form cannot be stored.

## What Changes

- Drop extra-repository checks from the `github-token` setter probe. Do not call `GET /user/repos`, do not parse `permissions.push`, and do not empty-POST `/releases` on extra names.
- Keep fail-closed origin checks: `github_pat_` prefix, successful `GET /repos/{owner}/{repo}` for the assets origin, empty `POST /repos/{owner}/{repo}/releases` expecting HTTP 422 (HTTP 403 still means missing Contents: write on the origin).
- README: Only-select + Contents: write on the assets origin remains operator guidance. The setter does not enforce extra-repo scope; GitHub’s always-on public-repository read must not fail `github-token`.
- This supersedes the extra-repo write probe in `github-token-probe-contents-write` (complete, not archived).

### Non-goals

- Changing envelope encryption, `--force`, TTY prompts, or token resolution (`GITHUB_TOKEN` / `GH_TOKEN` / config)
- Minting PATs, probing environment tokens, or GitHub Enterprise
- Enforcing GitHub UI “Only select repositories” vs “All repositories” (not observable for public extras)
- Distinguishing extra private listed repos from All-repositories
- Changing overlay git push (SSH) or assets `SRC_URI` origin parsing
- Proving origin empty POST 422 on a public origin is token-scoped Contents: write (residual; keep the existing 403/422 origin convention)

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `github-token-command`: Probe is origin GET + origin empty POST 422 only; extra owned repositories SHALL NOT fail the probe
- `test-coverage`: Probe fakes cover extra names in `/user/repos` as success when origin GET/POST succeed, not extra-write refusal
- `project-docs`: README states extra owned public repos do not fail the setter; Only-select is guidance, not an extra-repo API check

## Impact

- **Code:** `Update.GitHubToken` (`listOwnedRepos` / `refuseExtraContentsWrite` / extra POST)
- **Tests:** `test/Test/Assets.hs` probe fakes (extra names succeed; keep classic prefix, origin GET 404, origin POST 403)
- **Docs:** `README.md` `github-token` PAT instructions
- **Operator:** A PAT limited to the assets origin with Contents: write can be stored when the operator owns other public repositories
