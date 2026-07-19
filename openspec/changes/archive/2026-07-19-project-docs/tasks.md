## 1. Baseline documentation structure

- [x] 1.1 Ensure `README.md` is operator-focused: prerequisites (build via GHCup/GHC 9.10.x + runtime tools), build/run (`cabal build` + `--help` only as the primary examples), configuration (XDG path, keys, token resolution), and Commands (globals + `list` / `outdated` / `update` with examples)
- [x] 1.2 Ensure `CONTRIBUTING.md` holds rules and standards, developer onboarding (quality tools + hk), and workflows (pipeline, day-to-day, failure recovery, OpenSpec, layout)
- [x] 1.3 Ensure `AGENTS.md` stays thin: pointers to README/CONTRIBUTING/OpenSpec, preferred gate commands, agent-specific rules only

## 2. Accuracy audit (retrofit baseline)

- [x] 2.1 Audit README work commands and examples against `CLI.Parser` / `cli-help` / work-command specs (`list`, `outdated`, `update` only; no invented or removed commands)
- [x] 2.2 Audit README global options against implemented top-level flags
- [x] 2.3 Audit README configuration (default path, `overlay-path` / `assets-path` / `github-token`, token env order) against `Config.Loader`, `Config.Types`, and `Update.Auth`
- [x] 2.4 Audit README runtime requirements against `Update.Preflight` (`git`/`ebuild`/`gpg`; `go`/`xz` when assets)
- [x] 2.5 Audit CONTRIBUTING quality pipeline and bootstrap against `hk.pkl`, `git-hooks-quality-gates`, and `scripts/install-dev-tools` / pin notes
- [x] 2.6 Fix any false statements, missing catalog items, or bad examples found in the audit

## 3. Process visibility for agents

- [x] 3.1 Add a brief AGENTS (and/or CONTRIBUTING) pointer that docs-sync policy lives under OpenSpec `project-docs` (after apply) / this change’s spec until archive
- [x] 3.2 Confirm AGENTS does not re-host full quality pipeline tables or a full command catalog

## 4. Verification

- [x] 4.1 Cross-read the three files for consistent cross-links and no “see README for quality gates” reverse pointers
- [x] 4.2 Confirm no application code or `hk.pkl` changes are required for this capability (docs + OpenSpec only)
- [x] 4.3 Run `hk check` if the tree has other dirty state that needs the gate; markdown-only should not require code fixes
