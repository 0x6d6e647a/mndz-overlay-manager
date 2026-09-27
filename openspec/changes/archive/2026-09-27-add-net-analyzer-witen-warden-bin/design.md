# Design

## Context

See proposal.md for why this package is being added. The manager already fetches a plain-text Http body, strips whitespace, and parses an ebuild version. `GitMvAndManifest` already renames the newest ebuild, runs `ebuild manifest`, regenerates the package md5-cache, and signs one overlay commit. The only body rewrite on that path is the Grok Bot commit pin. Warden's version feed is `0.1.19` plus a newline, and both artifact names are functions of `${PV}`.

The overlay checkout is a separate repo from this one. `update` refuses a dirty ebuild or Manifest, so the 0.1.17 donor has to be a clean commit before the bump. Discovery walks category directories, and `net-analyzer` already exists in the Gentoo master, so the overlay needs no category declaration.

The published artifacts split the install set. The glibc tarball carries the OpenRC init script, conf.d, and logrotate, and its installer writes `/usr/local`. The `.deb` carries `/usr/bin/warden`, the systemd unit, the libexec helpers that unit calls, bash completion, and the man pages. 0.1.19's `-2` deb matches the `-1` deb byte for byte. 0.1.19's tarball adds `local-callers.md`, which 0.1.17 does not have. The same ebuild body has to install both trees, because apply copies that body forward.

This host's pid 1 is systemd, nftables is installed, and `all-rights-reserved` is already an accepted license (Grok Bot is installed). `warden validate` on the stock config reports the config, schema, actuator, and `firewall_nft` checks ok, and reports overall `failed` until the daemon is running.

## Goals / Non-Goals

**Goals:**

- One Http policy entry and no new fetch or apply machinery.
- An ebuild body that emerges at 0.1.17 and, unchanged, emerges at 0.1.19.
- A safe smoke that checks the version commands and the four validate checks that pass while the service is stopped.

**Non-Goals:**

- Copying the systemd unit or helpers into `files/`. They travel inside the `.deb` for that PV.
- Rewriting `warden.toml` for Gentoo log paths. The shipped file is the upstream default, including `jail.backend = "nft"` and journald plus `/var/log/auth.log`.
- A live network call inside the unit tests. The live `outdated` / `update` run is the acceptance proof.

## Decisions

1. **Version source is the existing Http source, with no fallback.** Primary URL `https://www.witenlabs.com/api/releases/warden/version`. The catalog document's `latest` field is the same string, and parsing that document would be a second source type for one package. The plain-text feed is the grok-build shape.

2. **Apply does not rewrite the body.** `grokBotCommitForApply` stays matched to `dev-util/grok-bot-bin` only. Warden's URLs already contain `${PV}`, so rename plus `ebuild manifest` fetches the new distfiles. A catalog lookup that picked the highest Debian revision was the alternative. It needs a new apply-time rewrite, and the only extra revision published today (`-1` vs `-2` of 0.1.19) is the same payload. The ebuild hardcodes `-1`.

3. **Both distfiles are unconditional.** USE-conditional `SRC_URI` would make the Manifest depend on USE flags. The tarball is the OpenRC, conf.d, and logrotate source. The `.deb` is the binary, the systemd unit, and the helpers. `unpacker.eclass` unpacks the deb and does not run its maintainer scripts, which is the grok-bot pattern. `src_install` installs the deb binary and ignores the tarball's copy of `warden`.

4. **OpenRC paths are rewritten in the ebuild, and `install.sh` is not executed.** The portable script installs to `/usr/local`, calls `useradd`, and skips systemd. `src_install` sed-replaces `/usr/local/bin/warden` with `/usr/bin/warden` in the init script and conf.d, then installs both of those plus the deb's unit. Neither service is added to a runlevel, enabled, started, or restarted.

5. **The service account is created in the ebuild.** `pkg_setup` creates group and user `witen-warden` (home `/var/lib/witen`, shell nologin). Separate `acct-user` / `acct-group` packages would be two more overlay entries the manager does not bump. `pkg_postinst` sets `/etc/witen/warden.toml` to mode `0640` and group `witen-warden` when that file is the one this install created. Portage config-protect keeps later operator edits.

6. **nftables is unconditional. `iptables` is a default-off USE flag.** The stock config's jail backend is `nft`, so a USE flag that removed nftables would leave the installed config unable to enforce. `IUSE` adds `iptables` and the matching `net-firewall/iptables` dependency when it is on. The ebuild does not edit the toml from USE. Other runtime dependencies are ca-certificates, acl, and `virtual/logger`, matching the deb and the Gentoo note in the upstream README.

7. **Optional docs are conditional.** `dodoc` of `local-callers.md` runs only when that file is in the unpacked tree. 0.1.17 emerges without it. 0.1.19 installs it. The condition is part of the preserved body.

8. **Policy tests follow `testHardcodedGrok`.** Assert the Http primary, the absent fallback, and `GitMvAndManifest`. An apply fixture asserts a bump from `0.1.17` to `0.1.19` changes the filename and leaves the two URL shapes and `IUSE` in the body. No live HTTP in those tests. Lane arches stay empty: that list is for DepsAndAssets planning, and `KEYWORDS` is what limits Portage to amd64.

9. **Proof order on the two repos.** Commit the 0.1.17 ebuild, Manifest, `metadata.xml`, and md5-cache in the overlay (`net-analyzer/witen-warden-bin: 0.1.17`) and emerge it before `update`. The md5-cache gate runs before GitMv renames anything. Then land the manager policy. `outdated witen-warden-bin` must print `net-analyzer/witen-warden-bin 0.1.17 -> 0.1.19`. `update witen-warden-bin` writes the signed `net-analyzer/witen-warden-bin: 0.1.19` commit. Emerge that ebuild and repeat the version smoke. Do not pass a version on the CLI.

## Risks / Trade-offs

- [A future release publishes only `witen-warden_<PV>-2_amd64.deb`] → `ebuild manifest` fails on the hardcoded `-1` URL. The version feed still reports the PV. Recovery is a later ebuild revision or a catalog-aware URL, which this design does not build. 0.1.17 and 0.1.19 both publish `-1`.
- [An operator reads overall `warden validate` status `failed` as a broken install] → the smoke records the four passing checks and treats the socket, nftables hook, and live source checks as expected failures while the unit is stopped.
- [Starting the unit bans SSH after three failures] → the ebuild never enables or restarts the service, and the proof tasks do not run `systemctl enable` or `rc-update add`. The stock toml is what a later manual start would enforce.
- [`/var/log/auth.log` is absent on this Gentoo host] → the stock toml also enables journald. The config schema check accepts that file. The ebuild leaves the toml unchanged so the body stays stable across versions. Review the log sources before ever starting the daemon.
- [The OpenRC script's capability line needs a current OpenRC] → this host is systemd, so the smoke does not execute that script. The script is upstream's, with only the command path rewritten.

## Migration Plan

1. In the overlay, add `net-analyzer/witen-warden-bin` at 0.1.17, run `ebuild manifest` and package `egencache`, and commit those files with the overlay's signed one-line subject.
2. Emerge `net-analyzer/witen-warden-bin` and run the safe 0.1.17 smoke.
3. In this repo, add the policy entry and tests. `hk check` is the gate.
4. With the overlay tree clean, run `outdated` and then `update` for this package only. The update commit replaces 0.1.17 with 0.1.19.
5. Emerge 0.1.19 and run the safe smoke against that PV.

Rollback is reverting the overlay commits and the manager commit, then deselecting the package. Nothing in the image or the assets repo changes. A manifest failure during `update` follows the existing half-applied GitMv failure path and does not enable the service.

## Open Questions

None. Seed PV, distfile templates, and the safe-smoke boundary are decided.
