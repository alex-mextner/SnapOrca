#!/usr/bin/env python3
# Runs INSIDE the GUI test container (started by driver.sh / fix-model-driver.sh) or on the
# throwaway machine of SO_DIRECT=1, never on the laptop.
# Starts the AppImage and records, in an events file, the exit status of that first instance and
# of the instance the updater relaunches. The relaunch is spawned by the app as
# `sh -c 'while kill -0 PID; ...; exec APPIMAGE ARGS'` and is orphaned when the first instance
# exits; as child subreaper this process inherits it, so its real exit status can be reaped here.
# Events (one per line): first_pid=, first_exit=RC, relaunch_pid=, relaunch_cmd=ARGV,
# relaunch_exit=RC, done. RC is the exit code, or -SIGNAL when killed by a signal.
# Usage: app-runner.py APPIMAGE DATADIR EVENTS [APP_ARG...]; APP_ARGs (e.g. a project file) follow --datadir.
import ctypes
import os
import sys
import time

PR_SET_CHILD_SUBREAPER = 36


def cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
    except OSError:
        return []


def main():
    appimage, datadir, events_path = sys.argv[1:4]
    app_args = sys.argv[4:]

    def event(msg):
        with open(events_path, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")

    if ctypes.CDLL(None, use_errno=True).prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        sys.exit(f"prctl(PR_SET_CHILD_SUBREAPER) failed: errno {ctypes.get_errno()}")

    first = os.posix_spawn(appimage, [appimage, "--datadir", datadir, *app_args], os.environ)
    event(f"first_pid={first}")
    relaunch, relaunch_cmd, first_done = None, None, False
    while True:
        pids = [int(p) for p in os.listdir("/proc") if p.isdigit() and int(p) not in (first, os.getpid())]
        argvs = {pid: cmdline(pid) for pid in pids}
        for pid, argv in argvs.items():
            if relaunch is None and argv[:2] == ["/bin/sh", "-c"] and len(argv) > 2 and "kill -0" in argv[2] and appimage in argv:
                relaunch = pid
                event(f"relaunch_pid={relaunch}")
            # The relaunch shell keeps its pid when it execs the AppImage; record the final argv.
            if pid == relaunch and argv and argv[0] == appimage and argv != relaunch_cmd:
                relaunch_cmd = argv
                event("relaunch_cmd=" + " ".join(argv))
        try:
            while True:
                pid, status = os.waitpid(-1, os.WNOHANG)
                if pid == 0:
                    break
                rc = os.waitstatus_to_exitcode(status)
                if pid == first:
                    event(f"first_exit={rc}")
                    first_done = True
                elif pid == relaunch:
                    event(f"relaunch_exit={rc}")
                else:
                    event(f"reaped pid={pid} rc={rc}")
        except ChildProcessError:
            break  # no children left: every app instance has exited
        # Helpers the app leaves behind (e.g. an autolaunched dbus-daemon) never exit on their own,
        # so stop once nothing refers to the AppImage any more (this covers a pending relaunch too).
        if first_done and not any(
            appimage in " ".join(argv) or "appimage_extracted_" in " ".join(argv) for argv in argvs.values()
        ):
            break
        time.sleep(0.3)
    event("done")


if __name__ == "__main__":
    main()
