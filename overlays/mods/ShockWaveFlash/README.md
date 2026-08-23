# Mod: Motor Upgrade (XY)

Adds a **Motor Upgrade (XY)** settings group to the firmware-config web UI
(`http://<printer-ip>/firmware-config/`, requires Advanced Mode) with three
independently switchable settings for an XY stepper hardware upgrade
(LDO-42STH48-2504MAC(F) 0.9° motors, optionally with Powge 26T 1.5GT pulleys):

| Setting | Options | Effect |
|---|---|---|
| XY Motor Kit | Stock / LDO-2504 + 26T 1.5GT / LDO-2504 + stock GT2 | `full_steps_per_rotation` (200/400) and `rotation_distance` (40/39/40) for stepper_x/y |
| XY Run Current | Stock 1.2A / 1.0–1.6A in 0.1A steps / Custom (0.50–1.77A, free input) | `run_current` for tmc2240 stepper_x/y |
| TMC AutoTune (Motor DB) | Disabled / LDO-2504 auto / LDO-2504 performance | `[autotune_tmc]` via the bundled [klipper_tmc_autotune](https://github.com/andrewmcgr/klipper_tmc_autotune) plugin with real motor constants |
| XY StallGuard Threshold | Stock / SG4_THRS custom (0-255, per axis) / SGT custom (-64..63, per axis) | `driver_SG4_THRS` or `driver_SGT` for tmc2240 stepper_x/y |
| XY Speed Limit | Stock / 450 / 400 / 350 / Custom (100-1000 mm/s) | `[printer] max_velocity` override |
| Commissioning Macros | Enabled / Disabled | `XY_DRIVER_TEMPS` (TMC2240 temps + run current via driver status) and `XY_STRESS_TEST` (bounded motion test with temp logging) |

A second overlay (`02-toolhead-fans/`) adds a **Toolhead Fans** group:

| Setting | Options | Effect |
|---|---|---|
| Nozzle Fan Speed (T0-T3) | Stock 1.0 / Reduced 0.8 / Quiet 0.6 / Custom per tool (0.30-1.0) | `fan_speed` for `[heater_fan e0..e3_nozzle_fan]` (heatbreak fans, NOT part cooling). Below ~0.6 raises heat-creep/clog risk. |

A third overlay (`03-z-axis/`) adds a **Z Axis** group (against Z bumps/noise):

| Setting | Options | Effect |
|---|---|---|
| Z Speed / Accel | Stock 30/500 / Smooth 20/300 / Extra Smooth 15/200 / Custom (5-30, 50-500) | `[printer] max_z_velocity` + `max_z_accel` override |
| Z StealthChop | Stock (SpreadCycle) / StealthChop | `stealthchop_threshold: 999999` on `[tmc2209 stepper_z]` (Z uses a TMC2209, not 2240; homes sensorless - re-verify G28 Z) |
| Z Run Current | Stock 0.85A / 0.7A / Custom (0.50-0.90) | `run_current` on `[tmc2209 stepper_z]`; Z lifts the full bed, low current risks lost steps |

A fourth overlay (`04-bed-chamber/`) adds a **Bed & Chamber** group:

| Setting | Options | Effect |
|---|---|---|
| Bed Max Temp | Stock 110C / 115C / 120C / Custom (111-120) | `[heater_bed] max_temp` override. Only lifts the ceiling for high-temp materials — heats nothing by itself. Confirm bed surface / adhesive / wiring ratings above 110C. |
| HEAT_SOAK Macro | Enabled / Disabled | Ships the `HEAT_SOAK` gcode macro (drop-in `heat_soak.cfg`). |

The `HEAT_SOAK` macro heats the bed and then soaks, in one of two mutually
exclusive modes (it is **blocking** — for slicer start gcode or manual
pre-heating):

- `HEAT_SOAK BED=100 MINUTES=15` — fixed timed soak (1–120 min).
- `HEAT_SOAK BED=100 CHAMBER=45` — waits until the stock `[temperature_sensor
  cavity]` (gcode_id C) reaches the target. Capped at **55C** (the cavity is
  only passively heated by the bed; sensor `max_temp` is 70C). This wait has no
  timeout — pick a target the bed can realistically drive the enclosure to, and
  abort with `CANCEL_PRINT` / `M112` if it stalls.

A fifth overlay (`05-input-shaper/`) adds an **Input Shaper** group:

| Setting | Options | Effect |
|---|---|---|
| Input Shaper (X/Y) | Stock (off) / Custom (type + freq per axis) | `[input_shaper]` override (`shaper_type_x/y`, `shaper_freq_x/y`). Type one of `zv/mzv/ei/2hump_ei/3hump_ei`, freq 20-150 Hz. |
| Calibration Macro | Enabled / Disabled | Ships `CALIBRATE_INPUT_SHAPER` — runs `SHAPER_CALIBRATE` for X/Y and prints the recommended shaper to enter above. |

Workflow: after the XY motor upgrade the resonance frequencies shift, so
re-measure. Enable the calibration macro, run `CALIBRATE_INPUT_SHAPER` (optional
`AXIS=X`/`AXIS=Y`), read the *Recommended shaper* line, then enter type + freq
per axis under **Input Shaper (X/Y) > Custom**. Values are persisted in
`extended/klipper` and are **not** auto-`SAVE_CONFIG`'d (this firmware manages
`printer.cfg`), so they survive firmware updates.

> **On-device caveat (untested):** `CALIBRATE_INPUT_SHAPER` assumes a working
> stock `[resonance_tester]` + accelerometer. On this 4-toolhead machine the
> accelerometer wiring/`accel_chip` and probe point still need verification —
> run `MEASURE_AXES_NOISE` once to confirm the sensor responds before trusting a
> `SHAPER_CALIBRATE` run. The manual **Input Shaper (X/Y)** values path works
> regardless of how the frequencies were obtained (accelerometer or ringing
> tower).

All five write separate `.cfg` fragments into `extended/klipper/` (included at
the end of `printer.cfg`, so they override stock values last-wins) and restart
Klipper. State is derived from the on-disk files (`get_cmd`), nothing else.

## Interactions with stock tweaks

- Selecting any **XY Run Current** value removes the *TMC Reduced Current*
  tweak file (both write `run_current` for the same sections).
- Enabling **TMC AutoTune (Motor DB)** removes the static *TMC AutoTune* tweak
  file (its register values are tuned for the stock motors and would conflict).

## Bundled files

- `klippy/extras/autotune_tmc.py`, `motor_constants.py`, `motor_database.cfg`
  from klipper_tmc_autotune (inert unless an `[autotune_tmc]` section exists —
  same drop-in mechanism the AFC overlay uses).
- Config templates + `set-current.sh` under
  `/usr/local/share/firmware-config/motor-upgrade/`.
- `set-bed-maxtemp.sh` + `heat-soak.cfg` under
  `/usr/local/share/firmware-config/bed-chamber/`.
- `set-input-shaper.sh` + `input-shaper-calibrate.cfg` under
  `/usr/local/share/firmware-config/input-shaper/`.

## After switching the motor kit

1. Verify wiring/direction: `STEPPER_BUZZ STEPPER=stepper_x` (and y)
2. Re-calibrate StallGuard sensorless homing (changed motor + current shift
   the SG4 threshold)
3. Re-tune Input Shaper
4. Watch driver temps via `XY_DRIVER_TEMPS` when escalating current above
   1.2A — values > 1.2A assume additional TMC driver cooling. (Note:
   mainline Klipper has no `temperature_driver` sensor section; the macro
   reads `printer['tmc2240 stepper_x'].temperature` from driver status.)

## Build

```bash
./dev.sh make build PROFILE=extended-<username>
```

## Status

- [x] YAML validated against firmware-config `deep_merge`/`handle_get_settings`
- [x] `bash -n` on all embedded commands, `sh -n` + round-trip on `set-current.sh`, `set-bed-maxtemp.sh`, `set-input-shaper.sh`
- [x] `py_compile` on bundled plugin files
- [x] Jinja2 parse of the `HEAT_SOAK` and `CALIBRATE_INPUT_SHAPER` gcode templates
- [ ] Full firmware build
- [ ] On-device validation (get_cmd state detection, Klipper restart, autotune plugin load on Snapmaker's Klipper fork, `[heater_bed] max_temp` last-wins override, `HEAT_SOAK` chamber/timer modes against the real cavity sensor, `[input_shaper]` last-wins override, `CALIBRATE_INPUT_SHAPER` against the real accelerometer/`resonance_tester`)

# Mod: Klipper Macros (06-klipper-makros)

Ships hand-written Klipper macro configs as **defaults**. Unlike the other mods
this one has **no firmware-config UI switches** — the files are dropped into
`/usr/local/share/firmware-config/extended/klipper/`, and `S49extended-config`
copies them to `printer_data/config/extended/klipper/` on boot using `cp -rn`:

- a file that does **not** exist on the printer is created,
- a file that **does** exist is never overwritten; if it differs, the image
  version is placed next to it as `<name>.cfg.default` for comparison.

So the image is a **fallback and a fresh-install source**, not an update
mechanism. To roll out a newer version, delete the file on the printer first.

| File | What it does |
|---|---|
| `shaper_persist.cfg` | Makes input shaper results survive a restart (the fork's `save_params` is commented out). Wraps `SHAPER_CALIBRATE`: full sweep when idle, narrow band during a print, internal `FREQ_*` calls passed through. Adds `SHAPER_SERVICE`, `SHAPER_SAVE`, `SHAPER_SHOW`. |
| `mesh_heatsoak.cfg` | Heat-soak before every bed mesh (frame thermal drift, tau = 8.1 min): 10 min at >=90 C, 5 min at 55-89 C, none below. Raises `idle_timeout` for the wait, then restores it. Chains in front of the adaptive-mesh wrapper. |
| `hotend_service.cfg` | One-button calibration run after a hotend/nozzle swap. |
| `pid_autotune.cfg` | `PID_ALL` — PID autotune for all four toolheads plus load/unload helpers. |
| `filament_batch.cfg` | Load/unload filament in all four toolheads in one go. |
| `heat_soak.cfg` | `HEAT_SOAK` for ABS/ASA without active chamber heating (fixed dwell, never `TEMPERATURE_WAIT` — that once blocked the whole command queue). |
| `print_modes.cfg` | Stealth / Normal mode (night mode), modelled on Prusa's. |
| `nozzle_fan_speed.cfg` | Hotend (heatbreak) fans limited to 70 % for noise. |
| `motor_hold_current.cfg` | Reduced XY hold current. |

Note: `heat_soak.cfg`, `nozzle_fan_speed.cfg` and `motor_hold_current.cfg` overlap
with settings the UI mods can write. The UI switches keep priority — they rewrite
their own file, and `cp -rn` will not touch it.

## 07-geraetestand — full device-state restore

Ships a complete snapshot of `printer_data/config` as it stood on the printer on
2026-08-23 (104 files, 1.2 MB) and puts back anything that is missing after a flash.

The init script `/etc/init.d/S49zgeraetestand` runs after `S49extended-config` and does
one thing: `cp -rn` from the image into `printer_data/config`, then `chown -R lava:lava`.
`-n` is no-clobber — **existing files are never overwritten**. So:

- whatever survived the flash stays untouched,
- whatever was lost is restored from the image,
- later calibrations are never reset on a reboot.

Covered: all `snapmaker/*.json` (PID for all four toolheads, input shaper, bed meshes,
defect detection, flow calibrator, filament parameters, product info), all
`persistent/*.json` (high-flow `volume_type`, homing origin, extruder config, switch
recorder), `extended/` (`extended2.cfg` with the camera mode, moonraker fragments, all
klipper overlays including the UI-written `nozzle_fans.cfg`), plus `moonraker.conf`,
`gui_config.json` and the factory/printer cfg variants.

Kill switch: `touch /oem/.no-geraetestand` disables the restore.

⚠️ Same caveat as above: this is a **fallback**, not an update mechanism. Refreshing a
file in the image does not push it to a printer that still has the old one — delete it
on the printer first.
