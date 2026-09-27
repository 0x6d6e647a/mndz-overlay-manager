# Tasks

## 1. Revision ebuild

- [x] 1.1 Add `net-analyzer/witen-warden-bin/witen-warden-bin-0.1.19-r1.ebuild` from `witen-warden-bin-0.1.19.ebuild` and remove the unrevised file. Inherit `bash-completion-r1` beside `unpacker` and `systemd`. Set `IUSE="bash-completion iptables"` with no leading `+` on either flag. Add `bash-completion? ( app-shells/bash-completion )` to `RDEPEND`. When `bash-completion` is on, `newbashcomp` the deb's `usr/share/bash-completion/completions/warden` as `warden`. When it is off, do not install that file. Leave the systemd unit, OpenRC init script, conf.d, logrotate snippet, `iptables` dependency, distfile URLs, and the rest of the install unchanged. Do not edit `metadata.xml`. Verify the `-r1` ebuild is the only ebuild in the directory, `IUSE` lists both flags without `+`, and the completion install is inside `use bash-completion`.

## 2. Overlay publish

- [x] 2.1 Run `ebuild witen-warden-bin-0.1.19-r1.ebuild manifest` and package-scoped `egencache --repo mndz --update net-analyzer/witen-warden-bin`. Remove `metadata/md5-cache/net-analyzer/witen-warden-bin-0.1.19` if it remains. Verify Manifest `DIST` lines are unchanged, `metadata/md5-cache/net-analyzer/witen-warden-bin-0.1.19-r1` exists with `IUSE` containing `bash-completion` and `RDEPEND` containing `bash-completion? ( app-shells/bash-completion )`, and the unrevised cache file is gone.
- [x] 2.2 Operator: GPG-sign the overlay commit of that revision with subject `net-analyzer/witen-warden-bin: 0.1.19-r1`. Verify `git log --show-signature -1` in the overlay shows that signed subject, and `git status` in the package directory is clean.

## 3. Install smoke

- [x] 3.1 Emerge `=net-analyzer/witen-warden-bin-0.1.19-r1` with the host USE, which enables `bash-completion`. Verify `/usr/share/bash-completion/completions/warden` is installed, the systemd unit, OpenRC init script, and logrotate policy are still installed, `warden --version` prints `warden 0.1.19`, and `witen-warden` is not enabled and is not running solely because of the emerge.
- [x] 3.2 Run `ebuild witen-warden-bin-0.1.19-r1.ebuild install` with `USE=-bash-completion` and inspect that image without merging it. Verify `/usr/share/bash-completion/completions/warden` is absent from the image and the systemd unit, OpenRC init script, and logrotate policy are present. Leave the merged system on the flag-on revision from 3.1.

## 4. Integration gate

- [x] 4.1 Merge the delta into `openspec/specs/net-analyzer-witen-warden-bin-seed/spec.md` so the live ebuild is `witen-warden-bin-0.1.19-r1.ebuild`, bash completion is installed only when `bash-completion` is enabled, and that flag adds `app-shells/bash-completion` only when enabled. Run `openspec validate revise-witen-warden-bin-bash-completion --type change --strict` and `openspec validate --specs --strict`. Verify both report zero issues and the living spec has no delta-residue language ("in this change", "as today").
- [x] 4.2 Run `hk check` and confirm it is green. The Warden apply fixture stays on its own 0.1.17 body and still asserts that a bump does not rewrite `IUSE`.
