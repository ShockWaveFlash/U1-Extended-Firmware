#!/bin/sh
# Schickt einen G-Code an Klipper und zeigt, was Klipper darauf geantwortet hat.
# Aufruf: gcode.sh "BED_MESH_CHECK MAX_DEVIATION=0.3"
#
# ⚠ Die HTTP-Antwort von Moonraker sagt nur {"result": "ok"} - die eigentliche
# Meldung des Befehls landet in Moonrakers gcode_store. Deshalb wird sie von dort
# nachgeholt. Fehler (z. B. eine fehlgeschlagene Mesh-Pruefung) kommen dagegen
# direkt in der HTTP-Antwort als "error" zurueck.
set -e

[ -n "$1" ] || { echo "Aufruf: gcode.sh <G-Code>" >&2; exit 1; }
BEFEHL="$1"
CURL=/usr/local/bin/curl

# Wieviele Zeilen im Speicher stehen, bevor der Befehl laeuft - damit hinterher
# nur die neuen Zeilen gezeigt werden.
VORHER=$($CURL -s "http://127.0.0.1:7125/server/gcode_store?count=100" 2>/dev/null \
         | tr ',' '\n' | grep -c '"message"' || echo 0)

echo "> $BEFEHL"
ANTWORT=$($CURL -s -G --data-urlencode "script=$BEFEHL" \
          "http://127.0.0.1:7125/printer/gcode/script" 2>&1)

case "$ANTWORT" in
    *'"error"'*)
        echo ""
        echo "Klipper hat den Befehl abgelehnt:"
        echo "$ANTWORT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    m = d.get("error", {}).get("message") or d.get("message") or str(d)
except Exception:
    m = sys.stdin.read()
for zeile in str(m).rstrip().split(chr(10)):
    print("  " + zeile)
'
        exit 1
        ;;
esac

# Kurz warten, damit die Konsolenmeldung im Speicher steht.
sleep 1
NACHHER=$($CURL -s "http://127.0.0.1:7125/server/gcode_store?count=100" 2>/dev/null)
NEU=$(echo "$NACHHER" | tr ',' '\n' | grep -c '"message"' || echo 0)
ANZ=$((NEU - VORHER))
[ "$ANZ" -gt 0 ] 2>/dev/null || ANZ=1

echo ""
echo "Antwort von Klipper:"
echo "$NACHHER" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)["result"]["gcode_store"]
except Exception:
    sys.exit(0)
n = int(sys.argv[1])
befehl = sys.argv[2] if len(sys.argv) > 2 else ""
gab_etwas = False
for e in d[-n:]:
    m = e.get("message","").strip()
    if not m or m == befehl:      # Klipper spiegelt den Befehl selbst - keine Antwort
        continue
    print("  " + m.replace("\n", "\n  "))
    gab_etwas = True
if not gab_etwas:
    print("  (keine Meldung - der Befehl lief still durch, das ist hier normal)")
' "$ANZ" "$BEFEHL" 2>/dev/null || echo "  (Antwort nicht lesbar)"

# ⚠ Nachkontrolle: Ein einziger unglueklicher Befehl kann Klipper in den Shutdown
# treiben - erlebt am 2026-08-24 mit PID_PROFILE GET_VALUES, das bei einem nie
# gespeicherten Profil in Kalico selbst abstuerzt. Dann steht der Drucker, und ohne
# Hinweis sucht man den Fehler an der falschen Stelle.
ZUSTAND=$($CURL -s "http://127.0.0.1:7125/printer/objects/query?webhooks" 2>/dev/null \
          | sed -e 's/.*"state": *"//' -e 's/".*//')
if [ "$ZUSTAND" = "shutdown" ] || [ "$ZUSTAND" = "error" ]; then
    echo ""
    echo "⚠⚠ ACHTUNG: Klipper steht jetzt im Zustand '$ZUSTAND'."
    echo "Der Befehl hat den Drucker lahmgelegt. Zum Weiterarbeiten:"
    echo "  Aktionen -> Dienste -> Klipper neu starten"
    echo "oder per SSH: curl -X POST http://127.0.0.1:7125/printer/firmware_restart"
    echo "⚠ Die Referenzierung ist danach weg, der Druckstart holt sie nach."
    exit 1
fi
