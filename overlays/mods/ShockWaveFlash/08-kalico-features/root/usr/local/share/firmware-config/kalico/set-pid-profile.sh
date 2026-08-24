#!/bin/sh
# Laedt ein gespeichertes PID-Profil in alle vier Hotends.
# Aufruf: set-pid-profile.sh <profilname>
#
# Kalico kann zu jedem Heizer mehrere Saetze von Regelwerten vorhalten und im
# laufenden Betrieb umschalten. Der Sinn: die richtigen PID-Werte haengen von der
# Zieltemperatur und von der Luefterdrehzahl ab. Ein Satz, der bei 210 Grad und
# stehendem Luefter stimmt, regelt bei 250 Grad und vollem Luefter schlechter.
# Damit lassen sich Profile je Material anlegen und beim Materialwechsel laden.
#
# ⚠ Das Laden gilt nur bis zum naechsten Klipper-Neustart; danach ist wieder
# "default" aktiv. Dauerhaft wird es, wenn der Profilname im Startmakro des
# Druckprofils geladen wird.
set -e

[ -n "$1" ] || { echo "Aufruf: set-pid-profile.sh <profilname>" >&2; exit 1; }
NAME="$1"
CURL=/usr/local/bin/curl
FEHLER=0

for E in extruder extruder1 extruder2 extruder3; do
    A=$($CURL -s -G --data-urlencode \
        "script=PID_PROFILE LOAD=$NAME HEATER=$E DEFAULT=default" \
        "http://127.0.0.1:7125/printer/gcode/script" 2>&1)
    case "$A" in
        *'"error"'*)
            echo "  $E: FEHLGESCHLAGEN"
            echo "$A" | sed -e 's/.*"message": *"//' -e 's/".*//' -e 's/^/      /'
            FEHLER=1
            ;;
        *)  echo "  $E: Profil '$NAME' geladen" ;;
    esac
done

if [ "$FEHLER" = "1" ]; then
    echo ""
    echo "Mindestens ein Hotend kennt das Profil '$NAME' nicht."
    echo "Vorhandene Profile anzeigen: Aktion „PID-Profile anzeigen“."
    echo "Neues Profil anlegen: erst PID_CALIBRATE HEATER=extruder TARGET=<Temperatur>,"
    echo "danach PID_PROFILE SAVE=$NAME HEATER=extruder und SAVE_CONFIG."
    exit 1
fi
echo ""
echo "Profil '$NAME' ist in allen vier Hotends aktiv (bis zum naechsten Klipper-Neustart)."
