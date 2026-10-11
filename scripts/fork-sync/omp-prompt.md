Snapmaker published OrcaSlicer release {{TAG}}. Bring it into this fork and publish a Linux release.

This repository is the Ubuntu 26.04 fork of Snapmaker Orca (branch `ubuntu-26.04`, remote `fork` =
github.com/alex-mextner/SnapOrca, upstream = github.com/Snapmaker/OrcaSlicer). Everything runs
unattended: do not ask questions; there is no one to answer.

Steps:
1. `git status` must be clean and the branch `ubuntu-26.04`. Run `scripts/fork-sync/release.sh --merge {{TAG}}`.
2. Exit code 10 (merge conflict): resolve every conflict so that upstream's changes are kept AND the
   fork's features keep working, then `git commit --no-edit`, and rerun `scripts/fork-sync/release.sh`
   (without --merge). Fork features that must survive (see `git log v2.4.0..HEAD --no-merges`):
   - Containerized Ubuntu 26.04 build: scripts/ubuntu2604/ (provision.sh, Runpod remote-build.sh),
     doc/developer-reference/How-to-build.md section.
   - Null guards in DynamicPrintConfig::normalize_fdm (nozzle_diameter, print_sequence).
   - SnapLog mask_secret_in_value input bounding (std::regex stack overflow).
   - SSL_CERT_FILE export in src/dev-utils/platform/unix/build_linux_image.sh.in.
   - GTK undecorated main frame: ResizeEdgePanel / update_edge_panels in MainFrame, GTK move/maximize in BBLTopbar.
   - scripts/flatten_profile.py.
   - Linux updater: ORCA_FORK_BUILD / ORCA_LINUX_UPDATE_URL (version.inc, GeneratedConfig.hpp.in),
     the platform_type "linux" branch of GUI_App::check_new_version_sf, AppImageUpdater, GUI_App::download_update.
   - LAN auto-connect: LanAutoConnect, sm_lan_on_connected / sm_lan_on_connection_lost in SSWCP,
     "auto_connect_last_printer" default + Preferences checkbox, "last_connected_device".
   - Test fixes in tests/ (Catch2 v3 header, bed temperature, placeholder parser, SSWCP).
   When upstream fixed the same problem itself, prefer upstream's version and drop ours.
3. Exit codes 11/12/13 (build, tests, smoke): find the root cause and fix it with a minimal commit;
   upstream code that broke on Ubuntu 26.04 / GCC 15 is in scope. Never disable or delete tests to get
   green; never weaken the smoke test. Rerun `scripts/fork-sync/release.sh` until it publishes.
   A remote build failing for infrastructure reasons (pod creation, SSH, transfer; exit codes other
   than 11/12) may be retried twice; after that report failed.
4. Never force-push, never rewrite published history, never touch other branches or the upstream remote.
5. Never start Snapmaker Orca (binary or AppImage, GUI or CLI) directly on this host: its USB stack
   has hung the machine. Run it only inside the `snap-orca-build:26.04` container without device
   passthrough, as release.sh does. Never write to removable drives under /run/media.
6. Never run heavy work on this laptop: no local builds (`BUILD_BACKEND=local`, `scripts/ubuntu2604/build.sh`,
   `cmake --build`), no full test-suite runs, no stress loops. Builds and tests run on Runpod through
   release.sh / scripts/ubuntu2604/remote-build.sh; reproduce a failing test by rerunning the remote build.
7. A git hook on this host rejects commits whose staged diff has not been reviewed. Before each of
   your own commits run `review diff --staged --task sync-{{TAG}} -C "$PWD" </dev/null` (no timeout, it
   takes minutes), then commit. release.sh reviews its own build bump commit. Never use `--no-verify`
   and never create review stamps or markers by hand.

When done, the last line of your answer must be exactly `RESULT: published <tag>` or
`RESULT: failed <one-line reason>`. If you cannot finish, leave the working tree clean (commit
work-in-progress fixes on a local branch `sync-{{TAG}}-wip`, switch back to ubuntu-26.04) and report
failed. Logs of earlier sync runs are in {{LOG_DIR}}.
