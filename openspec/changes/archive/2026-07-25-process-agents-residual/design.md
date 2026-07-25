## Context

Depends on CommandRunner pattern from `process-command-runner`. Locked T2-A: captured I/O first; interactive later/not this change.

## Goals / Non-Goals

**Goals:**

- Heat production SSH captured paths and residual GPG process edges under Unit
- Keep gate free of pinentry/TTY requirements

**Non-Goals:**

- Full interactive ssh-add (`sshAddWithDevTty` / askpass) as required scope
- Ecosystem process adapters (already prior wave)
- Floors

## Decisions

### D1: Captured SSH only

**Choice:** Production paths for run agent / parse env / list identities / kill / non-interactive add that can be expressed as CommandRunner or existing Ops fields. Do not require `runInherited` interactive coverage to close this change.

### D2: GPG process residual

**Choice:** Identify production process helpers still yellow after prior Gpg Unit tests; inject CommandRunner or extend `GpgAgentOps` production constructors consistently with ProcessOps style.

### D3: Accept interactive residual

**Choice:** Document remaining yellow TTY/askpass as known residual; optional future change.

### D4: Unit isolation

**Choice:** Unit-only agent residual tests.

### D5: Success metric

**Choice:** Gates green; guidance partial SshAgent/GpgAgent lift (~+1–3 Overall if captured paths warm); no floors.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Interactive residual remains large | Explicit non-goal; don't block archive |
| Depends on Process module API | Apply after process-command-runner |
| Over-mocking hides real parse bugs | Prefer pure parse tests already present + process script asserts |

## Migration Plan

1. Confirm Process seam available.
2. Migrate captured SSH production + GPG residual.
3. Unit fakes.
4. Coverage + hk check.

## Open Questions

None blocking.
