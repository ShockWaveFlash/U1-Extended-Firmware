#!/bin/sh
# Schaltet die Kaltextrusion an allen vier Hotends.
# Aufruf: set-cold-extrude.sh 1 | 0
#
# COLD_EXTRUDE ist ein Mux-Kommando je Heizer -- am Vierkopfdrucker muss es
# also viermal gesendet werden. Nicht dauerhaft: nach einem Klipper-Neustart
# gilt wieder die normale Mindesttemperatur.
set -e

case "${1:-}" in 0|1) AN="$1" ;; *) echo "Aufruf: set-cold-extrude.sh 1 | 0" >&2; exit 1 ;; esac

URL="http://127.0.0.1:7125/printer/gcode/script"
for E in extruder extruder1 extruder2 extruder3; do
    A=$(/usr/local/bin/curl -s -X POST "$URL?script=COLD_EXTRUDE%20HEATER=$E%20ENABLE=$AN")
    case "$A" in
        *error*|*Unknown*) echo "  $E: FEHLER - $A"; exit 1 ;;
        *) echo "  $E: ok" ;;
    esac
done

[ "$AN" = 1 ] \
  && echo "Kaltextrusion erlaubt (bis zum naechsten Klipper-Neustart)." \
  || echo "Kaltextrusion wieder gesperrt."
