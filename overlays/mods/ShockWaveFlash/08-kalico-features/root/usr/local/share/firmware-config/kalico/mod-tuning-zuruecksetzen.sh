#!/bin/sh
# Setzt die Tuning-Fragmente unter extended/klipper/ zurueck, indem es sie in
# einen Unterordner verschiebt. Danach gelten wieder die Werte der printer.cfg.
#
# ⚠ HARDWARE UND SICHERHEIT BLEIBEN UNANGETASTET:
#   motor_geometry / motor_current / motor_hold_current beschreiben, was
#     physisch verbaut ist (LDO-Stepper: rotation_distance 39,0 bei 400
#     Vollschritten, 1,4 A). Ohne sie faellt der Drucker auf die Stock-
#     Geometrie 40/200 zurueck und faehrt falsche Wege - kein Reset, ein Defekt.
#   frame_thermistor / z_thermal_ref tragen die Z-Drift-Kompensation ueber den
#     Rahmenthermistor am Pico.
#   kalico_pico_optional haelt den Pico unkritisch - ohne sie legt sein Ausfall
#     den ganzen Drucker lahm.
#   panda_breath / verify_heater_panda sind Heizungsueberwachung.
#   Das alles gehoert nicht in einen Tuning-Reset.
#
# ⚠ NICHTS WIRD GELOESCHT. Alles landet in extended/klipper/zurueckgesetzt-<Stempel>/
#   und laesst sich von Hand zurueckschieben.
#
# Aufruf:  mod-tuning-zuruecksetzen.sh [--trockenlauf]
set -e

DIR=${DIR:-/oem/printer_data/config/extended/klipper}
BEHALTEN="00_keep.cfg
          motor_geometry.cfg motor_current.cfg motor_hold_current.cfg
          frame_thermistor.cfg z_thermal_ref.cfg kalico_pico_optional.cfg
          panda_breath.cfg verify_heater_panda.cfg"
TROCKEN=0
[ "${1:-}" = "--trockenlauf" ] && TROCKEN=1

[ -d "$DIR" ] || { echo "Verzeichnis fehlt: $DIR"; exit 1; }

ZIEL="$DIR/zurueckgesetzt-$(date +%Y%m%d-%H%M%S)"
N=0
LISTE=""
for f in "$DIR"/*.cfg; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    skip=0
    for k in $BEHALTEN; do
        [ "$b" = "$k" ] && skip=1
    done
    [ "$skip" = "1" ] && continue
    LISTE="$LISTE $b"
    N=$((N + 1))
done

if [ "$N" = "0" ]; then
    echo "Keine Tuning-Fragmente vorhanden - nichts zu tun."
    exit 0
fi

echo "Wird zurueckgesetzt ($N Dateien):"
for b in $LISTE; do echo "   $b"; done
echo ""
echo "Bleibt unangetastet (Hardware, Sensorik, Sicherheit):"
for k in $BEHALTEN; do [ -e "$DIR/$k" ] && echo "   $k"; done

if [ "$TROCKEN" = "1" ]; then
    echo ""
    echo "TROCKENLAUF - es wurde nichts verschoben."
    exit 0
fi

mkdir -p "$ZIEL"
for b in $LISTE; do
    mv "$DIR/$b" "$ZIEL/$b"
done
chown -R lava:lava "$ZIEL" 2>/dev/null || true

echo ""
echo "Verschoben nach: $ZIEL"
echo "Zurueckholen:    mv $ZIEL/*.cfg $DIR/ && chown lava:lava $DIR/*.cfg"
echo ""
echo "Klipper neu starten, damit es greift:"
curl -s -m 25 -X POST "http://127.0.0.1:7125/printer/gcode/script?script=FIRMWARE_RESTART" >/dev/null 2>&1 || true
echo "   FIRMWARE_RESTART abgesetzt."
