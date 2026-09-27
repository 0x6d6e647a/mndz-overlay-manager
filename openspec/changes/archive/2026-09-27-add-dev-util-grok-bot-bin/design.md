# Design

## Context

See proposal.md for why `dev-util/grok-bot-bin` is a `GitMvAndManifest` package whose download URL is not a function of PV alone. Plain Http fetch treats the response body as the version. The Cursor feed is a JSON object, so that parse stores an incomparable raw value and apply hard-fails instead of reporting outdated. GitMv copies the ebuild body and only renames the file, so a commit buried in `SRC_URI` would keep pointing at the previous build.

The 0.61.0 linux-x64 and linux-arm64 feeds share commit `47a9d1df3a7d37aaa53d206ab2d1f9159a336223`. The deb names are `grok-bot_0.61.0_amd64.deb` and `grok-bot_0.61.0_arm64.deb`.

## Goals / Non-Goals

**Goals:**

- One policy row and one body edit let `outdated` and `update` follow the stable feed.
- The seed ebuild is emergeable at 0.61.0 on amd64 and arm64, with the USE line and install layout from the spike.
- A feed that renames the deb or splits the arches fails the package before manifest.

**Non-Goals:**

- A generic ebuild-template engine. The only new body edit is the `GROK_BOT_COMMIT` assignment.
- Republishing the deb, a materialize-image change, or a live-computer GUI test in CI.

## Decisions

### JSON version field, commit checked again at apply

Add an HttpJson source: URL plus the version field name (`version`). `outdated` compares that field with the local PV. The linux-x64 and linux-arm64 feeds are both fetched; differing `version` values are a fetch error, and the reported version is the shared one.

Apply does not trust a version cached from an earlier `outdated` run. It GETs both feeds again. The planned remote PV, both `version` fields, and both `commitSha` values must agree, and each `debUrl` must be

`https://downloads.cursor.com/grokbot/stable/<commitSha>/linux/<x64|arm64>/grok-bot_<version>_<amd64|arm64>.deb`

Only then does apply write `GROK_BOT_COMMIT="<commitSha>"` into the renamed ebuild and run `ebuild manifest`. Missing assignment, arch mismatch, or a drifted filename is a package hard-fail with no rename.

Alternative considered: treat the whole JSON body as the Http version. Rejected because version comparison then fails closed as incomparable. Alternative considered: a single opaque Grok Bot source type that hides both URLs. Rejected because the version half is the same "read one JSON field" operation a later feed can reuse; the arch and filename checks stay in this package's apply step.

### Ebuild shape

EAPI 8, `unpacker` and `xdg`. Unpack the deb and do not run its maintainer scripts. Install the `/opt/Grok Bot` tree from the archive, symlink `/usr/bin/grok-bot` to `/opt/Grok Bot/grok-bot`, and install the desktop file and hicolor icons from the deb. The desktop `Exec` is `grok-bot`. No `/usr/bin/sand`.

```
GROK_BOT_COMMIT="47a9d1df3a7d37aaa53d206ab2d1f9159a336223"
SRC_URI="
  amd64? ( https://downloads.cursor.com/grokbot/stable/${GROK_BOT_COMMIT}/linux/x64/grok-bot_${PV}_amd64.deb )
  arm64? ( https://downloads.cursor.com/grokbot/stable/${GROK_BOT_COMMIT}/linux/arm64/grok-bot_${PV}_arm64.deb )
"
```

`IUSE="+wayland +pulseaudio +libnotify suid apparmor"`. Unconditional RDEPEND covers the `DT_NEEDED` set the spike measured, including Cups (`libcups.so.2`), which the Debian control file omits, plus libsecret. `wayland`, `pulseaudio`, and `libnotify` add the libraries the ELF dlopens. `apparmor` installs `resources/apparmor-profile` for `/opt/Grok Bot/grok-bot`. `suid` sets `chrome-sandbox` to `4755`; the default leaves the upstream `0755`. The launcher does not pass `--no-sandbox`.

`RESTRICT="bindist mirror strip"`. `QA_PREBUILT` covers `opt/Grok Bot`. No `src_test`.

Alternative considered: the apt pool URL `grok-bot_${PV}_amd64.deb`, which needs no commit. Rejected because 0.61.0 was on the CDN feed and not in the pool, so a bump to the feed version would manifest a 404.

### Where the rewrite sits

The existing GitMv path already copies the newest ebuild and can edit a single field before manifest (the slot pin). The commit assignment is the same kind of edit, limited to this package, and it runs after the rename and before `ebuild manifest`. Other GitMv packages stay body-unchanged apart from the slot pin.

### Tests

Fixture feeds return JSON. Assert the parsed PV, the arch-mismatch error, the commit rewrite, preservation of `IUSE`, and the hard-fail when `debUrl` does not match the template. The policy lookup test gains `dev-util/grok-bot-bin`. No emerge in the unit tests. The seed emerge is an operator check: `/usr/bin/grok-bot` resolves to the installed ELF. A GUI login is not a gate.

## Risks / Trade-offs

- [Cursor renames `grok-bot_<version>_<arch>.deb`] → apply hard-fails on `debUrl` instead of writing a 404 into the Manifest. The ebuild template stays put until the filename rule is updated on purpose.
- [linux-arm64 ships a different commit than linux-x64] → one `GROK_BOT_COMMIT` cannot name both. Apply hard-fails. Splitting into two variables is a later change.
- [A release lands between planning and apply] → the apply-time version check refuses the bump rather than pairing a new commit with the old PV.
- [`suid` on a path that contains a space] → upstream's own `postinst` says the setuid helper cannot `exec` from `/opt/Grok Bot`. The flag still sets the mode bit; user namespaces are the working sandbox, which is why `suid` defaults off.
- [Seed manifest downloads about 99 MB and 94 MB] → within the existing GitMv distfile floor. Manifest needs network access to Cursor.

## Migration Plan

Add the policy and the seed ebuild together. `outdated grok-bot-bin` on 0.61.0 reports current until the feed moves. Rollback is removing the policy entry and the overlay package; nothing else consumes it.

No open questions. The spike closed the sandbox default, the `sand` symlink, the USE line, and the license.
