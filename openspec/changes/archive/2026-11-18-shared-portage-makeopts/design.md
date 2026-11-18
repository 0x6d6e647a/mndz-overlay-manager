# Design

## Context

Both image recipes inherit from Gentoo stage3 and run Portage during the build. Smoke already has a privileged setup script. Materialize and Portage tools sessions start a long-lived container and invoke workloads with the operator's UID and GID.

## Goals

- Give every Portage workload the default and override defined in the shared spec.
- Keep future image and container integrations small.

## Non-goals

- Consolidate Docker lifecycle code or move workload-specific Portage settings into the shared module.

## Decisions

### Share the configuration update

Add a small internal Portage module that renders a shell fragment to validate a positive jobs count, compute the load limit, and write the effective assignment to make.conf. Use the same fragment in both Dockerfile renderers and all workload setup paths. Make repeated updates idempotent, preserve unrelated configuration, and preserve file readability for the workload user.

### Resolve jobs where they are used

The Dockerfile fragment evaluates `nproc` in the build environment before any emerge. Runtime callers pass the jobs count already resolved by the CLI, including its existing default when the flag is omitted. A change to the CLI jobs count therefore leaves image eligibility and BuildKit inputs alone.

### Configure each workload before its first command

Reuse smoke's root setup and replace its existing MAKEOPTS append. For materialize and Portage tools, run a one-shot root exec after startup and before returning a usable session. Continue running workload commands with the operator's UID and GID. Route configuration errors through the existing setup failure and cleanup paths.

## Risks / Trade-offs

- A custom image may have a nonstandard or unwritable make.conf. Surface setup errors with the failing path before attempting the workload.
- Build CPU availability can differ from runtime CPU availability. The runtime override applies on every session start, including sessions backed by a previously recorded image.

## Migration Plan

Bump both generator identities so normal recipe validation refreshes old managed images when it next requires a build. The Portage tools fast path can reuse an existing image immediately because startup sets the runtime value, including for images that predate the baked default.
