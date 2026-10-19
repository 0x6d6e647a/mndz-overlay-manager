# Spec Delta

## ADDED Requirements

### Requirement: Test gate ignores the invoking repository environment

The blocking test gate SHALL ignore inherited Git repository-location variables. A git command it runs against a named directory SHALL apply to that directory. The gate SHALL NOT set `core.worktree` on the repository that launched the suite.

#### Scenario: Linked worktree environment does not retarget the common config

- **WHEN** the suite is launched with Git's repository-location variables pointing at a linked worktree, and a test initializes a repository in a temporary directory
- **THEN** that temporary directory is a git work tree
- **AND** the worktree's common config has no `core.worktree` value written by the suite

#### Scenario: Unset environment still creates a temporary work tree

- **WHEN** those variables are unset and a test initializes a repository in a temporary directory
- **THEN** that temporary directory is a git work tree
