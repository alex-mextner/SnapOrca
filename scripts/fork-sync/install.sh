#!/usr/bin/env bash
# Installs a systemd user timer that runs check-upstream.sh every 3 hours (and shortly after boot /
# login if a run was missed). Remove with: systemctl --user disable --now snap-orca-sync.timer
set -euo pipefail

ROOT=$(git -C "$(dirname "$(readlink -f "$0")")" rev-parse --show-toplevel)
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
mkdir -p "$UNIT_DIR"

# Release builds run on Runpod by default (scripts/ubuntu2604/remote-build.sh); review (review-cli)
# reviews release.sh's build bump commit for this host's review-before-commit hook.
for tool in omp gh docker git flock curl python3 rsync ssh review setsid; do
    command -v "$tool" >/dev/null || { echo "install.sh: $tool not found in PATH" >&2; exit 1; }
done

cat >"$UNIT_DIR/snap-orca-sync.service" <<EOF
[Unit]
Description=Merge new Snapmaker Orca releases into the Linux fork and publish them
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
# omp, gh and docker are resolved from the PATH of the user who installed the timer.
Environment=PATH=$PATH
ExecStart=$ROOT/scripts/fork-sync/check-upstream.sh
Nice=10
EOF

cat >"$UNIT_DIR/snap-orca-sync.timer" <<EOF
[Unit]
Description=Check for new Snapmaker Orca releases

[Timer]
OnBootSec=10min
OnCalendar=*-*-* 00/3:00:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now snap-orca-sync.timer
systemctl --user list-timers snap-orca-sync.timer --no-pager
