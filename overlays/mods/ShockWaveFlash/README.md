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

All three write separate `.cfg` fragments into `extended/klipper/` (included at
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
- [x] `bash -n` on all embedded commands, `sh -n` + round-trip test on `set-current.sh`
- [x] `py_compile` on bundled plugin files
- [ ] Full firmware build
- [ ] On-device validation (get_cmd state detection, Klipper restart, autotune plugin load on Snapmaker's Klipper fork)
