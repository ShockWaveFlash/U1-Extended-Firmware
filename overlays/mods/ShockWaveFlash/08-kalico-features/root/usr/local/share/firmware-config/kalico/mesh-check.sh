#!/bin/sh
# Bewertet das aktuell geladene Bettraster.
# Aufruf: mesh-check.sh [Grenzwert-Abweichung-in-mm]
#
# Zeigt, wie krumm das Bett gemessen wurde: groesster Hoehenunterschied ueber die
# ganze Flaeche, und die groesste Stufe zwischen zwei benachbarten Messpunkten.
# Der zweite Wert ist der wichtigere - eine gleichmaessige Woelbung faehrt die
# Rasterkorrektur problemlos aus, eine steile Stufe zwischen Nachbarpunkten
# dagegen deutet auf einen Messfehler oder etwas Verklemmtes hin.
#
# Zusaetzlich wird Kalicos eigener Befehl BED_MESH_CHECK mit dem Grenzwert
# gefahren, damit die Bewertung aus derselben Quelle kommt wie im Druckstart.
set -e

GRENZE="${1:-0.30}"
CURL=/usr/local/bin/curl

$CURL -s "http://127.0.0.1:7125/printer/objects/query?bed_mesh" 2>/dev/null | python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)["result"]["status"]["bed_mesh"]
except Exception:
    print("Bettraster nicht abfragbar - laeuft Klipper?"); sys.exit(1)

name = m.get("profile_name") or "(keins geladen)"
mat  = m.get("probed_matrix") or []
print(f"Geladenes Profil : {name}")
if not mat or not mat[0]:
    print("Es ist kein gemessenes Raster geladen. Erst BED_MESH_CALIBRATE fahren.")
    sys.exit(0)

flach = [v for zeile in mat for v in zeile]
hoch, tief = max(flach), min(flach)
print(f"Rastergroesse    : {len(mat)} x {len(mat[0])} Punkte")
print(f"Hoechster Punkt  : {hoch:+.3f} mm")
print(f"Tiefster Punkt   : {tief:+.3f} mm")
print(f"Gesamtabweichung : {hoch - tief:.3f} mm")

stufe, wo = 0.0, None
for y, zeile in enumerate(mat):
    for x, v in enumerate(zeile):
        if x + 1 < len(zeile):
            d = abs(zeile[x+1] - v)
            if d > stufe: stufe, wo = d, f"waagerecht bei Punkt ({x},{y})"
        if y + 1 < len(mat):
            d = abs(mat[y+1][x] - v)
            if d > stufe: stufe, wo = d, f"senkrecht bei Punkt ({x},{y})"
print(f"Groesste Stufe   : {stufe:.3f} mm  ({wo})")
print()
if stufe > 0.15:
    print("⚠ Die Stufe zwischen zwei Nachbarpunkten ist gross. Ueber diese kurze")
    print("  Strecke ist das selten echte Bettgeometrie - eher ein Messausreisser,")
    print("  ein Kruemel unter der Platte oder eine lose Schraube. Vor dem Druck")
    print("  nachsehen und die Messung wiederholen.")
elif stufe > 0.08:
    print("Eine Stufe in dieser Groesse ist unkritisch, aber merkbar. Wiederholt sie")
    print("sich bei der naechsten Messung an derselben Stelle, ist sie echt; wandert")
    print("sie, war es ein Messausreisser.")
elif hoch - tief > 0.40:
    print("Das Bett ist merklich krumm, aber gleichmaessig. Die Rasterkorrektur")
    print("faengt das ab; eine Schraubennivellierung wuerde es verbessern.")
else:
    print("Unauffaellig.")
' || exit 1

echo ""
echo "--- Kalicos eigene Pruefung (Grenzwert $GRENZE mm) ---"
A=$($CURL -s -G --data-urlencode "script=BED_MESH_CHECK MAX_DEVIATION=$GRENZE" \
    "http://127.0.0.1:7125/printer/gcode/script" 2>&1)
case "$A" in
    *'"error"'*)
        echo "NICHT BESTANDEN:"
        echo "$A" | sed -e 's/.*"message": *"//' -e 's/".*//' -e 's/\\n/\n/g' -e 's/^/  /'
        ;;
    *)
        sleep 1
        $CURL -s "http://127.0.0.1:7125/server/gcode_store?count=3" 2>/dev/null | python3 -c '
import json,sys
try:
    for e in json.load(sys.stdin)["result"]["gcode_store"][-3:]:
        m=e.get("message","").strip()
        if "mesh" in m.lower() or "deviation" in m.lower(): print("  "+m)
except Exception: pass
' || true
        echo "  (bestanden)"
        ;;
esac
