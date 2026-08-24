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

# ⚠⚠ Am 2026-08-24 am Geraet gelernt: Der HTTP-Aufruf bricht nach kurzer Zeit ab,
# WAEHREND MPC_CALIBRATE in Klipper unbeirrt weiterlaeuft (der G-Code haengt nicht
# an der Verbindung). Frueher feuerte diese Schleife dann sofort den naechsten
# Kopf hinterher - zwei Kalibrierungen gleichzeitig. Deshalb wird jetzt nicht auf
# den Aufruf gewartet, sondern auf die ABSCHLUSSMELDUNG in Klippers Konsole.
warte_auf_abschluss() {
    _e="$1"; _n=0
    while [ "$_n" -lt 240 ]; do        # bis zu 2 Stunden je Kopf
        sleep 30; _n=$((_n + 1))
        _m=$($CURL -s "$URL/server/gcode_store?count=6" 2>/dev/null)
        case "$_m" in
            *block_heat_capacity*|*"sensor_responsiveness"*)
                echo "    $_e fertig (Modellwerte liegen vor)."; return 0 ;;
            *"!! "*|*"Error"*|*"error"*)
                echo "    $_e: Klipper meldet einen Fehler - Abbruch."; return 1 ;;
        esac
        # Sicherheitsnetz: Steht der Heizer wieder auf 0, ist die Routine durch.
        _z=$($CURL -s "$URL/printer/objects/query?$_e" 2>/dev/null \
             | sed -e 's/.*"target": *//' -e 's/[,}].*//')
        case "$_z" in 0|0.0) [ "$_n" -gt 4 ] && { echo "    $_e fertig (Heizer aus)."; return 0; } ;;
        esac
    done
    echo "    $_e: Zeitgrenze erreicht - bitte in der Konsole nachsehen."
    return 1
}

# ⚠⚠ Am 2026-08-24 von Christopher aufgezeigt und hier nachgeprueft:
# Nur der AKTIVE Kopf haengt frei am Traeger. Die anderen drei sitzen in ihrem
# Parkplatz, und dort steckt die Duese in einer Dichtung.
# Zwei Gruende, einen geparkten Kopf NICHT zu kalibrieren:
#  1. Die Duese ist verschlossen - geschmolzenes Material kann nicht abfliessen
#     und staut sich im Hotend.
#  2. Der schwerwiegendere: In der Halterung gibt der Heizblock Waerme ans Metall
#     ab und liegt anders im Luftstrom. Die Messung "wieviel Waerme verliert dieses
#     Hotend" wuerde die PARKPOSITION vermessen, nicht den Druckbetrieb - die
#     Modellwerte waeren genau fuer den Fall falsch, fuer den MPC sie braucht.
pruefe_aktiv() {
    _e="$1"
    _z=$($CURL -s "$URL/printer/objects/query?$_e" 2>/dev/null \
         | sed -e "s/.*\"state\": *\"//" -e "s/\".*//")
    [ "$_z" = "ACTIVATE" ] && return 0
    echo ""
    echo "$_e ist nicht der aktive Kopf (Zustand: ${_z:-unbekannt}) - uebersprungen."
    echo "Ein geparkter Kopf darf nicht kalibriert werden: die Duese steckt in der"
    echo "Dichtung, und die Waermeabgabe in der Halterung ist eine andere als frei"
    echo "ueber dem Bett. Die Messwerte waeren unbrauchbar."
    echo "⇒ Erst diesen Kopf zum aktiven machen (Werkzeugwechsel ueber die"
    echo "  Bedienoberflaeche oder das Druckprofil), dann hier erneut kalibrieren."
    return 1
}

for E in $LISTE; do
    pruefe_aktiv "$E" || continue
    echo ""
    echo "=== MPC_CALIBRATE HEATER=$E FAN_BREAKPOINTS=7 ==="
    echo "    (kuehlt erst auf Raumtemperatur ab, heizt dann ueber 200 Grad und"
    echo "     misst den Waermeverlust in sieben Luefterstufen - dauert)"
    $CURL -s -m 20 -X POST \
        "$URL/printer/gcode/script?script=MPC_CALIBRATE%20HEATER=$E%20FAN_BREAKPOINTS=7" \
        >/dev/null 2>&1
    warte_auf_abschluss "$E" || exit 1
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
