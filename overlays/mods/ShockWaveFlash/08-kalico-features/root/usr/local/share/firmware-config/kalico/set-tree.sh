#!/bin/sh
# Schaltet zwischen Snapmakers Stock-Klipper und dem Kalico-Baum um.
# Aufruf: set-tree.sh stock | kalico
#
# Der Umschalter ist die Datei /oem/.klipper-tree, die das Init-Skript
# /etc/init.d/S60klipper auswertet. Fehlt sie oder zeigt sie ins Leere,
# startet Snapmakers Baum -- der Rueckweg ist also immer offen.
set -e

ZIEL=/home/lava/kalico
SCHALTER=/oem/.klipper-tree

# Nicht mitten im Druck umschalten.
ZUSTAND=$(/usr/local/bin/curl -s "http://127.0.0.1:7125/printer/objects/query?print_stats" 2>/dev/null \
          | sed -n 's/.*"state": *"\([a-z]*\)".*/\1/p')
case "$ZUSTAND" in
    printing|paused)
        echo "Der Drucker ist im Zustand '$ZUSTAND' - Abbruch."
        echo "Erst den Druck beenden, dann umschalten."
        exit 1 ;;
esac

case "${1:-}" in
    stock)
        rm -f "$SCHALTER"
        echo "Zurueck auf Snapmakers Klipper."
        ;;
    kalico)
        if [ ! -f "$ZIEL/klippy/klippy.py" ]; then
            echo "Der Kalico-Baum liegt nicht unter $ZIEL."
            echo "Erst tools/install-kalico-u1.sh von CT 105 aus laufen lassen."
            exit 1
        fi
        echo "$ZIEL" > "$SCHALTER"
        echo "Kalico eingeschaltet ($ZIEL)."
        ;;
    *)
        echo "Aufruf: set-tree.sh stock | kalico" >&2
        exit 1 ;;
esac

echo "Klipper startet neu..."
/etc/init.d/S60klipper restart
sleep 8
BAUM=$(tr '\0' ' ' < "/proc/$(pgrep -f klippy.py | head -1)/cmdline" 2>/dev/null \
       | tr ' ' '\n' | grep 'klippy\.py' | head -1)
echo "Laeuft jetzt: ${BAUM:-(Klipper startet noch)}"
