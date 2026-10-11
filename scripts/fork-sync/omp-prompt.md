Snapmaker published OrcaSlicer release {{TAG}}. Bring it into this fork and publish a Linux release.

This repository is the Ubuntu 26.04 fork of Snapmaker Orca (branch `ubuntu-26.04`, remote `fork` =
github.com/alex-mextner/SnapOrca, upstream = github.com/Snapmaker/OrcaSlicer). Everything runs
unattended: do not ask questions; there is no one to answer.

Steps:
1. `git status` must be clean and the branch `ubuntu-26.04`. Run `scripts/fork-sync/release.sh --merge {{TAG}}`.
2. Exit code 10 (merge conflict): release.sh left you on branch `fork-sync/{{TAG}}`, which starts at
   upstream's {{TAG}} and is merging `ubuntu-26.04` into it, so `ours`/HEAD is upstream and
   `theirs` is the fork. Resolve every conflict (no conflict markers, no file left unmerged, nothing
   deleted to make a conflict go away) so that upstream's changes are kept AND the fork's features
   keep working, stage the result, then review and commit it as rule 7 describes, `git switch
   ubuntu-26.04` and, without committing anything else first, rerun
   `scripts/fork-sync/release.sh --merge {{TAG}}`, which fast-forwards `ubuntu-26.04` to your merge
   and continues with the build. Fork features that must survive (see
   `git log v2.4.0..ubuntu-26.04 --no-merges`):
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
4. Never force-push, never rewrite published history, never touch the upstream remote or branches
   other than `ubuntu-26.04`, the `fork-sync/{{TAG}}` branch release.sh creates and `sync-{{TAG}}-wip`.
5. Never start Snapmaker Orca (binary or AppImage, GUI or CLI) directly on this host: its USB stack
   has hung the machine. Run it only inside the `snap-orca-build:26.04` container without device
   passthrough, as release.sh does. Never write to removable drives under /run/media.
6. Never run heavy work on this laptop: no local builds (`BUILD_BACKEND=local`, `scripts/ubuntu2604/build.sh`,
   `cmake --build`), no full test-suite runs, no stress loops. Builds and tests run on Runpod through
   release.sh / scripts/ubuntu2604/remote-build.sh; reproduce a failing test by rerunning the remote build.
7. A git hook on this host rejects every commit whose exact staged diff has not passed
   `review diff --staged` (only documentation-only diffs are exempt, and a merge's diff always
   carries the fork's code), the conflicted merge commit of step 2 included. Before each of your own
   commits stage exactly what you will commit and run
   `review diff --staged --task sync-{{TAG}} -C "$PWD" </dev/null` (no timeout, it takes minutes).
   For the merge commit prefix it with `REVIEW_DIFF_MAX_BYTES=1000000`: its staged diff is the
   fork's whole delta re-applied to {{TAG}} (about 0.4 MB), above review-cli's 300 KB default, and a
   truncated review writes no stamp. Read every finding: fix the real problems in what you changed
   (conflict resolutions, fixes), re-stage, review again, and commit only after a review of the final
   staged diff passed. A finding about fork code that neither upstream nor your resolution touched
   goes into your final answer instead. A merge whose staged diff exceeds 1 MB is not the merge
   release.sh makes (it would be upstream's whole release): abort it (`git merge --abort`) and report
   failed. release.sh reviews its own build bump commit. Never use `--no-verify`, never disable or
   raise the size limit further, and never create review stamps or markers by hand.

When done, the last line of your answer must be exactly `RESULT: published <tag>` or
`RESULT: failed <one-line reason>`. If you cannot finish, leave the working tree clean (commit
work-in-progress fixes, reviewed like every commit, on a local branch `sync-{{TAG}}-wip`; abort an
unfinished merge with `git merge --abort` and delete `fork-sync/{{TAG}}` unless it holds a committed
merge; switch back to ubuntu-26.04) and report failed. Logs of earlier sync runs are in {{LOG_DIR}}.
