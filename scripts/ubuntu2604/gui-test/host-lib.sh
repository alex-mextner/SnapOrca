# shellcheck shell=bash disable=SC2034 # DRIVER_WORK is read by the callers (update-test.sh)
# Host side shared by the GUI tests (update-test.sh, fix-model-test.sh): runs a driver either in the
# snap-orca-guitest container (default: no network, no devices, private Xvfb) or, with SO_DIRECT=1,
# straight on this machine's own Xvfb :99. SO_DIRECT=1 is only for a throwaway test machine without
# a desktop (the Runpod pod of remote-test.sh), never the development laptop: there is no container
# around the app, so it sees the machine's devices and network.
# The caller sets HERE (this directory) and DRIVER_ENV (names of the variables the driver gets).
# Provides prepare_driver, run_driver, stop_driver and DRIVER_WORK (the results directory as the
# driver sees it: /work in the container, the directory itself in direct mode).

IMAGE=snap-orca-guitest:26.04
BASE_IMAGE=snap-orca-build:26.04
CONTAINER=snap-orca-guitest-$$
DRIVER_WORK=''

# prepare_driver OUT: builds the test image on first use (container mode) and sets DRIVER_WORK.
prepare_driver() {
    if [[ "${SO_DIRECT:-0}" = 1 ]]; then
        # remote-test.sh creates this marker on its pod; without it, direct mode would start the
        # app on whatever machine this is, possibly the development laptop.
        [[ -e /etc/snap-orca-throwaway ]] || {
            echo "SO_DIRECT=1 only runs on a remote-test.sh pod (/etc/snap-orca-throwaway missing)" >&2
            exit 2
        }
        DRIVER_WORK=$1
        return
    fi
    DRIVER_WORK=/work
    if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
        docker image inspect "${BASE_IMAGE}" >/dev/null 2>&1 || docker build -t "${BASE_IMAGE}" "${HERE}/.."
        docker build -t "${IMAGE}" --build-arg BASE_IMAGE="${BASE_IMAGE}" "${HERE}"
    fi
}

# run_driver OUT DRIVER [ARG...]: runs DRIVER (a script in HERE) with OUT as its work directory.
run_driver() {
    local out=$1 driver=$2 name env=()
    shift 2
    for name in ${DRIVER_ENV:-}; do env+=("${name}=${!name:-}"); done
    if [[ "${SO_DIRECT:-0}" = 1 ]]; then
        env "${env[@]}" SO_WORK="${out}" bash "${HERE}/${driver}" "$@"
    else
        docker run --rm --name "${CONTAINER}" --network none --shm-size 512m --user "$(id -u):$(id -g)" \
            "${env[@]/#/--env=}" -v "${out}:/work" -v "${HERE}:/harness:ro" "${IMAGE}" bash "/harness/${driver}" "$@"
    fi
}

# stop_driver: removes a container left behind by an interrupted run (direct mode: the driver's
# own EXIT trap stops the app).
stop_driver() {
    [[ "${SO_DIRECT:-0}" = 1 ]] || docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
}
