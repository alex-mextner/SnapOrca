# shellcheck shell=bash
# Shared helpers for the GUI test drivers (driver.sh, fix-model-driver.sh); sourced INSIDE the
# container (or on the throwaway machine of SO_DIRECT=1), never on the laptop. The caller sets W
# (work dir) before sourcing and RUNNER (pid of app-runner.py) once the app is started; wait_win
# stops early when RUNNER is gone.
# Provides: log, shot, start_display (fake browsers + private Xvfb :99 + openbox), wait_win,
# wait_gone, wait_line, click_button, close_window, close_wizard, close_main.

export DISPLAY=:99 HOME=$W/home APPIMAGE_EXTRACT_AND_RUN=1 NO_AT_BRIDGE=1
RUNNER=''

log() { echo "$(date +%T) $*" | tee -a "$W/driver.log"; }
shot() { import -window root "$W/shots/$1.png" 2>/dev/null && log "screenshot shots/$1.png"; }

# start_display: every browser-launch path the app can take logs to browser.log instead of opening
# anything; then a private Xvfb display with openbox as window manager.
start_display() {
    mkdir -p "$W/fakebin" "$W/shots" "$HOME"
    for b in xdg-open x-www-browser sensible-browser www-browser firefox gio gnome-open kde-open; do
        # shellcheck disable=SC2016 # $(date) and $* expand in the fake browser script
        printf '#!/bin/sh\necho "$(date +%%T) BROWSER-LAUNCH via %s: $*" >> %s/browser.log\n' "$b" "$W" >"$W/fakebin/$b"
        chmod +x "$W/fakebin/$b"
    done
    export PATH=$W/fakebin:$PATH BROWSER=$W/fakebin/xdg-open

    Xvfb :99 -screen 0 1600x1000x24 -nolisten tcp >"$W/xvfb.log" 2>&1 &
    for _ in $(seq 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.2; done
    xdpyinfo >/dev/null 2>&1 || { log "Xvfb did not start"; return 1; }
    openbox >"$W/openbox.log" 2>&1 &
}

# wait_win REGEX SECONDS: print the id of the first visible window whose title matches.
# Polls `xdotool search` (instead of --sync) so a crashed app ends the wait at once.
wait_win() {
    local end=$((SECONDS + $2)) wid
    while ((SECONDS < end)); do
        wid=$(xdotool search --onlyvisible --name "$1" 2>/dev/null | head -n1)
        [ -n "$wid" ] && { echo "$wid"; return 0; }
        kill -0 "$RUNNER" 2>/dev/null || return 1
        sleep 0.5
    done
    return 1
}

# wait_gone WID SECONDS: wait until the window is unmapped or destroyed.
wait_gone() {
    local end=$((SECONDS + $2))
    while ((SECONDS < end)); do
        xdotool search --onlyvisible --name . 2>/dev/null | grep -qx "$1" || return 0
        sleep 0.3
    done
    return 1
}

# wait_line FILE REGEX SECONDS: wait until a line matching REGEX appears in FILE.
wait_line() {
    local end=$((SECONDS + $3))
    while ((SECONDS < end)); do
        grep -qE "$2" "$1" 2>/dev/null && return 0
        sleep 0.5
    done
    return 1
}

# click_button WID DX DY ABS_X ABS_Y NAME: move the dialog to a fixed spot (openbox may place it
# partly off-screen) and click at offset DX,DY from its top-left corner. If the window is still
# there afterwards, retry at the absolute screen position measured on the default layout.
click_button() {
    local wid=$1 X Y WIDTH HEIGHT
    xdotool windowmove --sync "$wid" 100 100 2>/dev/null
    sleep 0.5
    eval "$(xdotool getwindowgeometry --shell "$wid" | grep -E '^(X|Y|WIDTH|HEIGHT)=')"
    shot "click-$6"
    log "click $6 at $((X + $2)),$((Y + $3)) (window $wid ${WIDTH}x${HEIGHT}+$X+$Y)"
    xdotool mousemove --sync $((X + $2)) $((Y + $3)) click 1
    wait_gone "$wid" 5 && return 0
    log "window $wid still open, fallback click $6 at $4,$5"
    xdotool mousemove --sync "$4" "$5" click 1
    wait_gone "$wid" 5
}

# close_window WID NAME: WM close request (as the title bar [x]), via _NET_CLOSE_WINDOW.
close_window() {
    log "close $2 (window $1)"
    wmctrl -i -c "$1"
    wait_gone "$1" 20
}

# close_wizard SHOT_PREFIX [SECONDS]: the setup wizard opens on every start with a fresh datadir
# (it is never completed); the update check runs after it is closed.
close_wizard() {
    local wid
    if ! wid=$(wait_win '^Setup Wizard' "${2:-180}"); then
        log "no Setup Wizard window"
        return 1
    fi
    sleep 2 # let the wizard's web view settle before closing it
    shot "$1-wizard"
    close_window "$wid" "Setup Wizard" || log "Setup Wizard did not close"
}

# close_main: close the main window (titled after the open project, "*Untitled" when empty).
close_main() {
    local wid
    wid=$(wait_win 'Untitled' 30) || return 1
    shot "$1-main-window"
    close_window "$wid" "main window"
}
