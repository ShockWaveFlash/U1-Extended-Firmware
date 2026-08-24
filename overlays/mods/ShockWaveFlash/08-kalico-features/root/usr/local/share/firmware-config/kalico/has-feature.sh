#!/bin/sh
# Prueft, ob der GERADE LAUFENDE Klipper-Baum eine bestimmte Kalico-Funktion kennt.
# Rueckgabe 0 = kann er, 1 = kann er nicht. Fuer if_cmd in den YAML-Schaltern.
#
# Warum das noetig ist: Nicht jede Funktion, die in Kalicos Doku steht, liegt auch
# im gemergten Baum. Die Smooth-Shaper und das nichtlineare Pressure Advance stehen
# im Kalico-Zweig "bleeding_edge_v2" und fehlen im Hauptzweig - ein Schalter dafuer
# wuerde eine Option in die Konfiguration schreiben, die Klipper beim Start als
# unbekannt ablehnt. Deshalb wird die Oberflaeche gefragt, bevor sie etwas anbietet.
#
# Aufruf: has-feature.sh <name>
set -e

# Wurzel des laufenden Baums bestimmen (nicht raten - am Prozess ablesen).
baumwurzel() {
    _pid=$(pgrep -f klippy.py | head -1)
    [ -n "$_pid" ] && [ -r "/proc/$_pid/cmdline" ] || return 1
    _py=$(tr '\0' '\n' < "/proc/$_pid/cmdline" | grep 'klippy\.py' | head -1)
    [ -n "$_py" ] || return 1
    dirname "$(dirname "$_py")"
}

WURZEL=$(baumwurzel) || exit 1
KLIPPY="$WURZEL/klippy"

case "$1" in
    kalico)
        # Laeuft ueberhaupt Kalico und nicht Snapmakers eigener Klipper?
        [ -f "$KLIPPY/extras/danger_options.py" ]
        ;;
    smooth_shaper)
        grep -q 'smooth_mzv' "$KLIPPY/extras/shaper_defs.py" 2>/dev/null
        ;;
    pa_model)
        grep -rq 'pressure_advance_model' "$KLIPPY/kinematics/extruder.py" 2>/dev/null
        ;;
    mpc)
        grep -q '"mpc"' "$KLIPPY/extras/heaters.py" 2>/dev/null \
            || [ -f "$KLIPPY/extras/mpc.py" ]
        ;;
    pid_v)
        grep -q 'pid_v' "$KLIPPY/extras/heaters.py" 2>/dev/null
        ;;
    dual_loop_pid)
        grep -q 'dual_loop_pid' "$KLIPPY/extras/heaters.py" 2>/dev/null
        ;;
    *)
        echo "unbekannte Funktion: $1" >&2
        exit 2
        ;;
esac
