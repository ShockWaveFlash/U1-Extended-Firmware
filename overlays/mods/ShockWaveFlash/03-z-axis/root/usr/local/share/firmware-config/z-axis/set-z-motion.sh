#!/bin/sh
# Write Z velocity/accel override. Usage: set-z-motion.sh <max_z_velocity> <max_z_accel>
set -eu
V="$1"; A="$2"
DIR=/oem/printer_data/config/extended/klipper
case "$V" in [5-9]|[12][0-9]|30) ;; *) echo "Refusing max_z_velocity '$V' (allowed: 5-30)"; exit 1 ;; esac
case "$A" in [5-9][0-9]|[1-4][0-9][0-9]|500) ;; *) echo "Refusing max_z_accel '$A' (allowed: 50-500)"; exit 1 ;; esac
mkdir -p "$DIR"
cat > "$DIR/z_motion.cfg" <<CFG
# Z motion limits override
# Managed by firmware-config (Settings > Z Axis). Do not edit manually.

[printer]
max_z_velocity: $V
max_z_accel: $A
CFG
chown lava:lava "$DIR/z_motion.cfg"
echo "Z motion limits set: max_z_velocity=$V max_z_accel=$A"
