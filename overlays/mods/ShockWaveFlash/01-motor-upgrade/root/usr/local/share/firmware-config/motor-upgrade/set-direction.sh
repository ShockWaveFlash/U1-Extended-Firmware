#!/bin/sh
# Write the XY dir_pin inversion override for firmware-config's Motor Upgrade setting.
# Usage: set-direction.sh <x|y|both>
#
# The pin name is read from the base printer.cfg and only its leading '!' is
# toggled, so this keeps working if a firmware update changes the pin.
set -eu

MODE="$1"
DIR=/oem/printer_data/config/extended/klipper
FILE="$DIR/motor_direction.cfg"

case "$MODE" in
  x|y|both) ;;
  *) echo "Usage: set-direction.sh <x|y|both>"; exit 1 ;;
esac

PCFG=""
for base in /oem/printer_data/config /home/lava/printer_data/config; do
  if [ -f "$base/printer.cfg" ]; then PCFG="$base/printer.cfg"; break; fi
done
[ -n "$PCFG" ] || { echo "printer.cfg not found; cannot derive dir_pin"; exit 1; }

# First dir_pin inside the given section, e.g. read_dir_pin stepper_x
read_dir_pin() {
  awk -v want="[$1]" '
    /^\[/ { in_section = ($0 == want); next }
    in_section && $1 == "dir_pin:" { print $2; exit }
  ' "$PCFG"
}

# Print the section override with the inversion toggled: '!PC12' -> 'PC12', 'PB3' -> '!PB3'
emit_axis() {
  axis="$1"
  pin=$(read_dir_pin "$axis")
  [ -n "$pin" ] || { echo "No dir_pin found for [$axis] in $PCFG"; exit 1; }
  core=${pin#!}
  case "$core" in
    ""|*[!A-Za-z0-9_:.]*) echo "Unexpected dir_pin '$pin' for [$axis]"; exit 1 ;;
  esac
  if [ "$pin" = "$core" ]; then flipped="!$core"; else flipped="$core"; fi
  printf '\n[%s]\ndir_pin: %s\n' "$axis" "$flipped"
}

mkdir -p "$DIR"
{
  echo "# XY motor direction override (dir_pin inverted relative to printer.cfg)"
  echo "# Managed by firmware-config (Settings > Motor Upgrade). Do not edit manually."
  case "$MODE" in
    x|both) emit_axis stepper_x ;;
  esac
  case "$MODE" in
    y|both) emit_axis stepper_y ;;
  esac
} > "$FILE"
chown lava:lava "$FILE"

echo "XY direction override written for: $MODE"
echo "Verify with STEPPER_BUZZ STEPPER=stepper_x / STEPPER=stepper_y before homing."
