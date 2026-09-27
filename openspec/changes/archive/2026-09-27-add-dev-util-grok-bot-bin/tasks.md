# Tasks

## 1. JSON feed source

- [x] 1.1 Add an HttpJson update source (URL plus version field name) beside the plain-text Http source. Fetch reads that JSON field and parses it as an ebuild version. A missing field, a non-object body, or a field that is not a version string is a fetch error for that source. Verify with tests: body `{"version":"0.61.0","commitSha":"47a9d1df3a7d37aaa53d206ab2d1f9159a336223"}` and field `version` parses as PV `0.61.0`; the same body through a plain-text Http source does not parse as `0.61.0`.
- [x] 1.2 For `dev-util/grok-bot-bin`, fetch `https://api2.cursor.sh/updates/api/download/stable/linux-x64/sand` and `https://api2.cursor.sh/updates/api/download/stable/linux-arm64/sand`. Report the shared `version` only when both feeds agree. Differing versions are a fetch error and produce no PV. Verify with fixture feeds: equal `0.62.0` reports PV `0.62.0`; `0.62.0` versus `0.61.0` is an error and does not report a PV.

## 2. Policy

- [x] 2.1 Add `dev-util/grok-bot-bin` to `hardcodedPolicies` with technique `GitMvAndManifest` and the two HttpJson feeds from 1.2. Verify a new `test/Test/Policy.hs` assertion, modeled on `grok-build-bin`, that `lookupPolicy` returns that technique and those feeds.
- [x] 2.2 Confirm README, CONTRIBUTING, and AGENTS need no edit: this change adds no work subcommand, config key, quality-pipeline step, or agent-process rule (`project-docs`).

## 3. Commit rewrite on apply

- [x] 3.1 On `dev-util/grok-bot-bin` apply, after the GitMv rename and before `ebuild manifest`, GET both feeds again. Hard-fail the package with no overlay mutation unless both `version` fields equal the planned remote PV, both `commitSha` values are equal, and each `debUrl` is `https://downloads.cursor.com/grokbot/stable/<commitSha>/linux/<x64|arm64>/grok-bot_<version>_<amd64|arm64>.deb`. On success, replace the single `GROK_BOT_COMMIT` assignment and leave `IUSE`, `RDEPEND`, `SRC_URI` shape, and install layout unchanged. A missing assignment hard-fails before manifest. Verify with fixture tests: `0.61.0` → `0.62.0` writes commit `abc123` and keeps `IUSE="+wayland +pulseaudio +libnotify suid apparmor"`; a feed version other than the planned PV does not rename; a `debUrl` outside that template does not run manifest; unequal commits do not rename.
- [x] 3.2 Run the policy, fetch, and GitMv test groups and confirm the new assertions pass and the existing GitMv assertions still pass.

## 4. Overlay seed

- [x] 4.1 Write `dev-util/grok-bot-bin/grok-bot-bin-0.61.0.ebuild` in the mndz overlay: EAPI 8, `unpacker` and `xdg`, `KEYWORDS="-* ~amd64 ~arm64"`, `LICENSE="all-rights-reserved"`, homepage `https://x.ai/bot`, `GROK_BOT_COMMIT="47a9d1df3a7d37aaa53d206ab2d1f9159a336223"`, and the amd64/arm64 `SRC_URI` from the seed spec. `IUSE="+wayland +pulseaudio +libnotify suid apparmor"`. Unconditional RDEPEND includes GTK 3, NSS, ALSA, GBM, libxkbcommon, Cups, and libsecret. The three default-on flags add Wayland, libpulse, and libnotify. `RESTRICT="bindist mirror strip"`. `QA_PREBUILT` covers `opt/Grok Bot`. No `src_test` and no `test` in `IUSE`. Unpack the deb without maintainer scripts. Install `/opt/Grok Bot`, symlink `/usr/bin/grok-bot`, and install the desktop file and hicolor icons. The desktop file executes `grok-bot` and handles `grokbot` and `sand`. Do not install `/usr/bin/sand` and do not pass `--no-sandbox`. `USE=-suid` leaves `chrome-sandbox` mode `0755`; `USE=suid` sets `4755`. `USE=apparmor` installs the upstream profile for `/opt/Grok Bot/grok-bot`. Verify the ebuild text against each of those conditions.
- [x] 4.2 Write `dev-util/grok-bot-bin/metadata.xml` with homepage `https://x.ai/bot` and a long description of the prebuilt desktop agent. Verify it follows the `grok-build-bin` metadata.xml shape.
- [x] 4.3 Regenerate `Manifest` with `ebuild grok-bot-bin-0.61.0.ebuild manifest` under the manager distfiles environment, and regenerate the package md5-cache. Verify `DIST` entries exist for both debs and `metadata/md5-cache/dev-util/grok-bot-bin-0.61.0` exists.

## 5. Seed install

- [x] 5.1 Emerge `=dev-util/grok-bot-bin-0.61.0` with default USE. Verify the install exits 0, `/usr/bin/grok-bot` resolves to `/opt/Grok Bot/grok-bot`, `/usr/bin/sand` is absent, `chrome-sandbox` is mode `0755`, and the desktop file handles `x-scheme-handler/sand` and `x-scheme-handler/grokbot`.
- [x] 5.2 Run `outdated grok-bot-bin`. If both feeds still report `0.61.0`, verify the package is not reported outdated. If they report a newer shared version, verify `outdated` names that version, then `update grok-bot-bin` rewrites `GROK_BOT_COMMIT`, renames the ebuild, and regenerates the Manifest, and emerge of the new PV exits 0.

## 6. Gate

- [x] 6.1 Run `openspec validate add-dev-util-grok-bot-bin --strict --type change` and `hk check`. Verify both exit 0.
