## ADDED Requirements

### Requirement: Reliable activity panel teardown

When activity indicators are enabled, multi-progress and sequential step-bar hosts SHALL use an exception-safe mutex for all redraw, clear, pause, and resume critical sections that update the panel on standard error, so a throw during those sections cannot leave the mutex permanently acquired.

Panel lifetime SHALL be structured (parent-owned background work), not a fire-and-forget thread whose completion is signaled only by a one-shot empty MVar that the panel may never fill. After the phase body finishes (successfully or by exception), the host SHALL request cooperative stop of the panel, wait briefly for the panel to exit, and if the panel has not exited SHALL cancel the panel work and reap it so that host teardown cannot block indefinitely on progress-internal synchronization.

Panel chrome is best-effort: if the panel fails or is cancelled after the phase body has completed successfully, the program SHALL still complete the phase teardown path (including clearing the owned panel band when possible and flushing deferred logs) and SHALL NOT treat panel failure alone as a command failure for that successful body.

#### Scenario: Redraw failure does not hang the host

- **WHEN** indicators are enabled and a multi-progress or step-bar panel is active and redraw or clear throws during a locked panel update
- **THEN** the progress host still returns from the panel scope within a short bound after the phase body finishes (or after the body is abandoned), rather than blocking indefinitely on an internal MVar

#### Scenario: Phase body exception still tears down the panel

- **WHEN** indicators are enabled and the phase body under multi-progress or step-bar throws
- **THEN** the exception propagates to the caller and the panel is stopped (cooperatively or by cancel-after-grace) without leaving the process blocked indefinitely on progress-internal synchronization

#### Scenario: Successful body ignores panel failure

- **WHEN** indicators are enabled and the phase body completes successfully but the panel thread fails or is cancelled during teardown
- **THEN** the host still finishes teardown (panel band cleared when possible, deferred logs flushed) and returns the body’s success result without failing solely because of the panel

#### Scenario: Pause and resume use the same safe mutex

- **WHEN** indicators are enabled and the active panel is paused or resumed (for example for interactive GPG unlock)
- **THEN** pause/resume critical sections use the same exception-safe panel mutex as redraw so a throw during pause clear or resume cannot permanently acquire that mutex
