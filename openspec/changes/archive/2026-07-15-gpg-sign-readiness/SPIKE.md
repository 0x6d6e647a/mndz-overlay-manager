# Spike notes — gpg-sign-readiness

## 1.1 TTY pinentry (approach A vs B)

**Host stack:** GnuPG 2.5.x, `pinentry` → `pinentry-gnome3`, `pinentry-curses` on PATH, `gpg-connect-agent` available.

**KEYINFO:** Status line form  
`S KEYINFO <keygrip> <type> <serial> <idstr> <cached> …` with `cached` = `1` (warm) or `-` (cold). Confirmed against a live agent.

**Choice: approach A** — for warm and `git commit -S` children, set `GPG_TTY` to the controlling tty path and clear `DISPLAY` in the child only. Parent keeps its `DISPLAY`. Approach B (session `pinentry-program` → `pinentry-curses` with restore) not required on this stack; implement A and hard-fail if unlock cannot proceed on a TTY.

## 1.2 Dummy warm vs first-commit unlock

**Choice: dummy warm** — after the ready-prompt, run  
`gpg --local-user <user.signingkey> --clearsign` under the TTY pinentry child env, then mark `weWarmed`. Isolates pinentry from `git commit` error attribution. First `commit -S` as unlock remains an acceptable fallback only if dummy proves unreliable in production (not observed as necessary here).
