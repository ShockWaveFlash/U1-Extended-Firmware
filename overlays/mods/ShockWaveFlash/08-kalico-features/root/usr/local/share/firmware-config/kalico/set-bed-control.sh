#!/bin/sh
# Stellt die Temperaturregelung des HEIZBETTS um.
# Aufruf: set-bed-control.sh pid|pid_v|watermark
#
# Das Bett des U1 ist eine 400-W-Wechselstromheizung mit sehr traeger Reaktion
# (grosse Masse, Heizfolie unter der Platte). Deshalb:
#
# pid       - Standard. Bewaehrt, ueberschwingt beim Aufheizen leicht.
# pid_v     - Velocity PID. Ueberschwingt weniger, braucht aber ein ruhiges
#             Sensorsignal. Beim traegen Bett meist die bessere Wahl - vorher
#             aber PID_CALIBRATE fahren, die alten Werte passen nicht.
# watermark - Zweipunktregler: unter der Zieltemperatur voll an, darueber aus.
#             Simpel und unkaputtbar, dafuer pendelt die Temperatur um +/-2 Grad.
#             Nur als Notloesung, wenn die PID-Werte nicht mehr stimmen.
#
# ⚠ MPC gibt es fuers Bett bewusst nicht: MPC modelliert die Waermeabfuhr ueber
# den Bauteilluefter und das durchlaufende Filament - beides trifft aufs Bett
# nicht zu. Kalicos Dual-Loop-PID scheidet ebenfalls aus, es braucht einen
# ZWEITEN Temperaturfuehler im Heizelement, und den hat der U1 nicht.
set -e

ZIEL=/oem/printer_data/config/extended/klipper/kalico_bed_control.cfg
mkdir -p "$(dirname "$ZIEL")"

# ⚠⚠ Vorpruefung, am 2026-08-24 am Geraet erzwungen:
# Snapmakers Klipper-Patch bringt in [heater_bed] die Option ignore_pid_json mit.
# Gelesen wird sie ausschliesslich von der PID-Klasse (heaters.py,
# _init_snapmaker_pid_profiles in ControlPID). Stellt man das Bett auf pid_v oder
# watermark um, laeuft eine andere Klasse an, die Option bleibt ungelesen - und
# Klipper bricht beim Start ab:
#   "Option 'ignore_pid_json' is not valid in section 'heater_bed'"
# Der Drucker steht dann als "halted" da. Deshalb hier vorher nachsehen, statt den
# Nutzer in den Startfehler laufen zu lassen.
pruefe_snapmaker_option() {
    _wert=$(/usr/local/bin/curl -s \
        "http://127.0.0.1:7125/printer/objects/query?configfile=settings" 2>/dev/null \
        | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)["result"]["status"]["configfile"]["settings"]
    print("ja" if s.get("heater_bed", {}).get("ignore_pid_json") is not None else "nein")
except Exception:
    print("unbekannt")
' 2>/dev/null)
    [ "$_wert" = "ja" ] || return 1
    echo "Das geht bei diesem Drucker nicht." >&2
    echo "" >&2
    echo "In [heater_bed] steht Snapmakers eigene Option ignore_pid_json. Die liest nur" >&2
    echo "Kalicos PID-Klasse. Bei '$1' laeuft eine andere Klasse an, die Option bleibt" >&2
    echo "ungelesen, und Klipper verweigert den Start:" >&2
    echo "  Option 'ignore_pid_json' is not valid in section 'heater_bed'" >&2
    echo "" >&2
    echo "Das Bett bleibt deshalb auf PID. Aendern liesse sich das nur, indem die" >&2
    echo "Option aus der printer.cfg verschwindet - dann verliert das Bett aber" >&2
    echo "Snapmakers PID-Profilverwaltung." >&2
    return 0
}

case "$1" in
    pid)
        rm -f "$ZIEL"
        echo "Bett zurueck auf PID (Standard)."
        ;;
    pid_v)
        pruefe_snapmaker_option pid_v && exit 1
        {
            echo "# Erzeugt von firmware-config (Kalico -> Bett-Regelung)."
            echo "# Nicht von Hand aendern."
            echo ""
            echo "[heater_bed]"
            echo "control: pid_v"
        } > "$ZIEL"
        chown lava:lava "$ZIEL" 2>/dev/null || true
        chmod 644 "$ZIEL"
        echo "Bett auf Velocity PID umgestellt."
        echo "⚠ Empfohlen: PID_CALIBRATE HEATER=heater_bed TARGET=60"
        ;;
    watermark)
        pruefe_snapmaker_option watermark && exit 1
        {
            echo "# Erzeugt von firmware-config (Kalico -> Bett-Regelung)."
            echo "# Nicht von Hand aendern."
            echo ""
            echo "[heater_bed]"
            echo "control: watermark"
            echo "max_delta: 2.0"
        } > "$ZIEL"
        chown lava:lava "$ZIEL" 2>/dev/null || true
        chmod 644 "$ZIEL"
        echo "Bett auf Zweipunktregelung (watermark, +/-2 Grad) umgestellt."
        ;;
    *)
        echo "Aufruf: set-bed-control.sh pid|pid_v|watermark" >&2; exit 1 ;;
esac
