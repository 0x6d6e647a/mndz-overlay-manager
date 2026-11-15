# Spec Delta

## MODIFIED Requirements

### Requirement: Host keeps publish and Manifest

After a successful full-path container materialize, the host CLI SHALL hash sidecars, create the GPG-signed assets commit, `git push` the assets worktree, upload the GitHub release, then rewrite the overlay ebuild and run `ebuild … manifest` and md5-cache through the Portage tools container specified by `portage-tools-container`, as already specified by `assets-publish` and the ecosystem capabilities. The materialize session SHALL NOT run those steps. Neither container SHALL receive the GitHub token, GPG agent, or SSH agent solely to perform those steps.

#### Scenario: Token stays on the host

- **WHEN** full-path materialize finishes and assets publish begins
- **THEN** release create/upload runs in the host CLI using the host-resolved token

## ADDED Requirements

### Requirement: Session binds the managed tree read-only

Each materialize session container SHALL bind the managed Gentoo tree read-only at `/var/db/repos/gentoo`, so in-session tools that read Gentoo repository metadata (such as `pycargoebuild` reading `metadata/license-mapping.conf`) use the same tree commit as lane planning.

#### Scenario: pycargoebuild finds the license mapping

- **WHEN** a full-path Cargo session runs `pycargoebuild`
- **THEN** it reads `metadata/license-mapping.conf` from the managed tree bound at `/var/db/repos/gentoo`

#### Scenario: Session cannot modify the tree

- **WHEN** a session process writes under `/var/db/repos/gentoo`
- **THEN** the write fails and the managed tree is unchanged
