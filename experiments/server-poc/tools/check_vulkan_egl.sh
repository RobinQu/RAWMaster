#!/bin/sh
# Probe the headless NVIDIA Vulkan path with the EGL ICD.
#
# The packaged nvidia_icd.json points at libGLX_nvidia.so.0, which calls
# XOpenDisplay(NULL) and returns VK_ERROR_INCOMPATIBLE_DRIVER on a headless
# host. libEGL_nvidia.so.0 exports the same ICD interface and works without X.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
image=${VULKAN_IMAGE:-rawmaster-poc-vulkan2}
docker run --rm --gpus all \
  -e NVIDIA_DRIVER_CAPABILITIES=graphics,compute,utility \
  -e VK_DRIVER_FILES=/opt/vulkan/nvidia_egl_icd.json \
  -v "$here/nvidia_egl_icd.json:/opt/vulkan/nvidia_egl_icd.json:ro" \
  "$image" vulkaninfo --summary
