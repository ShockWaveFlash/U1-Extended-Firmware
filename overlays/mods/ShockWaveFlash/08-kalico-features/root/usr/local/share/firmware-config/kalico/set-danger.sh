#!/bin/sh
# Setzt oder entfernt eine einzelne Option im Kalico-Abschnitt [danger_options].
# Aufruf: set-danger.sh <name> <wert>     setzt die Option
#         set-danger.sh <name> --         entfernt sie (Kalico-Standard gilt wieder)
#
# [danger_options] sammelt die Einstellungen, die Klipper fest verdrahtet hat und
# Kalico zugaenglich macht. Sie heissen "danger", weil man mit ihnen Schutzmechanismen
# aushebeln KANN - die hier angebotenen tun das nicht, sie betreffen Protokollierung
# und Fehlertoleranz beim Start.
#
# Alle Optionen liegen gemeinsam in einer Datei, damit sich mehrere Schalter nicht
# gegenseitig ueberschreiben: jeder Aufruf liest die vorhandenen Zeilen, tauscht nur
# seine eigene aus und schreibt die Datei neu.
set -e

[ -n "$1" ] && [ -n "$2" ] || { echo "Aufruf: set-danger.sh <name> <wert|-->" >&2; exit 1; }
NAME="$1"; WERT="$2"
ZIEL=/oem/printer_data/config/extended/klipper/kalico_danger.cfg
mkdir -p "$(dirname "$ZIEL")"

# Bestehende Optionen einsammeln (ohne die, die gerade geaendert wird).
REST=""
if [ -f "$ZIEL" ]; then
    REST=$(grep -E '^[a-z_]+:' "$ZIEL" 2>/dev/null | grep -v "^$NAME:" || true)
fi

NEU="$REST"
if [ "$WERT" != "--" ]; then
    NEU=$(printf '%s\n%s: %s\n' "$REST" "$NAME" "$WERT" | grep -E '^[a-z_]+:' || true)
fi

if [ -z "$NEU" ]; then
    rm -f "$ZIEL"
    echo "Letzte danger_option entfernt - die Datei ist weg, es gelten die Kalico-Standards."
    exit 0
fi

{
    echo "# Erzeugt von firmware-config (Kalico -> Danger Options)."
    echo "# Nicht von Hand aendern - jeder Schalterdruck schreibt die Datei neu."
    echo ""
    echo "[danger_options]"
    echo "$NEU" | LC_ALL=C sort
} > "$ZIEL"
chown lava:lava "$ZIEL" 2>/dev/null || true
chmod 644 "$ZIEL"

if [ "$WERT" = "--" ]; then
    echo "$NAME entfernt - es gilt wieder der Kalico-Standard."
else
    echo "$NAME auf $WERT gesetzt."
fi
echo "Aktueller Inhalt von [danger_options]:"
echo "$NEU" | LC_ALL=C sort | sed 's/^/  /'
