#!/usr/bin/env bash
# End-to-end GUI test of the AppImage self-update flow, fully headless and inside docker, or with
# SO_DIRECT=1 on a throwaway machine's own Xvfb (remote-test.sh runs it so on a Runpod pod).
# Usage: scripts/ubuntu2604/gui-test/update-test.sh [normal|force] [AppImage]
#   normal: optional update; answers "Restart now?" with Yes and expects a relaunch with --datadir.
#   force:  forced update; answers No and expects the app to close without relaunch.
#   AppImage defaults to the newest build/Snapmaker_Orca_Linux_V*.AppImage; it is copied, never modified.
# A local HTTP server in the container serves a manifest offering a marked copy of the same AppImage
# (trailing bytes, so it has a different sha256), and the copied app's config points
# orca_upgrade_url at it. The container gets no devices, no host X socket and no network
# (--network none): the app cannot touch host USB devices or the user's screen.
# Env: SO_OUT=DIR results root (default ${TMPDIR:-/tmp}/snap-orca-gui-test)
#      SO_RO=1 read-only app dir: control run, Download must fall back to the browser
#      SO_VERSION=X.Y.Z manifest version when the AppImage name has no _V<version>
#      SO_DIRECT=1 no docker: run the driver on this machine (only a throwaway test machine, see host-lib.sh)
# Exit status: 0 all checks passed, 1 a check failed, 2 usage/setup error.
set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
ROOT=$(readlink -f "${HERE}/../../..")
# shellcheck source=host-lib.sh
. "${HERE}/host-lib.sh"
export SO_RO=${SO_RO:-0}
# shellcheck disable=SC2034 # read by run_driver
DRIVER_ENV=SO_RO

VARIANT=${1:-normal}
case "${VARIANT}" in
    normal | force) ;;
    *) sed -n '2,14p' "$0" >&2; exit 2 ;;
esac
# shellcheck disable=SC2012 # newest by mtime; build file names have no special characters
SRC=${2:-$(ls -t "${ROOT}"/build/Snapmaker_Orca_Linux_V*.AppImage 2>/dev/null | head -n1 || true)}
[[ -f "${SRC}" ]] || { echo "AppImage not found: ${SRC:-${ROOT}/build/Snapmaker_Orca_Linux_V*.AppImage}" >&2; exit 2; }
VERSION=${SO_VERSION:-$(basename "${SRC}" | sed -nE 's/.*_V([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')}
[[ -n "${VERSION}" ]] || { echo "cannot derive the version from ${SRC}; set SO_VERSION" >&2; exit 2; }

OUT=${SO_OUT:-${TMPDIR:-/tmp}/snap-orca-gui-test}/${VARIANT}$([[ "${SO_RO:-0}" = 1 ]] && echo -ro)-$(date +%Y%m%d-%H%M%S)
mkdir -p "${OUT}"/{app,srv,data,shots}
OUT=$(readlink -f "${OUT}")
prepare_driver "${OUT}"
APP=${OUT}/app/$(basename "${SRC}")
PORT=18765 # must match driver.sh

# Results keep sha.txt instead of the two 100+ MB AppImages.
cleanup() {
    stop_driver
    chmod 755 "${OUT}/app"
    rm -f "${APP}" "${OUT}/srv/new.AppImage"
}
trap cleanup EXIT

cp "${SRC}" "${APP}"
chmod 755 "${APP}"
# A newer fork build of the same version; the trailing marker is ignored by the AppImage runtime.
cp "${SRC}" "${OUT}/srv/new.AppImage"
printf 'snap-orca gui-test fork_build 9999\n' >>"${OUT}/srv/new.AppImage"
OLD_SHA=$(sha256sum "${APP}" | cut -c1-64)
NEW_SHA=$(sha256sum "${OUT}/srv/new.AppImage" | cut -c1-64)
printf 'source %s\noriginal %s\nmanifest %s\n' "${SRC}" "${OLD_SHA}" "${NEW_SHA}" >"${OUT}/sha.txt"
FORCE=$([[ "${VARIANT}" = force ]] && echo true || echo false)
cat >"${OUT}/srv/manifest.json" <<EOF
{"code":200,"message":"OK","data":{"version":"${VERSION}","fork_build":9999,"release_type":"stable","platform_type":"linux",
 "is_force_upgrade":${FORCE},"full":{"file_describe":"gui-test notes (${VARIANT} variant)",
 "default":{"file_url":"http://127.0.0.1:${PORT}/new.AppImage","file_sha256":"${NEW_SHA}","file_size":$(stat -c %s "${OUT}/srv/new.AppImage")}}}}
EOF
# Seed a fresh datadir: missing keys get defaults, the setup wizard opens on every start.
cat >"${OUT}/data/Snapmaker_Orca.conf" <<EOF
{"app": {"orca_upgrade_url": "http://127.0.0.1:${PORT}/manifest.json", "skip_3dmouse_detect": "true",
         "log_severity_level": "info"}}
EOF
# Read-only control: not self-updatable, so Download must fall back to the browser.
[[ "${SO_RO:-0}" = 1 ]] && chmod 555 "${OUT}/app"

echo "results: ${OUT}"
set +e
run_driver "${OUT}" driver.sh "${VARIANT}"
FLOW_RC=$?
set -e
FINAL_SHA=$(sha256sum "${APP}" | cut -c1-64)
echo "final ${FINAL_SHA}" >>"${OUT}/sha.txt"

# ---- checks ----
FAILED=0
check() { # check NAME DETAIL COMMAND...: PASS when COMMAND succeeds
    local name=$1 detail=$2
    shift 2
    if "$@"; then echo "PASS  ${name}  (${detail})"; else echo "FAIL  ${name}  (${detail})"; FAILED=1; fi
}
event() { { sed -nE "s/^[0-9:]+ $1=(.*)/\1/p" "${OUT}/events.log" 2>/dev/null || true; } | tail -n1; }
FIRST_EXIT=$(event first_exit)
BROWSER=$(cat "${OUT}/browser.log" 2>/dev/null || true)
INSTALLED=$(grep -aho 'AppImage update: installed .*' "${OUT}"/data/log/* 2>/dev/null | head -n1 || true)

check "scripted flow completed" "driver exit ${FLOW_RC}, see driver.log" test "${FLOW_RC}" = 0
if [[ "${SO_RO:-0}" = 1 ]]; then
    check "AppImage unchanged" "${FINAL_SHA}" test "${FINAL_SHA}" = "${OLD_SHA}"
    check "browser fallback launched" "${BROWSER:-no browser.log}" grep -q new.AppImage "${OUT}/browser.log"
else
    check "app log: update installed" "${INSTALLED:-no such line}" test -n "${INSTALLED}"
    check "AppImage sha == manifest sha" "${FINAL_SHA}" test "${FINAL_SHA}" = "${NEW_SHA}"
    check "no browser launch" "${BROWSER:-browser.log empty}" test -z "${BROWSER}"
fi
check "first instance exit code 0" "exit=${FIRST_EXIT:-none}" test "${FIRST_EXIT}" = 0
RELAUNCH=$(event relaunch_cmd)
if [[ "${VARIANT}" = normal && "${SO_RO:-0}" != 1 ]]; then
    RELAUNCH_EXIT=$(event relaunch_exit)
    check "relaunched instance has --datadir" "${RELAUNCH:-no relaunch}" grep -q -- "--datadir ${DRIVER_WORK}/data" <<<"${RELAUNCH}"
    check "relaunched instance exit code 0" "exit=${RELAUNCH_EXIT:-none}" test "${RELAUNCH_EXIT}" = 0
else
    check "no relaunch" "${RELAUNCH:-none}" test -z "$(event relaunch_pid)"
fi
echo "results: ${OUT}"
if [[ ${FAILED} = 0 ]]; then echo "RESULT: PASS (${VARIANT})"; else echo "RESULT: FAIL (${VARIANT})"; exit 1; fi
