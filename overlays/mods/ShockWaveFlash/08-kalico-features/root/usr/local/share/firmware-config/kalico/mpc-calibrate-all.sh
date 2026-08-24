#!/bin/sh
# Faehrt MPC_CALIBRATE nacheinander fuer alle vier Hotends.
# Wird vom Aktionsknopf "Calibrate MPC (all 4 hotends)" aufgerufen.
#
# Vorher pruefen: laeuft ueberhaupt Kalico, und sind die Hotends auf MPC?
# Ohne beides ist der Aufruf sinnlos und wuerde nur Zeit und Waerme kosten.
set -e

URL="http://127.0.0.1:7125"
CURL=/usr/local/bin/curl

CFG=/oem/printer_data/config/extended/klipper/kalico_hotend_control.cfg
if [ ! -f "$CFG" ] || ! grep -q "control: *mpc" "$CFG"; then
    echo "Die Hotends stehen nicht auf MPC."
    echo "Erst unter Einstellungen -> Kalico -> Temperaturregelung der Hotends"
    echo "auf MPC umschalten, dann hier kalibrieren."
    exit 1
fi

# Welche Hotends? Ohne Angabe alle vier.
LISTE="${1:-extruder extruder1 extruder2 extruder3}"

ZUSTAND=$($CURL -s "$URL/printer/objects/query?print_stats" 2>/dev/null \
          | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p')
case "$ZUSTAND" in
    printing|paused)
        echo "Drucker ist im Zustand '$ZUSTAND' - Abbruch."
        exit 1 ;;
esac

# ⚠ Kalicos MPC-Doku: "Ensure that the part cooling fan is off before starting
# calibration." Die Routine misst den Waermeverlust erst ohne und dann mit Luefter -
# laeuft er schon vorher, ist die erste Messung wertlos.
echo "Bauteilluefter werden abgeschaltet..."
$CURL -s -X POST "$URL/printer/gcode/script?script=M107" >/dev/null 2>&1
for f in e1_fan e2_fan e3_fan; do
    $CURL -s -X POST "$URL/printer/gcode/script?script=SET_FAN_SPEED%20FAN=$f%20SPEED=0" >/dev/null 2>&1
done

for E in $LISTE; do
    echo ""
    echo "=== MPC_CALIBRATE HEATER=$E FAN_BREAKPOINTS=7 ==="
    echo "    (heizt auf, kuehlt dann in mehreren Luefterstufen ab - dauert)"
    $CURL -s -X POST \
        "$URL/printer/gcode/script?script=MPC_CALIBRATE%20HEATER=$E%20FAN_BREAKPOINTS=7" \
        || { echo "Aufruf fuer $E fehlgeschlagen - Abbruch."; exit 1; }
    echo "    $E fertig."
done

echo ""
echo "Kalibrierung beendet fuer: $LISTE"
echo ""
echo "⚠ Die Werte sind JETZT NUR IM ARBEITSSPEICHER. Zum Festschreiben:"
echo "     SAVE_CONFIG        (startet Klipper neu)"
echo "Ohne das sind sie beim naechsten Neustart weg."
echo ""
echo "⚠ Sollte SAVE_CONFIG mit einem Fehler abbrechen, weil control: mpc aus einer"
echo "  eingebundenen Datei stammt: den Schalter \"Verhalten bei unbekannten"
echo "  Konfigurationsoptionen\" unberuehrt lassen und stattdessen die im Protokoll"
echo "  ausgegebenen Modellwerte von Hand in kalico_hotend_control.cfg eintragen."
