#!/bin/sh
# Schreibt das last-wins-Fragment, das die vier Hotends auf MPC umstellt.
# Aufruf: set-mpc.sh on
# Zurueck auf PID: Datei loeschen (macht der Schalter selbst).
#
# Werte fuer den U1 (in dieser Sitzung belegt):
#   heater_power 48   -> Keramikheizer 24 V / 48 W, auch bei den High-Flow-Hotends
#                        (Snapmaker-Shop und eigener HF-Beta-Test-Bericht)
#   cooling_fan       -> Part-Cooling je Toolhead: [fan] fuer extruder (Pin e0:PB3),
#                        fan_generic e1_fan / e2_fan / e3_fan fuer die anderen
#   ambient_temp_sensor wird ABSICHTLICH nicht gesetzt - Kalicos MPC-Doku
#                        empfiehlt ausdruecklich, den Wert schaetzen zu lassen
#   filament_*        -> Startwerte fuer PLA. Fuer andere Materialien anpassen:
#                        PETG 1.27 / 1.9, ABS 1.04 / 2.0, TPU 1.21 / 1.8
#
# ⚠ Ohne MPC_CALIBRATE arbeitet MPC nur mit Schaetzwerten. Nach dem Umschalten:
#     MPC_CALIBRATE HEATER=extruder  FAN_BREAKPOINTS=7
#     MPC_CALIBRATE HEATER=extruder1 FAN_BREAKPOINTS=7
#     MPC_CALIBRATE HEATER=extruder2 FAN_BREAKPOINTS=7
#     MPC_CALIBRATE HEATER=extruder3 FAN_BREAKPOINTS=7
#   Das Bett bleibt bewusst auf PID.
set -e

if [ "$1" != "on" ]; then
    echo "Aufruf: set-mpc.sh on" >&2
    exit 1
fi

ZIEL=/oem/printer_data/config/extended/klipper/kalico_mpc.cfg
mkdir -p "$(dirname "$ZIEL")"

schreibe_extruder() {
    _sec="$1"; _fan="$2"
    echo ""
    echo "[$_sec]"
    echo "control: mpc"
    echo "heater_power: 48"
    echo "cooling_fan: $_fan"
    echo "filament_diameter: 1.75"
    echo "filament_density: 1.24"
    echo "filament_heat_capacity: 1.8"
}

{
    echo "# Erzeugt von firmware-config (Kalico Features -> Hotend Temperature Control)."
    echo "# Nicht von Hand aendern - der naechste Schalterdruck ueberschreibt die Datei."
    echo "# Nach dem Umschalten MPC_CALIBRATE je Hotend fahren, sonst schaetzt MPC nur."
    schreibe_extruder extruder  "fan"
    schreibe_extruder extruder1 "fan_generic e1_fan"
    schreibe_extruder extruder2 "fan_generic e2_fan"
    schreibe_extruder extruder3 "fan_generic e3_fan"
} > "$ZIEL"

echo "All four hotends switched to MPC. Run MPC_CALIBRATE for each of them."
