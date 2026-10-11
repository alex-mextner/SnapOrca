#!/usr/bin/env python3
# Runs INSIDE the GUI test container (used by fix-model-driver.sh) or on the throwaway machine of
# SO_DIRECT=1, never on the laptop.
# Finds controls whose position depends on the printer preset (sidebar height, toolbar item count)
# in a fresh screenshot of the maximized 1600x1000 main window and prints "X Y" for xdotool.
#   process-toggle: centre of the selected "Global" pill of the Process panel's Global/Objects toggle
#                   (first teal pixel run in column x=140 below the filament list)
#   arrange-tool:   the 4th main toolbar icon (Add, Add plate, Auto orient, Arrange all): dark pixel
#                   column runs in the toolbar strip; greyed-out icons are too light to count
#   slice-button:   centre of the first wide teal run in the top bar's right half ("Slice plate")
# Exit status 1 when the element is not found.
import subprocess
import sys


def teal(r, g, b):  # the #009688 accent of selected toggles and primary buttons, incl. hover and label tints
    return r < 40 and g >= 120 and b >= 110


def grab(x, y, w, h, fmt):
    return subprocess.run(["import", "-window", "root", "-crop", f"{w}x{h}+{x}+{y}", "-depth", "8", f"{fmt}:-"],
                          check=True, capture_output=True).stdout


def runs(flags, min_len):
    found, start = [], None
    for i, f in enumerate(flags + [False]):
        if f and start is None:
            start = i
        elif not f and start is not None:
            if i - start >= min_len:
                found.append((start, i - 1))
            start = None
    return found


def process_toggle():
    x, y0, h = 140, 400, 400
    px = grab(x, y0, 1, h, "rgb")
    r = runs([teal(*px[i * 3:i * 3 + 3]) for i in range(h)], 12)
    return (x, y0 + (r[0][0] + r[0][1]) // 2) if r else None


def arrange_tool():
    x0, y0, w, h = 560, 76, 500, 40
    g = grab(x0, y0, w, h, "gray")
    r = runs([any(g[row * w + col] < 170 for row in range(h)) for col in range(w)], 20)
    return (x0 + (r[3][0] + r[3][1]) // 2, y0 + h // 2) if len(r) >= 4 else None


def slice_button():
    # Row 40 runs above the button label; the dropdown arrow left of it is a separate, narrower run.
    x0, w = 1000, 600
    px = grab(x0, 40, w, 1, "rgb")
    r = runs([teal(*px[i * 3:i * 3 + 3]) for i in range(w)], 60)
    return (x0 + (r[0][0] + r[0][1]) // 2, 48) if r else None


def main():
    pos = {"process-toggle": process_toggle, "arrange-tool": arrange_tool, "slice-button": slice_button}[sys.argv[1]]()
    if pos is None:
        sys.exit(f"{sys.argv[1]} not found on screen")
    print(*pos)


if __name__ == "__main__":
    main()
