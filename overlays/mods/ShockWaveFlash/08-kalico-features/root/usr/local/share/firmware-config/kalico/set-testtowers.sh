#!/bin/sh
# Schaltet Kalicos eingebaute Testdrucke frei.
# Aufruf: set-testtowers.sh on|off
#
# Kalico kann zwei Kalibrier-Testkoerper OHNE Slicer drucken - der G-Code entsteht
# direkt im Drucker. Der Vorteil gegenueber den ueblichen Testdateien: Beschleunigung
# bzw. Druckvorhalt aendern sich WAEHREND des Drucks in sauber definierten Stufen,
# statt dass fuer jede Stufe ein eigenes Modell gesliced werden muss.
#
#   PRINT_RINGING_TOWER - Turm gegen Geisterbilder. Die Beschleunigung steigt alle
#                         5 mm Hoehe um 500 mm/s^2. An der Hoehe, ab der die Kerben
#                         unsauber werden, liest man die Grenze ab.
#   PRINT_PA_TOWER      - Turm fuer den Druckvorhalt. Jede Bahn wird mit drei
#                         Geschwindigkeiten gedruckt, der Vorhalt steigt nach oben.
#
# Die Werte bleiben auf den Vorgaben der Module; Bettmitte und Modellgroesse
# ermitteln sie selbst aus der Druckerkonfiguration.
set -e

ZIEL=/oem/printer_data/config/extended/klipper/kalico_testtowers.cfg
mkdir -p "$(dirname "$ZIEL")"

case "$1" in
    on)
        {
            echo "# Erzeugt von firmware-config (Kalico -> Testdrucke)."
            echo "# Nicht von Hand aendern."
            echo "#"
            echo "# Schaltet die Befehle PRINT_RINGING_TOWER und PRINT_PA_TOWER frei."
            echo "# Ohne diese Abschnitte kennt Klipper die Befehle nicht."
            echo ""
            echo "[ringing_test]"
            echo ""
            echo "[pa_test]"
        } > "$ZIEL"
        chown lava:lava "$ZIEL" 2>/dev/null || true
        chmod 644 "$ZIEL"
        echo "Testdrucke freigeschaltet: PRINT_RINGING_TOWER und PRINT_PA_TOWER."
        ;;
    off)
        rm -f "$ZIEL"
        echo "Testdrucke abgeschaltet - die beiden Befehle sind wieder unbekannt."
        ;;
    *)
        echo "Aufruf: set-testtowers.sh on|off" >&2; exit 1 ;;
esac
