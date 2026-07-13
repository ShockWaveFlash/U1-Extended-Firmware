#!/bin/sh
# Write the XY StallGuard threshold override.
# Usage: set-stallguard.sh sg4|sgt <x_value> <y_value>
set -eu

MODE="$1"; XV="$2"; YV="$3"
DIR=/oem/printer_data/config/extended/klipper
FILE="$DIR/motor_stallguard.cfg"

case "$MODE" in
  sg4)
    PARAM=driver_SG4_THRS
    for v in "$XV" "$YV"; do
      case "$v" in
        [0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) ;;
        *) echo "Refusing SG4_THRS '$v' (allowed: 0-255)"; exit 1 ;;
      esac
    done ;;
  sgt)
    PARAM=driver_SGT
    for v in "$XV" "$YV"; do
      case "$v" in
        -6[0-4]|-[1-5][0-9]|-[1-9]|6[0-3]|[1-5][0-9]|[0-9]) ;;
        *) echo "Refusing SGT '$v' (allowed: -64..63)"; exit 1 ;;
      esac
    done ;;
  *) echo "Unknown mode '$MODE' (sg4|sgt)"; exit 1 ;;
esac

mkdir -p "$DIR"
cat > "$FILE" <<CFG
# XY StallGuard threshold override ($PARAM)
# Managed by firmware-config (Settings > Motor Upgrade). Do not edit manually.

[tmc2240 stepper_x]
$PARAM: $XV

[tmc2240 stepper_y]
$PARAM: $YV
CFG
chown lava:lava "$FILE"
echo "StallGuard override set: $PARAM X=$XV Y=$YV"
