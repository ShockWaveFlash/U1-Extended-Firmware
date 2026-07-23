#!/bin/sh
# Write [input_shaper] override. Usage: set-input-shaper.sh <type_x> <freq_x> <type_y> <freq_y>
set -eu
TX="$1"; FX="$2"; TY="$3"; FY="$4"
DIR=/oem/printer_data/config/extended/klipper
for T in "$TX" "$TY"; do
  case "$T" in zv|mzv|ei|2hump_ei|3hump_ei) ;; *) echo "Refusing shaper type '$T' (allowed: zv mzv ei 2hump_ei 3hump_ei)"; exit 1 ;; esac
done
for F in "$FX" "$FY"; do
  echo "$F" | grep -Eq '^(2[0-9]|[3-9][0-9]|1[0-4][0-9]|150)(\.[0-9])?$' || { echo "Refusing shaper freq '$F' (allowed: 20-150 Hz)"; exit 1; }
done
mkdir -p "$DIR"
cat > "$DIR/input_shaper.cfg" <<CFG
# Input Shaper override
# Managed by firmware-config (Settings > Input Shaper). Do not edit manually.

[input_shaper]
shaper_type_x: $TX
shaper_freq_x: $FX
shaper_type_y: $TY
shaper_freq_y: $FY
CFG
chown lava:lava "$DIR/input_shaper.cfg"
echo "Input shaper set: X=${TX}@${FX}Hz Y=${TY}@${FY}Hz"
