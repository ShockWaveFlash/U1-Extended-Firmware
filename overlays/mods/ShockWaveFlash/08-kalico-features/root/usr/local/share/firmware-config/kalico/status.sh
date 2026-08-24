#!/bin/sh
# Zeigt, welcher Klipper-Baum laeuft und welche Kalico-Schalter aktiv sind.
CFG=/oem/printer_data/config/extended/klipper

echo "Klipper-Baum:"
PID=$(pgrep -f klippy.py | head -1)
if [ -n "$PID" ] && [ -r "/proc/$PID/cmdline" ]; then
    BAUM=$(tr '\0' ' ' < "/proc/$PID/cmdline" | tr ' ' '\n' | grep 'klippy\.py' | head -1)
    case "$BAUM" in
        */kalico/*) echo "  KALICO aktiv  ($BAUM)" ;;
        *)          echo "  Snapmaker Stock  ($BAUM)" ;;
    esac
else
    echo "  Klipper laeuft nicht"
fi
if [ -f /oem/.klipper-tree ]; then
    echo "  Umschalter /oem/.klipper-tree -> $(cat /oem/.klipper-tree)"
else
    echo "  Umschalter /oem/.klipper-tree nicht gesetzt (= Stock)"
fi

echo ""
echo "Kalico-Schalter:"

if [ -f "$CFG/kalico_shaper.cfg" ]; then
    echo "  Input Shaper       : $(grep -m1 '^shaper_type_x' "$CFG/kalico_shaper.cfg" | awk '{print $2}')"
else
    echo "  Input Shaper       : classic (stock)"
fi

if [ -f "$CFG/kalico_pa.cfg" ]; then
    echo "  Pressure Advance   : $(grep -m1 '^pressure_advance_model' "$CFG/kalico_pa.cfg" | awk '{print $2}')"
else
    echo "  Pressure Advance   : linear (stock)"
fi

if [ -f "$CFG/kalico_mpc.cfg" ]; then
    echo "  Hotend-Regelung    : MPC"
else
    echo "  Hotend-Regelung    : PID (stock)"
fi

if [ -f /oem/.kalico-separate-autosave ]; then
    echo "  SAVE_CONFIG        : eigene Datei (printer.autosave.cfg)"
    [ -f /home/lava/printer_data/config/printer.autosave.cfg ] \
        || echo "                       (noch nicht angelegt - ein SAVE_CONFIG fehlt)"
else
    echo "  SAVE_CONFIG        : printer.cfg (Standard, Stock-tauglich)"
fi

echo ""
echo "Kaltextrusion (nicht dauerhaft, gilt bis zum Klipper-Neustart):"
# ⚠ Die Antwort von COLD_EXTRUDE steht NICHT in der HTTP-Antwort (die sagt nur
# {"result": "ok"}), sondern geht als Konsolenmeldung an Moonrakers gcode_store.
# Deshalb: abfragen, kurz warten, letzte Meldung dort abholen.
for E in extruder extruder1 extruder2 extruder3; do
    /usr/local/bin/curl -s -X POST \
        "http://127.0.0.1:7125/printer/gcode/script?script=COLD_EXTRUDE%20HEATER=$E" \
        >/dev/null 2>&1
    A=$(/usr/local/bin/curl -s "http://127.0.0.1:7125/server/gcode_store?count=1" 2>/dev/null)
    case "$A" in
        *"Cold extrudes are enabled"*)  echo "  $E: erlaubt" ;;
        *"Cold extrudes are disabled"*) echo "  $E: gesperrt" ;;
        *)                              echo "  $E: nicht abfragbar (laeuft Kalico?)" ;;
    esac
done

echo ""
echo "High-Precision Stepping: nur per MCU-Flash schaltbar (CONFIG_HIGH_PREC_STEP),"
echo "  nicht ueber diese Oberflaeche."
