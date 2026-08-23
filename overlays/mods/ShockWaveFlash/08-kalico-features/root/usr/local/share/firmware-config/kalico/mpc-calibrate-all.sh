#!/bin/sh
# Faehrt MPC_CALIBRATE nacheinander fuer alle vier Hotends.
# Wird vom Aktionsknopf "Calibrate MPC (all 4 hotends)" aufgerufen.
#
# Vorher pruefen: laeuft ueberhaupt Kalico, und sind die Hotends auf MPC?
# Ohne beides ist der Aufruf sinnlos und wuerde nur Zeit und Waerme kosten.
set -e

URL="http://127.0.0.1:7125"
CURL=/usr/local/bin/curl

if [ ! -f /oem/printer_data/config/extended/klipper/kalico_mpc.cfg ]; then
    echo "Die Hotends stehen nicht auf MPC."
    echo "Erst unter Settings -> Kalico Features -> Hotend Temperature Control"
    echo "auf MPC umschalten, dann hier kalibrieren."
    exit 1
fi

ZUSTAND=$($CURL -s "$URL/printer/objects/query?print_stats" 2>/dev/null \
          | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p')
case "$ZUSTAND" in
    printing|paused)
        echo "Drucker ist im Zustand '$ZUSTAND' - Abbruch."
        exit 1 ;;
esac

for E in extruder extruder1 extruder2 extruder3; do
    echo ""
    echo "=== MPC_CALIBRATE HEATER=$E FAN_BREAKPOINTS=7 ==="
    echo "    (heizt auf, kuehlt dann in mehreren Luefterstufen ab - dauert)"
    $CURL -s -X POST \
        "$URL/printer/gcode/script?script=MPC_CALIBRATE%20HEATER=$E%20FAN_BREAKPOINTS=7" \
        || { echo "Aufruf fuer $E fehlgeschlagen - Abbruch."; exit 1; }
    echo "    $E fertig."
done

echo ""
echo "Alle vier Hotends kalibriert."
echo "Die Werte stehen jetzt im SAVE_CONFIG-Block - mit SAVE_CONFIG festschreiben"
echo "(startet Klipper neu), sonst sind sie nach dem naechsten Neustart weg."
