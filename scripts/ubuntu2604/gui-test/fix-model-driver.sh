#!/usr/bin/env bash
# Runs INSIDE the GUI test container (started by fix-model-test.sh), or with SO_DIRECT=1 on a
# throwaway test machine (see host-lib.sh); never on the development laptop.
# Drives "Fix model" -> arrange -> slice -> save on a private headless Xvfb display in SO_WORK
# (default /work): starts the app with the project from proj/, answers the load dialogs, closes the
# wizard, then (SO_FIX=1) selects every object with a Shift+drag rectangle on the 3D view, picks
# "Fix Model" from the object list context menu, arranges with the toolbar's Arrange popup, slices
# with the "Slice plate" button and saves the project as saved.3mf via File > Save Project as.
# Writes driver.log, events.log (step=... lines with the app log line number), shots/.
# Fixed screen positions are measured on the maximized 1600x1000 main window (see the shots of a
# run); controls that move with the printer preset (sidebar height, toolbar width) are found by
# locate.py in a fresh screenshot.
# Env: SO_FIX=1|0 (run Fix model), SO_FIX_TIMEOUT, SO_SLICE_TIMEOUT (seconds).
set -u

W=${SO_WORK:-/work}
H=$(dirname "$(readlink -f "$0")")
APP=$(echo "$W"/app/*.AppImage)
PROJECT=$(echo "$W"/proj/*)
STEM=$(basename "${PROJECT%.*}")
EVENTS=$W/events.log
SAVED=$W/saved.3mf
# shellcheck source=gui-lib.sh
. "$H/gui-lib.sh"

cleanup() {
    shot zz-final
    pkill -f appimage_extracted_ 2>/dev/null
    pkill -f "$APP" 2>/dev/null
    kill "$RUNNER" 2>/dev/null
}
trap cleanup EXIT
fail() { log "FLOW: $*"; shot zz-flow-failed; exit 1; }

# Positions on the maximized main window; layout-dependent ones are set by locate() later.
RECT_FROM=(560 140)    # Shift+drag rectangle over the whole bed (empty canvas at both corners)
RECT_TO=(1480 790)
EMPTY_CANVAS=(650 790) # below the bed: deselects
OBJECT_LIST=(250 600)  # scroll wheel target to show the end of the object list
FILE_MENU=(41 14)
SAVE_AS_ITEM=(85 142)  # File > "Save Project as..."
LEGEND_COLLAPSE=(1139 95) # preview: collapse the line type legend
GCODE_TOGGLE=(1171 95)    # preview: hide the G-code text window

# locate NAME VAR: store "X Y" of a locate.py element in the array VAR, or fail.
locate() {
    local pos
    pos=$(python3 "$H/locate.py" "$1" 2>&1) || fail "$pos"
    read -r -a "$2" <<<"$pos"
    log "located $1 at $pos"
}

# shellcheck disable=SC2012 # newest by mtime; app log names have no special characters
app_log() { ls -t "$W"/data/log/*.log* 2>/dev/null | head -n1; }
app_log_lines() { local f; f=$(app_log); [ -n "$f" ] && wc -l <"$f" || echo 0; }
app_log_count() { local c; c=$(grep -acE "$1" "$(app_log)" 2>/dev/null); echo "${c:-0}"; }
step() { echo "$(date +%T) step=$1 applog_line=$(app_log_lines)" >>"$EVENTS"; log "step $1"; }
# wait_line_count REGEX OLD_COUNT SECONDS: wait until the app log has more than OLD_COUNT matching lines.
wait_line_count() {
    local end=$((SECONDS + $3))
    while ((SECONDS < end)); do
        (($(app_log_count "$1") > $2)) && return 0
        sleep 0.5
    done
    return 1
}
main_title() { xdotool getwindowname "$MAIN" 2>/dev/null; }
# click X Y: slow press/release; ImGui widgets on the 3D view miss a press and release in one frame.
click() { xdotool mousemove --sync "$1" "$2"; sleep 0.4; xdotool mousedown "${3:-1}"; sleep 0.25; xdotool mouseup "${3:-1}"; }
# shot_list_end NAME: screenshot with the object list scrolled to its end (it shows 8 rows).
shot_list_end() {
    xdotool mousemove --sync "${OBJECT_LIST[@]}" click --repeat 8 --delay 50 5
    sleep 1
    shot "$1"
    xdotool click --repeat 8 --delay 50 4
    sleep 0.5
}

is_main() { case "$1" in "$STEM" | "*$STEM" | Untitled | "*Untitled") return 0 ;; esac; return 1; }

# startup: answer every dialog that appears while the project loads (Return, then a WM close if it
# stays), close the setup wizard and return once the main window has been quiet for a while.
startup() {
    local end=$((SECONDS + 300)) quiet=$SECONDS wizard=0 n=0 wid name
    declare -A tries=()
    MAIN=''
    while ((SECONDS < end)); do
        kill -0 "$RUNNER" 2>/dev/null || return 1
        for wid in $(xdotool search --onlyvisible --name . 2>/dev/null); do
            name=$(xdotool getwindowname "$wid" 2>/dev/null) || continue
            if is_main "$name"; then MAIN=$wid; continue; fi
            case "$name" in
            snapmaker-orca | Loading* | '') continue ;; # popup helpers, load progress
            'Setup Wizard')
                sleep 2
                shot 01-wizard
                close_window "$wid" "Setup Wizard" || log "Setup Wizard did not close"
                wizard=1 ;;
            *)
                tries[$wid]=$((${tries[$wid]:-0} + 1))
                n=$((n + 1))
                sleep 1
                shot "01-dialog-$n"
                if ((${tries[$wid]} <= 2)); then
                    log "dialog '$name' (window $wid): Return"
                    xdotool windowactivate --sync "$wid" key Return 2>/dev/null
                else
                    close_window "$wid" "dialog '$name'"
                fi
                sleep 1 ;;
            esac
            quiet=$SECONDS
        done
        if [ -n "$MAIN" ] && { ((wizard && SECONDS - quiet >= 5)) || ((SECONDS - quiet >= 60)); }; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

start_display || exit 1
python3 "$H/app-runner.py" "$APP" "$W/data" "$EVENTS" "$PROJECT" >>"$W/driver.log" 2>&1 &
RUNNER=$!
log "app=$APP project=$PROJECT fix=${SO_FIX:-1} runner=$RUNNER"

startup || fail "main window ($STEM) not ready"
wmctrl -i -r "$MAIN" -b add,maximized_vert,maximized_horz
sleep 3
step loaded
log "main window $MAIN '$(main_title)'"

# Before: object list (warning icons) and the info panel of the first object (error line).
# The object list replaces the process settings when the toggle next to "Global" says "Objects";
# its first object row lies below the "Plate 1" row. Deselect first: a click on an already
# selected row starts renaming it (a STEP import leaves the new object selected).
click "${EMPTY_CANVAS[@]}"
sleep 1
locate process-toggle TOGGLE
OBJECTS_TAB=(189 "${TOGGLE[1]}")
FIRST_ROW=(140 $((TOGGLE[1] + 74)))
click "${OBJECTS_TAB[@]}"
sleep 1
click "${FIRST_ROW[@]}"
sleep 2
shot 02-before
shot_list_end 02-before-list-end

if [ "${SO_FIX:-1}" = 1 ]; then
    # Select all objects: Shift+drag a rectangle around the bed.
    xdotool mousemove --sync "${RECT_FROM[@]}"
    sleep 0.3
    xdotool keydown shift mousedown 1
    for i in $(seq 1 20); do
        xdotool mousemove --sync $((RECT_FROM[0] + (RECT_TO[0] - RECT_FROM[0]) * i / 20)) $((RECT_FROM[1] + (RECT_TO[1] - RECT_FROM[1]) * i / 20))
        sleep 0.05
    done
    xdotool mouseup 1 keyup shift
    sleep 2
    shot 03-selected

    # Context menu of the (all selected) object list; "Fix Model" is the second enabled entry of the
    # multi-selection menu (Assemble, [Center, Drop disabled], Fix Model, ...). Keyboard navigation
    # skips disabled entries, so this does not depend on the menu's pixel layout.
    before=$(main_title)
    xdotool mousemove --sync "${FIRST_ROW[@]}" click 3
    sleep 1.5
    xdotool key Down
    sleep 0.3
    xdotool key Down
    sleep 0.5
    shot 03-menu
    step fix_start
    xdotool key Return
    # Done when the progress dialog is gone and the project is marked modified ("*" title).
    end=$((SECONDS + ${SO_FIX_TIMEOUT:-900}))
    while ((SECONDS < end)); do
        title=$(main_title)
        if [ "${title:0:1}" = '*' ] && [ "$title" != "$before" ] && ! xdotool search --onlyvisible --name '^Repairing' >/dev/null 2>&1; then
            break
        fi
        kill -0 "$RUNNER" 2>/dev/null || fail "app exited during Fix model"
        sleep 0.5
    done
    title=$(main_title)
    [ "${title:0:1}" = '*' ] && [ "$title" != "$before" ] || fail "Fix model did not modify the project (title '$title')"
    step fix_done
    sleep 3
    shot 04-after-fix
    click "${FIRST_ROW[@]}"
    sleep 2
    shot 05-after-fix-info
    shot_list_end 05-after-fix-list-end
fi

# Arrange all. The A key only reaches the 3D view when it has keyboard focus, which a click on the
# canvas does not reliably give after the object list had it, so use the toolbar popup instead.
arranged=$(app_log_count 'ArrangeJob.* spend')
click "${EMPTY_CANVAS[@]}"
sleep 1
locate arrange-tool ARRANGE_TOOL
step arrange_start
click "${ARRANGE_TOOL[@]}"
sleep 1.5
shot 06-arrange-popup
# The popup opens below the toolbar, left-aligned with the icon; "Arrange" is its first button.
click $((ARRANGE_TOOL[0] + 32)) 326
xdotool mousemove --sync "${EMPTY_CANVAS[@]}"
wait_line_count 'ArrangeJob.* spend' "$arranged" 60 || fail "arrange did not run"
step arrange_done
sleep 3
shot 06-after-arrange

sliced=$(app_log_count 'Slicing process finished')
locate slice-button SLICE_BUTTON
step slice_start
click "${SLICE_BUTTON[@]}"
xdotool mousemove --sync "${EMPTY_CANVAS[@]}"
wait_line_count 'Slicing process finished' "$sliced" "${SO_SLICE_TIMEOUT:-900}" || fail "slicing did not finish"
step slice_done
sleep 8 # G-code export and preview load
shot 07-after-slice
click "${LEGEND_COLLAPSE[@]}"
sleep 0.5
click "${GCODE_TOGGLE[@]}"
xdotool mousemove --sync "${EMPTY_CANVAS[@]}"
sleep 2
shot 07-after-slice-plate

step save_start
click "${FILE_MENU[@]}"
sleep 1.5
shot 08-file-menu
click "${SAVE_AS_ITEM[@]}"
wait_win '^Save file as' 30 >/dev/null || fail "Save as dialog not seen"
sleep 1
xdotool key ctrl+a
xdotool type --delay 30 "$SAVED"
sleep 0.5
xdotool key Return
end=$((SECONDS + 120))
while ((SECONDS < end)); do
    [ "$(main_title)" = saved ] && [ -s "$SAVED" ] && break
    sleep 0.5
done
[ -s "$SAVED" ] || fail "project not saved to $SAVED"
step saved
sleep 2
shot 09-saved

close_window "$MAIN" "main window" || log "main window did not close"
for wid in $(xdotool search --onlyvisible --name . 2>/dev/null); do
    name=$(xdotool getwindowname "$wid" 2>/dev/null)
    [ "$name" = snapmaker-orca ] || { shot 10-close-dialog; log "dialog on close: '$name'"; }
done
wait_line "$EVENTS" 'first_exit=' 60 || log "app did not exit within 60 s"
log "flow complete"
