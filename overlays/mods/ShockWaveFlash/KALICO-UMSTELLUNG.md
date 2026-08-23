# Mods auf Kalico umstellen — Bewertung je Mod

Branch **`kalico-mods`**, angelegt 2026-08-23. Alles hier Genannte wurde in
derselben Sitzung im Merge-Baum `/root/u1-kalico` nachgesehen, nicht geschaetzt.

⚠️ **Dieser Branch ist NICHT fuer die laufende Firmware.** Auf dem Drucker
laeuft Snapmakers Stock-Klipper; Python-Makros und die Kalico-Kommandos gibt es
dort nicht. Erst einsetzen, wenn der Kalico-Baum auf dem U1 laeuft. Die
Stock-Fassung liegt weiter im Branch `feature/paxx12-ai-zstd-20260819`.

## Ersetzt

| Datei | Vorher | Kalico-Fassung |
|---|---|---|
| `06/heat_soak.cfg` | feste Wartezeit `G4`, weil `TEMPERATURE_WAIT` am 2026-08-06 den Drucker 30 min blockiert hat und Jinja kein Zeitlimit erlaubt | Python-Makro mit `wait_while`: wartet auf ein echtes Kammer-Temperaturziel, **hoechstens** MINUTES lang, und bricht bei jedem Abbruch-Kommando ab. `CHAMBER=` ist damit wieder gefahrlos nutzbar. |

## Bewusst NICHT ersetzt (Ersatz waere schlechter oder wirkungslos)

| Mod | Kalico-Gegenstueck | Warum es bleibt |
|---|---|---|
| `04-bed-chamber` Bed-Max-Temp | `[danger_options] temp_ignore_limits` | Kalicos Schalter hebt **alle** Temperaturgrenzen im ganzen Drucker auf. Dein Mod hebt gezielt `heater_bed max_temp` an, in Stufen, mit Warntext und Rueckweg auf 110 C. Das ist die sicherere Loesung. |
| `06/pid_autotune.cfg` | `PID_PROFILE SAVE` | Spart **keinen** Neustart: `save_profile()` in `heaters.py` schreibt ebenfalls nur in den SAVE_CONFIG-Block. Der Ablauf im Makro ist bereits richtig. Nur ein Kommentarblock mit den Kalico-Zusaetzen ergaenzt. |
| `01-motor-upgrade` TMC Autotune | — | **Kalico hat kein TMC Autotune.** `autotune_tmc.py` und `motor_constants.py` bleiben dein eigenes Modul; das Overlay bringt sie mit. |
| `02-toolhead-fans`, `03-z-axis`, `05-input-shaper`, `07-geraetestand` | — | Reine Konfiguration bzw. Config-Abzug. Kein Kalico-Gegenstueck noetig. |

## Was durch Kalico von selbst wegfaellt

- **`[force_move]`** ist bei Kalico standardmaessig **an** (`force_move.py:54`,
  Snapmaker hatte `False`). Richtungstests ohne Homing brauchen keinen Mod mehr.
- **`[respond]`** und **`[exclude_object]`** ebenfalls default an.

## ⚠️ Vor dem Umstieg zwingend mitnehmen

Vier Module liegen NUR auf dem Geraet, weder in Snapmakers Repo noch in einem
Overlay — ohne sie fehlen Beschleunigungssensoren, Luftfilter und
Flow-Kalibrierung. Gesichert in
`/root/backups/u1-geraeteexklusive-module-20260823/`:

    panda_breath.py                  1 Config-Abschnitt, 340 Treffer im klippy.log
    sc7a20.py                        4 Abschnitte (je Toolhead einer)
    sensor_accelerometer_identify.py 4 Abschnitte
    flow_calc_server                 ARM64-Binary, laeuft als Prozess, 11 [flow_calibrator]

Ebenfalls noetig, aber aus Overlays reproduzierbar: AFC/AFC_lane/AFC_unit,
spoollink, filament_protocol_ndef, autotune_tmc, motor_constants,
motor_database.cfg.

## Neue Kalico-Moeglichkeiten, die es vorher nicht gab

- `[mcu] is_non_critical` — ein Toolhead darf abgezogen werden, ohne dass
  Klipper stirbt. Beim U1 mit fuenf MCUs interessant.
- `HEATER_INTERRUPT` bricht ein laufendes `TEMPERATURE_WAIT` ab.
- `[tmcXXXX] home_current` + `current_change_dwell_time` — eigener
  Homing-Strom, nativ statt per Makro.
- `BED_MESH_CHECK` prueft eine Mesh vor dem Druck gegen Grenzwerte.
- `RELOAD_GCODE_MACROS` laedt Makros ohne Neustart neu.
- Python-Makros, `math`-Bibliothek, `[constants]`, `gcode_shell_command`.
