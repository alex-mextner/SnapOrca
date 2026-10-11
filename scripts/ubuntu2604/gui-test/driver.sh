#!/usr/bin/env bash
# Runs INSIDE the GUI test container (started by update-test.sh), or with SO_DIRECT=1 on a throwaway
# test machine (see host-lib.sh); never on the development laptop.
# Drives the AppImage self-update flow on a private headless Xvfb display: serves the manifest,
# starts the app via app-runner.py, closes the setup wizard, clicks Download, answers the restart
# question (Yes: normal, No: force) and, for normal, closes the relaunched instance.
# Works in SO_WORK (default /work, prepared by update-test.sh); writes driver.log, events.log,
# browser.log, shots/.
# Usage: driver.sh normal|force   Env: SO_RO=1 (read-only control run).
set -u

VARIANT=$1
W=${SO_WORK:-/work}
H=$(dirname "$(readlink -f "$0")")
APP=$(echo "$W"/app/*.AppImage)
EVENTS=$W/events.log
PORT=18765
# shellcheck source=gui-lib.sh
. "$H/gui-lib.sh"

cleanup() {
    shot zz-final
    pkill -f appimage_extracted_ 2>/dev/null
    pkill -f "$APP" 2>/dev/null
    kill "$HTTP_PID" "$RUNNER" 2>/dev/null
}
trap cleanup EXIT
HTTP_PID=''

start_display || exit 1
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$W/srv" >"$W/http.log" 2>&1 &
HTTP_PID=$!

python3 "$H/app-runner.py" "$APP" "$W/data" "$EVENTS" >>"$W/driver.log" 2>&1 &
RUNNER=$!
log "variant=$VARIANT ro=${SO_RO:-0} app=$APP runner=$RUNNER"

fail() { log "FLOW: $*"; shot zz-flow-failed; exit 1; }

close_wizard 01 || fail "first instance: setup wizard not seen"

if [ "$VARIANT" = force ]; then
    title='needs an (upgrade|update)'
else
    title='^New version of Snapmaker Orca'
fi
wid=$(wait_win "$title" 120) || fail "update dialog ($title) not seen"
sleep 1
shot 02-update-dialog
# Offsets are relative to the window position xdotool reports (frame-adjusted) after the move;
# the absolute fallbacks are the button positions of openbox's default placement.
if [ "$VARIANT" = force ]; then
    click_button "$wid" 410 79 1086 539 Download || fail "Download click had no effect"
else
    click_button "$wid" 409 474 881 747 Download || fail "Download click had no effect"
fi

if [ "${SO_RO:-0}" = 1 ]; then
    # Control run: the AppImage is not writable, so Download must fall back to the browser.
    wait_line "$W/browser.log" BROWSER-LAUNCH 30 || fail "no browser launch in read-only control run"
    log "browser launch seen (read-only control)"
    if [ "$VARIANT" = normal ]; then
        close_main 05 || fail "main window not closed"
    fi
else
    shot 03-downloading
    # The update renames the verified download over the AppImage, then asks to restart. (The app
    # log is buffered, so its "AppImage update: installed" line is checked after exit instead.)
    inode=$(stat -c %i "$APP")
    end=$((SECONDS + 180))
    while [ "$(stat -c %i "$APP")" = "$inode" ]; do
        if ((SECONDS >= end)) || ! kill -0 "$RUNNER" 2>/dev/null; then fail "AppImage was not replaced"; fi
        sleep 0.5
    done
    log "AppImage replaced"
    # Stop serving: the relaunched instance must not be offered the same update again.
    kill "$HTTP_PID" 2>/dev/null
    wid=$(wait_win '^Update$' 30) || fail "restart question not seen"
    sleep 1
    shot 04-restart-question
    if [ "$VARIANT" = force ]; then
        click_button "$wid" 467 79 992 539 No || fail "No click had no effect"
    else
        click_button "$wid" 357 79 882 539 Yes || fail "Yes click had no effect"
    fi
fi

wait_line "$EVENTS" 'first_exit=' 60 || fail "first instance did not exit"
log "first instance exited"

if [ "$VARIANT" = normal ] && [ "${SO_RO:-0}" != 1 ]; then
    wait_line "$EVENTS" 'relaunch_cmd=' 60 || fail "no relaunched instance"
    close_wizard 06 || fail "relaunched instance: setup wizard not seen"
    close_main 07 || fail "relaunched main window not closed"
fi

wait_line "$EVENTS" '^.* done$' 90 || fail "app processes still running"
log "all app processes exited"
