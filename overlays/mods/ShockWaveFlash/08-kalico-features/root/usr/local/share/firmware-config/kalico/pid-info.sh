#!/bin/sh
# Zeigt die Regelwerte aller Heizer und die gespeicherten PID-Profile.
#
# ⚠ Kalicos eigener Befehl PID_PROFILE GET_VALUES taugt dafuer nicht: er formatiert
# die Zieltemperatur des Profils als Zahl und stuerzt mit "must be real number, not
# NoneType" ab, sobald ein Profil nie ueber PID_CALIBRATE gespeichert wurde - also
# genau im Auslieferungszustand. Deshalb werden die Werte hier direkt aus der
# aufbereiteten Konfiguration gelesen, die Klipper ueber Moonraker herausgibt.
CURL=/usr/local/bin/curl

$CURL -s "http://127.0.0.1:7125/printer/objects/query?configfile=settings&extruder&extruder1&extruder2&extruder3&heater_bed" 2>/dev/null \
| python3 -c '
import json, sys
try:
    st = json.load(sys.stdin)["result"]["status"]
except Exception:
    print("Nicht abfragbar - laeuft Klipper?"); sys.exit(1)
cfg = st["configfile"]["settings"]

heizer = ["extruder", "extruder1", "extruder2", "extruder3", "heater_bed"]
print("Aktive Regelung je Heizer")
print("  %-12s %-14s %-9s %-9s %-9s %s" % ("Heizer","aktives Profil","Kp","Ki","Kd","Verfahren"))
for h in heizer:
    c = cfg.get(h)
    if not c: continue
    prof = (st.get(h) or {}).get("pid_profile", "-")
    art  = c.get("control", "-")
    def z(k):
        v = c.get(k)
        return f"{v:.3f}" if isinstance(v, (int, float)) else "-"
    print("  %-12s %-14s %-9s %-9s %-9s %s"
          % (h, prof, z("pid_kp"), z("pid_ki"), z("pid_kd"), art))

print()
print("Gespeicherte Profile")
gefunden = False
for k in sorted(cfg):
    if k.startswith("pid_profile "):
        teile = k.split()
        h = teile[1] if len(teile) > 1 else "?"
        n = " ".join(teile[2:]) or "?"
        p = cfg[k]
        def z(x):
            v = p.get(x)
            return f"{v:.3f}" if isinstance(v, (int, float)) else "-"
        print("  %-12s %-14s Kp=%-9s Ki=%-9s Kd=%-9s" % (h, n, z("pid_kp"), z("pid_ki"), z("pid_kd")))
        gefunden = True
if not gefunden:
    print("  Ausser \"default\" ist keins angelegt.")
    print()
    print("  Ein Profil anlegen (Beispiel PETG bei 255 Grad):")
    print("    PID_CALIBRATE HEATER=extruder TARGET=255")
    print("    PID_PROFILE SAVE=petg HEATER=extruder")
    print("    SAVE_CONFIG          (startet Klipper neu)")
'
