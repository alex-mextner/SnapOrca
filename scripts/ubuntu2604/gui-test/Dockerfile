# Headless GUI test image for Snapmaker Orca AppImages (used by update-test.sh, fix-model-test.sh).
# The build image already carries the GTK/WebKit/GStreamer runtime libraries the AppImage expects
# from the host; provision-gui.sh adds the X server, UI automation and screenshot tools.
ARG BASE_IMAGE=snap-orca-build:26.04
FROM ${BASE_IMAGE}

COPY provision-gui.sh /tmp/provision-gui.sh
RUN bash /tmp/provision-gui.sh && rm /tmp/provision-gui.sh
