#!/usr/bin/env bash

if [[ -z "$CREATE_FIRMWARE" ]]; then
    echo "Error: This script should be run within the create_firmware.sh environment."
    exit 1
fi

set -eo pipefail

# The pip installs above add ~108 MB to a partition that only has ~99 MB of stock headroom,
# so drop the parts that are only needed to develop against numpy/opencv, not to run them.
SP="$ROOTFS_DIR/usr/lib/python3.11/site-packages"

echo ">> Slimming down the installed Python packages..."
BEFORE=$(du -sb "$SP" | cut -f1)

# numpy ships its full test suite (~17 MB uncompressed).
find "$SP/numpy" -type d -name tests -prune -exec rm -rf {} +

# OpenCV haarcascade XMLs - classic face/eye detection, unused by the RKNN models.
rm -rf "$SP/cv2/data"

# C headers, static libs and type stubs are build-time only.
find "$SP/numpy" "$SP/cv2" \( -name '*.h' -o -name '*.a' -o -name '*.pyi' \) -delete
rm -rf "$SP/cv2/typing"

# numpy's shared objects ship unstripped. Only strip when the toolchain matches the target,
# otherwise leave them alone rather than risk corrupting them.
if command -v strip >/dev/null && [ "$(uname -m)" = "aarch64" ]; then
  find "$SP/numpy" "$SP/cv2" -name '*.so*' -type f -exec strip --strip-unneeded {} +
  echo "   stripped numpy/cv2 shared objects"
else
  echo "   skipping strip: needs an aarch64 host, running on $(uname -m)"
fi

AFTER=$(du -sb "$SP" | cut -f1)
echo "   site-packages $((BEFORE / 1048576)) MB -> $((AFTER / 1048576)) MB (uncompressed)"

# Sanity check: the modules the mod imports must still be present.
for m in cv2 numpy rknnlite paho; do
  if [ ! -d "$SP/$m" ]; then
    echo "!! Error: $m disappeared from site-packages while slimming"
    exit 1
  fi
done
