# How to Build

This wiki page provides detailed instructions for building OrcaSlicer from source on different operating systems, including Windows, macOS, and Linux.  
It includes tool requirements, setup commands, and build steps for each platform.

Whether you're a contributor or just want a custom build, this guide will help you compile OrcaSlicer successfully.

- [Windows 64-bit](#windows-64-bit)
  - [Windows Tools Required](#windows-tools-required)
  - [Windows Instructions](#windows-instructions)
- [MacOS 64-bit](#macos-64-bit)
  - [MacOS Tools Required](#macos-tools-required)
  - [MacOS Instructions](#macos-instructions)
  - [Debugging in Xcode](#debugging-in-xcode)
- [Linux](#linux)
  - [Using Docker](#using-docker)
    - [Docker Dependencies](#docker-dependencies)
    - [Docker Instructions](#docker-instructions)
  - [Troubleshooting](#troubleshooting)
  - [Linux Build](#linux-build)
    - [Dependencies](#dependencies)
      - [Common dependencies across distributions](#common-dependencies-across-distributions)
      - [Additional dependencies for specific distributions](#additional-dependencies-for-specific-distributions)
    - [Linux Instructions](#linux-instructions)
- [Portable User Configuration](#portable-user-configuration)
  - [Example folder structure](#example-folder-structure)

## Windows 64-bit

How to building with Visual Studio 2022 on Windows 64-bit.

### Windows Tools Required

- [Visual Studio 2022](https://visualstudio.microsoft.com/vs/) or Visual Studio 2019
  ```shell
  winget install --id=Microsoft.VisualStudio.2022.Professional -e
  ```
- [CMake (version 3.31)](https://cmake.org/) — **⚠️ version 3.31.x is mandatory**
  ```shell
  winget install --id=Kitware.CMake -v "3.31.6" -e
  ```
- [Strawberry Perl](https://strawberryperl.com/)
  ```shell
  winget install --id=StrawberryPerl.StrawberryPerl -e
  ```
- [Git](https://git-scm.com/)
  ```shell
  winget install --id=Git.Git -e
  ```
- [git-lfs](https://git-lfs.com/)
  ```shell
  winget install --id=GitHub.GitLFS -e
  ```

> [!TIP]
> GitHub Desktop (optional): A GUI for Git and Git LFS, which already includes both tools.
> ```shell
> winget install --id=GitHub.GitHubDesktop -e
> ```

### Windows Instructions

1. Clone the repository:
   - If using GitHub Desktop clone the repository from the GUI.
   - If using the command line:
     1. Clone the repository:
     ```shell
     git clone https://github.com/SoftFever/OrcaSlicer
     ```
     2. Run lfs to download tools on Windows:
     ```shell
     git lfs pull
     ```
2. Open the appropriate command prompt:
   - For Visual Studio 2019:  
     Open **x64 Native Tools Command Prompt for VS 2019** and run:
     ```shell
     build_release.bat
     ```
   - For Visual Studio 2022:  
     Open **x64 Native Tools Command Prompt for VS 2022** and run:
     ```shell
     build_release_vs2022.bat
     ```

> [!NOTE]
> If you encounter issues, you can try to uninstall ZLIB from your Vcpkg library.

3. If successful, you will find the VS 2022 solution file in:
   ```shell
   build\OrcaSlicer.sln
   ```

> [!IMPORTANT]
> Make sure that CMake version 3.31.x is actually being used. Run `cmake --version` and verify it returns a **3.31.x** version.
> If you see an older version (e.g. 3.29), it's likely due to another copy in your system's PATH (e.g. from Strawberry Perl).
> You can run where cmake to check the active paths and rearrange your **System Environment Variables** > PATH, ensuring the correct CMake (e.g. C:\Program Files\CMake\bin) appears before others like C:\Strawberry\c\bin.

> [!NOTE]
> If the build fails, try deleting the `build/` and `deps/build/` directories to clear any cached build data. Rebuilding after a clean-up is usually sufficient to resolve most issues.

## MacOS 64-bit

How to building with Xcode on MacOS 64-bit.

### MacOS Tools Required

- Xcode
- CMake (version 3.31.x is mandatory)
- Git
- gettext
- libtool
- automake
- autoconf
- texinfo

> [!TIP]
> You can install most of them by running:
> ```shell
> brew install gettext libtool automake autoconf texinfo
> ```

Homebrew currently only offers the latest version of CMake (e.g. **4.X**), which is not compatible. To install the required version **3.31.X**, follow these steps:

1. Download CMake **3.31.7** from: [https://cmake.org/download/](https://cmake.org/download/)
2. Install the application (drag it to `/Applications`).
3. Add the following line to your shell configuration file (`~/.zshrc` or `~/.bash_profile`):

```sh
export PATH="/Applications/CMake.app/Contents/bin:$PATH"
```

4. Restart the terminal and check the version:

```sh
cmake --version
```

5. Make sure it reports a **3.31.x** version.

> [!IMPORTANT]
> If you've recently upgraded Xcode, be sure to open Xcode at least once and install the required macOS build support.

### MacOS Instructions

1. Clone the repository:
   ```shell
   git clone https://github.com/SoftFever/OrcaSlicer
   cd OrcaSlicer
   ```
2. Build the application:
   ```shell
   ./build_release_macos.sh
   ```
3. Open the application:
   ```shell
   open build/arm64/OrcaSlicer/OrcaSlicer.app
   ```

### Debugging in Xcode

To build and debug directly in Xcode:

1. Open the Xcode project:
   ```shell
   open build/arm64/OrcaSlicer.xcodeproj
   ```
2. In the menu bar:
   - **Product > Scheme > OrcaSlicer**
   - **Product > Scheme > Edit Scheme...**
     - Under **Run > Info**, set **Build Configuration** to `RelWithDebInfo`
     - Under **Run > Options**, uncheck **Allow debugging when browsing versions**
   - **Product > Run**

## Linux

Linux distributions are available in two formats: [using Docker](#using-docker) (recommended) or [building directly](#linux-build) on your system.

### Using Docker

How to build and run OrcaSlicer using Docker.

#### Docker Dependencies

- Docker
- Git

#### Docker Instructions

```shell
git clone https://github.com/SoftFever/OrcaSlicer && cd OrcaSlicer && ./scripts/DockerBuild.sh && ./scripts/DockerRun.sh
```

### Troubleshooting

The `scripts/DockerRun.sh` script includes several commented-out options that can help resolve common issues. Here's a breakdown of what they do:

- `xhost +local:docker`: If you encounter an "Authorization required, but no authorization protocol specified" error, run this command in your terminal before executing `scripts/DockerRun.sh`. This grants Docker containers permission to interact with your X display server.
- `-h $HOSTNAME`: Forces the container's hostname to match your workstation's hostname. This can be useful in certain network configurations.
- `-v /tmp/.X11-unix:/tmp/.X11-unix`: Helps resolve problems with the X display by mounting the X11 Unix socket into the container.
- `--net=host`: Uses the host's network stack, which is beneficial for printer Wi-Fi connectivity and D-Bus communication.
- `--ipc host`: Addresses potential permission issues with X installations that prevent communication with shared memory sockets.
- `-u $USER`: Runs the container as your workstation's username, helping to maintain consistent file permissions.
- `-v $HOME:/home/$USER`: Mounts your home directory into the container, allowing you to easily load and save files.
- `-e DISPLAY=$DISPLAY`: Passes your X display number to the container, enabling the graphical interface.
- `--privileged=true`: Grants the container elevated privileges, which may be necessary for libGL and D-Bus functionalities.
- `-ti`: Attaches a TTY to the container, enabling command-line interaction with OrcaSlicer.
- `--rm`: Automatically removes the container once it exits, keeping your system clean.
- `orcaslicer $*`: Passes any additional parameters from the `scripts/DockerRun.sh` script directly to the OrcaSlicer executable within the container.

By uncommenting and using these options as needed, you can often resolve issues related to display authorization, networking, and file permissions.

### Ubuntu 26.04 (containerized build, native run)

Ubuntu 26.04 ships CMake 4.x, which `build_linux.sh` rejects. `scripts/ubuntu2604/build.sh` builds inside an `ubuntu:26.04` container (CMake 3.30, all `-dev` packages from `scripts/ubuntu2604/provision.sh`) under your UID, with the repo mounted at the same absolute path, at low CPU priority. No host `sudo` is needed. The resulting binary links against the same system libraries as the host and runs natively. Compiles go through ccache, kept in `~/.cache/snap-orca-ccache` (`SNAP_ORCA_CCACHE_DIR`), so a rebuild after a commit or a clean recompiles only what changed.

| Command | What it does |
|---|---|
| `scripts/ubuntu2604/build.sh` | Local container build: deps + slicer (`./build_linux.sh -dsr`); pass other `build_linux.sh` flags, or `-- COMMAND` to run any command in the same environment |
| `scripts/ubuntu2604/build.sh -isr` | Rebuild the slicer + AppImage locally |
| `scripts/ubuntu2604/remote-build.sh` | Same build + AppImage + test suite on a Runpod pod; about 4 minutes with warm caches |
| `scripts/ubuntu2604/gui-test/update-test.sh [normal\|force]` | Scripted in-app update test of an AppImage in a headless container |
| `scripts/ubuntu2604/gui-test/fix-model-test.sh [AppImage] PROJECT` | Scripted Fix model → arrange → slice → save test of a project or model file; run it through `remote-test.sh` (`SO_LOCAL=1` for the local container) |
| `scripts/ubuntu2604/gui-test/remote-test.sh TEST [:: TEST]...` | The GUI tests above on a Runpod CPU pod, without docker |
| `scripts/fork-sync/release.sh` | Build, test, smoke-slice and publish a fork release |
| `scripts/fork-sync/install.sh` | Install the timer that merges and releases new Snapmaker versions |

```shell
scripts/ubuntu2604/build.sh          # deps + slicer: ./build_linux.sh -dsr
scripts/ubuntu2604/build.sh -isr     # rebuild slicer + AppImage
```

Outputs: `build/package/snapmaker-orca` (run in place) and `build/Snapmaker_Orca_Linux_V*.AppImage`.
Host runtime needs: `libgtk-3-0t64`, `libwebkit2gtk-4.1-0`, `libopengl0` (present on a stock desktop install).

`scripts/ubuntu2604/remote-build.sh` runs the same build (plus the AppImage and the test suite) on a temporary [Runpod](https://www.runpod.io) CPU pod: 32 vCPU `cpu5c` by default, about $1.1/h. Only the AppImage comes back to `build/`. Caches live on a Runpod network volume (`snap-orca-cache`, 20 GB in `EU-RO-1`, about $1.4/month, created on first use): the built dependencies keyed by the `deps/` tree and `scripts/ubuntu2604/provision.sh`, a ccache of the slicer and tests, and ninja's build log, so the longest units start first. Without capacity in that data center the build runs uncached elsewhere (about 12–19 minutes including dependencies). The pod installs its packages (`provision.sh`, shared with the local container image) and unpacks the caches while the script connects. The pod is deleted when the script exits. As backstops, a detached local process deletes it after 3 hours, and so does the pod itself when Runpod gives it its own credentials (the script warns when it does not). A pod orphaned by this machine going down is otherwise only stopped by hand in the Runpod console. It needs a Runpod API key (`runpodctl doctor`, or `RUNPOD_API_KEY`), push access to the fork, and `~/.ssh/id_ed25519`. HEAD is pushed to a temporary `remote-build/<sha>` branch and uncommitted changes are copied over rsync. The commit hash reaches only `GUI_App.cpp` (through the generated `GitCommitHash.hpp`), so a new commit does not invalidate the cache.

`REMOTE_EXTRA_CMD='…'` runs one more command in `build/` on the pod after the test suite, for example `REMOTE_EXTRA_CMD='ctest -C Release -R "batch lifecycle" --repeat until-fail:500'` to chase a flaky test without loading this machine.

To test the in-app AppImage self-update end to end, run `scripts/ubuntu2604/gui-test/update-test.sh [normal|force] [AppImage]` (the AppImage defaults to the newest `build/Snapmaker_Orca_Linux_V*.AppImage`; it is copied, never modified). The script builds the `snap-orca-guitest:26.04` image on first use and runs the app in a container with no network, no devices and a private headless Xvfb display, so nothing touches host USB devices or appears on screen. Inside, a local HTTP server offers a newer fork build (a marked copy of the same AppImage). The script closes the setup wizard, clicks Download and answers the restart question: Yes for `normal`, No for the forced update in `force`. It then checks that the installed AppImage matches the manifest sha256, that the app exited with 0 and opened no browser, and for `normal` that the relaunched instance kept `--datadir` and exited cleanly. Each check prints PASS/FAIL and the script exits non-zero on any failure; screenshots and logs go to `${TMPDIR:-/tmp}/snap-orca-gui-test/<variant>-<timestamp>/`. `SO_RO=1` runs a read-only control in which Download must fall back to the browser.

`scripts/ubuntu2604/gui-test/fix-model-test.sh [AppImage] PROJECT` loads a `.3mf` project or a model file (`.step`, `.stl`, …) in the same container (only with `SO_LOCAL=1`: a Fix model run on a big project takes minutes of full CPU and GBs of RAM, so the documented path is `remote-test.sh` below; without `SO_LOCAL=1` or `SO_DIRECT=1` it exits 2), selects every object and runs Fix model from the object list (skipped with `SO_FIX=0`, e.g. to check that a STEP file imports without mesh errors; Fix model is in the Linux menu only with the CGAL repair port, so use `SO_FIX=0` for other builds), arranges, slices and saves the project as `saved.3mf`. `analyze-3mf.py` then checks the saved mesh (open edges, winding, volume, size, inside the bed, no overlaps); `SO_ANALYZE_ARGS="--count N --volume V --size X,Y,Z"` sets the expectations. Results go to `${TMPDIR:-/tmp}/snap-orca-gui-test/fixmodel-<name>-<timestamp>/` (`SO_OUT` changes the root).

`scripts/ubuntu2604/gui-test/remote-test.sh` runs these tests on a temporary 8 vCPU `cpu5c` Runpod pod (about $0.28/h) instead of this machine, e.g. `remote-test.sh SO_FIX=0 fix-model-test.sh build/x.AppImage part.stp :: update-test.sh normal build/x.AppImage`. The pod installs `provision.sh` plus the GUI test packages (`gui-test/provision-gui.sh`, shared with the container image), receives every local file named in a test's arguments, and runs each test with `SO_DIRECT=1`: the driver uses the pod's own Xvfb as an unprivileged user instead of a container. The app's network is cut off only when the pod may unshare a network namespace; the log says which. Result folders and `remote-<timestamp>.log` (console, pod, price, run time) come back to `SO_OUT`, and the pod is deleted on exit. `SO_DIRECT=1` is meant for such throwaway machines only, never the development laptop: it refuses to run without the `/etc/snap-orca-throwaway` marker that `remote-test.sh` creates on its pod.

#### Command-line slicing

`--load-settings`/`--load-filaments` read a preset file as-is and do not follow `inherits`, so system presets must be flattened first (otherwise inherited values such as `filament_density` are missing):

```shell
scripts/flatten_profile.py -o /tmp/u1 \
    --machine "Snapmaker U1 (0.4 nozzle)" \
    --process "0.20mm Standard @Snapmaker U1 (0.4 nozzle)" \
    --filament "Snapmaker PLA Basic @U1"
build/package/snapmaker-orca --slice 0 --outputdir out --export-3mf out.3mf \
    --load-settings "/tmp/u1/machine-Snapmaker U1 (0.4 nozzle).json;/tmp/u1/process-0.20mm Standard @Snapmaker U1 (0.4 nozzle).json" \
    --load-filaments "/tmp/u1/filament-Snapmaker PLA Basic @U1.json" model.stl
```

The CLI skips plate thumbnails on Linux: it renders them through an OSMesa context, and the bundled GLEW cannot initialize on one (even with `libosmesa6` installed). G-code and 3MF are otherwise complete. If the printer screen needs a preview image, slice in the GUI, which renders thumbnails with the regular OpenGL context.

#### Releases and in-app updates

Linux builds check `ORCA_LINUX_UPDATE_URL` (`version.inc`; default: the fork's `releases/latest/download/version.json`) on startup and from Help → Check for Update. A release is offered when its Snapmaker version is newer, or equal with a higher `fork_build`. When the app runs from a writable AppImage, Download fetches the new AppImage, verifies its SHA-256, replaces the file in place and offers a restart. Otherwise it opens the download in the browser. Setting `orca_upgrade_url` in `Snapmaker_Orca.conf` overrides the manifest URL.

`scripts/fork-sync/release.sh [--merge <upstream-tag>] [--dry-run]` builds deps, the slicer, the AppImage and the tests, runs the test suite and a CLI smoke slice. The build runs on Runpod through `remote-build.sh` when an API key is configured (`BUILD_BACKEND=local` forces the local container). It then bumps `ORCA_FORK_BUILD`, tags `v<version>-linux.<build>` and publishes the AppImage and `version.json` as the latest GitHub release.

`scripts/fork-sync/install.sh` installs a systemd user timer (every 3 hours) that runs `check-upstream.sh`. When Snapmaker publishes a new stable release, the timer starts a headless `omp` session (`scripts/fork-sync/omp-prompt.md`). That session merges the tag, fixes conflicts and build/test failures, and publishes through `release.sh`. Logs go to `~/.local/state/snap-orca-sync/logs`, and a desktop notification reports the result. A failed tag is not retried until `check-upstream.sh --force <tag>`. No human reviews the merge before clients are offered it: the only gates are the build, the test suite and the smoke slice. Read the log after each notification; `gh release delete <tag>` withdraws a bad release (the manifest URL then resolves to the previous release, but clients that already updated keep the bad build until the next release).

#### LAN printer auto-connect

After a printer has been connected once from the Device page, later starts reconnect to it in the background without switching to the Device tab. The printer re-issues TLS credentials for the stored client id (`server.client_manager.confirm_lan_status`), so no confirmation is needed on its screen. That reply arrives over plain MQTT, so it is accepted only for the stored serial number and client id, and only with the CA certificate seen on the previous connection (`last_connected_ca_sha256`, trust on first use). If the printer no longer authorizes the client or presents another CA, the app stays disconnected; add the printer again on the Device page. Opt out with Preferences → Presets → "Reconnect to the last LAN printer on startup" (`auto_connect_last_printer`).

### Linux Build

How to build OrcaSlicer on Linux.

#### Dependencies

The build system supports multiple Linux distributions including Ubuntu/Debian and Arch Linux. All required dependencies will be installed automatically by the provided shell script where possible, however you may need to manually install some dependencies.

> [!NOTE]
> Fedora and other distributions are not currently supported, but you can try building manually by installing the required dependencies listed below.

##### Common dependencies across distributions

- autoconf / automake
- cmake
- curl / libcurl4-openssl-dev
- dbus-devel / libdbus-1-dev
- eglexternalplatform-dev / eglexternalplatform-devel
- extra-cmake-modules
- file
- gettext
- git
- glew-devel / libglew-dev
- gstreamer-devel / libgstreamerd-3-dev
- gtk3-devel / libgtk-3-dev
- libmspack-dev / libmspack-devel
- libsecret-devel / libsecret-1-dev
- libspnav-dev / libspnav-devel
- libssl-dev / openssl-devel
- libtool
- libudev-dev
- mesa-libGLU-devel
- ninja-build
- texinfo
- webkit2gtk-devel / libwebkit2gtk-4.0-dev or libwebkit2gtk-4.1-dev
- wget

##### Additional dependencies for specific distributions

- **Ubuntu 22.x/23.x**: libfuse-dev, m4
- **Arch Linux**: mesa, wayland-protocols

#### Linux Instructions

1. **Install system dependencies:**
   ```shell
   ./build_linux.sh -u
   ```

2. **Build dependencies:**
   ```shell
   ./build_linux.sh -d
   ```

3. **Build OrcaSlicer:**
   ```shell
   ./build_linux.sh -s
   ```

4. **Build AppImage (optional):**
   ```shell
   ./build_linux.sh -i
   ```

5. **All-in-one build (recommended):**
   ```shell
   ./build_linux.sh -dsi
   ```

**Additional build options:**

- `-b`: Build in debug mode
- `-c`: Force a clean build
- `-C`: Enable ANSI-colored compile output (GNU/Clang only)
- `-j N`: Limit builds to N cores (useful for low-memory systems)
- `-1`: Limit builds to one core
- `-l`: Use Clang instead of GCC
- `-p`: Disable precompiled headers (boost ccache hit rate)
- `-r`: Skip RAM and disk checks (for low-memory systems)

> [!NOTE]
> The build script automatically detects your Linux distribution and uses the appropriate package manager (apt, pacman) to install dependencies.

> [!TIP]
> For first-time builds, use `./build_linux.sh -u` to install dependencies, then `./build_linux.sh -dsi` to build everything.

> [!WARNING]
> If you encounter memory issues during compilation, use `-j 1` or `-1` to limit parallel compilation, or `-r` to skip memory checks.

---

## Portable User Configuration

If you want OrcaSlicer to use a custom user configuration folder (e.g., for a portable installation), you can simply place a folder named `data_dir` next to the OrcaSlicer executable. OrcaSlicer will automatically use this folder as its configuration directory.

This allows for multiple self-contained installations with separate user data.

> [!TIP]
> This feature is especially useful if you want to run OrcaSlicer from a USB stick or keep different profiles isolated.

### Example folder structure

```shell
OrcaSlicer.exe
data_dir/
```

You don’t need to recompile or modify any settings — this works out of the box as long as `data_dir` exists in the same folder as the executable.
