#!/bin/sh
# Laesst Klipper auch Unterordner nach Druckdateien durchsuchen.
# Aufruf: set-sdcard-subdirs.sh on|off
#
# Klipper listet von sich aus nur Dateien, die direkt im Druckdatei-Ordner liegen.
# Wer seine Projekte in Unterordnern sortiert, findet sie ueber die Befehle M20/M23
# und im Menue des Touchscreens deshalb nicht. Kalicos [virtual_sdcard] with_subdirs
# schaltet die Suche in Unterordnern ein.
#
# Betrifft NICHT die Weboberflaeche Mainsail - die listet Unterordner ohnehin, weil
# sie ueber Moonraker geht und nicht ueber M20.
set -e

ZIEL=/oem/printer_data/config/extended/klipper/kalico_sdcard.cfg
mkdir -p "$(dirname "$ZIEL")"

case "$1" in
    on)
        {
            echo "# Erzeugt von firmware-config (Kalico -> Unterordner durchsuchen)."
            echo "# Nicht von Hand aendern."
            echo ""
            echo "[virtual_sdcard]"
            echo "with_subdirs: True"
        } > "$ZIEL"
        chown lava:lava "$ZIEL" 2>/dev/null || true
        chmod 644 "$ZIEL"
        echo "Unterordner werden jetzt mit durchsucht (M20/M23 und Touchscreen-Menue)."
        ;;
    off)
        rm -f "$ZIEL"
        echo "Zurueck zum Standard: nur der oberste Ordner wird gelistet."
        ;;
    *)
        echo "Aufruf: set-sdcard-subdirs.sh on|off" >&2; exit 1 ;;
esac
