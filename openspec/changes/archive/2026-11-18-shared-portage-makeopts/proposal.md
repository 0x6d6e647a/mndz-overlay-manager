# Shared Portage MAKEOPTS

## Why

Smoke container setup sets Portage build parallelism, while the generated smoke and materialize Dockerfiles and the other runtime paths rely on inherited defaults. A shared contract gives new Portage workloads the same behavior.

## What Changes

- Bake a default derived from the Docker build environment's processor count into both managed image families before the first Portage operation.
- Use the current command's resolved jobs count in each managed Portage workload container, including those launched from reused or operator-supplied images.
- Keep the formula and configuration update in one shared implementation.

## Capabilities

### New Capabilities

- `portage-build-parallelism` defines the build default and runtime override for current and future Portage workloads.

### Modified Capabilities

- `cli-concurrency` refers to the shared rule and retains the smoke sequencing requirements.

## Impact

The smoke and materialize image recipes, smoke setup, materialize sessions, Portage tools sessions, and operator documentation are affected. Operator-supplied runtime images need to support updating `/etc/portage/make.conf` inside the container.

## Non-goals

- Configure tree snapshots or helper containers that perform no Portage work.
- Unify container lifecycles, cache mounts, or other Portage settings.
