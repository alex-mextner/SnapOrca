# Repository Guidelines

## Project Structure & Module Organization
Snapmaker_Orca’s C++17 sources live in `src/`, split by feature modules and platform adapters. User assets, icons, and printer presets are in `resources/`; translations stay in `localization/`. Tests sit in `tests/`, grouped by domain (`libslic3r/`, `sla_print/`, etc.) with fixtures under `tests/data/`. CMake helpers reside in `cmake/`, and longer references in `doc/` and `SoftFever_doc/`. Automation scripts belong in `scripts/` and `tools/`. Treat everything in `deps/` and `deps_src/` as vendored snapshots—do not modify without mirroring upstream tags.

## Build, Test, and Development Commands
Use out-of-source builds:
- `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release` configures dependencies and generates build files.
- `cmake --build build --target Snapmaker_Orca --config Release` compiles the app; add `--parallel` to speed up.
- `cmake --build build --target tests` then `ctest --test-dir build --output-on-failure` runs automated suites — both on the Runpod pod (§ Heavy work runs on Runpod).
Platform helpers such as `build_linux.sh`, `build_release_macos.sh`, and `build_release_vs2022.bat` wrap the same flow with toolchain flags. Use `build_release_macos.sh -sx` when reproducing macOS build issues, and `scripts/DockerBuild.sh` for reproducible container builds.

### Ubuntu 26.04 fork (branch `ubuntu-26.04`) — host rules
- Never start Snapmaker Orca (AppImage or binary, GUI or CLI) directly on the development laptop: USB/HID enumeration there has hung the machine. Run it only in containers without device access (`scripts/ubuntu2604/gui-test/update-test.sh`, the smoke slice in `scripts/fork-sync/release.sh`) or on a Runpod pod (`scripts/ubuntu2604/gui-test/remote-test.sh`); never with `SO_DIRECT=1` on the laptop.
- No heavy work on the laptop: no local compiles, full test-suite runs or stress loops. Build and test on Runpod with `scripts/ubuntu2604/remote-build.sh` (`REMOTE_EXTRA_CMD` repeats a flaky test there); `release.sh` uses it by default. See `doc/developer-reference/How-to-build.md`, section "Ubuntu 26.04".
- Runpod spend: one pod at a time, never parallel pods (GUI runs included). A red/green (TDD) loop uses one session pod: `remote-build.sh --session start`, then `--session run [ctest args]` per iteration (`REMOTE_APPIMAGE=0` while only unit tests matter), GUI tests with `remote-test.sh` on the same pod, and `--session stop` when done (it waits for the API's 404). A fresh pod is only for a final or release build. Don't build OrcaSlicer PRs on Runpod: their CI builds and tests them.

## Heavy work runs on Runpod

This workstation is shared by many agent sessions, the review queue and the owner's own
desktop; a compile or a full ctest here starves all of them (it froze the machine twice on
2026-10-10). **Rule: locally, a single test binary or a one-file compile check at most; a
build, the full test suite, AppImage packaging or a docker build goes to a Runpod pod.**

Heavy here: `cmake --build build …` (any target), `ctest --test-dir build`, `build_linux.sh`,
`scripts/DockerBuild.sh`, `scripts/fork-sync/release.sh`.

```bash
scripts/ubuntu2604/remote-build.sh                 # build + tests on this repo's Runpod pod (REMOTE_EXTRA_CMD repeats a test); it deletes its pod on exit, best-effort
ctest --test-dir build -R <OneTest>                # local: one test, that's the limit (and never the GUI — see above)
```

`remote-build.sh` is the only remote path for a build or the suite: it provisions the
dependencies (cached on a network volume) and configures its own build tree on the pod. The
shared `runpod-offload` skill (`skill://runpod-offload`; `runpod-run` on PATH) syncs just the
checkout — no `build*/` (git-ignored), no deps — so a bare `runpod-run -- cmake --build build`
fails; use it only for commands that need nothing but the sources (a script, a one-file
check). `runpod-run --status` lists every pod on the account; bare `runpod-run --stop`
terminates only this repo's pods, `runpod-run --stop all` every pod created under this
hostname — except a pod a run currently holds locked (it logs "not stopping it"); stop that
one by id once the run ends. A `snap-orca-build` pod that `remote-build.sh` failed to delete
(control plane down at cleanup) is not a runpod-run pod: check `runpodctl pod list` / the
Runpod console after a failed remote build and remove it there. Leave none behind.

## Coding Style & Naming Conventions
`.clang-format` enforces 4-space indents, a 140-column limit, aligned initializers, and brace wrapping for classes and functions. Run `clang-format -i <file>` before committing; the CMake `clang-format` target is available when LLVM tools are on your PATH. Prefer `CamelCase` for classes, `snake_case` for functions and locals, and `SCREAMING_CASE` for constants, matching conventions in `src/`. Keep headers self-contained and align include order with the IWYU pragmas.

## Testing Guidelines
Unit tests rely on Catch2 (`tests/catch2/`). Name specs after the component under test—for example `tests/libslic3r/TestPlanarHole.cpp`—and tag long-running cases so `ctest -L fast` remains useful. Cover new algorithms with deterministic fixtures or sample G-code stored in `tests/data/`. Document manual printer validation or regression slicer checks in your PR when automated coverage is insufficient.

## Commit & Pull Request Guidelines
The history favors concise, sentence-style subject lines with optional issue references, e.g., `Fix grid lines origin for multiple plates (#10724)`. Squash fixups locally before opening a PR. Complete `.github/pull_request_template.md`, include reproduction steps or screenshots for UI changes, and mention impacted presets or translations. Link issues via `Closes #NNNN` when applicable, and call out dependency bumps or profile migrations for maintainer review.

## Security & Configuration Tips
Follow `SECURITY.md` for vulnerability reporting. Keep API tokens and printer credentials out of tracked configs; use `sandboxes/` for experimental settings. When touching third-party code in `deps_src/`, record the upstream commit or release in your PR description and run the relevant platform build script to confirm integration.
