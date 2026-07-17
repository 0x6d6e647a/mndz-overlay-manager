## 0. Prerequisite

- [x] 0.1 Confirm `fix-progress-panel-redraw` is applied (or equivalent in-place redraw on main) and TTY `outdated` no longer stacks progress lines
- [x] 0.2 Capture post-A baseline notes: MultiHandle/StepHandle surface, pause path, log-hold, deferred stdout—use as parity checklist

## 1. Pause spike (gate)

- [x] 1.1 Spike layoutz inline/runtime: show a multi-line panel, clear it, run a blocking interactive-style read (stand-in for pinentry), resume or re-show without ghosts
- [x] 1.2 Confirm indicator output can stay on stderr (or document blocking limitation)
- [x] 1.3 Go/no-go: if pause or stderr placement is unclean, document rejection in design notes, mark remaining tasks cancelled, stop implementation

## 2. Host swap (only if spike passes)

- [x] ~~2.1 Implement multi-progress hosted by layoutz runtime while preserving MultiHandle call semantics (workers enqueue/update; runtime owns redraw)~~ — cancelled (experiment rejected; see SPIKE.md)
- [x] ~~2.2 Implement sequential step bars on the same host approach~~ — cancelled (experiment rejected)
- [x] ~~2.3 Wire `withUiSuspended` / panel pause to the layoutz host (clear, yield TTY, resume)~~ — cancelled (experiment rejected)
- [x] ~~2.4 Remove or bypass project-owned multi-line `drawFrame` line-count loop for active panels once parity holds~~ — cancelled (experiment rejected)
- [x] ~~2.5 Keep log hold and flush-after-clear behavior unchanged~~ — cancelled (no host swap; post-A behavior retained)

## 3. Parity and quality

- [x] ~~3.1 Preserve or adapt pure multi-state / view tests as content parity under the new host~~ — cancelled (no host swap)
- [x] ~~3.2 TTY smoke: `outdated` and `update` (including path that suspends for GPG when available) match post-A contracts~~ — cancelled (no host swap; post-A retained)
- [x] ~~3.3 `cabal test all` and `hk check` green~~ — cancelled (no code changes; post-A already green)
- [x] 3.4 Decide keep vs revert using design kill criteria; if revert, restore post-A host and archive experiment notes
