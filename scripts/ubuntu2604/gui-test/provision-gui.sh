#!/usr/bin/env bash
# Installs what the GUI tests need on top of the build environment (provision.sh), as root: a
# private X server (Xvfb + openbox), UI automation (xdotool, wmctrl), screenshots (imagemagick
# `import`), Mesa software GL and GStreamer plugins for the app, and gdb for debugging a hung or
# crashed app by hand. Shared by the Dockerfile (snap-orca-guitest image) and remote-test.sh.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    xvfb openbox xdotool wmctrl x11-utils imagemagick gdb libgl1-mesa-dri \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav gstreamer1.0-gl
rm -rf /var/lib/apt/lists/*
