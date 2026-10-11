#!/usr/bin/env bash
# End-to-end GUI test of "Fix model" -> arrange -> slice -> save on a real project, fully headless
# and inside docker (same container as update-test.sh: no devices, no network, private Xvfb), or
# with SO_DIRECT=1 on a throwaway machine's own Xvfb (remote-test.sh runs it so on a Runpod pod).
# Fix model is in the Linux object-list menu only with the CGAL repair port (branch fixmodel/ubuntu);
# upstream builds offer it on Windows only, so test those with SO_FIX=0.
# Usage: scripts/ubuntu2604/gui-test/fix-model-test.sh [AppImage] PROJECT
#   AppImage defaults to the newest build/Snapmaker_Orca_Linux_V*.AppImage; it is copied, never modified.
#   PROJECT is a .3mf project or a model file (.step/.stp/.stl...) given to the app on the command line;
#   it is copied into the results and the copy is removed afterwards.
# The driver (fix-model-driver.sh) screenshots the plate before and after Fix model, after arranging
# and after slicing, then saves the project as saved.3mf; analyze-3mf.py checks that file outside the driver.
# Env: SO_OUT=DIR results root (default ${TMPDIR:-/tmp}/snap-orca-gui-test)
#      SO_FIX=0 skip Fix model (e.g. a STEP import that must load without mesh errors)
#      SO_ANALYZE_ARGS="--count N --volume V --size X,Y,Z" expectations for the saved 3MF
#      SO_PYTHON=python with numpy (+ trimesh) for analyze-3mf.py (default python3)
#      SO_FIX_TIMEOUT, SO_SLICE_TIMEOUT seconds (default 900 each)
#      SO_DIRECT=1 no docker: run the driver on this machine (only a throwaway test machine, see host-lib.sh)
#      SO_LOCAL=1 run in the local docker container. Required unless SO_DIRECT=1: the documented path
#                 is remote-test.sh on a Runpod pod, because a Fix model run on a big project takes
#                 minutes of full CPU and GBs of RAM, and the app must never run on the laptop itself.
# Exit status: 0 all checks passed, 1 a check failed, 2 usage/setup error.
set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
ROOT=$(readlink -f "${HERE}/../../..")
# shellcheck source=host-lib.sh
. "${HERE}/host-lib.sh"
export SO_FIX=${SO_FIX:-1} SO_FIX_TIMEOUT=${SO_FIX_TIMEOUT:-900} SO_SLICE_TIMEOUT=${SO_SLICE_TIMEOUT:-900}
# shellcheck disable=SC2034 # read by run_driver
DRIVER_ENV='SO_FIX SO_FIX_TIMEOUT SO_SLICE_TIMEOUT'

if [[ "${SO_DIRECT:-0}" != 1 && "${SO_LOCAL:-0}" != 1 ]]; then
    echo "fix-model-test.sh: use remote-test.sh to run it on a Runpod pod, or SO_LOCAL=1 for the local container" >&2
    exit 2
fi
if [[ $# -ge 2 ]]; then SRC=$1 PROJECT=$2; else SRC='' PROJECT=${1:-}; fi
# shellcheck disable=SC2012 # newest by mtime; build file names have no special characters
SRC=${SRC:-$(ls -t "${ROOT}"/build/Snapmaker_Orca_Linux_V*.AppImage 2>/dev/null | head -n1 || true)}
[[ -f "${SRC}" ]] || { echo "AppImage not found: ${SRC:-${ROOT}/build/Snapmaker_Orca_Linux_V*.AppImage}" >&2; exit 2; }
[[ -f "${PROJECT}" ]] || { echo "usage: $0 [AppImage] PROJECT (project not found: ${PROJECT})" >&2; exit 2; }
PY=${SO_PYTHON:-python3}
"${PY}" -c 'import numpy' 2>/dev/null || { echo "${PY} has no numpy; set SO_PYTHON" >&2; exit 2; }

NAME=$(basename "${PROJECT}")
OUT=${SO_OUT:-${TMPDIR:-/tmp}/snap-orca-gui-test}/fixmodel-${NAME%.*}$([[ "${SO_FIX}" = 0 ]] && echo -nofix)-$(date +%Y%m%d-%H%M%S)
mkdir -p "${OUT}"/{app,data,proj,shots}
OUT=$(readlink -f "${OUT}")
prepare_driver "${OUT}"

# Results keep sha.txt instead of the AppImage and the project copy.
cleanup() {
    stop_driver
    rm -rf "${OUT:?}/app" "${OUT:?}/proj" "${OUT:?}/fakebin" "${OUT:?}/home"
    if [[ -d "${OUT}/data/log" ]]; then mv "${OUT}/data/log" "${OUT}/applog"; fi
    rm -rf "${OUT}/data"
}
trap cleanup EXIT

cp "${SRC}" "${OUT}/app/"
chmod 755 "${OUT}"/app/*.AppImage
cp "${PROJECT}" "${OUT}/proj/"
printf 'appimage %s %s\nproject %s %s\n' "$(sha256sum "${SRC}" | cut -c1-64)" "${SRC}" \
    "$(sha256sum "${PROJECT}" | cut -c1-64)" "${PROJECT}" >"${OUT}/sha.txt"
# Fresh datadir: the setup wizard opens on start and is closed by the driver. STEP files import
# with the default deflections (0.003 mm / 0.5) instead of asking in the "Step file import
# parameters" dialog (its OK does the same, but the dialog ignores Return).
cat >"${OUT}/data/Snapmaker_Orca.conf" <<EOF
{"app": {"skip_3dmouse_detect": "true", "log_severity_level": "info", "enable_step_mesh_setting": "false"}}
EOF

echo "results: ${OUT}"
set +e
run_driver "${OUT}" fix-model-driver.sh
FLOW_RC=$?
set -e

# ---- evidence ----
# shellcheck disable=SC2012 # newest by mtime; app log names have no special characters
APPLOG=$(ls -t "${OUT}"/data/log/*.log* 2>/dev/null | head -n1 || true)
step_line() { sed -nE "s/^[0-9:]+ step=$1 applog_line=([0-9]+)/\1/p" "${OUT}/events.log" 2>/dev/null | tail -n1; }
LOADED=$(step_line loaded)
SAVED_AT=$(step_line saved)
# App log after the project was loaded: repair / arrange / slice lines and every error.
if [[ -n "${APPLOG}" ]]; then
    tail -n +"${LOADED:-1}" "${APPLOG}" |
        grep -aiE 'repair|cgal|fix_model|arrange:|ArrangeJob|Slicing process|process_completed_with_error|export G-code|Exporting G-code|_save_model_to_file:.*finished|^\[(error|fatal)\]|exception' \
            >"${OUT}/app-log-excerpt.txt" || true
fi
# Known noise of the offline container (no network, no D-Bus, no 3D mouse, fresh datadir).
NOISE='spacenavd|[Dd][Bb]us|resolv|curl|Orca Updater|Profile staging|atomic_replace_directory|calc_exclude_triangles|tree_sel_change_delayed|SMUserLogin|WEBVIEW|JavaScript|check_new_version'
# Errors between "project loaded" and "project saved"; shutdown lines (lockfile, health check) follow.
if [[ -n "${APPLOG}" ]]; then
    sed -n "${LOADED:-1},${SAVED_AT:-\$}p" "${APPLOG}" | grep -aE '^\[(error|fatal)\]' | grep -avE "${NOISE}" >"${OUT}/app-errors.txt" || true
else
    echo "no app log in ${OUT}/data/log" >"${OUT}/app-errors.txt"
fi

if [[ "${NAME,,}" == *.3mf ]]; then
    "${PY}" "${HERE}/analyze-3mf.py" "${PROJECT}" >"${OUT}/input-analysis.txt" || true
fi
ANALYZE_RC=2
if [[ -s "${OUT}/saved.3mf" ]]; then
    set +e
    # shellcheck disable=SC2086 # SO_ANALYZE_ARGS is a list of options
    "${PY}" "${HERE}/analyze-3mf.py" "${OUT}/saved.3mf" ${SO_ANALYZE_ARGS:-} --json "${OUT}/saved-analysis.json" >"${OUT}/saved-analysis.txt" 2>&1
    ANALYZE_RC=$?
    set -e
fi

# ---- checks ----
FAILED=0
check() { # check NAME DETAIL COMMAND...: PASS when COMMAND succeeds
    local name=$1 detail=$2
    shift 2
    if "$@"; then echo "CHECK PASS ${name}: ${detail}"; else echo "CHECK FAIL ${name}: ${detail}"; FAILED=1; fi
}
has_step() { [[ -n "$(step_line "$1")" ]]; }
{
    if [[ -f "${OUT}/input-analysis.txt" ]]; then
        echo "input: $(grep -c '^CHECK FAIL .* 0 open edges' "${OUT}/input-analysis.txt" || true) object(s) with open edges before the fix"
    fi
    check "scripted flow completed" "driver exit ${FLOW_RC}, see driver.log" test "${FLOW_RC}" = 0
    if [[ "${SO_FIX}" = 1 ]]; then
        check "Fix model ran" "events.log step=fix_done" has_step fix_done
    fi
    check "arrange ran" "events.log step=arrange_done (ArrangeJob in the app log)" has_step arrange_done
    check "slicing finished" "events.log step=slice_done ('Slicing process finished')" has_step slice_done
    check "no slicing error" "$(grep -acE 'process_completed_with_error=[0-9]' "${OUT}/app-log-excerpt.txt" 2>/dev/null || true) process_completed_with_error>=0 line(s)" \
        bash -c "! grep -qE 'process_completed_with_error=[0-9]' '${OUT}/app-log-excerpt.txt' 2>/dev/null"
    check "no unexpected app errors from load to save" "$(wc -l <"${OUT}/app-errors.txt" 2>/dev/null || echo '?') line(s) in app-errors.txt" \
        test ! -s "${OUT}/app-errors.txt"
    check "project saved" "saved.3mf $(stat -c %s "${OUT}/saved.3mf" 2>/dev/null || echo missing) bytes" test -s "${OUT}/saved.3mf"
    if [[ -f "${OUT}/saved-analysis.txt" ]]; then
        grep '^CHECK ' "${OUT}/saved-analysis.txt" | sed 's/^CHECK \(PASS\|FAIL\) /CHECK \1 saved 3MF: /'
        check "saved 3MF analysis" "analyze-3mf.py exit ${ANALYZE_RC}, see saved-analysis.txt" test "${ANALYZE_RC}" = 0
    fi
} | tee "${OUT}/summary.txt"
grep -q '^CHECK FAIL' "${OUT}/summary.txt" && FAILED=1
echo "results: ${OUT}"
if [[ ${FAILED} = 0 ]]; then echo "RESULT: PASS" | tee -a "${OUT}/summary.txt"; else echo "RESULT: FAIL" | tee -a "${OUT}/summary.txt"; exit 1; fi
