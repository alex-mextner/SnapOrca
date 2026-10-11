#!/usr/bin/env bash
# Runs GUI tests on a temporary Runpod CPU pod instead of this machine. The pod (plain ubuntu:26.04)
# gets the build environment (provision.sh, which carries the app's runtime libraries) plus the GUI
# test packages (provision-gui.sh), this harness, and every local file named in a test's arguments
# (AppImages, projects). Each test then runs with SO_DIRECT=1, i.e. on the pod's own Xvfb without
# docker, as an unprivileged user, and the result folders are copied back. The pod is deleted when
# this script exits; as backstops a detached local process, and the pod itself when Runpod gives it
# its credentials, delete it after RUNPOD_MAX_HOURS.
#
#   scripts/ubuntu2604/gui-test/remote-test.sh TEST [:: TEST]...
#   TEST = [SO_VAR=VALUE...] fix-model-test.sh|update-test.sh ARG...
#   e.g. remote-test.sh SO_FIX=0 fix-model-test.sh build/x.AppImage part.stp :: update-test.sh normal build/x.AppImage
#
# Results: SO_OUT (default ${TMPDIR:-/tmp}/snap-orca-gui-test) gets one folder per test, as a local
# run does, plus remote-<time>.log with the console of every test, the pod, its price and run time.
# Needs a Runpod API key (RUNPOD_API_KEY, or ~/.runpod/config.toml from `runpodctl doctor`) and an
# SSH key (SSH_KEY, default ~/.ssh/id_ed25519).
# Env: RUNPOD_CPU_FLAVORS (default cpu5c,cpu3c), RUNPOD_VCPU (default 8), RUNPOD_MAX_HOURS (default 2).
# Exit status: 0 every test passed, 1 a test failed, 2 usage error, other: pod / transfer errors.
set -euo pipefail

HERE=$(dirname "$(readlink -f "$0")")
FLAVORS=${RUNPOD_CPU_FLAVORS:-cpu5c,cpu3c} # compute-optimized, 2 GB RAM per vCPU
VCPU=${RUNPOD_VCPU:-8}
MAX_HOURS=${RUNPOD_MAX_HOURS:-2}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
OUT=${SO_OUT:-${TMPDIR:-/tmp}/snap-orca-gui-test}
API=https://rest.runpod.io/v1
POD_HARNESS=/opt/snap-orca/scripts/ubuntu2604 # same layout as the repository
POD_HOME=/home/gui

die() { echo "remote-test.sh: $1" >&2; exit "${2:-1}"; }
usage() { sed -n '10,12p' "$0" >&2; exit 2; }
step() { printf '== [%dm%02ds] %s\n' $((SECONDS / 60)) $((SECONDS % 60)) "$*" | tee -a "$LOG"; }

# ---- the tests: one command line per test, local files replaced by their pod copies ----
[[ $# -gt 0 ]] || usage
uploads=()  # "LOCAL\tPOD" per distinct local file
tests=()    # shell-quoted command lines run on the pod as the gui user
upload_path() { # upload_path FILE: sets UPLOAD to the pod copy of FILE (each distinct file is sent once, keeping its name)
    local real i
    real=$(readlink -f "$1")
    for i in "${!uploads[@]}"; do
        if [[ ${uploads[i]%%$'\t'*} == "$real" ]]; then UPLOAD=${uploads[i]#*$'\t'}; return; fi
    done
    UPLOAD=$POD_HOME/in/${#uploads[@]}/$(basename "$real")
    uploads+=("$real"$'\t'"$UPLOAD")
}
add_test() { # add_test WORD...: [SO_VAR=VALUE...] SCRIPT ARG...
    local env=() script='' arg line
    while [[ $# -gt 0 && $1 =~ ^SO_[A-Z_]+= ]]; do
        case ${1%%=*} in SO_OUT | SO_PYTHON | SO_DIRECT | SO_WORK) die "$1: set by remote-test.sh" 2 ;; esac
        env+=("$1")
        shift
    done
    case ${1:-} in fix-model-test.sh | update-test.sh) script=$1 ;; *) die "unknown test '${1:-}'" 2 ;; esac
    shift
    line=$(printf '%q ' "${env[@]}" SO_DIRECT=1 "SO_OUT=$POD_HOME/results" bash "$POD_HARNESS/gui-test/$script")
    for arg in "$@"; do
        if [[ -f $arg ]]; then
            upload_path "$arg"
            arg=$UPLOAD
        fi
        line+=$(printf ' %q' "$arg")
    done
    tests+=("$line")
}
words=()
for w in "$@" ::; do
    if [[ $w == :: ]]; then
        [[ ${#words[@]} -gt 0 ]] || usage
        add_test "${words[@]}"
        words=()
    else
        words+=("$w")
    fi
done

api_key=${RUNPOD_API_KEY:-$(sed -nE 's/^apikey *= *"(.*)"/\1/p' "$HOME/.runpod/config.toml" 2>/dev/null || true)}
[[ -n $api_key ]] || die "no Runpod API key: set RUNPOD_API_KEY or run runpodctl doctor"
[[ -r $SSH_KEY.pub ]] || die "missing $SSH_KEY.pub"
# Key passed through a curl config on stdin, not argv (visible in ps).
api() { printf 'header = "Authorization: Bearer %s"\n' "$api_key" | curl -fsS -m 60 -K - -H 'Content-Type: application/json' "$@"; }
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

mkdir -p "$OUT"
LOG=$(readlink -f "$OUT")/remote-$(date +%Y%m%d-%H%M%S).log
tmp=$(mktemp -d)
pod_id=""
pod_start=""
cost=""
ip=""
watchdog_pid=""

fetch_results() {
    [[ -n $ip ]] || return 0
    rsync -a -e "ssh ${ssh_opts[*]}" "root@$ip:$POD_HOME/results/" "$OUT/" 2>>"$LOG" ||
        echo "remote-test.sh: could not copy the results from the pod" | tee -a "$LOG" >&2
}
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
    local rc=$?
    if [[ -n $pod_id ]]; then
        local id=$pod_id
        pod_id=""
        fetch_results
        step "deleting pod $id"
        if api -X DELETE "$API/pods/$id" >/dev/null; then
            local secs=$((SECONDS - pod_start))
            step "pod $id deleted after $((secs / 60))m$((secs % 60))s (\$${cost:-?}/h: about \$$(python3 -c "print(f'{${cost:-0} * $secs / 3600:.3f}')"))"
        else
            echo "remote-test.sh: could not delete pod $id, delete it in the Runpod console" | tee -a "$LOG" >&2
        fi
    fi
    [[ -z $watchdog_pid ]] || kill -- "-$watchdog_pid" 2>/dev/null || true # its session: bash + sleep
    rm -rf "$tmp"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Plain ubuntu:26.04: the start command only installs and starts sshd (and the pod's own deleter);
# provisioning runs over SSH while the inputs upload.
boot=$(cat <<'EOF'
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends openssh-server ca-certificates curl rsync >/dev/null
if [[ -n ${RUNPOD_API_KEY:-} && -n ${RUNPOD_POD_ID:-} ]]; then
    ( sleep "$GUI_MAX_SECONDS"; curl -fsS -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID" ) &
fi
mkdir -p /root/.ssh /run/sshd
chmod 700 /root/.ssh
printf '%s\n' "$GUI_SSH_KEY" >/root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ssh-keygen -A
exec /usr/sbin/sshd -D -e
EOF
)
pod_request() { # pod_request FLAVOR: the create body
    python3 - "$1" "$VCPU" "$((MAX_HOURS * 3600))" "$(cat "$SSH_KEY.pub")" "$boot" <<'EOF'
import json, sys
flavor, vcpu, max_seconds, pubkey, boot = sys.argv[1:]
print(json.dumps({
    "name": "snap-orca-gui-test", "computeType": "CPU", "cloudType": "SECURE",
    "cpuFlavorIds": [flavor], "vcpuCount": int(vcpu),
    "imageName": "ubuntu:26.04", "containerDiskInGb": 30, "ports": ["22/tcp"],
    "env": {"GUI_SSH_KEY": pubkey, "GUI_MAX_SECONDS": max_seconds},
    "dockerStartCmd": ["bash", "-c", boot],
}))
EOF
}

step "${#tests[@]} test(s), ${#uploads[@]} file(s) to upload; results in $OUT"
for t in "${tests[@]}"; do echo "   $t" | tee -a "$LOG"; done
step "creating pod ($VCPU vCPU, $FLAVORS)"
pod=""
for flavor in ${FLAVORS//,/ }; do # one at a time, in order: with several, Runpod picks by availability
    pod=$(api -X POST "$API/pods" -d "$(pod_request "$flavor")" 2>"$tmp/create.err") && break
    pod=""
done
[[ -n $pod ]] || die "pod creation failed: $(cat "$tmp/create.err")"
pod_id=$(field id <<<"$pod")
pod_start=$SECONDS
cost=$(field costPerHr <<<"$pod")
step "pod $pod_id: $(field cpuFlavorId <<<"$pod") $(field vcpuCount <<<"$pod") vCPU $(field memoryInGb <<<"$pod") GB, \$$cost/h"
# Backstop if this script dies without its EXIT trap (kill -9, crash): a detached deleter, with the
# key in its environment rather than argv.
# shellcheck disable=SC2016 # $RP_KEY/$RP_POD expand in the detached shell, not here
RP_KEY=$api_key RP_POD=$pod_id setsid bash -c "sleep $((MAX_HOURS * 3600)); "'printf "header = \"Authorization: Bearer %s\"\n" "$RP_KEY" | curl -fsS -m 60 -K - -X DELETE "'"$API"'/pods/$RP_POD"' \
    </dev/null >/dev/null 2>&1 &
watchdog_pid=$!

port=""
for _ in $(seq 120); do
    pod=$(api "$API/pods/$pod_id" || true)
    ip=$(field publicIp <<<"$pod")
    port=$(field portMappings 22 <<<"$pod")
    [[ -n $ip && -n $port ]] && break
    ip=""
    sleep 5
done
[[ -n $ip ]] || die "pod $pod_id got no public SSH port"
ssh_opts=(-i "$SSH_KEY" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30
          -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$tmp/known_hosts")
# shellcheck disable=SC2029 # commands are built locally on purpose
on_pod() { ssh "${ssh_opts[@]}" "root@$ip" "$@"; }
for _ in $(seq 60); do
    on_pod true 2>/dev/null && break
    sleep 5
done
on_pod true || die "pod $pod_id: SSH on $ip:$port does not answer"
step "pod reachable at $ip:$port"
if ! on_pod 'tr "\0" "\n" </proc/1/environ | grep -q "^RUNPOD_API_KEY=." && tr "\0" "\n" </proc/1/environ | grep -q "^RUNPOD_POD_ID=."'; then
    echo "remote-test.sh: warning: Runpod gave the pod no API key, so it cannot delete itself; a pod orphaned by this machine going down keeps billing" | tee -a "$LOG" >&2
fi

step "provisioning (provision.sh, provision-gui.sh, iproute2, numpy/scipy/trimesh for analyze-3mf.py) while uploading"
on_pod "useradd -m -d $POD_HOME gui && mkdir -p $POD_HARNESS $POD_HOME/results && touch /etc/snap-orca-throwaway"
rsync -a -e "ssh ${ssh_opts[*]}" "$HERE/../provision.sh" "root@$ip:$POD_HARNESS/"
rsync -a --exclude __pycache__ -e "ssh ${ssh_opts[*]}" "$HERE/" "root@$ip:$POD_HARNESS/gui-test/"
on_pod "bash -s" >"$tmp/provision.log" 2>&1 <<EOF &
set -euo pipefail
bash $POD_HARNESS/provision.sh
bash $POD_HARNESS/gui-test/provision-gui.sh
apt-get update
apt-get install -y --no-install-recommends iproute2 python3-numpy python3-scipy
apt-get install -y --no-install-recommends python3-trimesh ||
    { apt-get install -y --no-install-recommends python3-pip && pip install --break-system-packages trimesh; }
rm -rf /var/lib/apt/lists/*
EOF
provision_pid=$!
for u in "${uploads[@]}"; do
    on_pod "mkdir -p '$(dirname "${u#*$'\t'}")'"
    rsync -a -e "ssh ${ssh_opts[*]}" "${u%%$'\t'*}" "root@$ip:${u#*$'\t'}"
done
on_pod "chown -R gui:gui $POD_HOME"
step "uploaded"
if ! wait "$provision_pid"; then
    tail -n 30 "$tmp/provision.log" | tee -a "$LOG"
    die "provisioning failed"
fi
step "provisioned"
# shellcheck disable=SC2016 # expands on the pod
on_pod 'echo "pod: $(nproc) CPUs, /dev/shm $(df -h --output=size /dev/shm | tail -n1 | tr -d " ")"' | tee -a "$LOG"
# The container mode runs the app with --network none; here the pod's network namespace is only
# replaceable when the pod may unshare one (then with loopback up for update-test.sh's local server).
run_as=(runuser -u gui --)
if on_pod "unshare -n -- ip link set lo up" 2>/dev/null; then
    run_as=(unshare -n -- sh -c "'ip link set lo up && exec \"\$@\"'" sh "${run_as[@]}")
    step "network: isolated (unshare -n, loopback only)"
else
    step "network: NOT isolated (the pod may not unshare a network namespace); the app can reach the internet"
fi

failed=0
for t in "${tests[@]}"; do
    step "test: $t"
    set +e
    on_pod "cd $POD_HOME && ${run_as[*]} env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 $t" 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
    set -e
    step "exit $rc"
    [[ $rc == 0 ]] || failed=1
done
fetch_results
step "results copied to $OUT"
exit "$failed"
