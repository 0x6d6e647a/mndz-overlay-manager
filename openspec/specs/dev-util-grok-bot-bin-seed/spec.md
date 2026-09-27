# dev-util-grok-bot-bin-seed Specification

## Purpose

Seeded overlay package truth for `dev-util/grok-bot-bin`: the prebuilt Grok Bot desktop agent, its commit-pinned Linux `.deb` sources, install layout, and USE flags.

## Requirements

### Requirement: Grok Bot package identity

The overlay SHALL ship `dev-util/grok-bot-bin` as a prebuilt package. The introduced live ebuild SHALL be `grok-bot-bin-0.61.0.ebuild` with `GROK_BOT_COMMIT` set to `47a9d1df3a7d37aaa53d206ab2d1f9159a336223`. `KEYWORDS` SHALL be `-* ~amd64 ~arm64`. `LICENSE` SHALL be `all-rights-reserved`. The homepage SHALL be `https://x.ai/bot`.

#### Scenario: Introduced ebuild is 0.61.0 for both arches

- **WHEN** the introduced `dev-util/grok-bot-bin` ebuild is inspected
- **THEN** its filename PV is `0.61.0`
- **AND** `KEYWORDS` includes `~amd64` and `~arm64`
- **AND** `LICENSE` is `all-rights-reserved`
- **AND** `GROK_BOT_COMMIT` is `47a9d1df3a7d37aaa53d206ab2d1f9159a336223`

### Requirement: Commit-pinned deb SRC_URI

`SRC_URI` SHALL download the upstream `.deb` from `https://downloads.cursor.com/grokbot/stable/${GROK_BOT_COMMIT}/linux/x64/grok-bot_${PV}_amd64.deb` for amd64 and `https://downloads.cursor.com/grokbot/stable/${GROK_BOT_COMMIT}/linux/arm64/grok-bot_${PV}_arm64.deb` for arm64. The ebuild SHALL contain one `GROK_BOT_COMMIT` assignment. A later `GitMvAndManifest` bump SHALL change the filename PV and that assignment, and SHALL preserve this URL shape.

#### Scenario: Both arches use the commit and PV

- **WHEN** the ebuild `SRC_URI` is inspected
- **THEN** the amd64 URI contains `/linux/x64/grok-bot_${PV}_amd64.deb` under `${GROK_BOT_COMMIT}`
- **AND** the arm64 URI contains `/linux/arm64/grok-bot_${PV}_arm64.deb` under the same `${GROK_BOT_COMMIT}`

### Requirement: Install layout

`src_install` SHALL install the upstream tree at `/opt/Grok Bot`, SHALL install a `/usr/bin/grok-bot` symlink to `/opt/Grok Bot/grok-bot`, and SHALL install the upstream desktop file and hicolor icons. The desktop file SHALL execute `grok-bot` and SHALL handle `x-scheme-handler/grokbot` and `x-scheme-handler/sand`. The package SHALL NOT install `/usr/bin/sand`, SHALL NOT install an apt source or signing key, and SHALL NOT run the Debian maintainer scripts.

#### Scenario: Commands and schemes

- **WHEN** the package is installed
- **THEN** `/usr/bin/grok-bot` resolves to `/opt/Grok Bot/grok-bot`
- **AND** the installed desktop file names `grok-bot` and both `grokbot` and `sand` schemes
- **AND** `/usr/bin/sand` is absent

### Requirement: USE flags and runtime dependencies

`IUSE` SHALL default `wayland`, `pulseaudio`, and `libnotify` on, and `suid` and `apparmor` off. The ebuild SHALL unconditionally RDEPEND on GTK 3, NSS, ALSA, GBM, libxkbcommon, Cups, and libsecret. `wayland` SHALL add a Wayland dependency. `pulseaudio` SHALL add libpulse. `libnotify` SHALL add libnotify. `apparmor` SHALL install the upstream AppArmor profile, whose attachment path is `/opt/Grok Bot/grok-bot`, and SHALL NOT install that profile when the flag is off. Cups SHALL be an unconditional dependency because the executable links `libcups`.

#### Scenario: Default flags

- **WHEN** the ebuild `IUSE` is inspected
- **THEN** `wayland`, `pulseaudio`, and `libnotify` are enabled by default
- **AND** `suid` and `apparmor` are disabled by default

#### Scenario: AppArmor profile is flag-gated

- **WHEN** the package is installed with `USE=-apparmor`
- **THEN** the upstream AppArmor profile is not installed
- **AND** enabling `apparmor` installs that profile for `/opt/Grok Bot/grok-bot`

### Requirement: Sandbox helper

The installed `/usr/bin/grok-bot` SHALL NOT pass `--no-sandbox`. `chrome-sandbox` SHALL remain mode `0755` unless `suid` is enabled, in which case `src_install` SHALL set it to mode `4755`.

#### Scenario: Default install leaves the helper non-setuid

- **WHEN** the package is installed with `USE=-suid`
- **THEN** `/opt/Grok Bot/chrome-sandbox` is mode `0755`
- **AND** the `grok-bot` launcher does not pass `--no-sandbox`

#### Scenario: suid sets the helper setuid

- **WHEN** the package is installed with `USE=suid`
- **THEN** `/opt/Grok Bot/chrome-sandbox` is mode `4755`

### Requirement: Prebuilt package has no test phase

The ebuild SHALL NOT define `src_test` and SHALL NOT add `test` to `IUSE`. `RESTRICT` SHALL include `bindist`, `mirror`, and `strip`. `QA_PREBUILT` SHALL cover the installed `/opt/Grok Bot` tree.

#### Scenario: No test USE

- **WHEN** the ebuild is inspected
- **THEN** it has no `src_test`
- **AND** `IUSE` does not include `test`
- **AND** `RESTRICT` includes `bindist`, `mirror`, and `strip`
