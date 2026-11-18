# Design

## Context

The flavor wrapper assigns a separate build root to each flavor. It collects dev and release HIE inside those roots. Both coverage flavors write to the same reports directory.

## Goals / Non-Goals

**Goals**

- Limit deletion to the paths specified by the cleanup contract.
- Support stale HIE recovery even when Cabal cannot build.

**Non-Goals**

- Change build orchestration or move coverage reports into separate directories.

## Decisions

- Use one recipe with a default argument so cleanup follows the existing dev default while exposing each flavor through the same interface. Separate recipes would add four commands for the same operation.
- Pass the selector as a positional shell argument and map it to fixed repository-relative paths before deletion. Explicitly enumerate the paths for `all` because deleting the parent `dist/` would also remove unrelated contents.
- Delete the selected output paths directly. Going through Cabal would couple cleanup to the build tool, and the existing flavor wrapper runs HIE collection after successful dev and release commands.

## Risks / Trade-offs

- A single-flavor coverage cleanup preserves the shared reports, which can describe an earlier run. Document this behavior alongside the `all` option.
- Release cleanup removes the HIE inputs for static analysis. Document rebuilding release as the next step in stale HIE recovery.
