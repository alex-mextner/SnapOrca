#!/usr/bin/env bash
# Builds Snapmaker Orca on a temporary Runpod CPU pod instead of this machine: dependencies (or a
# cached copy of them), the slicer, the AppImage and the tests, then runs ctest there and copies the
# AppImage into build/. The pod is deleted when this script exits; as backstops a detached local
# process, and the pod itself when Runpod gives it its credentials, delete it after RUNPOD_MAX_HOURS.
#
#   scripts/ubuntu2604/remote-build.sh
#
# The pod checks out HEAD from the fork (pushed to a temporary remote-build/<sha> branch, deleted
# afterwards) and receives uncommitted changes over rsync, so the build matches the working tree.
#
# Caches live on a Runpod network volume (RUNPOD_VOLUME, created on first use in RUNPOD_DC and
# mounted at /workspace): the built dependencies per deps/ tree + provision.sh, the ccache of the
# slicer and tests (ccache remote storage, written and read entry by entry), and ninja's build log
# (so the longest units start first). A pod that cannot get that data center falls back to building
# everything uncached in RUNPOD_POD_DCS (comma list, tried in order; also the data centers of every
# pod without the volume). Flavors are tried in RUNPOD_CPU_FLAVORS order.
#
# RUNPOD_VCPU sets the pod size; by default a pod with the volume and a dependencies key gets 16 vCPU
# (the slicer mostly comes from ccache, and a deps cache miss costs about the same in pod-hours at 16),
# a pod that must build the dependencies anyway (no volume, modified deps/) gets 32.
#
# Runpod sometimes schedules a pod that never starts (no runtime, no SSH port) while reporting the
# data center's stock as high. A pod without an SSH port after RUNPOD_START_MINUTES is deleted and
# replaced once, uncached, in the data centers of RUNPOD_POD_DCS after the one that failed.
#
# Needs: a Runpod API key (RUNPOD_API_KEY, or ~/.runpod/config.toml from `runpodctl doctor`), git
# push access to FORK_REPO, and an SSH key (SSH_KEY, default ~/.ssh/id_ed25519).
# Exit codes: 11 build failed, 12 tests failed, other non-zero: pod / transfer errors.
set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
cd "$ROOT"
# The pod builds at the main checkout's path even when this runs from a linked worktree: cached
# dependencies embed absolute paths (wx-config is a symlink into deps/build/destdir).
POD_ROOT=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")

FORK_REPO=${FORK_REPO:-alex-mextner/SnapOrca}
FLAVORS=${RUNPOD_CPU_FLAVORS:-cpu5c,cpu3c} # compute-optimized, 2 GB RAM per vCPU
MAX_HOURS=${RUNPOD_MAX_HOURS:-3}
VOLUME=${RUNPOD_VOLUME:-snap-orca-cache}
VOLUME_DC=${RUNPOD_DC:-EU-RO-1}            # has cpu5c and cpu3c
# Secure-cloud data centers with cpu5c (the first two) or cpu3c, Europe first.
POD_DCS=${RUNPOD_POD_DCS:-EUR-IS-1,EU-RO-1,EU-NL-1,EU-CZ-1,EU-SE-1,US-IL-1,US-KS-2,US-GA-2,US-WA-1,US-CA-2}
POD_DCS=${POD_DCS//[[:space:]]/}
START_MINUTES=${RUNPOD_START_MINUTES:-4}
VOLUME_GB=${RUNPOD_VOLUME_GB:-20}          # ~$0.07/GB/month
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
API=https://rest.runpod.io/v1

die() { echo "remote-build.sh: $1" >&2; exit "${2:-1}"; }
step() { printf '== [%dm%02ds] %s\n' $((SECONDS / 60)) $((SECONDS % 60)) "$*"; }

api_key=${RUNPOD_API_KEY:-$(sed -nE 's/^apikey *= *"(.*)"/\1/p' "$HOME/.runpod/config.toml" 2>/dev/null || true)}
[[ -n $api_key ]] || die "no Runpod API key: set RUNPOD_API_KEY or run runpodctl doctor"
[[ -r $SSH_KEY.pub ]] || die "missing $SSH_KEY.pub"
[[ $START_MINUTES =~ ^[1-9][0-9]*$ ]] || die "RUNPOD_START_MINUTES must be a positive integer"
# Key passed through a curl config on stdin, not argv (visible in ps).
api() { printf 'header = "Authorization: Bearer %s"\n' "$api_key" | curl -fsS -m 60 -K - -H 'Content-Type: application/json' "$@"; }
# api_status URL: the HTTP status of a GET, 000 when there was no response.
api_status() { printf 'header = "Authorization: Bearer %s"\n' "$api_key" | curl -sS -m 60 -K - -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true; }
# field KEY [SUBKEY]: value from the JSON object on stdin, empty when missing or not JSON.
field() {
    python3 -c 'import json, sys
try:
    v = json.load(sys.stdin)
    for k in sys.argv[1:]:
        v = v.get(k) if isinstance(v, dict) else None
except ValueError:
    v = None
print("" if v is None else v)' "$@"
}

tmp=$(mktemp -d)
sha=$(git rev-parse HEAD)
build_ref=refs/heads/remote-build/$sha
fork_url=https://github.com/$FORK_REPO.git
pod_id=""
watchdog_pid=""

cleanup() {
    local rc=$?
    if [[ -n $pod_id ]]; then
        local id=$pod_id
        pod_id=""
        step "deleting pod $id"
        # On failure the detached deleter stays as the last backstop.
        if delete_pod "$id"; then
            [[ -z $watchdog_pid ]] || kill -- "-$watchdog_pid" 2>/dev/null || true # its session: bash + sleep
        fi
    elif [[ -n $watchdog_pid ]]; then
        kill -- "-$watchdog_pid" 2>/dev/null || true
    fi
    git push -q "$fork_url" ":$build_ref" 2>/dev/null || true
    rm -rf "$tmp"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Dependencies cache key: everything that feeds deps/build/destdir (none for a modified tree).
# deps/mesa is a Windows-only prebuilt opengl32.dll that deps/CMakeLists.txt never builds; Snapmaker's
# main has it and the fork does not, so leaving it out lets both share one cached deps archive. The
# provision.sh part hashes the working file: Snapmaker branches carry it uncommitted.
deps_key=""
if [[ -f scripts/ubuntu2604/provision.sh && -z $(git status --porcelain -- deps ':!deps/mesa') ]]; then
    deps_tree=$(git ls-tree HEAD:deps | grep -v $'\tmesa$' | git mktree)
    deps_key="$(cut -c1-12 <<<"$deps_tree")-$(git hash-object scripts/ubuntu2604/provision.sh | cut -c1-8)"
fi
# The pod provisions itself while this script waits for SSH, from the pushed commit's provision.sh;
# a locally modified one is run over SSH after the sync instead.
provision_url=""
if git diff --quiet HEAD -- scripts/ubuntu2604/provision.sh; then
    provision_url="https://raw.githubusercontent.com/$FORK_REPO/$sha/scripts/ubuntu2604/provision.sh"
fi

step "pushing $sha to $build_ref"
git push -q "$fork_url" "$sha:$build_ref" # named by the sha: an existing branch already matches

# A failed lookup builds uncached rather than creating a second volume.
if volumes=$(api "$API/networkvolumes"); then
    volume_id=$(python3 -c 'import json, sys
for v in json.loads(sys.argv[3]):
    if v.get("name") == sys.argv[1] and v.get("dataCenterId") == sys.argv[2]:
        print(v["id"]); break' "$VOLUME" "$VOLUME_DC" "$volumes")
    if [[ -z $volume_id ]]; then
        step "creating cache volume $VOLUME ($VOLUME_GB GB in $VOLUME_DC)"
        volume_id=$(api -X POST "$API/networkvolumes" -d "{\"name\":\"$VOLUME\",\"size\":$VOLUME_GB,\"dataCenterId\":\"$VOLUME_DC\"}" | field id || true)
        [[ -n $volume_id ]] || echo "remote-build.sh: warning: could not create the cache volume, building uncached" >&2
    fi
else
    volume_id=""
    echo "remote-build.sh: warning: could not list network volumes, building uncached" >&2
fi

# Plain ubuntu:26.04: the start command installs and starts sshd, then in the background installs
# the build environment (provision.sh) and unpacks the caches from /workspace.
boot=$(cat <<'EOF'
set -eo pipefail # pipefail: a failed download must not pass as a successful provisioning
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends openssh-server ca-certificates curl git rsync zstd >/dev/null
if [[ -n ${RUNPOD_API_KEY:-} && -n ${RUNPOD_POD_ID:-} ]]; then
    ( sleep "$BUILD_MAX_SECONDS"; curl -fsS -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID" ) &
fi
if [[ -n $BUILD_PROVISION_URL ]]; then
    ( set +e; curl -fsSL "$BUILD_PROVISION_URL" | bash >/root/provision.log 2>&1; echo $? >/root/provision.rc ) &
fi
(
    trap 'touch /root/cache.done' EXIT # whatever fails here, the build step must not wait forever
    mkdir -p "$BUILD_ROOT/deps/build" "$BUILD_ROOT/build" /root/.cache
    # Into a scratch directory first: a truncated archive must not leave a partial destdir behind.
    if [[ -n $BUILD_DEPS_KEY && -f /workspace/deps/$BUILD_DEPS_KEY.tar.zst ]] && mkdir -p /root/deps.tmp &&
        zstd -dcq "/workspace/deps/$BUILD_DEPS_KEY.tar.zst" | tar -x -C /root/deps.tmp &&
        mv /root/deps.tmp/destdir "$BUILD_ROOT/deps/build/destdir"; then
        touch /root/deps.restored
    fi
    rm -rf /root/deps.tmp
    rm -f /workspace/ccache.tar.zst # archive of the previous cache layout
    [[ -f /workspace/ninja_log ]] && cp /workspace/ninja_log "$BUILD_ROOT/build/.ninja_log" || true
) &
mkdir -p /root/.ssh /run/sshd
chmod 700 /root/.ssh
printf '%s\n' "$BUILD_SSH_KEY" >/root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -A
exec /usr/sbin/sshd -D -e
EOF
)
pod_vcpu() { # pod_vcpu VOLUME_ID: the pod's vCPU count (a power of two, flavor maximum is 32)
    if [[ -n ${RUNPOD_VCPU:-} ]]; then echo "$RUNPOD_VCPU"
    elif [[ -n $1 && -n $deps_key ]]; then echo 16
    else echo 32
    fi
}
pod_request() { # pod_request VOLUME_ID FLAVOR DCS: the create body, without a volume when VOLUME_ID is empty
    python3 - "$2" "$(pod_vcpu "$1")" "$((MAX_HOURS * 3600))" "$(cat "$SSH_KEY.pub")" "$boot" "$POD_ROOT" "$deps_key" "$provision_url" \
        "$1" "$VOLUME_DC" "$3" <<'EOF'
import json, sys
flavor, vcpu, max_seconds, pubkey, boot, root, deps_key, provision_url, volume, volume_dc, dcs = sys.argv[1:]
body = {
    "name": "snap-orca-build", "computeType": "CPU", "cloudType": "SECURE",
    "cpuFlavorIds": [flavor], "vcpuCount": int(vcpu),
    "imageName": "ubuntu:26.04", "containerDiskInGb": 100, "ports": ["22/tcp"],
    "env": {"BUILD_SSH_KEY": pubkey, "BUILD_MAX_SECONDS": max_seconds, "BUILD_ROOT": root,
            "BUILD_DEPS_KEY": deps_key, "BUILD_PROVISION_URL": provision_url},
    "dockerStartCmd": ["bash", "-c", boot],
    # Without a list Runpod's default puts EU-RO-1 first; "custom" keeps the given order.
    "dataCenterIds": [volume_dc] if volume else dcs.split(","), "dataCenterPriority": "custom",
}
if volume:
    body.update(networkVolumeId=volume, volumeMountPath="/workspace")
print(json.dumps(body))
EOF
}
# One flavor at a time, in order: with several, Runpod picks by availability (mostly the slower cpu3c).
create_pod() { # create_pod VOLUME_ID DCS: prints the pod JSON of the first flavor that has capacity
    local flavor
    for flavor in ${FLAVORS//,/ }; do
        api -X POST "$API/pods" -d "$(pod_request "$1" "$flavor" "$2")" 2>"$tmp/create.err" && return 0
    done
    echo "remote-build.sh: last pod creation error: $(cat "$tmp/create.err")" >&2
    return 1
}
# delete_pod ID: deletes the pod and waits up to a minute until the API no longer knows it (404).
delete_pod() {
    local code
    api -X DELETE "$API/pods/$1" >/dev/null || true
    for _ in $(seq 12); do
        code=$(api_status "$API/pods/$1")
        [[ $code == 404 ]] && return 0
        sleep 5
    done
    echo "remote-build.sh: pod $1 still exists after deletion (HTTP $code), delete it in the Runpod console" >&2
    return 1
}
# start_pod VOLUME_ID DCS: creates a pod (pod_id, pod_dc, pod) and a backstop deleter for it, then
# waits up to START_MINUTES for its public SSH port (ip, port). Returns 0 with the port, 2 when no
# flavor could be created (no pod), 1 when the pod got no SSH port (left for the caller to delete):
# Runpod sometimes schedules pods that never start a container.
start_pod() {
    pod=$(create_pod "$1" "$2") || return 2
    pod_id=$(field id <<<"$pod")
    # Backstop if this script dies without its EXIT trap (kill -9, crash): a detached deleter, with
    # the key in its environment rather than argv. It does not survive this machine going down; the
    # pod's own deleter (when Runpod gives the pod its credentials, reported below) does.
    [[ -z $watchdog_pid ]] || kill -- "-$watchdog_pid" 2>/dev/null || true
    # shellcheck disable=SC2016 # $RP_KEY and $RP_POD are expanded by the detached bash
    RP_KEY=$api_key RP_POD=$pod_id setsid bash -c "sleep $((MAX_HOURS * 3600)); "'printf "header = \"Authorization: Bearer %s\"\n" "$RP_KEY" | curl -fsS -m 60 -K - -X DELETE "'"$API"'/pods/$RP_POD"' \
        </dev/null >/dev/null 2>&1 &
    watchdog_pid=$!
    ip="" port="" pod_dc=""
    # Where a pod that never gets a machine was meant to go: the first data center asked for.
    first_dc=$2
    [[ -z $1 ]] || first_dc=$VOLUME_DC
    first_dc=${first_dc%%,*}
    local deadline=$((SECONDS + START_MINUTES * 60)) reported=""
    while ((SECONDS < deadline)); do
        pod=$(api "$API/pods/$pod_id?includeMachine=true" || true)
        pod_dc=${pod_dc:-$(field machine dataCenterId <<<"$pod")}
        if [[ -z $reported && -n $pod_dc ]]; then
            step "pod $pod_id in $pod_dc: $(field cpuFlavorId <<<"$pod") $(field vcpuCount <<<"$pod") vCPU $(field memoryInGb <<<"$pod") GB, \$$(field costPerHr <<<"$pod")/h"
            reported=1
        fi
        ip=$(field publicIp <<<"$pod")
        port=$(field portMappings 22 <<<"$pod")
        [[ -n $ip && -n $port ]] && return 0
        sleep 5
    done
    return 1
}
# next_dcs DC: POD_DCS starting after DC, without it (all of POD_DCS when DC is not in it).
next_dcs() {
    local -a dcs=() after=() before=()
    local dc seen=""
    IFS=, read -ra dcs <<<"$POD_DCS"
    for dc in "${dcs[@]}"; do
        if [[ $dc == "$1" ]]; then seen=1
        elif [[ -n $seen ]]; then after+=("$dc")
        else before+=("$dc"); fi
    done
    dcs=("${after[@]}" "${before[@]}")
    (IFS=,; echo "${dcs[*]}")
}

step "creating pod ($(pod_vcpu "$volume_id") vCPU, $FLAVORS, $(if [[ -n $volume_id ]]; then echo "cache volume in $VOLUME_DC"; else echo "in $POD_DCS"; fi))"
rc=0
start_pod "$volume_id" "$POD_DCS" || rc=$?
if ((rc == 2)) && [[ -n $volume_id ]]; then
    echo "remote-build.sh: warning: no capacity next to the cache volume in $VOLUME_DC, building uncached" >&2
    volume_id=""
    rc=0
    start_pod "" "$POD_DCS" || rc=$?
fi
((rc != 2)) || die "pod creation failed"
if ((rc == 1)); then
    # One retry, uncached: the volume would pin the new pod to the same data center.
    stuck_dc=${pod_dc:-$first_dc}
    retry_dcs=$(next_dcs "$stuck_dc")
    retry_dcs=${retry_dcs:-$POD_DCS} # RUNPOD_POD_DCS was only the failed data center
    echo "remote-build.sh: warning: pod $pod_id${stuck_dc:+ in $stuck_dc} got no SSH port in $START_MINUTES min, deleting it and building uncached in $retry_dcs" >&2
    stuck_id=$pod_id
    delete_pod "$stuck_id" || die "could not delete the stuck pod $stuck_id" # cleanup tries again
    pod_id=""
    step "pod $stuck_id deleted"
    volume_id=""
    rc=0
    start_pod "" "$retry_dcs" || rc=$?
    ((rc != 2)) || die "pod creation failed"
    ((rc == 0)) || die "pod $pod_id${pod_dc:+ in $pod_dc} got no SSH port in $START_MINUTES min either"
fi

ssh_opts=(-i "$SSH_KEY" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30
          -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$tmp/known_hosts")
# shellcheck disable=SC2029 # the commands are meant to run on the pod
on_pod() { ssh "${ssh_opts[@]}" "root@$ip" "$@"; }
# on_pod_script ARG...: runs the script on stdin with these arguments (quoted: ssh joins argv into
# one command line, which would drop empty arguments and split ones with spaces).
on_pod_script() { on_pod "bash -s --$(printf ' %q' "$@")"; }
for _ in $(seq 60); do
    on_pod true 2>/dev/null && break
    sleep 5
done
on_pod true || die "pod $pod_id: SSH on $ip:$port does not answer"
step "pod reachable at $ip:$port"
if ! on_pod 'tr "\0" "\n" </proc/1/environ | grep -q "^RUNPOD_API_KEY=." && tr "\0" "\n" </proc/1/environ | grep -q "^RUNPOD_POD_ID=."'; then
    echo "remote-build.sh: warning: Runpod gave the pod no API key, so it cannot delete itself; a pod orphaned by this machine going down keeps billing" >&2
fi

step "checkout"
on_pod_script "$POD_ROOT" "$fork_url" "$sha" <<'EOF'
set -euo pipefail
mkdir -p "$1" && cd "$1"
git init -q && git fetch -q --depth 1 "$2" "$3" && git checkout -q FETCH_HEAD
EOF

# Uncommitted changes: modified and untracked (not ignored) files, and deletions.
git diff --name-only -z HEAD --diff-filter=d >"$tmp/changed"
git ls-files -z -o --exclude-standard >>"$tmp/changed"
if [[ -s $tmp/changed ]]; then
    step "syncing $(tr -cd '\0' <"$tmp/changed" | wc -c) uncommitted files"
    rsync -az --from0 --files-from="$tmp/changed" -e "ssh ${ssh_opts[*]}" ./ "root@$ip:$POD_ROOT/"
fi
deleted=$(git diff --name-only HEAD --diff-filter=D)
if [[ -n $deleted ]]; then
    printf '%s\n' "$deleted" | on_pod "cd '$POD_ROOT' && xargs -d '\n' rm -f --"
fi

step "waiting for provisioning and caches"
on_pod_script "$POD_ROOT" "$provision_url" <<'EOF'
set -euo pipefail
root=$1 provision_url=$2
cd "$root"
wait_for() { # wait_for FILE: up to 20 minutes, for the pod's start command
    local i
    for ((i = 0; i < 1200; i++)); do [[ -f $1 ]] && return 0; sleep 1; done
    echo "timed out waiting for $1" >&2
    return 1
}
if [[ -n $provision_url ]]; then
    wait_for /root/provision.rc || { tail -50 /root/provision.log; exit 1; }
    rc=$(cat /root/provision.rc)
else
    rc=0
    bash scripts/ubuntu2604/provision.sh >/root/provision.log 2>&1 || rc=$?
fi
[[ $rc == 0 ]] || { tail -50 /root/provision.log; exit 1; }
wait_for /root/cache.done
EOF

on_pod_script "$POD_ROOT" "$deps_key" "${volume_id:+1}" "${REMOTE_EXTRA_CMD:-}" "$(field memoryInGb <<<"$pod")" <<'EOF' || { rc=$?; [[ $rc == 12 ]] && die "tests failed on the pod" 12; die "build failed on the pod" 11; }
set -euo pipefail
root=$1 deps_key=$2 volume=$3 extra_cmd=$4 pod_mem_gb=${5%%.*}
cd "$root"
flags=-sitr
[[ -f /root/deps.restored ]] || flags=-dsitr
# Parallel jobs: the vCPUs the pod may use (cgroup quota, nproc shows the host), capped at
# 2 GB of RAM per job (the heaviest libslic3r units need about that much). The RAM is the smallest
# of the host, the cgroup limit and the pod size Runpod reports (the cgroup may say "max").
cpus=$(nproc)
read -r quota period </sys/fs/cgroup/cpu.max 2>/dev/null || quota=max
[[ $quota != max ]] && cpus=$(( quota / period ))
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
[[ $limit != max ]] && (( limit / 1024 < mem_kb )) && mem_kb=$(( limit / 1024 ))
[[ $pod_mem_gb =~ ^[0-9]+$ ]] && (( pod_mem_gb > 0 && pod_mem_gb * 1024 * 1024 < mem_kb )) && mem_kb=$(( pod_mem_gb * 1024 * 1024 ))
jobs=$(( mem_kb / 1024 / 1024 / 2 ))
(( jobs > cpus )) && jobs=$cpus
(( jobs < 1 )) && jobs=1
echo "cpus=$cpus mem=$(( mem_kb / 1024 / 1024 ))G jobs=$jobs flags=$flags"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 CMAKE_BUILD_PARALLEL_LEVEL=$jobs
# ccache for the slicer and tests, stored only on the volume (remote storage: hits are read and
# new results written entry by entry, nothing to unpack or save). pch_defines,time_macros: required
# with precompiled headers; include_file_*: the fresh checkout gives every header a new mtime.
export CCACHE_DIR=/root/.cache/ccache CCACHE_BASEDIR=$root CCACHE_NOHASHDIR=1 CCACHE_COMPILERCHECK=content \
       CCACHE_SLOPPINESS=pch_defines,time_macros,include_file_mtime,include_file_ctime
if [[ -n $volume ]]; then
    mkdir -p /workspace/ccache
    export CCACHE_REMOTE_STORAGE="file:///workspace/ccache|update-mtime=true" CCACHE_REMOTE_ONLY=true
fi
export ORCA_EXTRA_BUILD_ARGS="-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
ccache -z >/dev/null

# Also on failure: report the hit rate, expire entries unused for 30 days (update-mtime marks hits),
# keep ninja's log.
finish() {
    ccache -s | grep -m2 -E '^ *(Hits|Misses):' || true
    [[ -n $volume ]] || return 0
    find /workspace/ccache -type f -mtime +30 -delete 2>/dev/null || true
    [[ ! -f $root/build/.ninja_log ]] || { cp "$root/build/.ninja_log" /workspace/ninja_log.$$ && mv /workspace/ninja_log.$$ /workspace/ninja_log; } ||
        echo "remote-build.sh: warning: could not save the ninja log to the volume" >&2
}
trap finish EXIT

echo "== [$(date +%T)] build_linux.sh $flags"
./build_linux.sh "$flags" || exit 11
if [[ $flags == -dsitr && -n $deps_key && -n $volume ]]; then
    echo "== caching dependencies $deps_key"
    mkdir -p /workspace/deps
    tar -C deps/build -cf - destdir | zstd -T0 -10 -q -o "/workspace/deps/$deps_key.tar.zst.$$"
    mv "/workspace/deps/$deps_key.tar.zst.$$" "/workspace/deps/$deps_key.tar.zst"
    find /workspace/deps -name '*.tar.zst' ! -name "$deps_key.tar.zst" -mtime +30 -delete
fi
# build_linux.sh builds only the Snapmaker_Orca target; -t merely configures the tests.
echo "== [$(date +%T)] tests: build"
cmake --build build --config Release || exit 11
echo "== [$(date +%T)] tests: run"
cd build && ctest -C Release -j1 --output-on-failure || exit 12
# REMOTE_EXTRA_CMD (e.g. repeat a flaky test): counted as a test failure when it fails.
if [[ -n $extra_cmd ]]; then
    echo "== [$(date +%T)] extra: $extra_cmd"
    bash -c "$extra_cmd" || exit 12
fi
EOF

step "fetching the AppImage"
rsync -a -e "ssh ${ssh_opts[*]}" "root@$ip:$POD_ROOT/build/Snapmaker_Orca_Linux_V*.AppImage" build/
step "done: $(ls build/Snapmaker_Orca_Linux_V*.AppImage)"
