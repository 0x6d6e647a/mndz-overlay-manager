## 1. Spike and core md5-cache library

- [x] 1.1 Spike `egencache --repositories-configuration` with `mndz` location = overlay-path and confirm masters/eclasses resolve; document the production argv fragment in code comments or module header
- [x] 1.2 Add module (e.g. `Update.Md5Cache`) for: parse `layout.conf` `cache-formats` gate; list non-live ebuild versions under a package; compute ebuild MD5; read `_md5_` from a cache file; classify complete/matching vs missing vs mismatch
- [x] 1.3 Define injectable `EgencacheRunner` and production implementation (`egencache` on PATH, `--repo mndz`, injected repos config, `--update`, optional atoms and `-j`)
- [x] 1.4 Unit tests for layout gate, MD5 match/mismatch/missing, and multi-version package completeness

## 2. Preflight and update integration

- [x] 2.1 Add `egencache` to update required tools (`Update.Preflight` / callers) and enforce layout gate on `update` spine before package mutation
- [x] 2.2 Before each apply unit mutates a package, run package cache completeness gate; hard-fail with `gencache` / `gencache --force` recovery messages
- [x] 2.3 After successful `ebuild … manifest` on GitMv path: run package-scoped egencache under overlay lock; extend commit pathspecs with `metadata/md5-cache/` paths; then signed commit
- [x] 2.4 Same post-manifest egencache + pathspecs for Go PV materialize path (full and reuse)
- [x] 2.5 Prune path: after removals + Manifest, package egencache under lock; include cache paths in prune commit
- [x] 2.6 Extend half-applied warnings to mention cache repair via `gencache` / `gencache --force` when failure is after mutation / after egencache
- [x] 2.7 Tests: mock egencache runner; assert gate failures; assert commit path lists include cache files

## 3. gencache command

- [x] 3.1 Add `gencache` to CLI parser (optional `PACKAGE...`, `--force`) and top-level/per-command help
- [x] 3.2 Implement spine: config, overlay resolve/validate, git worktree, tools (`git`, `egencache`, `gpg`), layout gate, target resolution (all vs selected)
- [x] 3.3 Implement strict-strict package loop: missing → generate; mismatch without force → error; match without force → skip; `--force` → always generate
- [x] 3.4 Single signed overlay commit of changed `metadata/md5-cache/**` paths (message e.g. `metadata: regenerate md5-cache`); no empty commit when nothing changed; GPG readiness reuse
- [x] 3.5 Wire Main command dispatch and exit codes consistent with `update` hard-fail patterns
- [x] 3.6 Tests for target selection, force/mismatch/missing behaviors (mocked runner)

## 4. Docs and quality

- [x] 4.1 Update `README.md`: `gencache` section, `egencache` in runtime tools table, bootstrap/recovery notes (`layout.conf`, initial `gencache`, `update` maintenance, force repair)
- [x] 4.2 Confirm CLI help catalog lists `gencache`; adjust any help tests
- [x] 4.3 Run `hk check` (or full quality pipeline) and fix issues

## 5. Overlay rollout (operator / live mndz-overlay)

- [x] 5.1 On mndz-overlay: ensure `metadata/layout.conf` contains `cache-formats = md5-dict` and commit if needed
- [x] 5.2 Run `mndz-overlay-manager gencache` for full-tree bootstrap; verify signed commit of `metadata/md5-cache/`
- [x] 5.3 Smoke: `update` on a package with matching cache succeeds and co-commits cache; intentional missing/mismatch produce the specified hard-fail messages
