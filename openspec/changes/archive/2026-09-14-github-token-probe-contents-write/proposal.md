## Why

`github-token` refuses a correctly scoped fine-grained PAT because the setter probe requires `GET /user/repos?affiliation=owner` to list **exactly** the assets origin repository. GitHub always grants fine-grained PATs read-only access to all public repositories, so that list includes every public repo the operator owns. Operators who follow README (Only select repositories + Contents: write on the assets repo) cannot store a token.

## What Changes

- Change the setter probe’s extra-repository check from “exactly one owned repo name” to “Contents: write on the assets origin only.” Extra names that are public-read-only SHALL NOT fail the probe.
- Keep the existing fail-closed checks: `github_pat_` prefix, successful `GET /repos/{owner}/{repo}` for the assets origin, and empty `POST /repos/{owner}/{repo}/releases` expecting HTTP 422 (HTTP 403 still means missing Contents: write).
- Still refuse a token that has Contents: write on any listed repository other than the assets origin (for example “All repositories” with Contents: write, or extra selected repos with Contents: write).
- README (and tests) document GitHub’s always-on public-repo read so operators are not told to pick a PAT form that the probe cannot accept.

### Non-goals

- Changing envelope encryption, `--force`, TTY prompts, or token resolution (`GITHUB_TOKEN` / `GH_TOKEN` / config)
- Minting PATs, probing environment tokens, or GitHub Enterprise
- Proving GitHub UI checkboxes beyond Contents: write (Metadata-only extra selected public repos are not distinguishable from always-on public read)
- Using extra-repo empty `POST /releases` as a write test when a listed extra repo already reports no write permission
- Changing overlay git push (SSH) or assets `SRC_URI` origin parsing

## Capabilities

### New Capabilities

<!-- none -->

### Modified Capabilities

- `github-token-command`: Probe extra-repo rule is Contents: write on the assets origin only; public-read-only owned repos SHALL NOT fail
- `test-coverage`: Probe fakes cover public-read extra names (success) vs extra Contents: write (fail), not name-list singleton
- `project-docs`: README documents GitHub’s always-on public-repo read and that the setter checks Contents: write on the assets repo only

## Impact

- **Code:** `Update.GitHubToken` probe (`listOwnedRepos` / extra-name comparison)
- **Tests:** `test/Test/Assets.hs` probe fakes (success with extra public-read names; refuse extra write)
- **Docs:** `README.md` `github-token` PAT instructions
- **Operator:** A PAT limited to `assets-path` origin with Contents: write can be stored even when the operator owns other public repositories
