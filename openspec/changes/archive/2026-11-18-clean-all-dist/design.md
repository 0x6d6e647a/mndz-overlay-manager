## Context

The recipe validates the selector before passing a fixed set of paths to `rm -rf`. Full cleanup currently targets four known children of `dist/`.

## Goals

Make the full cleanup boundary explicit in the recipe and contributor documentation.

## Non-Goals

Keep selector parsing and named-flavor path selection as they are.

## Decisions

Use `dist` and `coverage` as the two fixed paths for the `all` branch and reuse the existing recursive removal command. Empty-directory pruning would preserve custom trees under `dist/`, which would leave the full cleanup boundary dependent on the directory contents.

## Risks and Migration

Custom or stale builds under `dist/` previously survived full cleanup. Document that the entire tree is disposable and tell contributors to move anything they need to keep before running `just clean all` with the updated recipe. Verify the wider deletion scope in a disposable fixture.
