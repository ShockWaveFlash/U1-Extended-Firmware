#!/bin/sh
# Write heater_bed max_temp override. Usage: set-bed-maxtemp.sh <celsius>
set -eu
T="$1"
DIR=/oem/printer_data/config/extended/klipper
case "$T" in 11[1-9]|120) ;; *) echo "Refusing bed max_temp '$T' (allowed: 111-120)"; exit 1 ;; esac
mkdir -p "$DIR"
cat > "$DIR/bed_maxtemp.cfg" <<CFG
# heater_bed max_temp override (stock: 110)
# Managed by firmware-config (Settings > Bed & Chamber). Do not edit manually.

[heater_bed]
max_temp: $T
CFG
chown lava:lava "$DIR/bed_maxtemp.cfg"
echo "heater_bed max_temp set to ${T}C."
