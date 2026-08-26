## ADDED Requirements

### Requirement: node-gyp Manifest wait is visible

When activity indicators are enabled and `update` will `docker build` a recipe that emerges overlay node-gyp, and overlay node-gyp needs overlay file work (`ebuild … manifest` / egencache) before that build, the program SHALL show that work so the wait is not indistinguishable from a hung ensure. The program SHALL NOT show opencode, ralph-tui, or other packages as waiting on `dev-build/node-gyp`.

#### Scenario: node-gyp manifest is a visible status

- **WHEN** indicators are enabled, node-gyp needs overlay file work, and ensure will emerge overlay node-gyp
- **THEN** node-gyp’s apply row (or a sequential step) indicates Manifest regeneration before `docker build` starts
- **AND** opencode is not shown as waiting on `dev-build/node-gyp`
