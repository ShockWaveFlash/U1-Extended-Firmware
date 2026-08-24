#!/bin/sh
# Legt fest, wohin SAVE_CONFIG schreibt.
# Aufruf: set-autosave.sh main | separate
#
#   main     -- Klippers urspruenglicher Weg: der Block haengt hinten an der
#               printer.cfg. Snapmakers Stock-Klipper findet ihn dort, der
#               Rueckweg ueber /oem/.klipper-tree bleibt also vollstaendig.
#   separate -- Kalicos Weg: eigene Datei printer.autosave.cfg.
#
# ⚠ In diesem Block stehen am U1 das Bettnetz und die PID-Werte aller vier
#   Hotends. Nach dem Umschalten auf "separate" braucht es EIN SAVE_CONFIG,
#   damit die Werte wandern -- und ab da sieht Snapmakers Baum sie nicht mehr.
set -e

MARKE=/oem/.kalico-separate-autosave

case "${1:-}" in
    main)     rm -f "$MARKE"; echo "SAVE_CONFIG schreibt wieder in die printer.cfg." ;;
    separate) : > "$MARKE";   echo "SAVE_CONFIG schreibt kuenftig printer.autosave.cfg." ;;
    *)        echo "Aufruf: set-autosave.sh main | separate" >&2; exit 1 ;;
esac

echo "Klipper startet neu..."
/etc/init.d/S60klipper restart
