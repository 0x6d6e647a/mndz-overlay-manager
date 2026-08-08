## MODIFIED Requirements

### Requirement: Prefer configured git remote transport

Assets `git push` SHALL use the assets worktree’s existing `origin` (or configured) remote URL without rewriting SSH remotes to HTTPS token URLs.

#### Scenario: SSH remote left intact

- **WHEN** the assets worktree `origin` is an SSH URL
- **THEN** push uses that remote and does not convert it to an HTTPS URL embedding the GitHub token
