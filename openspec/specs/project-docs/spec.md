# project-docs Specification

## Purpose

Process rules for maintaining repository operator, contributor, and agent documentation (`README.md`, `CONTRIBUTING.md`, `AGENTS.md`) in sync with product CLI/config surfaces, quality-gate bootstrap, and agent workflow. Complements `cli-help` (in-binary help) and `git-hooks-quality-gates` (executable quality pipeline) without merging those capabilities.

## Requirements

### Requirement: Document roles for README, CONTRIBUTING, and AGENTS

The repository SHALL maintain three documentation roles as follows:

1. **`README.md`** — operator-facing documentation for product purpose, build and run (without quality-gate bootstrap as the primary path), configuration, and work commands (including a summary of global options and per-command usage at operator depth).
2. **`CONTRIBUTING.md`** — contributor-facing documentation for rules and standards, developer onboarding (quality tools and hooks), and quality workflows (pipeline, day-to-day commands, failure recovery).
3. **`AGENTS.md`** — agent-facing guidance that points at README and CONTRIBUTING for product and quality detail, plus agent-specific process rules. `AGENTS.md` SHALL remain thin and SHALL NOT be required to list every work command or restate the full quality pipeline tables.

#### Scenario: README is the operator home

- **WHEN** an operator needs to configure and run the program
- **THEN** `README.md` documents configuration, build/run, and work commands without requiring OpenSpec or CONTRIBUTING as the primary path

#### Scenario: CONTRIBUTING is the quality-workflow home

- **WHEN** a contributor needs to bootstrap quality tools or pass the project quality gates
- **THEN** `CONTRIBUTING.md` documents bootstrap and the quality pipeline

#### Scenario: AGENTS stays thin

- **WHEN** an AI agent reads `AGENTS.md`
- **THEN** the file directs the agent to README and CONTRIBUTING for detailed product and quality content rather than duplicating full pipeline tables

### Requirement: Update triggers by surface change

When a change alters an operator, contributor, or agent surface, the repository documentation for that surface SHALL be updated according to this trigger matrix:

| Surface change | File(s) that SHALL be updated |
|----------------|-------------------------------|
| Add, remove, or rename a work subcommand; change operator-relevant global options; change config path defaults or config keys; change operator-facing runtime tool requirements; change command usage that operators rely on | `README.md` |
| Change the quality pipeline steps or policy, install-dev-tools / hook bootstrap, tool pin policy, or documented contributor workflows | `CONTRIBUTING.md` |
| Change agent workflow, OpenSpec implementation process for agents, agent anti-patterns, or preferred agent gate commands | `AGENTS.md` |

A change that only alters internal implementation with no change to the surfaces above SHALL NOT be required to update those markdown files solely for documentation policy.

#### Scenario: New work command updates README

- **WHEN** a change adds a new work subcommand to the CLI
- **THEN** `README.md` documents that command (purpose and at least one example invocation) in the same change

#### Scenario: Config key rename updates README

- **WHEN** a change renames or replaces a TOML config key used by operators
- **THEN** `README.md` configuration documentation uses the new key names and does not present the old names as valid

#### Scenario: Quality pipeline change updates CONTRIBUTING

- **WHEN** a change alters the blocking quality pipeline or bootstrap policy
- **THEN** `CONTRIBUTING.md` is updated in the same change to match the new policy

#### Scenario: Internal-only change needs no operator docs update

- **WHEN** a change only refactors internal apply logic without changing CLI commands, global options, config keys, runtime tool requirements, quality gates, or agent process
- **THEN** documentation policy does not require updating `README.md`, `CONTRIBUTING.md`, or `AGENTS.md`

### Requirement: Same-change documentation updates

Required documentation updates for a surface change SHALL land in the same OpenSpec change (and the same implementation delivery) as the surface change. Documentation-only follow-up changes SHALL NOT be used as the sole means of satisfying this capability when the surface change is otherwise ready to archive.

#### Scenario: Docs ship with the product delta

- **WHEN** a change modifies the operator CLI surface and is marked complete for archive
- **THEN** the corresponding `README.md` updates are included in that change

### Requirement: Accuracy bar for operator and contributor docs

Operator and contributor documentation SHALL satisfy all of the following:

1. **No false statements** — documented command names, config keys, default config path behavior, global options, runtime tools, and quality-gate steps that are described MUST match the implemented system and current main OpenSpec capabilities.
2. **Catalog completeness at role depth** — `README.md` SHALL list every current work subcommand and document config keys and path defaults that operators need; `CONTRIBUTING.md` SHALL describe the current blocking quality pipeline and bootstrap sufficiently to reproduce it.
3. **Real examples** — command and config examples shown in those files SHALL use real subcommands, options, and config keys (not invented names).

Operator documentation is NOT required to restate full behavioral detail from product specs (including complete exit-code matrices, soft-skip rules, or apply internals). In-binary help remains the authoritative source for exhaustive flag-level help text; `README.md` MAY summarize.

#### Scenario: Removed command must not remain documented as current

- **WHEN** a work subcommand is removed from the CLI
- **THEN** `README.md` no longer presents that subcommand as an available command

#### Scenario: Examples use real invocations

- **WHEN** `README.md` shows an example invocation for a work command
- **THEN** the subcommand name and any options shown exist on the implemented CLI surface

#### Scenario: Deep product specs not required in README

- **WHEN** product OpenSpec capabilities define detailed per-package apply behavior
- **THEN** documentation policy does not require `README.md` to restate those details for compliance with this capability

### Requirement: Consistency with CLI help surface

Repository operator documentation SHALL not contradict the work-command catalog and global option surface exposed by the program and specified under `cli-help` and the work-command capabilities. When help text and `README.md` both describe the same command or option, they SHALL agree on names and general purpose. Flag-level completeness remains owned by in-binary help (`cli-help`); narrative configuration, prerequisites, and examples remain owned by `README.md`.

#### Scenario: Command catalog names align

- **WHEN** the program’s top-level help lists work commands
- **THEN** every work command named there is also represented in `README.md` command documentation

#### Scenario: Help remains flag authority

- **WHEN** an operator needs exhaustive per-flag help for a subcommand
- **THEN** documentation policy allows relying on `COMMAND --help` without requiring `README.md` to duplicate every flag description

### Requirement: Baseline accuracy when introducing this capability

The change that introduces this capability SHALL establish a baseline where `README.md`, `CONTRIBUTING.md`, and `AGENTS.md` satisfy the document roles and accuracy bar against the then-current CLI, configuration, and quality-gate surfaces. After that baseline is established, ongoing compliance is via the update-trigger and same-change requirements; historical archived changes are not required to be retroactively edited solely for this capability.

#### Scenario: Introducing change includes baseline docs

- **WHEN** the `project-docs` capability is applied and prepared for archive
- **THEN** the three documentation files meet the accuracy bar for the surfaces that exist at that time

#### Scenario: No historical archive rewrite required

- **WHEN** older archived changes predate this capability
- **THEN** this capability does not require reopening those archives to add documentation tasks
