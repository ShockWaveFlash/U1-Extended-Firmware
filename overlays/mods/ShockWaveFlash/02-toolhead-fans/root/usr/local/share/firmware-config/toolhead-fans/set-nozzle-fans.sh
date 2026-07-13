#!/bin/sh
# Write per-toolhead nozzle (heatbreak) fan speed overrides.
# Usage: set-nozzle-fans.sh <t0> <t1> <t2> <t3>   (each 0.30-1.0)
set -eu
DIR=/oem/printer_data/config/extended/klipper
FILE="$DIR/nozzle_fans.cfg"

for v in "$1" "$2" "$3" "$4"; do
  case "$v" in
    0.[3-9]|0.[3-9][0-9]|1|1.0|1.00) ;;
    *) echo "Refusing fan_speed '$v' (allowed: 0.30-1.0)"; exit 1 ;;
  esac
done

mkdir -p "$DIR"
cat > "$FILE" <<CFG
# Per-toolhead nozzle (heatbreak) fan speed override
# WARNING: values below ~0.6 increase heat-creep/clog risk.
# Managed by firmware-config (Settings > Toolhead Fans). Do not edit manually.

[heater_fan e0_nozzle_fan]
fan_speed: $1

[heater_fan e1_nozzle_fan]
fan_speed: $2

[heater_fan e2_nozzle_fan]
fan_speed: $3

[heater_fan e3_nozzle_fan]
fan_speed: $4
CFG
chown lava:lava "$FILE"
echo "Nozzle fan speeds set: T0=$1 T1=$2 T2=$3 T3=$4"
