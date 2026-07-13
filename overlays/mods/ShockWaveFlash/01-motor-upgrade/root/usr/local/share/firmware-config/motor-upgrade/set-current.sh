#!/bin/sh
# Write the XY run_current override for firmware-config's Motor Upgrade setting.
# Usage: set-current.sh <amps>
set -eu

CUR="$1"
DIR=/oem/printer_data/config/extended/klipper
FILE="$DIR/motor_current.cfg"

# Basic sanity: 0.50 .. 1.77 A RMS (LDO-2504 ceiling)
case "$CUR" in
  0.[5-9]|0.[5-9][0-9]|1.[0-6]|1.[0-6][0-9]|1.7|1.7[0-7]) ;;
  *) echo "Refusing run_current '$CUR' (allowed: 0.50-1.77)"; exit 1 ;;
esac

mkdir -p "$DIR"
cat > "$FILE" <<CFG
# XY run current override
# Managed by firmware-config (Settings > Motor Upgrade). Do not edit manually.

[tmc2240 stepper_x]
run_current: $CUR

[tmc2240 stepper_y]
run_current: $CUR
CFG
chown lava:lava "$FILE"

# Supersede the stock "TMC Reduced Current" tweak to avoid conflicting overrides
if [ -f "$DIR/tmc_current.cfg" ]; then
  rm -f "$DIR/tmc_current.cfg"
  echo "NOTE: TMC Reduced Current tweak removed (superseded by Motor Upgrade run current)."
fi

echo "XY run_current set to ${CUR}A."
