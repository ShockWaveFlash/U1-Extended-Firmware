#!/bin/sh
# Zeigt, welcher Klipper-Unterbau laeuft und wie die Kalico-Schalter stehen.
# Die Werte werden am laufenden System abgelesen, nicht aus den Dateien geraten.
CFG=/oem/printer_data/config/extended/klipper
CURL=/usr/local/bin/curl

echo "Klipper-Unterbau"
PID=$(pgrep -f klippy.py | head -1)
if [ -n "$PID" ] && [ -r "/proc/$PID/cmdline" ]; then
    BAUM=$(tr '\0' ' ' < "/proc/$PID/cmdline" | tr ' ' '\n' | grep 'klippy\.py' | head -1)
    case "$BAUM" in
        */kalico/*) echo "  KALICO laeuft            $BAUM" ;;
        *)          echo "  Snapmaker Original       $BAUM" ;;
    esac
else
    echo "  Klipper laeuft nicht"
fi
if [ -f /oem/.klipper-tree ]; then
    echo "  Umschalter               /oem/.klipper-tree -> $(cat /oem/.klipper-tree)"
else
    echo "  Umschalter               nicht gesetzt (= Original)"
fi

echo ""
echo "Verfuegbare Funktionen im laufenden Unterbau"
H=/usr/local/share/firmware-config/kalico/has-feature.sh
for paar in "kalico|Kalico-Erweiterungen" "smooth_shaper|Weiche Schwingungsausgleicher" \
            "pa_model|Nichtlinearer Druckvorhalt" "mpc|Modellbasierte Heizregelung" \
            "pid_v|Velocity PID"; do
    f=${paar%%|*}; t=${paar#*|}
    if sh "$H" "$f" 2>/dev/null; then
        printf "  %-38s ja\n" "$t"
    else
        printf "  %-38s nein\n" "$t"
    fi
done

echo ""
echo "Schalterstellungen"

zeige() {  # zeige <Beschriftung> <Text>
    printf "  %-24s %s\n" "$1" "$2"
}

if [ -f "$CFG/kalico_home_current.cfg" ]; then
    zeige "Homing-Strom X/Y" "$(grep -m1 '^home_current' "$CFG/kalico_home_current.cfg" | awk '{print $2}') A"
else
    zeige "Homing-Strom X/Y" "nicht gesetzt (Kalico nimmt den vollen Fahrstrom)"
fi

if [ -f "$CFG/kalico_pico_optional.cfg" ]; then
    zeige "Rahmenfuehler-Pico" "entbehrlich"
else
    zeige "Rahmenfuehler-Pico" "Pflicht (Standard)"
fi

if [ -f "$CFG/kalico_hotend_control.cfg" ]; then
    if grep -q 'control: *mpc' "$CFG/kalico_hotend_control.cfg"; then
        zeige "Hotend-Regelung" "MPC"
    else
        zeige "Hotend-Regelung" "Velocity PID"
    fi
elif [ -f "$CFG/kalico_mpc.cfg" ]; then
    zeige "Hotend-Regelung" "MPC (alte Datei kalico_mpc.cfg)"
else
    zeige "Hotend-Regelung" "PID (Standard)"
fi

if [ -f "$CFG/kalico_bed_control.cfg" ]; then
    zeige "Bett-Regelung" "$(grep -m1 '^control:' "$CFG/kalico_bed_control.cfg" | awk '{print $2}')"
else
    zeige "Bett-Regelung" "PID (Standard)"
fi

if [ -f "$CFG/kalico_shaper.cfg" ]; then
    zeige "Schwingungsausgleich" "$(grep -m1 '^shaper_type' "$CFG/kalico_shaper.cfg" | awk '{print $2}')"
else
    zeige "Schwingungsausgleich" "klassisch (Standard)"
fi

if [ -f "$CFG/kalico_pa.cfg" ]; then
    zeige "Druckvorhalt-Modell" "$(grep -m1 '^pressure_advance_model' "$CFG/kalico_pa.cfg" | awk '{print $2}')"
else
    zeige "Druckvorhalt-Modell" "linear (Standard)"
fi

if [ -f /oem/.kalico-separate-autosave ]; then
    zeige "SAVE_CONFIG schreibt nach" "printer.autosave.cfg"
    [ -f /home/lava/printer_data/config/printer.autosave.cfg ] \
        || echo "                           (noch nicht angelegt - ein SAVE_CONFIG fehlt)"
else
    zeige "SAVE_CONFIG schreibt nach" "printer.cfg (Standard)"
fi

[ -f "$CFG/kalico_sdcard.cfg" ] \
    && zeige "Unterordner-Suche" "ein" \
    || zeige "Unterordner-Suche" "aus (Standard)"

[ -f "$CFG/kalico_testtowers.cfg" ] \
    && zeige "Testdrucke" "freigeschaltet" \
    || zeige "Testdrucke" "aus (Standard)"

if [ -f "$CFG/kalico_danger.cfg" ]; then
    zeige "Danger Options" "gesetzt:"
    grep -E '^[a-z_]+:' "$CFG/kalico_danger.cfg" | sed 's/^/                             /'
else
    zeige "Danger Options" "keine (Kalico-Standard)"
fi

P=$($CURL -s "http://127.0.0.1:7125/printer/objects/query?extruder" 2>/dev/null \
    | sed -e 's/.*"pid_profile": *"//' -e 's/".*//')
zeige "PID-Profil (extruder)" "${P:-nicht abfragbar}"

echo ""
echo "Kaltextrusion (gilt nur bis zum naechsten Klipper-Neustart)"
# ⚠ Die Antwort von COLD_EXTRUDE steht NICHT in der HTTP-Antwort (die sagt nur
# {"result": "ok"}), sondern geht als Konsolenmeldung an Moonrakers gcode_store.
for E in extruder extruder1 extruder2 extruder3; do
    $CURL -s -X POST \
        "http://127.0.0.1:7125/printer/gcode/script?script=COLD_EXTRUDE%20HEATER=$E" \
        >/dev/null 2>&1
    A=$($CURL -s "http://127.0.0.1:7125/server/gcode_store?count=1" 2>/dev/null)
    case "$A" in
        *"Cold extrudes are enabled"*)  printf "  %-24s erlaubt\n"  "$E" ;;
        *"Cold extrudes are disabled"*) printf "  %-24s gesperrt\n" "$E" ;;
        *)                              printf "  %-24s nicht abfragbar\n" "$E" ;;
    esac
done

echo ""
echo "High Precision Stepping: nur per MCU-Neubau schaltbar, nicht ueber diese"
echo "Oberflaeche - die Option verlangt eine selbst uebersetzte Firmware fuer alle"
echo "sechs Mikrocontroller."
