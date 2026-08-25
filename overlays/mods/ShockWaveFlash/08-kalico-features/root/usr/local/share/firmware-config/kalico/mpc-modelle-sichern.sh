#!/bin/sh
# Zieht die gemessenen MPC-Modellwerte aus der printer.cfg in das Rueckfall-
# Fragment kalico_mpc_modelle.cfg nach.
#
# WARUM: Die Werte aus MPC_CALIBRATE landen per SAVE_CONFIG im Autosave-Block
# der printer.cfg - und jeder Firmware-Flash ersetzt die printer.cfg durch die
# Werksversion. Rund 15 min Messzeit je Hotend waeren dann weg. Das Fragment
# haelt sie vor, greift aber nur, solange in der printer.cfg nichts steht:
# Klipper haengt den Autosave-Block immer hinten an (configfile.py,
# regular_data + autosave_data), frische Messwerte gewinnen also stets.
#
# WANN AUFRUFEN: nach jedem SAVE_CONFIG, das eine MPC-Kalibrierung festschreibt.
#
# ⚠ 'control: mpc', heater_power, cooling_fan und die Filamentkennwerte stehen
#   in kalico_hotend_control.cfg und werden hier NICHT angefasst.
set -e

CFG=${CFG:-/oem/printer_data/config/printer.cfg}
ZIEL=${ZIEL:-/oem/printer_data/config/extended/klipper/kalico_mpc_modelle.cfg}

[ -r "$CFG" ] || { echo "printer.cfg nicht lesbar: $CFG"; exit 1; }

python3 - "$CFG" "$ZIEL" <<'PY'
import re, sys, os, time

cfg, ziel = sys.argv[1], sys.argv[2]
txt = open(cfg, encoding="utf-8", errors="replace").read()
kopf = txt.find("<---------------------- SAVE_CONFIG ---")
if kopf < 0:
    print("Kein SAVE_CONFIG-Block in der printer.cfg - nichts zu sichern.")
    raise SystemExit(0)

WERTE = ("block_heat_capacity", "sensor_responsiveness",
         "ambient_transfer", "fan_ambient_transfer")
bloecke, akt = {}, None
for z in txt[kopf:].splitlines():
    m = re.match(r"^\[(extruder\d*)\]\s*$", z)
    if m:
        akt = m.group(1); bloecke[akt] = []; continue
    if akt:
        if z.startswith("[") or z.startswith("#*#"):
            akt = None; continue
        if z.split("=")[0].strip() in WERTE:
            bloecke[akt].append(z.rstrip())

gefunden = [k for k in bloecke if bloecke[k]]
if not gefunden:
    print("Keine MPC-Modellwerte in der printer.cfg - Fragment bleibt unveraendert.")
    print("(Erst MPC_CALIBRATE fahren und mit SAVE_CONFIG festschreiben.)")
    raise SystemExit(0)

zeilen = []
for k in ("extruder", "extruder1", "extruder2", "extruder3"):
    if bloecke.get(k):
        zeilen.append("[%s]" % k)
        zeilen += bloecke[k]
        zeilen.append("")

neu = """# MPC-Modellwerte aller vier Hotends -- RUECKFALL fuer den Fall, dass die
# printer.cfg sie verliert (jeder Firmware-Flash ersetzt sie durch die
# Werksversion; die Messung kostet rund 15 min je Kopf).
#
# ⚠ KEIN Konflikt mit einer spaeteren Kalibrierung: Klipper haengt den
# SAVE_CONFIG-Block IMMER hinten an (configfile.py: regular_data +
# autosave_data), und dieser Include steht davor. Frisch gemessene Werte
# gewinnen also stets gegen diese Datei. Sie greift nur, solange in der
# printer.cfg nichts steht.
#
# ⚠ 'control: mpc' steht bewusst NICHT hier -- das setzt bereits
# kalico_hotend_control.cfg, zusammen mit heater_power, cooling_fan und den
# Filamentkennwerten. Diese Datei traegt ausschliesslich die GEMESSENEN Werte.
#
# Erzeugt von mpc-modelle-sichern.sh am %s
# Quelle: %s

""" % (time.strftime("%Y-%m-%d %H:%M"), cfg) + "\n".join(zeilen)

alt = open(ziel, encoding="utf-8").read() if os.path.exists(ziel) else ""
def ohne_kopf(s):
    return "\n".join(z for z in s.splitlines() if not z.startswith("#"))
if ohne_kopf(alt) == ohne_kopf(neu):
    print("Fragment ist bereits auf dem Stand der printer.cfg (%s)." % ", ".join(gefunden))
    raise SystemExit(0)

open(ziel, "w", encoding="utf-8").write(neu)
try:
    import pwd
    p = pwd.getpwnam("lava")
    os.chown(ziel, p.pw_uid, p.pw_gid)
except Exception:
    pass
os.chmod(ziel, 0o644)
print("Fragment aktualisiert: %s" % ziel)
print("Gesicherte Hotends: %s" % ", ".join(gefunden))
PY

echo ""
echo "Wirksam wird das erst nach einem FIRMWARE_RESTART - die laufenden Werte"
echo "aendern sich dabei nicht, denn die printer.cfg hat weiterhin Vorrang."
