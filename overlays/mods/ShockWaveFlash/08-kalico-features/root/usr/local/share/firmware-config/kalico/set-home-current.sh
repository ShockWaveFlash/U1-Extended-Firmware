#!/bin/sh
# Setzt den Motorstrom, mit dem Kalico die X/Y-Achsen referenziert.
# Aufruf: set-home-current.sh <Ampere>   oder   set-home-current.sh aus
#
# ⚠⚠ Warum es diesen Schalter ueberhaupt gibt (am 2026-08-24 teuer gelernt):
# Kalico bringt [tmc] home_current mit und setzt den Strom beim Homing selbst.
# Ohne Angabe nimmt es den vollen run_current (klippy/extras/tmc.py). Der U1 homt
# aber SENSORLESS: der Treiber erkennt den Anschlag daran, dass das Drehmoment
# einbricht. Mit vollen 1,4 A merkt StallGuard davon nichts mehr - das Ergebnis war
#   "No trigger on y after full movement"
# und der Drucker liess sich nicht mehr referenzieren.
# 0,650 A ist derselbe Wert, den auch das Makro in homing_holdcurrent.cfg benutzt;
# damit ziehen Makro und Kalico am selben Strang statt gegeneinander.
set -e

ZIEL=/oem/printer_data/config/extended/klipper/kalico_home_current.cfg

if [ "$1" = "aus" ]; then
    rm -f "$ZIEL"
    echo "home_current entfernt - Kalico homt wieder mit dem vollen run_current."
    echo "⚠ Beim U1 faellt damit das sensorless Homing aus. Nur sinnvoll, wenn das"
    echo "  Homing anders geloest ist."
    exit 0
fi

WERT="$1"
case "$WERT" in
    0.[3-9]|0.[3-9][0-9]|0.[3-9][0-9][0-9]|1.[0-4]|1.[0-4][0-9]|1.[0-4][0-9][0-9]) ;;
    *) echo "Ungueltiger Strom: '$WERT'. Erlaubt sind 0.30 bis 1.49 A." >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$ZIEL")"
{
    echo "# Erzeugt von firmware-config (Kalico -> Homing-Strom X/Y)."
    echo "# Nicht von Hand aendern - der naechste Schalterdruck ueberschreibt die Datei."
    echo "#"
    echo "# Strom waehrend des Referenzierens. Zu hoch = StallGuard erkennt den Anschlag"
    echo "# nicht (\"No trigger on x/y after full movement\"), zu niedrig = der Kopf bleibt"
    echo "# schon unterwegs stehen und meldet einen Anschlag, der keiner ist."
    echo ""
    echo "[tmc2240 stepper_x]"
    echo "home_current: $WERT"
    echo "current_change_dwell_time: 0.5"
    echo ""
    echo "[tmc2240 stepper_y]"
    echo "home_current: $WERT"
    echo "current_change_dwell_time: 0.5"
} > "$ZIEL"
chown lava:lava "$ZIEL" 2>/dev/null || true
chmod 644 "$ZIEL"
echo "Homing-Strom X/Y auf $WERT A gesetzt (Wartezeit nach dem Umschalten: 0,5 s)."
