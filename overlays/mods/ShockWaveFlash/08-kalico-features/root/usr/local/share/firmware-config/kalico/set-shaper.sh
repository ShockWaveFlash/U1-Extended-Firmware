#!/bin/sh
# Schreibt das last-wins-Fragment fuer den Input-Shaper-Typ.
# Aufruf: set-shaper.sh <smooth_mzv|smooth_ei|smooth_2hump_ei|smooth_zv|smooth_zvd_ei|smooth_si>
#
# Gesetzt werden shaper_type_x UND shaper_type_y, nicht shaper_type:
# die achsspezifischen Optionen haben in Klipper Vorrang, ein blosses
# shaper_type waere also wirkungslos, sobald 05-input-shaper die
# achsspezifischen Werte schreibt.
# Die Frequenzen werden bewusst NICHT angefasst - die kommen weiter aus
# extended/klipper/input_shaper.cfg (wird alphabetisch vorher geladen).
set -e

TYP="$1"
ZIEL=/oem/printer_data/config/extended/klipper/kalico_shaper.cfg

case "$TYP" in
    smooth_zv|smooth_mzv|smooth_ei|smooth_2hump_ei|smooth_zvd_ei|smooth_si) ;;
    *) echo "Unbekannter Shaper-Typ: $TYP" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$ZIEL")"
cat > "$ZIEL" <<EOF
# Erzeugt von firmware-config (Kalico Features -> Input Shaper Type).
# Nicht von Hand aendern - der naechste Schalterdruck ueberschreibt die Datei.
# Frequenzen bleiben in input_shaper.cfg, hier steht nur der Typ.
[input_shaper]
shaper_type_x: $TYP
shaper_type_y: $TYP
EOF

echo "Input shaper set to $TYP"
