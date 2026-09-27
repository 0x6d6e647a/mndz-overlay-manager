# Proposal: add `net-analyzer/witen-warden-bin`

## Why

Witen Warden, the log-tailing jailer published at https://www.witenlabs.com, is not in the mndz overlay, and the manager cannot bump it. Upstream already publishes a one-line version feed and version-templated Linux artifacts, so a plain-text Http source and a rename-only manifest bump can follow releases.

## What Changes

- Seed `net-analyzer/witen-warden-bin` at PV **0.1.17** for **amd64**. The ebuild fetches the glibc tarball `witen-warden-${PV}-linux-amd64-glibc.tar.gz` and the Debian package `witen-warden_${PV}-1_amd64.deb` from `https://www.witenlabs.com/api/releases/warden/artifacts/`. It installs `/usr/bin/warden`, the systemd unit and its libexec helpers, the OpenRC init script and conf.d with `/usr/local/bin` rewritten to `/usr/bin`, logrotate, man pages, and `/etc/witen/warden.toml`. It creates the `witen-warden` user and group. It does not run `install.sh` or the Debian maintainer scripts, and it does not enable or restart the service.
- `LICENSE="all-rights-reserved"`. `KEYWORDS="-* ~amd64"`. nftables is a hard dependency because the shipped config sets `jail.backend = "nft"`. `iptables` is an optional USE flag. The package is prebuilt and has no `src_test`.
- Add the manager policy: `net-analyzer/witen-warden-bin` → technique `GitMvAndManifest`, source `https://www.witenlabs.com/api/releases/warden/version` (plain-text body, today `0.1.19`). Apply renames the ebuild and regenerates the Manifest. It does not rewrite the ebuild body. The package is not a wait-edge and is not emerged by the materialize image.
- Prove the loop on the live overlay. After the 0.1.17 ebuild is emerged, `warden --version` and `warden version --json` report 0.1.17. `outdated` then prints `net-analyzer/witen-warden-bin 0.1.17 -> 0.1.19`. `update` renames the ebuild to 0.1.19, regenerates the Manifest, and signs the overlay commit. Emerging that ebuild makes `warden --version` report 0.1.19. `warden validate` is checked only for the config, schema, actuator, and `firewall_nft` results. Overall `validate` status stays `failed` while the daemon is stopped; that is the expected safe smoke.

PV selection stays planner-owned. Package targets remain `category/package` tokens. 0.1.17 is the donor PV used to prove the bump. 0.1.19 is the live PV this change leaves in the overlay.

## Capabilities

### New Capabilities

- `net-analyzer-witen-warden-bin-seed`: seeded overlay package truth for `net-analyzer/witen-warden-bin` — identity, the two `${PV}` distfile URLs, install layout, user and service names, license, and the live ebuild PV **0.1.19** left by the proof bump.

### Modified Capabilities

- `update-source`: `net-analyzer/witen-warden-bin` maps to an Http source whose primary URL is `https://www.witenlabs.com/api/releases/warden/version`.
- `update-apply`: `net-analyzer/witen-warden-bin` uses `GitMvAndManifest`. That apply preserves the ebuild body, including both `SRC_URI` shapes. The package is not an overlay wait-edge and is not emerged by the materialize image.
- `overlay-test-use`: `net-analyzer/witen-warden-bin` joins the prebuilt exemption from `IUSE=test`.

## Impact

- **Manager code**: one Http policy entry on the existing plain-text fetch path; policy tests. No new source type, no apply-time body rewrite, no CLI, materialize-image, or assets-publish changes.
- **Overlay repo**: `net-analyzer/witen-warden-bin/` seeded at `witen-warden-bin-0.1.17.ebuild` with `metadata.xml`, `Manifest`, and md5-cache, then replaced by the signed `update` commit that leaves `witen-warden-bin-0.1.19.ebuild`. `net-analyzer` already exists in the Gentoo master, so the overlay adds no category file.
- **Specs**: new `net-analyzer-witen-warden-bin-seed`; deltas on `update-source`, `update-apply`, and `overlay-test-use`.
- **Docs**: no operator CLI, config, quality-pipeline, or agent-process change, so README, CONTRIBUTING, and AGENTS stay as they are.
- **Host**: emerging the package installs a firewall agent and its default config. The proof does not enable `witen-warden`. The stock config enables nftables SSH jailing (`max_ssh_failures = 3`) for whenever an operator starts the unit later.

## Non-goals

- No `DepsAndAssets` technique and no republish of the tarball or `.deb` into `mndz-overlay-assets`. Distfiles are fetched from witenlabs.com at manifest time.
- No arm64, musl, or 386 artifacts. The catalog publishes those for some libc and distro builds; this package is amd64 glibc only.
- No tracking of the Debian `-2` republish. For 0.1.19, `-1` and `-2` are the same payload, and the version feed does not expose a distro revision.
- No catalog-driven `SRC_URI` rewrite. Both artifact names are a function of `${PV}` with the Debian revision fixed at `-1`.
- No `acct-user` / `acct-group` packages. The ebuild creates the service account itself.
- No enabling, starting, or restarting `witen-warden`, and no requirement that `warden validate` exit 0. The socket, nftables table, and `/var/lib/witen` checks need a running daemon.
- No `src_test`. The upstream `smoke-journal` helper SSHes to localhost against a running service and is not a Portage test phase.
- No addition of this package to the materialize image.
- No CLI version pins.
