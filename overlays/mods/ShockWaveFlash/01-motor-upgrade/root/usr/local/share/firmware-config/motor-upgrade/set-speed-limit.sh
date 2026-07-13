#!/bin/sh
# Write the max_velocity override. Usage: set-speed-limit.sh <mm_per_s>
set -eu
V="$1"
DIR=/oem/printer_data/config/extended/klipper
FILE="$DIR/motor_speed_limit.cfg"
case "$V" in
  [1-9][0-9][0-9]|1000) ;;
  *) echo "Refusing max_velocity '$V' (allowed: 100-1000)"; exit 1 ;;
esac
mkdir -p "$DIR"
cat > "$FILE" <<CFG
# XY velocity limit override
# Managed by firmware-config (Settings > Motor Upgrade). Do not edit manually.

[printer]
max_velocity: $V
CFG
chown lava:lava "$FILE"
echo "max_velocity set to ${V}mm/s."
