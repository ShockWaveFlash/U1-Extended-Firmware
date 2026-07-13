#!/bin/sh
# Write Z run_current override. Usage: set-z-current.sh <amps>
set -eu
C="$1"
DIR=/oem/printer_data/config/extended/klipper
case "$C" in 0.[5-8]|0.[5-8][0-9]|0.9|0.90) ;; *) echo "Refusing Z run_current '$C' (allowed: 0.50-0.90)"; exit 1 ;; esac
mkdir -p "$DIR"
cat > "$DIR/z_current.cfg" <<CFG
# Z run current override (stock: 0.85)
# Managed by firmware-config (Settings > Z Axis). Do not edit manually.

[tmc2209 stepper_z]
run_current: $C
CFG
chown lava:lava "$DIR/z_current.cfg"
echo "Z run_current set to ${C}A."
