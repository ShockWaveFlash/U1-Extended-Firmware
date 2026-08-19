#!/usr/bin/env bash

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <upgrade.bin> <temp-dir> <output.bin> [overlays...]"
  exit 1
fi

if [[ $(id -u) -ne 0 ]]; then
  echo "Error: This script must be run as root (sudo) - squashfs operations require root privileges"
  exit 1
fi

set -eo pipefail

IN_FIRMWARE="$(realpath "$1")"
OUT_FIRMWARE="$(realpath -m "$3")"

export CREATE_FIRMWARE=1
export ROOT_DIR="$(realpath "$(dirname "$0")/..")"
export CACHE_DIR="$ROOT_DIR/tmp/cache"
export PATH="$ROOT_DIR/scripts/helpers:$PATH"
export BUILD_DIR="$(realpath -m "$2")"
export ROOTFS_DIR="$BUILD_DIR/rootfs"
export BOOT_IMG="$BUILD_DIR/rk-unpacked/boot.img"
export ROOTFS_IMG="$BUILD_DIR/rk-unpacked/rootfs.img"

# Cache dirs for build tools
export GOPATH="$ROOT_DIR/tmp/cache-go"
export CCACHE_DIR="$ROOT_DIR/tmp/ccache"
export CHROOT_CACHE="$ROOT_DIR/tmp/cache-chroot"

rm -rf "$BUILD_DIR"

shift 3

check_perms() {
  local file="$1"
  local expected_uid="$2"
  local expected_gid="$3"

  if [[ ! -e "$file" ]]; then
    echo "Error: $file does not exist for ownership check."
    exit 1
  fi

  local actual_uid=$(stat -c '%u' "$file")
  local actual_gid=$(stat -c '%g' "$file")

  if [[ "$actual_uid" != "$expected_uid" ]] || [[ "$actual_gid" != "$expected_gid" ]]; then
    echo "Error: $file should be $expected_uid:$expected_gid, got $actual_uid:$actual_gid"
    echo "This system does not properly preserve file ownership in squashfs operations."
    exit 1
  fi
}

echo ">> Unpacking firmware..."
"$ROOT_DIR/scripts/helpers/unpack_firmware.sh" "$IN_FIRMWARE" "$BUILD_DIR"

echo ">> Extracting squashfs from rootfs.img..."
unsquashfs -d "$ROOTFS_DIR" "$BUILD_DIR/rk-unpacked/rootfs.img"

echo ">> Verifying ownership preservation..."
check_perms "$ROOTFS_DIR/etc/passwd" 0 0
check_perms "$ROOTFS_DIR/home/lava/bin/hwver.sh" 1000 1000
echo "   Ownership check passed"

if [[ -z "$CI" ]]; then
  echo ">> Restoring chroot cache..."
  mkdir -p "$CHROOT_CACHE" "$ROOTFS_DIR/cache"
  cp -a "$CHROOT_CACHE/." "$ROOTFS_DIR/cache/"
fi

for overlay; do
  if [[ ! -d "$overlay" ]]; then
    echo "!! Overlay directory '$overlay' does not exist, skipping."
    exit 1
  fi

  echo ">> Applying overlay $overlay..."
  if [[ -d "$overlay/pre-scripts/" ]]; then
    for scriptfile in "$overlay/pre-scripts/"*.sh; do
      echo "[+] Running pre-script: $(basename "$scriptfile")"
      ./"$scriptfile" "$ROOTFS_DIR"
    done
  fi

  if [[ -d "$overlay/patches/" ]]; then
    pushd "$overlay/patches/" > /dev/null
    # apply all .patch to their respective directories
    while read -r patchfile; do
      echo "[+] Applying patch: $(basename "$patchfile") in subdir $(dirname "$patchfile")"
      patch -F 0 --no-backup-if-mismatch -d "$ROOTFS_DIR/$(dirname "$patchfile")" -p1 < "$patchfile"
    done < <(find -type f -name "*.patch" | sort)
    popd > /dev/null
  fi

  if [[ -d "$overlay/root/" ]]; then
    echo ">> Copying custom files..."
    cp -rv "$overlay/root/." "$ROOTFS_DIR/"
  fi

  if [[ -d "$overlay/scripts/" ]]; then
    for scriptfile in "$overlay/scripts/"*.sh; do
      echo "[+] Running script: $(basename "$scriptfile")"
      ./"$scriptfile" "$ROOTFS_DIR"
    done
  fi
done

if [[ -z "$CI" ]]; then
  echo ">> Saving chroot cache..."
  cp -a "$ROOTFS_DIR/cache/." "$CHROOT_CACHE/"
  rm -rf "$ROOTFS_DIR/cache"
fi

echo ">> Checking for non-ARM binaries in rootfs..."
if FILES=$(find "$ROOTFS_DIR" -type f -exec file {} + | grep "ELF" | grep -v "ARM"); then
  echo "!! Error: Found non-ARM binaries in the rootfs:"
  echo "$FILES"
  exit 1
fi

echo ">> Create squash filesystem..."
# Take the compression settings from the stock rootfs instead of hardcoding them.
# Snapmaker switched from gzip to lz4 in 1.6.0 and dropped CONFIG_SQUASHFS_ZLIB from
# the kernel, so a hardcoded compressor produces an image the kernel cannot mount.
SQUASH_INFO=$(unsquashfs -s "$BUILD_DIR/rk-unpacked/rootfs.img")
STOCK_COMP=$(echo "$SQUASH_INFO" | awk '/^Compression/ {print $2}')
STOCK_BLOCK=$(echo "$SQUASH_INFO" | awk '/^Block size/ {print $3}')
if [ -z "$STOCK_COMP" ] || [ -z "$STOCK_BLOCK" ]; then
  echo "!! Error: could not read compression settings from the stock rootfs.img"
  exit 1
fi

# SQUASH_COMP may override the stock compressor to gain partition headroom (zstd packs
# ~45 MB smaller than lz4 here). Only compressors the kernel was built with can be used,
# so the choice is verified against the kernel config shipped in the rootfs below.
SQUASH_COMP="${SQUASH_COMP:-$STOCK_COMP}"
# SQUASH_BLOCK may override the stock block size. Larger blocks compress better across file
# boundaries (128K saves ~6 MB here) at the cost of a proportionally larger decompression
# buffer in the kernel. Squashfs supports up to 1 MiB and has no kernel config knob for it.
SQUASH_BLOCK="${SQUASH_BLOCK:-$STOCK_BLOCK}"
if [ "$SQUASH_BLOCK" != "$STOCK_BLOCK" ]; then
  if [ "$SQUASH_BLOCK" -gt 1048576 ] 2>/dev/null; then
    echo "!! Error: SQUASH_BLOCK=$SQUASH_BLOCK exceeds the 1 MiB squashfs maximum."
    exit 1
  fi
  echo ">> Overriding stock block size '$STOCK_BLOCK' with '$SQUASH_BLOCK'"
fi
SQUASH_XHC=""
if [ "$SQUASH_COMP" = "lz4" ]; then
  # -Xhc is an lz4-only option; it is what stock uses.
  echo "$SQUASH_INFO" | grep -q -- "-Xhc" && SQUASH_XHC="-Xhc"
fi

if [ "$SQUASH_COMP" != "$STOCK_COMP" ]; then
  KERNEL_CONFIG="$ROOTFS_DIR/info/config-6.1"
  KERNEL_OPT="CONFIG_SQUASHFS_$(echo "$SQUASH_COMP" | tr '[:lower:]' '[:upper:]')=y"
  if [ ! -f "$KERNEL_CONFIG" ]; then
    echo "!! Error: SQUASH_COMP=$SQUASH_COMP requested but $KERNEL_CONFIG is missing,"
    echo "!! so kernel support cannot be verified. Refusing to build an unbootable image."
    exit 1
  fi
  if ! grep -q "^$KERNEL_OPT\$" "$KERNEL_CONFIG"; then
    echo "!! Error: the kernel lacks $KERNEL_OPT - an image compressed with"
    echo "!! '$SQUASH_COMP' would not mount. Stock uses '$STOCK_COMP'."
    exit 1
  fi
  echo ">> Overriding stock compressor '$STOCK_COMP' with '$SQUASH_COMP' ($KERNEL_OPT present)"
fi

echo ">> Using -comp $SQUASH_COMP $SQUASH_XHC -b $SQUASH_BLOCK"
mksquashfs "$ROOTFS_DIR" "$BUILD_DIR/rk-unpacked/rootfs-v2.img" \
  -comp "$SQUASH_COMP" $SQUASH_XHC -b "$SQUASH_BLOCK"

echo ">> Verifying the new rootfs uses the requested compression..."
NEW_INFO=$(unsquashfs -s "$BUILD_DIR/rk-unpacked/rootfs-v2.img")
NEW_COMP=$(echo "$NEW_INFO" | awk '/^Compression/ {print $2}')
if [ "$NEW_COMP" != "$SQUASH_COMP" ]; then
  echo "!! Error: new rootfs uses '$NEW_COMP' but '$SQUASH_COMP' was requested"
  exit 1
fi
NEW_BLOCK=$(echo "$NEW_INFO" | awk '/^Block size/ {print $3}')
if [ "$NEW_BLOCK" != "$SQUASH_BLOCK" ]; then
  echo "!! Error: new rootfs uses block size '$NEW_BLOCK' but '$SQUASH_BLOCK' was requested"
  exit 1
fi

echo ">> Checking the new rootfs fits into the system partition..."
PART_SECTORS=$(grep -oE '0x[0-9a-fA-F]+@0x[0-9a-fA-F]+\(system_a\)' "$BUILD_DIR/rk-unpacked/parameter.txt" | cut -d@ -f1)
if [ -z "$PART_SECTORS" ]; then
  echo "!! Error: could not read the system_a partition size from parameter.txt"
  exit 1
fi
PART_SIZE=$(( PART_SECTORS * 512 ))
ROOTFS_SIZE=$(stat -c %s "$BUILD_DIR/rk-unpacked/rootfs-v2.img")
echo "   rootfs $ROOTFS_SIZE B of $PART_SIZE B ($(( ROOTFS_SIZE * 100 / PART_SIZE ))% used)"
if [ "$ROOTFS_SIZE" -gt "$PART_SIZE" ]; then
  echo "!! Error: the rootfs is larger than the system partition and would not flash."
  exit 1
fi

echo ">> Replace rootfs.img in firmware..."
mv -v "$BUILD_DIR/rk-unpacked"/{rootfs-v2,rootfs}.img

echo ">> Update version..."
git rev-parse --short HEAD >> "$BUILD_DIR/UPFILE_VERSION"

echo ">> Repacking firmware..."
"$ROOT_DIR/scripts/helpers/pack_firmware.sh" "$BUILD_DIR" "$OUT_FIRMWARE"

echo ">> Done: $OUT_FIRMWARE"
