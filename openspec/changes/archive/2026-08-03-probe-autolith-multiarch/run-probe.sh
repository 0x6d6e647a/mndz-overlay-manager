#!/usr/bin/env bash
# Full-emerge multiarch probe for seeded dev-util/autolith under QEMU.
# Usage: run-probe.sh <riscv64|ppc64le>
# Sequential policy: run one arch at a time; reclaim container when done.
set -euo pipefail

ARCH="${1:?usage: $0 <riscv64|ppc64le>}"
case "$ARCH" in
  riscv64) PLATFORM=linux/riscv64; GENTOO_ARCH=riscv ;;
  ppc64le) PLATFORM=linux/ppc64le; GENTOO_ARCH=ppc64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 2 ;;
esac

OVERLAY="${OVERLAY:-/home/mndz/repos/com.github/0x6d6e647a/mndz-overlay}"
DISTDIR_HOST="${DISTDIR_HOST:-/var/cache/distfiles}"
STAGE3="${STAGE3:-gentoo/stage3:latest}"
PORTAGE_IMG="${PORTAGE_IMG:-gentoo/portage:latest}"
ATOM="${ATOM:-=dev-util/autolith-0.17.2}"
PORTAGE_CTR="${PORTAGE_CTR:-autolith-probe-portage}"
CTR="autolith-probe-${ARCH}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGDIR="${LOGDIR:-${SCRIPT_DIR}/logs}"
mkdir -p "$LOGDIR"
LOG="${LOGDIR}/${ARCH}.log"

log() { echo "$*" | tee -a "$LOG"; }

: >"$LOG"
log "==> arch=$ARCH platform=$PLATFORM atom=$ATOM"
log "==> overlay=$OVERLAY distdir=$DISTDIR_HOST"
log "$(date -Is)"

# Shared portage tree volume (reuse across arches).
if ! docker inspect "$PORTAGE_CTR" >/dev/null 2>&1; then
  log "==> creating portage volume container $PORTAGE_CTR"
  docker create -v /var/db/repos/gentoo --name "$PORTAGE_CTR" "$PORTAGE_IMG" >/dev/null
fi

# Reclaim prior probe container for this arch.
docker rm -f "$CTR" >/dev/null 2>&1 || true

log "==> starting $CTR"
docker run -d --name "$CTR" \
  --platform "$PLATFORM" \
  --volumes-from "$PORTAGE_CTR" \
  -v "${OVERLAY}:/var/db/repos/mndz:ro" \
  -v "${DISTDIR_HOST}:/var/cache/distfiles" \
  "$STAGE3" \
  sleep infinity

# Wait for qemu-slow start
for _ in $(seq 1 30); do
  if docker exec "$CTR" true 2>/dev/null; then
    break
  fi
  sleep 2
done

uname_m=$(docker exec "$CTR" uname -m)
log "==> container uname -m: $uname_m"
if [[ "$uname_m" != "$ARCH" ]]; then
  log "ERROR: expected uname -m=$ARCH, got $uname_m"
  exit 1
fi

log "==> configuring Portage / overlay"
# Host sticky DISTDIR (1777) blocks container Portage renames of layout/mirror
# cache files under user namespaces. Use a container-local DISTDIR seeded from
# the host mount, and run emerge as root (-userpriv) for reliability under QEMU.
docker exec -i -e GENTOO_ARCH="$GENTOO_ARCH" "$CTR" bash -s <<'INNER' 2>&1 | tee -a "$LOG"
set -euo pipefail
mkdir -p /etc/portage/repos.conf /etc/portage/package.accept_keywords /etc/portage/package.use
mkdir -p /var/cache/distfiles-local
# Seed known Autolith/SBCL distfiles from host bind (best-effort).
cp -an /var/cache/distfiles/autolith-* /var/cache/distfiles-local/ 2>/dev/null || true
cp -an /var/cache/distfiles/sbcl-* /var/cache/distfiles-local/ 2>/dev/null || true
cp -an /var/cache/distfiles/bsd-sockets-* /var/cache/distfiles-local/ 2>/dev/null || true
cp -an /var/cache/distfiles/rust-bin-* /var/cache/distfiles-local/ 2>/dev/null || true
chmod 1777 /var/cache/distfiles-local

cat > /etc/portage/repos.conf/gentoo.conf <<'EOF'
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type =
auto-sync = no
EOF

cat > /etc/portage/repos.conf/mndz.conf <<'EOF'
[mndz]
location = /var/db/repos/mndz
masters = gentoo
auto-sync = no
EOF

printf '%s\n' \
  "*/* ~${GENTOO_ARCH}" \
  "dev-util/autolith" \
  ">=dev-lisp/sbcl-2.6.4" \
  > /etc/portage/package.accept_keywords/autolith-probe

printf '%s\n' "dev-lisp/sbcl source" > /etc/portage/package.use/autolith-probe

# Portage expands ${COMMON_FLAGS} when reading make.conf.
# Prefer official stage3 binhost packages when available (huge QEMU win).
# -userpriv: avoid sticky-DISTDIR rename failures under docker user NS.
cat > /etc/portage/make.conf <<'EOF'
COMMON_FLAGS="-O2 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j2"
FEATURES="-ipc-sandbox -network-sandbox -pid-sandbox -mount-sandbox -userpriv -usersandbox getbinpkg binpkg-request-signature"
DISTDIR="/var/cache/distfiles-local"
EMERGE_DEFAULT_OPTS="--ask=n --verbose --quiet-build=y --keep-going=n --getbinpkg"
ACCEPT_LICENSE="*"
EOF

test -d /var/db/repos/gentoo/profiles
test -d /var/db/repos/mndz/dev-util/autolith
echo "setup OK arch=${GENTOO_ARCH}"
echo "--- accept_keywords ---"
cat /etc/portage/package.accept_keywords/autolith-probe
INNER

log "==> emerge --info (first lines)"
docker exec "$CTR" bash -lc 'emerge --info 2>/dev/null | head -50' 2>&1 | tee -a "$LOG" || true

log "==> emerge -pv ${ATOM}"
docker exec "$CTR" bash -lc "emerge -pv ${ATOM}" 2>&1 | tee -a "$LOG"

log "==> emerge -1 ${ATOM}  (long-running under QEMU)"
set +e
docker exec "$CTR" bash -lc "emerge -1 ${ATOM}" 2>&1 | tee -a "$LOG"
emerge_rc=${PIPESTATUS[0]}
set -e
log "==> emerge exit=$emerge_rc"

if [[ "$emerge_rc" -ne 0 ]]; then
  log "==> FAILED emerge on $ARCH"
  log "$(date -Is)"
  exit "$emerge_rc"
fi

log "==> smoke: autolith --version"
set +e
docker exec "$CTR" bash -lc 'autolith --version; echo exit=$?' 2>&1 | tee -a "$LOG"
smoke_rc=${PIPESTATUS[0]}
set -e

if [[ "$smoke_rc" -ne 0 ]]; then
  log "==> FAILED smoke on $ARCH"
  log "$(date -Is)"
  exit "$smoke_rc"
fi

log "==> SUCCESS $ARCH"
log "$(date -Is)"
exit 0
