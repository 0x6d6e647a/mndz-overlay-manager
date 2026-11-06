# Design

## Context

See proposal.md for why the 2.37.1 body cannot move. The overlay tree is clean: `dev-util/kiro-cli-bin/kiro-cli-bin-2.37.1.ebuild` is the only ebuild, and its Manifest lists four `2.37.1` `.tar.xz` distfiles. `GitMvAndManifest` renames that file, then runs `ebuild manifest`. It does not edit the body. `${PV}` comes from the filename.

The live feed `version` is `3.1.0`. All four `3.0.0` and all four `3.1.0` headless `tar.gz` archives unpack to `kirocli/` with `bin/kiro-cli`, `install.sh`, `BUILD-INFO`, and `README`. `S="${WORKDIR}/kirocli"` still matches. x86_64 gnu symbols top out at `GLIBC_2.34`. aarch64 gnu symbols top out at `GLIBC_2.30` and still need `libpthread` and `libdl` from glibc. Both musl binaries have no `DT_NEEDED`. `kiro-cli --version` on the 3.1.0 x86_64 gnu and musl binaries printed `kiro-cli 3.1.0`. `kiro-cli chat` is the chat UI. `kiro-cli term` is an unrecognized subcommand. An argv0 of `kiro-cli-chat` or `kiro-cli-term` still prints `kiro-cli 3.1.0`.

## Goals / Non-Goals

**Goals:**

- One signed overlay commit that replaces `kiro-cli-bin-2.37.1.ebuild` with `kiro-cli-bin-3.0.0.ebuild`, a matching Manifest, and a matching md5-cache.
- A body `update` can rename onto the live feed version without a further edit.
- The operator loop from the original seed: emerge and smoke `3.0.0`, `outdated`, `update`, emerge and smoke the bump, then `FEATURES=test` without `USE=test`.

**Non-Goals:**

- A Haskell or policy change. The `2.31.1` → `2.32.0` apply fixture stays a body-preservation test.
- A second live ebuild, a `-r1`, or an assets release.
- Running `update` before that `3.0.0` commit is clean.

## Decisions

- **Replace `2.37.1` in the seed commit.** Rename the ebuild to `kiro-cli-bin-3.0.0.ebuild` and edit that file. Delete the `2.37.1` md5-cache entry and write `metadata/md5-cache/dev-util/kiro-cli-bin-3.0.0`. Leave `metadata.xml`. Alternative: add `3.0.0` beside `2.37.1`. The later rename would keep the old ebuild. Alternative: hand-write `3.1.0` and skip `update`. That skips the proof this seed exists to provide.
- **Use `.tar.gz`, with the same `-> kirocli-${PV}-…` distfile names.** Upstream basenames omit the version, so the Manifest name still carries `${PV}`. `tar.gz` unpacks in EAPI 8 and is the layout already listed. Alternative: `tar.zst`, which the feed also publishes for the same four triples. It is a second unpack path for no install difference. Deb, rpm, and zip stay out, as they did for the 2.x seed.
- **`doexe bin/kiro-cli` only.** `QA_PREBUILT` is `usr/bin/kiro-cli`. A symlink named `kiro-cli-chat` does not enter the chat subcommand. A wrapper would be a new command the operator declined.
- **No `-r1`.** `3.0.0` has not been merged. The first body is the merged body. The glibc atom stays `elibc_glibc? ( >=sys-libs/glibc-2.34 )`.
- **Manifest and cache before the commit.** From the package directory, `DISTDIR="${HOME}/.cache/mndz/overlay-manager/distfiles" ebuild kiro-cli-bin-3.0.0.ebuild manifest` fetches all four conditional archives. Then `egencache --update --repo mndz` with a `--repositories-configuration` whose `mndz` location is the overlay root. The commit subject is `dev-util/kiro-cli-bin: 3.0.0` with an empty body. Stage the new ebuild, the Manifest, the new md5-cache, and the removal of the `2.37.1` ebuild and md5-cache. Do not push.
- **Smoke is one command.** `kiro-cli --version` prints `kiro-cli <PV>`. Do not use `doctor`, and do not require `kiro-cli-chat` or `figterm`.

## Risks / Trade-offs

- [Risk] The feed moves past `3.1.0` before `update`, and the new archives differ. → `update` follows the live `version`. Before accepting the bump, confirm that feed's four `tar.gz` archives still contain only `bin/kiro-cli` under `kirocli/`. Stop if they do not.
- [Risk] `3.0.0` `tar.gz` URLs disappear before manifest. → Manifest fails and nothing is committed. The `2.37.1` ebuild stays the packaged version.
- [Risk] `update` runs on a dirty ebuild or Manifest. → The unit hard-fails and does not rename. The seed commit has to be clean first.
- [Risk] Callers of `/usr/bin/kiro-cli-chat` and `/usr/bin/kiro-cli-term` break. → Accepted. Chat is `kiro-cli chat`. Term has no successor in the archive.
- [Risk] `update` on the unchanged `2.37.1` body renames the file and then fails manifest, leaving an uncommitted `3.x` ebuild. → Do not run `update` until the `3.0.0` commit is in place.

## Migration Plan

1. Replace the ebuild, regenerate Manifest and md5-cache, and create the signed `3.0.0` commit.
2. The operator emerges `=dev-util/kiro-cli-bin-3.0.0` and smokes `kiro-cli --version`.
3. On a clean tree, `outdated` then `update` on a TTY. The bump renames `3.0.0` away, leaves one `<feed>` ebuild, and commits `dev-util/kiro-cli-bin: <feed>`.
4. The operator emerges that PV, smokes it, then emerges it again with `FEATURES=test` and no `USE=test`, and smokes it again.
5. Sync the delta into the living seed spec and archive the change. The requirement that names `kiro-cli-bin-2.31.1.ebuild` stays.

Rollback is dropping the local overlay commits and re-emerging `2.37.1` while its distfiles are still cached. Do not push.
