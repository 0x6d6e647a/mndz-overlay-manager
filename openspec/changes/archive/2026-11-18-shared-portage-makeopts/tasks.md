# Tasks

## 1. Shared configuration and image defaults

- [x] 1.1 Add the shared internal Portage make.conf update. Verify the assignment for 4 jobs, repeated application, preservation of unrelated settings and readability, and failure when the file cannot be updated.
- [x] 1.2 Wire both generated Dockerfiles to the shared update with build-local `nproc` and bump both generator identities. Verify both recipes configure MAKEOPTS before the first emerge and that build configuration takes no CLI jobs input. Document the baked default in README.

## 2. Container startup overrides

- [x] 2.1 Route the resolved CLI jobs count through the smoke, materialize, and Portage tools startup paths. Verify an image default of `-j8 -l9` becomes `-j4 -l5` inside each workload started with `--jobs 4`, including a reused image, and verify smoke sequencing.
- [x] 2.2 Verify override-image setup, operator UID/GID for workload commands, and cleanup on configuration failure. Document runtime jobs behavior and the override image configuration requirement in README.

## 3. Integration gates

- [x] 3.1 Review shared and smoke-specific requirements for duplicate rules or contradictions and pass `openspec validate shared-portage-makeopts --strict` and `just check` (which runs `hk check`).

## Workflow follow-up

- When archiving, merge both deltas into the main specs, scrub any duplicate or outdated wording, and validate the merged specs.
