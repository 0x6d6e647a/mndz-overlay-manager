# Tasks

## 1. Overlay donor at 0.1.17

- [x] 1.1 Write `net-analyzer/witen-warden-bin/witen-warden-bin-0.1.17.ebuild` in the mndz overlay. EAPI 8. Inherit `unpacker` and `systemd`. `KEYWORDS="-* ~amd64"`. `LICENSE="all-rights-reserved"`. Homepage `https://www.witenlabs.com`. `SRC_URI` fetches `witen-warden-${PV}-linux-amd64-glibc.tar.gz` and `witen-warden_${PV}-1_amd64.deb` from `https://www.witenlabs.com/api/releases/warden/artifacts/`. `IUSE="iptables"` with iptables off by default. RDEPEND always includes nftables, ca-certificates, acl, and `virtual/logger`; `iptables` adds `net-firewall/iptables`. `RESTRICT="bindist mirror strip"`. `QA_PREBUILT` covers `/usr/bin/warden`. No `src_test` and no `test` in `IUSE`. Unpack the deb without maintainer scripts and do not run `install.sh`. Install the deb's `/usr/bin/warden`, systemd unit, and `/usr/libexec/witen-warden/{prepare-state,prepare-log-access,smoke-journal}`. Install the tarball's OpenRC init script and conf.d after replacing `/usr/local/bin/warden` with `/usr/bin/warden`, plus its logrotate policy. Install `/etc/witen/warden.toml` from the upstream default, bash completion, and the man pages. `dodoc` `local-callers.md` only when that file is present. `pkg_setup` creates group and user `witen-warden` with home `/var/lib/witen` and shell nologin. Do not enable, start, or restart the service. Verify the ebuild text against each of those conditions.
- [x] 1.2 Write `net-analyzer/witen-warden-bin/metadata.xml` with homepage `https://www.witenlabs.com` and a long description of the prebuilt jailer. Verify it follows the `grok-build-bin` metadata.xml shape.
- [x] 1.3 Regenerate `Manifest` with `ebuild witen-warden-bin-0.1.17.ebuild manifest` under the manager distfiles environment, and regenerate the package md5-cache. Verify `DIST` entries exist for the 0.1.17 tarball and the `witen-warden_0.1.17-1_amd64.deb`, and that `metadata/md5-cache/net-analyzer/witen-warden-bin-0.1.17` exists.

## 2. Safe smoke of 0.1.17

- [x] 2.1 Emerge `=net-analyzer/witen-warden-bin-0.1.17` with default USE. Verify the emerge exits 0, `/usr/bin/warden` is executable, `warden --version` prints `warden 0.1.17`, `warden version --json` reports `0.1.17`, user and group `witen-warden` exist, and `witen-warden` is not enabled and is not running.
- [x] 2.2 Run `warden validate --config /etc/witen/warden.toml --json`. Verify `config`, `config_schema`, `actuator`, and `firewall_nft` are `ok`. An overall status of `failed` from the stopped daemon is expected. Verify the service is still not enabled.
- [x] 2.3 Commit the 0.1.17 ebuild, `metadata.xml`, `Manifest`, and md5-cache in the overlay with signed subject `net-analyzer/witen-warden-bin: 0.1.17`. Verify those paths are clean relative to overlay HEAD.

## 3. Manager policy

- [x] 3.1 Add `net-analyzer/witen-warden-bin` to the hardcoded policy map with technique `GitMvAndManifest` and Http primary `https://www.witenlabs.com/api/releases/warden/version` and no fallback. Verify a `test/Test/Policy.hs` assertion, modeled on `testHardcodedGrok`, that `lookupPolicy` returns that technique and that source.
- [x] 3.2 Keep the Grok Bot commit rewrite matched only to `dev-util/grok-bot-bin`. A Warden GitMv apply renames the ebuild and does not rewrite the body. Verify a fixture test: bumping a `0.1.17` body to `0.1.19` yields `witen-warden-bin-0.1.19.ebuild`, still containing `witen-warden-${PV}-linux-amd64-glibc.tar.gz` and `witen-warden_${PV}-1_amd64.deb`, with `IUSE` unchanged.
- [x] 3.3 Confirm README, CONTRIBUTING, and AGENTS need no edit: this change adds no work subcommand, config key, quality-pipeline step, or agent-process rule (`project-docs`).
- [x] 3.4 Run the policy and GitMv test groups. Verify the new assertions pass and the existing GitMv and Grok Bot assertions still pass.

## 4. Live bump to 0.1.19

- [x] 4.1 Run this change's manager, not a previously installed binary, as `outdated net-analyzer/witen-warden-bin` (or the unambiguous bare name). Verify stdout includes the line `net-analyzer/witen-warden-bin 0.1.17 -> 0.1.19`.
- [x] 4.2 Run `update` for that package only. Verify the signed overlay commit subject is `net-analyzer/witen-warden-bin: 0.1.19`, the live ebuild is `witen-warden-bin-0.1.19.ebuild`, the 0.1.17 ebuild is gone, and the body still contains both `${PV}` distfile templates. Verify `Manifest` has `DIST` entries for the 0.1.19 tarball and `witen-warden_0.1.19-1_amd64.deb`.
- [x] 4.3 Emerge `=net-analyzer/witen-warden-bin-0.1.19`. Verify emerge exits 0, `warden --version` prints `warden 0.1.19`, `warden version --json` reports `0.1.19`, and the four validate checks from 2.2 are `ok` while the service stays disabled and stopped.

## 5. Gate

- [x] 5.1 Leave living `openspec/specs/` unchanged; the change deltas are the contract until archive. Run `openspec validate add-net-analyzer-witen-warden-bin --strict --type change` and `hk check`. Verify both exit 0, and verify living specs were not edited.
