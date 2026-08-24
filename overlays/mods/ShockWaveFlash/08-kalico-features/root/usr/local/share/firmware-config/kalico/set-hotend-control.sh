#!/bin/sh
# Stellt die Temperaturregelung ALLER VIER Hotends um.
# Aufruf: set-hotend-control.sh pid|pid_v|mpc
#
# pid    - Klippers Original. Regelt nach dem Temperaturfehler: zu kalt -> mehr
#          Heizleistung. Kennt weder Materialfluss noch Luefter und faengt deshalb
#          immer erst NACH dem Temperatureinbruch an gegenzusteuern.
# pid_v  - "Velocity PID". Rechnet mit der AENDERUNGSRATE der Temperatur statt mit
#          dem absoluten Fehler. Reagiert schneller und ueberschwingt weniger,
#          reagiert dafuer empfindlicher auf einen verrauschten Temperaturfuehler.
# mpc    - Model Predictive Control. Bildet das Hotend physikalisch ab: 48 W
#          Heizleistung, Waermekapazitaet des Blocks, abgefuehrte Waerme durch das
#          durchlaufende Filament und durch den Bauteilluefter. Damit weiss die
#          Regelung schon VOR dem Einbruch, dass gleich mehr Leistung noetig ist.
#
# Die MPC-Werte fuer den U1 sind in dieser Datei hinterlegt (belegt aus dem
# Snapmaker-Shop und dem eigenen High-Flow-Beta-Test): Keramikheizer 24 V / 48 W,
# je Toolhead ein eigener Bauteilluefter.
# ambient_temp_sensor wird ABSICHTLICH nicht gesetzt - Kalicos MPC-Doku empfiehlt
# ausdruecklich, die Umgebungstemperatur schaetzen zu lassen.
# filament_* sind Startwerte fuer PLA (PETG 1.27/1.9, ABS 1.04/2.0, TPU 1.21/1.8).
#
# ⚠ Ohne MPC_CALIBRATE arbeitet MPC nur mit diesen Schaetzwerten.
# Das Bett wird hier NICHT angefasst - dafuer gibt es einen eigenen Schalter.
set -e

ZIEL=/oem/printer_data/config/extended/klipper/kalico_hotend_control.cfg
ALT=/oem/printer_data/config/extended/klipper/kalico_mpc.cfg   # Name vor 2026-08-24
mkdir -p "$(dirname "$ZIEL")"
rm -f "$ALT"

case "$1" in
    pid)
        rm -f "$ZIEL"
        echo "Alle vier Hotends zurueck auf PID (Klipper-Original)."
        echo "Die gespeicherten pid_Kp/Ki/Kd gelten wieder unveraendert."
        ;;
    pid_v)
        {
            echo "# Erzeugt von firmware-config (Kalico -> Hotend-Regelung)."
            echo "# Nicht von Hand aendern."
            echo "#"
            echo "# Velocity PID: regelt ueber die Aenderungsrate der Temperatur."
            echo "# Die vorhandenen pid_Kp/Ki/Kd werden weiterverwendet, passen aber"
            echo "# nicht zwingend - nach dem Umstellen einmal PID_CALIBRATE fahren."
            for s in extruder extruder1 extruder2 extruder3; do
                echo ""
                echo "[$s]"
                echo "control: pid_v"
            done
        } > "$ZIEL"
        chown lava:lava "$ZIEL" 2>/dev/null || true
        chmod 644 "$ZIEL"
        echo "Alle vier Hotends auf Velocity PID umgestellt."
        echo "⚠ Empfohlen: PID_CALIBRATE HEATER=extruder TARGET=220 (je Hotend)."
        ;;
    mpc)
        {
            echo "# Erzeugt von firmware-config (Kalico -> Hotend-Regelung)."
            echo "# Nicht von Hand aendern."
            echo "#"
            echo "# MPC rechnet mit einem physikalischen Modell des Hotends. Ohne"
            echo "# MPC_CALIBRATE sind die Werte unten nur Schaetzungen."
            for paar in "extruder|fan" "extruder1|fan_generic e1_fan" \
                        "extruder2|fan_generic e2_fan" "extruder3|fan_generic e3_fan"; do
                s=${paar%%|*}; f=${paar#*|}
                echo ""
                echo "[$s]"
                echo "control: mpc"
                echo "heater_power: 48"
                echo "cooling_fan: $f"
                echo "filament_diameter: 1.75"
                echo "filament_density: 1.24"
                echo "filament_heat_capacity: 1.8"
            done
        } > "$ZIEL"
        chown lava:lava "$ZIEL" 2>/dev/null || true
        chmod 644 "$ZIEL"
        echo "Alle vier Hotends auf MPC umgestellt."
        echo "⚠ Jetzt MPC_CALIBRATE je Hotend fahren, sonst schaetzt MPC nur."
        ;;
    *)
        echo "Aufruf: set-hotend-control.sh pid|pid_v|mpc" >&2; exit 1 ;;
esac
