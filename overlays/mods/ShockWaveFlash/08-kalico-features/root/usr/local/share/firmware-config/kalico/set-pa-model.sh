#!/bin/sh
# Schreibt das last-wins-Fragment fuer das Pressure-Advance-Modell.
# Aufruf: set-pa-model.sh <tanh|recipr>
# "linear" braucht kein Fragment - dafuer wird die Datei geloescht.
set -e

MODELL="$1"
ZIEL=/oem/printer_data/config/extended/klipper/kalico_pa.cfg

case "$MODELL" in
    tanh|recipr) ;;
    *) echo "Unbekanntes PA-Modell: $MODELL (erlaubt: tanh, recipr)" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$ZIEL")"
{
    echo "# Erzeugt von firmware-config (Kalico Features -> Pressure Advance Model)."
    echo "# Nicht von Hand aendern - der naechste Schalterdruck ueberschreibt die Datei."
    echo "# ACHTUNG: Nach dem Wechsel muss die PA-Kalibrierung neu gefahren werden."
    for E in extruder extruder1 extruder2 extruder3; do
        echo ""
        echo "[$E]"
        echo "pressure_advance_model: $MODELL"
    done
} > "$ZIEL"

echo "Pressure advance model set to $MODELL for all four extruders"
