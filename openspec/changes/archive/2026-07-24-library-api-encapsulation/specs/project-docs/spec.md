## ADDED Requirements

### Requirement: Agent guidance on weeder and library surface

When the package’s weeder roots or cabal exposed-module policy is part of the agent workflow, `AGENTS.md` SHALL state that agents must not reintroduce a blanket weeder `root-modules` list covering the entire library, and must not casually expand `exposed-modules` without need from the executable or tests.

#### Scenario: AGENTS mentions weeder surface policy

- **WHEN** an agent reads `AGENTS.md` after this policy is in force
- **THEN** the file includes guidance against blanket weeder roots and unjustified public module expansion
