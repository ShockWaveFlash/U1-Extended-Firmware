# Tracking of PWM controlled heaters and their temperature control
#
# Copyright (C) 2016-2025  Kevin O'Connor <kevin@koconnor.net>
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import collections
import json
import logging
import os
import threading

import queuefile

from .control_mpc import (
    FILAMENT_TEMP_SRC_AMBIENT,
    FILAMENT_TEMP_SRC_FIXED,
    FILAMENT_TEMP_SRC_SENSOR,
    ControlMPC,
)

######################################################################
# Heater
######################################################################

KELVIN_TO_CELSIUS = -273.15
# Snapmaker U1 uses a longer heater watchdog window and a sensor read
# tolerance; both values are required by the U1 hardware timing.
MAX_HEAT_TIME = 7.0
AMBIENT_TEMP = 25.0
PID_PARAM_BASE = 255.0
READ_TIME_TOL = 0.45
MIN_UPDATE_RATIO = 0.15
MAX_MAINTHREAD_TIME = 5.0
QUELL_STALE_TIME = 7.0
PID_PROFILE_VERSION = 1
PID_PROFILE_OPTIONS = {
    "pid_target": (float, "%.2f"),
    "pid_tolerance": (float, "%.4f"),
    "control": (str, "%s"),
    "smooth_time": (float, "%.3f"),
    "pid_kp": (float, "%.3f"),
    "pid_ki": (float, "%.3f"),
    "pid_kd": (float, "%.3f"),
}
PID_CONTROL_TYPES = ("pid", "pid_v", "dual_loop_pid")
DUAL_LOOP_PID_INNER_TARGET_OPTION = "inner_target_temp"
DUAL_LOOP_PID_INNER_TARGET_DEPRECATED_OPTION = "inner_max_temp"


def lookup_dual_loop_pid_inner_target_temp(config):
    inner_target_temp = config.getfloat(DUAL_LOOP_PID_INNER_TARGET_OPTION, None)
    inner_max_temp = config.getfloat(
        DUAL_LOOP_PID_INNER_TARGET_DEPRECATED_OPTION, None
    )
    if inner_target_temp is not None and inner_max_temp is not None:
        raise config.error(
            "Options '%s' and '%s' may not both be specified"
            % (
                DUAL_LOOP_PID_INNER_TARGET_OPTION,
                DUAL_LOOP_PID_INNER_TARGET_DEPRECATED_OPTION,
            )
        )
    if inner_target_temp is not None:
        return inner_target_temp
    if inner_max_temp is not None:
        config.deprecate(DUAL_LOOP_PID_INNER_TARGET_DEPRECATED_OPTION)
        return inner_max_temp
    return config.getfloat(DUAL_LOOP_PID_INNER_TARGET_OPTION)


class Heater:
    def __init__(self, config, sensor):
        self.printer = config.get_printer()
        self.name = config.get_name()
        self.short_name = short_name = self.name.split()[-1]
        self.reactor = self.printer.get_reactor()
        self.config = config
        self.configfile = self.printer.lookup_object("configfile")
        # Setup sensor
        self.sensor = sensor
        self.mpc_sensors = []
        self.min_temp = config.getfloat("min_temp", minval=KELVIN_TO_CELSIUS)
        self.max_temp = config.getfloat("max_temp", above=self.min_temp)
        min_temp_overshoot = config.getfloat("min_temp_overshoot", 0, minval=0)
        max_temp_overshoot = config.getfloat("max_temp_overshoot", 0, minval=0)
        self.sensor.setup_minmax(
            self.min_temp - min_temp_overshoot,
            self.max_temp + max_temp_overshoot,
        )
        self.sensor.setup_callback(self.temperature_callback)
        # Merge-Anpassung: set_read_tolerance ist eine Snapmaker-Erweiterung.
        # Kalicos zusaetzliche Sensorklassen (bme280, sht3x, lm75, ...) kennen
        # sie nicht - dort entfaellt die Lost-Update-Erkennung.
        if hasattr(self.sensor, "set_read_tolerance"):
            self.sensor.set_read_tolerance(READ_TIME_TOL, MIN_UPDATE_RATIO)
        else:
            logging.info(
                "heater %s: sensor %s ohne set_read_tolerance -"
                " Lost-Update-Erkennung inaktiv",
                self.name, config.get("sensor_type", "?"),
            )
        self.pwm_delay = self.sensor.get_report_time_delta()
        self.lost_update_tolerance = float(
            config.getint("lost_update_tolerance", 2, minval=0) + 1
        )
        # Setup temperature checks
        self.min_extrude_temp = config.getfloat(
            "min_extrude_temp",
            170.0,
            minval=self.min_temp,
            maxval=self.max_temp,
        )
        is_fileoutput = (
            self.printer.get_start_args().get("debugoutput") is not None
        )
        self.can_extrude = self.min_extrude_temp <= 0.0 or is_fileoutput
        self.cold_extrude = False
        self.max_power = config.getfloat(
            "max_power", 1.0, above=0.0, maxval=1.0
        )
        self.config_smooth_time = config.getfloat("smooth_time", 1.0, above=0.0)
        self.smooth_time = self.config_smooth_time
        self.pwm_min_set_diff = config.getfloat(
            "pwm_min_set_diff", 0.05, above=0.0
        )
        self.inv_smooth_time = 1.0 / self.smooth_time
        self.verify_mainthread_time = -999.0
        self.lock = threading.Lock()
        self.last_temp = self.smoothed_temp = self.target_temp = 0.0
        self.last_temp_time = 0.0
        # Snapmaker: extruder hold max power limit
        self.idle_hold_max_power = config.getfloat(
            "idle_hold_max_power", None, above=0.0, maxval=1.0
        )
        self.active_hold_max_power = config.getfloat(
            "active_hold_max_power", None, above=0.0, maxval=1.0
        )
        self.dynamic_max_power = self.max_power
        self.pending_power_change = False
        # pwm caching
        self.next_pwm_time = 0.0
        self.last_pwm_value = 0.0
        # Snapmaker: PID autotune may be blocked per heater
        self.allow_pid_calibrate = config.getboolean(
            "allow_pid_calibrate", True
        )
        # Those are necessary so the klipper config check does not complain
        config.get("control", None)
        config.getfloat("pid_kp", None)
        config.getfloat("pid_ki", None)
        config.getfloat("pid_kd", None)
        config.getfloat("max_delta", None)
        # Setup output heater pin
        heater_pin = config.get("heater_pin")
        ppins = self.printer.lookup_object("pins")
        self.mcu_pwm = ppins.setup_pin("pwm", heater_pin)
        pwm_cycle_time = config.getfloat(
            "pwm_cycle_time", 0.100, above=0.0, maxval=self.pwm_delay
        )
        self.mcu_pwm.setup_cycle_time(pwm_cycle_time)
        self.mcu_pwm.setup_max_duration(MAX_HEAT_TIME)
        # Load additional modules
        self.printer.load_object(config, "verify_heater %s" % (short_name,))
        self.printer.load_object(config, "pid_calibrate")
        self.gcode = self.printer.lookup_object("gcode")
        self.pmgr = self.ProfileManager(self)
        self.control = self.lookup_control(
            self.pmgr.init_default_profile(), True
        )
        self.gcode.register_mux_command(
            "SET_HEATER_TEMPERATURE",
            "HEATER",
            short_name,
            self.cmd_SET_HEATER_TEMPERATURE,
            desc=self.cmd_SET_HEATER_TEMPERATURE_help,
        )
        self.gcode.register_mux_command(
            "COLD_EXTRUDE",
            "HEATER",
            self.name,
            self.cmd_COLD_EXTRUDE,
            desc=self.cmd_COLD_EXTRUDE_help,
        )
        self.gcode.register_mux_command(
            "SET_SMOOTH_TIME",
            "HEATER",
            short_name,
            self.cmd_SET_SMOOTH_TIME,
            desc=self.cmd_SET_SMOOTH_TIME_help,
        )
        self.gcode.register_mux_command(
            "PID_PROFILE",
            "HEATER",
            short_name,
            self.pmgr.cmd_PID_PROFILE,
            desc=self.pmgr.cmd_PID_PROFILE_help,
        )
        self.gcode.register_mux_command(
            "SET_HEATER_PID",
            "HEATER",
            short_name,
            self.cmd_SET_HEATER_PID,
            desc=self.cmd_SET_HEATER_PID_help,
        )
        # Snapmaker: switch between the pid profiles from printer.cfg / JSON
        self.gcode.register_mux_command(
            "SET_PID_PROFILE",
            "HEATER",
            short_name,
            self.cmd_SET_PID_PROFILE,
            desc=self.cmd_SET_PID_PROFILE_help,
        )

        self.printer.register_event_handler(
            "klippy:shutdown", self._handle_shutdown
        )

    def lookup_control(self, profile, load_clean=False):
        algos = collections.OrderedDict(
            {
                "watermark": ControlBangBang,
                "pid": ControlPID,
                "pid_v": ControlVelocityPID,
                "mpc": ControlMPC,
                "dual_loop_pid": ControlDualLoopPID,
            }
        )
        return algos[profile["control"]](profile, self, load_clean)

    def set_pwm(self, read_time, value):
        if self.target_temp <= 0.0 or read_time > self.verify_mainthread_time:
            value = 0.0
        if (read_time < self.next_pwm_time or not self.last_pwm_value) and abs(
            value - self.last_pwm_value
        ) < self.pwm_min_set_diff:
            # No significant change in value - can suppress update
            return
        pwm_time = read_time + self.pwm_delay
        # Snapmaker: never schedule a pwm update in the past
        min_pwm_time = (
            self.mcu_pwm.get_mcu().estimated_print_time(
                self.printer.get_reactor().monotonic()
            )
            + 0.5 * self.pwm_delay
        )
        if pwm_time < min_pwm_time:
            pwm_time = min_pwm_time
        self.next_pwm_time = pwm_time + 0.5 * MAX_HEAT_TIME
        self.last_pwm_value = value
        self.mcu_pwm.set_pwm(pwm_time, value)
        # logging.debug("%s: pwm=%.3f@%.3f (from %.3f@%.3f [%.3f])",
        #              self.name, value, pwm_time,
        #              self.last_temp, self.last_temp_time, self.target_temp)

    def temperature_callback(self, read_time, temp):
        with self.lock:
            time_diff = read_time - self.last_temp_time
            self.last_temp = temp
            self.last_temp_time = read_time
            self.control.temperature_update(read_time, temp, self.target_temp)
            temp_diff = temp - self.smoothed_temp
            adj_time = min(time_diff * self.inv_smooth_time, 1.0)
            self.smoothed_temp += temp_diff * adj_time
            self.can_extrude = (
                self.smoothed_temp >= self.min_extrude_temp or self.cold_extrude
            )
        # logging.debug("temp: %.3f %f = %f", read_time, temp)
        for mpc_sensor in self.mpc_sensors:
            mpc_sensor.process_temp_update(self.get_control(), read_time)

    def _handle_shutdown(self):
        self.verify_mainthread_time = -999.0

    # External commands
    def get_name(self):
        return self.name

    def add_mpc_sensor(self, mpc_sensor):
        self.mpc_sensors.append(mpc_sensor)

    def get_pwm_delay(self):
        return self.pwm_delay

    def get_max_power(self):
        return self.max_power

    def get_smooth_time(self):
        return self.smooth_time

    def set_inv_smooth_time(self, inv_smooth_time):
        self.inv_smooth_time = inv_smooth_time

    # Snapmaker: dynamic max power for idle / active toolheads
    def get_dynamic_max_power(self):
        return self.dynamic_max_power

    def set_dynamic_max_power(self, power, delay_increase=True):
        if (
            self.idle_hold_max_power is None
            and self.active_hold_max_power is None
        ):
            return
        new_power = max(0.0, min(self.max_power, power))
        if delay_increase:
            if self.dynamic_max_power != new_power:
                if new_power <= self.dynamic_max_power:
                    self.dynamic_max_power = new_power
                    self.pending_power_change = False
                else:
                    if self.pending_power_change:
                        self.dynamic_max_power = new_power
                        self.pending_power_change = False
                    else:
                        self.pending_power_change = True
            else:
                self.pending_power_change = False
        else:
            self.dynamic_max_power = new_power
            self.pending_power_change = False

    def set_temp(self, degrees):
        if degrees and (degrees < self.min_temp or degrees > self.max_temp):
            # Snapmaker: error codes are evaluated by the U1 touchscreen
            err_msg = (
                "%s: Requested temperature (%.1f) out of range (%.1f:%.1f)"
                % (self.short_name, degrees, self.min_temp, self.max_temp)
            )
            if self.short_name == "extruder":
                err_msg = (
                    '{"coded": "0003-0523-0000-0036", "oneshot": %d,'
                    ' "msg":"%s"}' % (1, err_msg)
                )
            elif (
                self.short_name.startswith("extruder")
                and self.short_name[8:].isdigit()
            ):
                index = int(self.short_name[8:])
                err_msg = (
                    '{"coded": "0003-0523-%04d-0036", "oneshot": %d,'
                    ' "msg":"%s"}' % (index, 1, err_msg)
                )
            elif self.short_name == "heater_bed":
                err_msg = (
                    '{"coded": "0003-0526-0000-0002", "oneshot": %d,'
                    ' "msg":"%s"}' % (1, err_msg)
                )
            raise self.printer.command_error(err_msg)
        with self.lock:
            if degrees != 0.0 and hasattr(self.control, "check_valid"):
                self.control.check_valid()
            self.target_temp = degrees

    def get_temp(self, eventtime):
        est_print_time = self.mcu_pwm.get_mcu().estimated_print_time(eventtime)
        # Snapmaker uses a 10s stale window instead of QUELL_STALE_TIME
        quell_time = est_print_time - 10.0
        with self.lock:
            if self.last_temp_time < quell_time:
                return 0.0, self.target_temp
            return self.smoothed_temp, self.target_temp

    def check_busy(self, eventtime):
        with self.lock:
            return self.control.check_busy(
                eventtime, self.smoothed_temp, self.target_temp
            )

    def set_control(self, control, keep_target=True):
        with self.lock:
            old_control = self.control
            self.control = control
            if not keep_target:
                self.target_temp = 0.0
        return old_control

    def get_control(self):
        return self.control

    def alter_target(self, target_temp):
        if target_temp:
            target_temp = max(self.min_temp, min(self.max_temp, target_temp))
        self.target_temp = target_temp

    def stats(self, eventtime):
        est_print_time = self.mcu_pwm.get_mcu().estimated_print_time(eventtime)
        if not self.printer.is_shutdown():
            self.verify_mainthread_time = est_print_time + MAX_MAINTHREAD_TIME
        with self.lock:
            target_temp = self.target_temp
            last_temp = self.last_temp
            last_pwm_value = self.last_pwm_value
        is_active = target_temp or last_temp > 50.0
        return is_active, "%s: target=%.0f temp=%.1f pwm=%.3f" % (
            self.short_name,
            target_temp,
            last_temp,
            last_pwm_value,
        )

    def get_status(self, eventtime):
        control_stats = None
        with self.lock:
            target_temp = self.target_temp
            smoothed_temp = self.smoothed_temp
            last_pwm_value = self.last_pwm_value
            if hasattr(self.control, "get_status"):
                control_stats = self.control.get_status(eventtime)
        ret = {
            # Snapmaker reports whole degrees
            "temperature": round(smoothed_temp, 0),
            "target": target_temp,
            "power": last_pwm_value,
            "pid_profile": self.get_control().get_profile()["name"],
        }
        if control_stats is not None:
            ret["control_stats"] = control_stats
        return ret

    def is_adc_faulty(self):
        if self.last_temp > self.max_temp or self.last_temp < self.min_temp:
            return True
        return False

    def set_cold_extrude(self, cold_extrude, min_extrude_temp):
        if cold_extrude is None and min_extrude_temp is None:
            self.gcode.respond_info(
                "Cold extrudes are %s (min temp %.2fC)"
                % (
                    "enabled" if self.cold_extrude else "disabled",
                    self.min_extrude_temp,
                )
            )
            return
        self.cold_extrude = True if cold_extrude else False
        if min_extrude_temp is not None:
            self.min_extrude_temp = min_extrude_temp
            self.configfile.set(
                self.name, "min_extrude_temp", self.min_extrude_temp
            )
            self.gcode.respond_info(
                "min_extrude_temp has been set to %.2fC "
                "for [%s] for the current session.\n"
                "The SAVE_CONFIG command will update the "
                "printer config file and restart the "
                "printer." % (self.min_extrude_temp, self.name)
            )
        self.can_extrude = (
            self.smoothed_temp >= self.min_extrude_temp or self.cold_extrude
        )

    cmd_SET_HEATER_TEMPERATURE_help = "Sets a heater temperature"
    cmd_SET_PID_PROFILE_help = "Sets active PID profile"

    def cmd_SET_PID_PROFILE(self, gcmd):
        # Snapmaker: switch between 'default'/'pid2'/'pid3'
        profile = gcmd.get("PROFILE", "default")
        if not isinstance(self.control, ControlPID):
            raise gcmd.error("Heater is not using PID control")
        self.control.set_pid_profile(profile)

    def cmd_SET_HEATER_TEMPERATURE(self, gcmd):
        temp = gcmd.get_float("TARGET", 0.0)
        pheaters = self.printer.lookup_object("heaters")
        pheaters.set_temperature(self, temp)

    cmd_COLD_EXTRUDE_help = "Control cold extrusions"

    def cmd_COLD_EXTRUDE(self, gcmd):
        cold_extrude = gcmd.get_int("ENABLE", None, minval=0, maxval=1)
        min_extrude_temp = gcmd.get_float(
            "MIN_EXTRUDE_TEMP", None, minval=self.min_temp, maxval=self.max_temp
        )
        self.set_cold_extrude(cold_extrude, min_extrude_temp)

    cmd_SET_SMOOTH_TIME_help = "Set the smooth time for the given heater"

    def cmd_SET_SMOOTH_TIME(self, gcmd):
        save_to_profile = gcmd.get_int("SAVE_TO_PROFILE", 0, minval=0, maxval=1)
        self.smooth_time = gcmd.get_float(
            "SMOOTH_TIME", self.config_smooth_time, minval=0.0
        )
        self.inv_smooth_time = 1.0 / self.smooth_time
        self.get_control().update_smooth_time()
        if save_to_profile:
            self.get_control().get_profile()["smooth_time"] = self.smooth_time
            self.pmgr.save_profile()

    cmd_SET_HEATER_PID_help = "Sets a heater PID parameter"

    def cmd_SET_HEATER_PID(self, gcmd):
        if not isinstance(self.control, (ControlPID, ControlVelocityPID)):
            raise gcmd.error("Not a PID/PID_V controlled heater")
        kp = gcmd.get_float("KP", None)
        if kp is not None:
            self.control.Kp = kp / PID_PARAM_BASE
        ki = gcmd.get_float("KI", None)
        if ki is not None:
            self.control.Ki = ki / PID_PARAM_BASE
        kd = gcmd.get_float("KD", None)
        if kd is not None:
            self.control.Kd = kd / PID_PARAM_BASE

    class ProfileManager:
        def __init__(self, outer_instance):
            self.outer_instance = outer_instance
            self.profiles = {}
            self.incompatible_profiles = []
            # Fetch stored profiles from Config
            stored_profs = self.outer_instance.config.get_prefix_sections(
                "pid_profile %s" % self.outer_instance.short_name
            )
            for profile in stored_profs:
                self._init_profile(
                    profile, profile.get_name().split(" ", 2)[-1]
                )

        def _init_profile(self, config_section, name):
            version = config_section.getint("pid_version", 1)
            if version != PID_PROFILE_VERSION:
                logging.info(
                    "Profile [%s] not compatible with this version "
                    "of pid_profile.\n"
                    "Profile Version: %d Current Version: %d"
                    % (name, version, PID_PROFILE_VERSION)
                )
                self.incompatible_profiles.append(name)
                return None
            temp_profile = {}
            control = self._check_value_config(
                "control", config_section, str, False
            )
            if control == "watermark":
                temp_profile["max_delta"] = config_section.getfloat(
                    "max_delta", 2.0, above=0.0
                )
            elif control == "mpc":
                temp_profile["block_heat_capacity"] = config_section.getfloat(
                    "block_heat_capacity", above=0.0, default=None
                )
                temp_profile["ambient_transfer"] = config_section.getfloat(
                    "ambient_transfer", minval=0.0, default=None
                )
                temp_profile["target_reach_time"] = config_section.getfloat(
                    "target_reach_time", above=0.0, default=2.0
                )
                temp_profile["smoothing"] = config_section.getfloat(
                    "smoothing", above=0.0, maxval=1.0, default=0.83
                )
                temp_profile["heater_power"] = config_section.getfloat(
                    "heater_power", above=0.0
                )
                temp_profile["sensor_responsiveness"] = config_section.getfloat(
                    "sensor_responsiveness", above=0.0, default=None
                )
                temp_profile["min_ambient_change"] = config_section.getfloat(
                    "min_ambient_change", above=0.0, default=1.0
                )
                temp_profile["steady_state_rate"] = config_section.getfloat(
                    "steady_state_rate", above=0.0, default=0.5
                )
                temp_profile["filament_diameter"] = config_section.getfloat(
                    "filament_diameter", above=0.0, default=1.75
                )
                temp_profile["filament_density"] = config_section.getfloat(
                    "filament_density", above=0.0, default=1.2
                )
                temp_profile["filament_heat_capacity"] = (
                    config_section.getfloat(
                        "filament_heat_capacity", above=0.0, default=1.8
                    )
                )
                temp_profile["maximum_retract"] = config_section.getfloat(
                    "maximum_retract", above=0.0, default=2.0
                )

                filament_temp_src_raw = config_section.get(
                    "filament_temperature_source", "ambient"
                )
                temp = filament_temp_src_raw.lower().strip()
                if temp == "sensor":
                    filament_temp_src = (FILAMENT_TEMP_SRC_SENSOR,)
                elif temp == "ambient":
                    filament_temp_src = (FILAMENT_TEMP_SRC_AMBIENT,)
                else:
                    try:
                        value = float(temp)
                    except ValueError:
                        raise config_section.error(
                            f"Unable to parse option 'filament_temperature_source' in section '{config_section.get_name()}'"
                        )
                    filament_temp_src = (FILAMENT_TEMP_SRC_FIXED, value)
                temp_profile["filament_temp_src"] = filament_temp_src

                ambient_sensor_name = config_section.get(
                    "ambient_temp_sensor", None
                )
                ambient_sensor = None
                if ambient_sensor_name is not None:
                    ambient_sensor = config_section.get_printer().load_object(
                        config_section,
                        ambient_sensor_name,
                        None,
                    )
                    if ambient_sensor is None:
                        ambient_sensor = (
                            config_section.get_printer().lookup_object(
                                ambient_sensor_name, None
                            )
                        )
                    if ambient_sensor is None:
                        raise config_section.error(
                            f"Unknown ambient_temp_sensor '{ambient_sensor_name}' specified"
                        )
                temp_profile["ambient_temp_sensor"] = ambient_sensor

                fan_name = config_section.get("cooling_fan", None)
                fan = None
                if fan_name is not None:
                    fan_obj = config_section.get_printer().load_object(
                        config_section,
                        fan_name,
                        None,
                    )
                    if fan_obj is None:
                        fan_obj = config_section.get_printer().lookup_object(
                            fan_name, None
                        )
                    if fan_obj is None:
                        raise config_section.error(
                            f"Unknown part_cooling_fan '{fan_name}' specified"
                        )
                    if not hasattr(fan_obj, "fan") or not hasattr(
                        fan_obj.fan, "set_speed"
                    ):
                        raise config_section.error(
                            f"part_cooling_fan '{fan_name}' is not a valid fan object"
                        )
                    fan = fan_obj.fan
                temp_profile["cooling_fan"] = fan

                temp_profile["fan_ambient_transfer"] = (
                    config_section.getfloatlist("fan_ambient_transfer", [])
                )
            elif control == "pid" or control == "pid_v":
                for key, (type, placeholder) in PID_PROFILE_OPTIONS.items():
                    can_be_none = (
                        key != "pid_kp" and key != "pid_ki" and key != "pid_kd"
                    )
                    temp_profile[key] = self._check_value_config(
                        key, config_section, type, can_be_none
                    )
                if name == "default":
                    temp_profile["smooth_time"] = None
            elif control == "dual_loop_pid":
                for key, (type, placeholder) in PID_PROFILE_OPTIONS.items():
                    can_be_none = key not in ["pid_kp", "pid_ki", "pid_kd"]
                    temp_profile[key] = self._check_value_config(
                        key, config_section, type, can_be_none
                    )
                    # Add the keys for the outer/primary loop
                    if key in ["pid_kp", "pid_ki", "pid_kd"]:
                        inner_key = "inner_" + key
                        temp_profile[inner_key] = self._check_value_config(
                            inner_key,
                            config_section,
                            type,
                            can_be_none,
                        )

                if name == "default":
                    temp_profile["smooth_time"] = None
            else:
                raise self.outer_instance.printer.config_error(
                    "Unknown control type '%s' "
                    "in [pid_profile %s %s]."
                    % (control, self.outer_instance.short_name, name)
                )
            temp_profile["control"] = control
            temp_profile["name"] = name
            self.profiles[name] = temp_profile
            return temp_profile

        def _check_value_config(self, key, config_section, type, can_be_none):
            if type is int:
                value = config_section.getint(key, None)
            elif type is float:
                value = config_section.getfloat(key, None)
            else:
                value = config_section.get(key, None)
            if not can_be_none and value is None:
                raise self.outer_instance.gcode.error(
                    "pid_profile: '%s' has to be "
                    "specified in [pid_profile %s %s]."
                    % (
                        key,
                        self.outer_instance.short_name,
                        config_section.get_name(),
                    )
                )
            return value

        def _compute_section_name(self, profile_name):
            return (
                self.outer_instance.short_name
                if profile_name == "default"
                else (
                    "pid_profile "
                    + self.outer_instance.short_name
                    + " "
                    + profile_name
                )
            )

        def _check_value_gcmd(
            self,
            name,
            default,
            gcmd,
            type,
            can_be_none,
            minval=None,
            maxval=None,
        ):
            if type is int:
                value = gcmd.get_int(
                    name, default, minval=minval, maxval=maxval
                )
            elif type is float:
                value = gcmd.get_float(
                    name, default, minval=minval, maxval=maxval
                )
            else:
                value = gcmd.get(name, default)
            if not can_be_none and value is None:
                raise self.outer_instance.gcode.error(
                    "pid_profile: '%s' has to be specified." % name
                )
            return value.lower() if type == "lower" else value

        def init_default_profile(self):
            return self._init_profile(self.outer_instance.config, "default")

        def set_values(self, profile_name, gcmd, verbose):
            current_profile = self.outer_instance.get_control().get_profile()
            target = self._check_value_gcmd("TARGET", None, gcmd, float, False)
            tolerance = self._check_value_gcmd(
                "TOLERANCE",
                current_profile["pid_tolerance"],
                gcmd,
                float,
                False,
            )
            control = self._check_value_gcmd(
                "CONTROL", current_profile["control"], gcmd, "lower", False
            )
            kp = self._check_value_gcmd("KP", None, gcmd, float, False)
            ki = self._check_value_gcmd("KI", None, gcmd, float, False)
            kd = self._check_value_gcmd("KD", None, gcmd, float, False)
            smooth_time = self._check_value_gcmd(
                "SMOOTH_TIME", None, gcmd, float, True
            )
            keep_target = self._check_value_gcmd(
                "KEEP_TARGET", 0, gcmd, int, True, minval=0, maxval=1
            )
            load_clean = self._check_value_gcmd(
                "LOAD_CLEAN", 0, gcmd, int, True, minval=0, maxval=1
            )
            temp_profile = {
                "pid_target": target,
                "pid_tolerance": tolerance,
                "control": control,
                "smooth_time": smooth_time,
                "pid_kp": kp,
                "pid_ki": ki,
                "pid_kd": kd,
            }
            if control == "dual_loop_pid":
                # The inner loop has its own gains, default to the values from
                # the current profile when not overridden on the command line.
                inner_kp = self._check_value_gcmd(
                    "INNER_KP",
                    current_profile.get("inner_pid_kp"),
                    gcmd,
                    float,
                    False,
                )
                inner_ki = self._check_value_gcmd(
                    "INNER_KI",
                    current_profile.get("inner_pid_ki"),
                    gcmd,
                    float,
                    False,
                )
                inner_kd = self._check_value_gcmd(
                    "INNER_KD",
                    current_profile.get("inner_pid_kd"),
                    gcmd,
                    float,
                    False,
                )
                temp_profile["inner_pid_kp"] = inner_kp
                temp_profile["inner_pid_ki"] = inner_ki
                temp_profile["inner_pid_kd"] = inner_kd
            temp_control = self.outer_instance.lookup_control(
                temp_profile, load_clean
            )
            self.outer_instance.set_control(temp_control, keep_target)
            msg = (
                "PID Parameters:\n"
                "Target: %.2f,\n"
                "Tolerance: %.4f\n"
                "Control: %s\n" % (target, tolerance, control)
            )
            if smooth_time is not None:
                msg += "Smooth Time: %.3f\n" % smooth_time
            msg += "pid_Kp=%.3f pid_Ki=%.3f pid_Kd=%.3f\n" % (kp, ki, kd)
            if control == "dual_loop_pid":
                msg += (
                    "inner_pid_Kp=%.3f inner_pid_Ki=%.3f "
                    "inner_pid_Kd=%.3f\n" % (inner_kp, inner_ki, inner_kd)
                )
            msg += "have been set as current profile."
            self.outer_instance.gcode.respond_info(msg)
            self.save_profile(profile_name=profile_name, verbose=True)

        def _profile_fields_msg(self, profile):
            # Generic field dump for non-PID profile types
            msg = "Control: %s\n" % (profile["control"],)
            for key, value in sorted(profile.items()):
                if key in ("control", "name") or value is None:
                    continue
                if isinstance(value, (int, float, str)):
                    msg += "%s: %s\n" % (key, value)
            msg += "name: %s" % (profile["name"],)
            return msg

        def get_values(self, profile_name, gcmd, verbose):
            temp_profile = self.outer_instance.get_control().get_profile()
            if temp_profile["control"] not in PID_CONTROL_TYPES:
                self.outer_instance.gcode.respond_info(
                    self._profile_fields_msg(temp_profile)
                )
                return
            target = temp_profile["pid_target"]
            tolerance = temp_profile["pid_tolerance"]
            control = temp_profile["control"]
            kp = temp_profile["pid_kp"]
            ki = temp_profile["pid_ki"]
            kd = temp_profile["pid_kd"]
            smooth_time = (
                self.outer_instance.get_smooth_time()
                if temp_profile["smooth_time"] is None
                else temp_profile["smooth_time"]
            )
            name = temp_profile["name"]
            msg = (
                "PID Parameters:\n"
                "Target: %.2f,\n"
                "Tolerance: %.4f\n"
                "Control: %s\n"
                "Smooth Time: %.3f\n"
                "pid_Kp=%.3f pid_Ki=%.3f pid_Kd=%.3f\n"
                % (target, tolerance, control, smooth_time, kp, ki, kd)
            )
            if control == "dual_loop_pid":
                msg += (
                    "inner_pid_Kp=%.3f inner_pid_Ki=%.3f "
                    "inner_pid_Kd=%.3f\n"
                    % (
                        temp_profile["inner_pid_kp"],
                        temp_profile["inner_pid_ki"],
                        temp_profile["inner_pid_kd"],
                    )
                )
            msg += "name: %s" % name
            self.outer_instance.gcode.respond_info(msg)

        def save_profile(self, profile_name=None, gcmd=None, verbose=True):
            temp_profile = self.outer_instance.get_control().get_profile()
            control = temp_profile["control"]
            if control not in PID_CONTROL_TYPES and control != "watermark":
                self.outer_instance.gcode.respond_info(
                    "Saving [%s] profiles with PID_PROFILE SAVE"
                    " is not supported." % (control,)
                )
                return
            if profile_name is None:
                profile_name = temp_profile["name"]
            section_name = self._compute_section_name(profile_name)
            self.outer_instance.configfile.set(
                section_name, "pid_version", PID_PROFILE_VERSION
            )
            if control == "watermark":
                self.outer_instance.configfile.set(
                    section_name, "control", control
                )
                self.outer_instance.configfile.set(
                    section_name,
                    "max_delta",
                    "%.4f" % (temp_profile["max_delta"],),
                )
            else:
                is_dual_loop = control == "dual_loop_pid"
                for key, (type, placeholder) in PID_PROFILE_OPTIONS.items():
                    value = temp_profile[key]
                    if value is not None:
                        self.outer_instance.configfile.set(
                            section_name, key, placeholder % value
                        )
                    # Mirror the inner/secondary loop keys read in
                    # _init_profile
                    if is_dual_loop and key in ("pid_kp", "pid_ki", "pid_kd"):
                        inner_key = "inner_" + key
                        inner_value = temp_profile.get(inner_key)
                        if inner_value is not None:
                            self.outer_instance.configfile.set(
                                section_name,
                                inner_key,
                                placeholder % inner_value,
                            )
            temp_profile["name"] = profile_name
            self.profiles[profile_name] = temp_profile
            if verbose:
                self.outer_instance.gcode.respond_info(
                    "Current PID profile for heater [%s] "
                    "has been saved to profile [%s] "
                    "for the current session.  The SAVE_CONFIG command will\n"
                    "update the printer config file and restart the printer."
                    % (self.outer_instance.short_name, profile_name)
                )

        def load_profile(self, profile_name, gcmd, verbose):
            verbose = self._check_value_gcmd(
                "VERBOSE", "low", gcmd, "lower", True
            )
            load_clean = self._check_value_gcmd(
                "LOAD_CLEAN", 0, gcmd, int, True, minval=0, maxval=1
            )
            if (
                profile_name
                == self.outer_instance.get_control().get_profile()["name"]
                and not load_clean
            ):
                if verbose == "high" or verbose == "low":
                    self.outer_instance.gcode.respond_info(
                        "PID Profile [%s] already loaded for heater [%s]."
                        % (profile_name, self.outer_instance.short_name)
                    )
                return
            keep_target = self._check_value_gcmd(
                "KEEP_TARGET", 0, gcmd, int, True, minval=0, maxval=1
            )
            profile = self.profiles.get(profile_name, None)
            defaulted = False
            default = gcmd.get("DEFAULT", None)
            if profile is None:
                if default is None:
                    raise self.outer_instance.gcode.error(
                        "pid_profile: Unknown profile [%s] for heater [%s]."
                        % (profile_name, self.outer_instance.short_name)
                    )
                profile = self.profiles.get(default, None)
                defaulted = True
                if profile is None:
                    raise self.outer_instance.gcode.error(
                        "pid_profile: Unknown default "
                        "profile [%s] for heater [%s]."
                        % (default, self.outer_instance.short_name)
                    )
            control = self.outer_instance.lookup_control(profile, load_clean)
            self.outer_instance.set_control(control, keep_target)

            if verbose != "high" and verbose != "low":
                return
            if defaulted:
                self.outer_instance.gcode.respond_info(
                    "Couldn't find profile "
                    "[%s] for heater [%s]"
                    ", defaulted to [%s]."
                    % (profile_name, self.outer_instance.short_name, default)
                )
            self.outer_instance.gcode.respond_info(
                "PID Profile [%s] loaded for heater [%s].\n"
                % (profile["name"], self.outer_instance.short_name)
            )
            if verbose == "high":
                if profile["control"] not in PID_CONTROL_TYPES:
                    self.outer_instance.gcode.respond_info(
                        self._profile_fields_msg(profile)
                    )
                    return
                smooth_time = (
                    self.outer_instance.get_smooth_time()
                    if profile["smooth_time"] is None
                    else profile["smooth_time"]
                )
                msg = "Target: %.2f\nTolerance: %.4f\nControl: %s\n" % (
                    profile["pid_target"],
                    profile["pid_tolerance"],
                    profile["control"],
                )
                if smooth_time is not None:
                    msg += "Smooth Time: %.3f\n" % smooth_time
                msg += (
                    "PID Parameters: pid_Kp=%.3f pid_Ki=%.3f pid_Kd=%.3f\n"
                    % (
                        profile["pid_kp"],
                        profile["pid_ki"],
                        profile["pid_kd"],
                    )
                )
                if profile["control"] == "dual_loop_pid":
                    msg += (
                        "Inner PID Parameters: inner_pid_Kp=%.3f "
                        "inner_pid_Ki=%.3f inner_pid_Kd=%.3f\n"
                        % (
                            profile["inner_pid_kp"],
                            profile["inner_pid_ki"],
                            profile["inner_pid_kd"],
                        )
                    )
                self.outer_instance.gcode.respond_info(msg)

        def remove_profile(self, profile_name, gcmd, verbose):
            if profile_name in self.profiles:
                section_name = self._compute_section_name(profile_name)
                self.outer_instance.configfile.remove_section(section_name)
                profiles = dict(self.profiles)
                del profiles[profile_name]
                self.profiles = profiles
                self.outer_instance.gcode.respond_info(
                    "Profile [%s] for heater [%s] "
                    "removed from storage for this session.\n"
                    "The SAVE_CONFIG command will update the printer\n"
                    "configuration and restart the printer"
                    % (profile_name, self.outer_instance.short_name)
                )
            else:
                self.outer_instance.gcode.respond_info(
                    "No profile named [%s] to remove" % profile_name
                )

        cmd_PID_PROFILE_help = "PID Profile Persistent Storage management"

        def cmd_PID_PROFILE(self, gcmd):
            options = collections.OrderedDict(
                {
                    "LOAD": self.load_profile,
                    "SAVE": self.save_profile,
                    "GET_VALUES": self.get_values,
                    "SET_VALUES": self.set_values,
                    "REMOVE": self.remove_profile,
                }
            )
            for key in options:
                profile_name = gcmd.get(key, None)
                if profile_name is not None:
                    if not profile_name.strip():
                        raise self.outer_instance.gcode.error(
                            "pid_profile: Profile must be specified"
                        )
                    options[key](profile_name, gcmd, True)
                    return
            raise self.outer_instance.gcode.error(
                "pid_profile: Invalid syntax '%s'" % (gcmd.get_commandline(),)
            )


######################################################################
# Dual Sensor Heater
######################################################################


class DualSensorHeater(Heater):
    def __init__(self, config, primary_sensor, secondary_sensor):
        super().__init__(config=config, sensor=primary_sensor)
        self.secondary_sensor = secondary_sensor

        if (
            isinstance(self.control, ControlDualLoopPID)
            and self.secondary_sensor is None
        ):
            raise config.error("dual_loop_pid requires a secondary sensor")

    def temperature_callback(self, read_time, primary_temp):
        with self.lock:
            time_diff = read_time - self.last_temp_time
            self.last_temp = primary_temp
            self.last_temp_time = read_time

            secondary_status = self.secondary_sensor.get_status(read_time)
            secondary_temp = secondary_status["temperature"]

            self.control.temperature_update(
                read_time, primary_temp, self.target_temp, secondary_temp
            )

            temp_diff = primary_temp - self.smoothed_temp
            adj_time = min(time_diff * self.inv_smooth_time, 1.0)
            self.smoothed_temp += temp_diff * adj_time
            self.can_extrude = (
                self.smoothed_temp >= self.min_extrude_temp or self.cold_extrude
            )


######################################################################
# Bang-bang control algo
######################################################################


class ControlBangBang:
    def __init__(self, profile, heater, load_clean=False):
        self.profile = profile
        self.heater = heater
        self.heater_max_power = heater.get_max_power()
        self.max_delta = profile["max_delta"]
        self.heating = False

    def temperature_update(self, read_time, temp, target_temp):
        if self.heating and temp >= target_temp + self.max_delta:
            self.heating = False
        elif not self.heating and temp <= target_temp - self.max_delta:
            self.heating = True
        if self.heating:
            heater_max_power = self.heater_max_power
            if self.heater.idle_hold_max_power is not None or self.heater.active_hold_max_power is not None:
                heater_max_power = min(heater_max_power, self.heater.get_dynamic_max_power())
            self.heater.set_pwm(read_time, heater_max_power)
        else:
            self.heater.set_pwm(read_time, 0.0)

    def check_busy(self, eventtime, smoothed_temp, target_temp):
        return smoothed_temp < target_temp - self.max_delta

    def update_smooth_time(self):
        self.smooth_time = self.heater.get_smooth_time()  # smoothing window

    def get_profile(self):
        return self.profile

    def get_type(self):
        return "watermark"


######################################################################
# Proportional Integral Derivative (PID) control algo
######################################################################

# Snapmaker uses wider settle tolerances than Kalico (1.0 / 0.1)
PID_SETTLE_DELTA = 2.0
PID_SETTLE_SLOPE = 0.5


class ControlPID:
    def __init__(self, profile, heater, load_clean=False):
        self.profile = profile
        self.heater = heater
        self.heater_max_power = heater.get_max_power()
        self.Kp = profile["pid_kp"] / PID_PARAM_BASE
        self.Ki = profile["pid_ki"] / PID_PARAM_BASE
        self.Kd = profile["pid_kd"] / PID_PARAM_BASE
        self.min_deriv_time = (
            self.heater.get_smooth_time()
            if profile["smooth_time"] is None
            else profile["smooth_time"]
        )
        self.heater.set_inv_smooth_time(1.0 / self.min_deriv_time)
        self.temp_integ_max = 0.0
        if self.Ki:
            self.temp_integ_max = self.heater_max_power / self.Ki
        self.prev_temp = (
            AMBIENT_TEMP
            if load_clean
            else self.heater.get_temp(self.heater.reactor.monotonic())[0]
        )
        self.prev_temp_time = 0.0
        self.prev_temp_deriv = 0.0
        self.prev_temp_integ = 0.0
        # Snapmaker: additional pid profiles ('default', 'pid2', 'pid3') taken
        # from printer.cfg and optionally overridden by a JSON file.  They are
        # switched at runtime with SET_PID_PROFILE (used by power_loss_check).
        self._init_snapmaker_pid_profiles(getattr(self.heater, "config", None))

    # ------------------------------------------------------------------
    # Snapmaker pid profile handling (config + JSON)
    # ------------------------------------------------------------------
    def _init_snapmaker_pid_profiles(self, config):
        self.pid_profiles = {}
        self.current_profile = "default"
        self.full_power_threshold = None
        self.zero_power_threshold = None
        self.settle_delta = PID_SETTLE_DELTA
        self.settle_slope = PID_SETTLE_SLOPE
        self.ignore_pid_json = True
        self.json_filename = None
        if config is None:
            return
        self.ignore_pid_json = config.getboolean("ignore_pid_json", False)
        config_name = self.heater.get_name()
        config_dir = self.heater.printer.get_snapmaker_config_dir()
        self.json_filename = os.path.join(
            config_dir, config_name.replace(" ", "_") + "_pid_parameters.json"
        )
        heater_json_profiles = None
        need_save_to_json = False
        if not self.ignore_pid_json:
            heater_json_profiles = self._load_heater_pid_profiles_from_json(
                self.json_filename
            )

        for prefix in ["", "pid2_", "pid3_"]:
            profile = prefix[:-1] if prefix != "" else "default"
            has_config_profile = (
                config.getfloat(prefix + "pid_Kp", None) is not None
            )

            # If profile exists in JSON and JSON is enabled, try to use it
            profile_loaded_from_json = False
            if (
                not self.ignore_pid_json
                and heater_json_profiles
                and profile in heater_json_profiles
            ):
                validated_profile = self._validate_pid_profile(
                    heater_json_profiles[profile]
                )
                if validated_profile:
                    validated_profile["Kp"] = (
                        validated_profile["Kp"] / PID_PARAM_BASE
                    )
                    validated_profile["Ki"] = (
                        validated_profile["Ki"] / PID_PARAM_BASE
                    )
                    validated_profile["Kd"] = (
                        validated_profile["Kd"] / PID_PARAM_BASE
                    )
                    self.pid_profiles[profile] = validated_profile
                    profile_loaded_from_json = True
                else:
                    logging.warning(
                        "Invalid PID profile '%s' for heater '%s' in JSON"
                        " file, using config values",
                        profile,
                        config_name,
                    )
                    need_save_to_json = True

            if has_config_profile:
                config_Kp = config.getfloat(prefix + "pid_Kp")
                config_Ki = config.getfloat(prefix + "pid_Ki")
                config_Kd = config.getfloat(prefix + "pid_Kd")
                config_full_power_threshold = config.getfloat(
                    prefix + "full_power_threshold", None, above=0.0
                )
                config_zero_power_threshold = config.getfloat(
                    prefix + "zero_power_threshold", None, above=0.0
                )
                config_settle_delta = config.getfloat(
                    prefix + "settle_delta", PID_SETTLE_DELTA
                )
                config_settle_slope = config.getfloat(
                    prefix + "settle_slope", PID_SETTLE_SLOPE
                )

                profile_data = {
                    "Kp": config_Kp / PID_PARAM_BASE,
                    "Ki": config_Ki / PID_PARAM_BASE,
                    "Kd": config_Kd / PID_PARAM_BASE,
                    "full_power_threshold": config_full_power_threshold,
                    "zero_power_threshold": config_zero_power_threshold,
                    "settle_delta": config_settle_delta,
                    "settle_slope": config_settle_slope,
                }

                json_profile_data = {
                    "Kp": config_Kp,
                    "Ki": config_Ki,
                    "Kd": config_Kd,
                    "full_power_threshold": config_full_power_threshold,
                    "zero_power_threshold": config_zero_power_threshold,
                    "settle_delta": config_settle_delta,
                    "settle_slope": config_settle_slope,
                }

                if not profile_loaded_from_json:
                    self.pid_profiles[profile] = profile_data
                    if not self.ignore_pid_json:
                        need_save_to_json = True

                if not self.ignore_pid_json:
                    if heater_json_profiles is None:
                        heater_json_profiles = {}
                    heater_json_profiles[profile] = json_profile_data

        if not self.pid_profiles:
            # No Snapmaker style profiles - keep the Kalico profile values
            return

        if (
            not self.ignore_pid_json
            and need_save_to_json
            and heater_json_profiles
        ):
            self._save_heater_pid_profiles_to_json(
                self.json_filename, heater_json_profiles
            )

        # Only the (Kalico) default profile is overlaid with the Snapmaker
        # values; a profile explicitly loaded via PID_PROFILE stays untouched.
        if (
            self.profile.get("name", "default") == "default"
            and "default" in self.pid_profiles
        ):
            self._apply_snapmaker_pid_profile("default")

    def _apply_snapmaker_pid_profile(self, profile):
        values = self.pid_profiles[profile]
        self.current_profile = profile
        self.Kp = values["Kp"]
        self.Ki = values["Ki"]
        self.Kd = values["Kd"]
        self.full_power_threshold = values["full_power_threshold"]
        self.zero_power_threshold = values["zero_power_threshold"]
        self.settle_delta = values["settle_delta"]
        self.settle_slope = values["settle_slope"]
        self.temp_integ_max = 0.0
        if self.Ki:
            self.temp_integ_max = self.heater_max_power / self.Ki

    def _validate_pid_profile(self, profile_data):
        if not isinstance(profile_data, dict):
            return None

        required_fields = ["Kp", "Ki", "Kd"]
        validated_profile = {}

        for field in required_fields:
            if field not in profile_data:
                return None
            try:
                validated_profile[field] = float(profile_data[field])
            except (ValueError, TypeError):
                return None

        optional_fields = [
            "full_power_threshold",
            "zero_power_threshold",
            "settle_delta",
            "settle_slope",
        ]
        for field in optional_fields:
            if field in profile_data and profile_data[field] is not None:
                try:
                    validated_profile[field] = float(profile_data[field])
                except (ValueError, TypeError):
                    pass
            else:
                if field == "settle_delta":
                    validated_profile[field] = PID_SETTLE_DELTA
                elif field == "settle_slope":
                    validated_profile[field] = PID_SETTLE_SLOPE
                else:
                    validated_profile[field] = None

        return validated_profile

    def _load_heater_pid_profiles_from_json(self, json_filename):
        try:
            if os.path.exists(json_filename):
                with open(json_filename, "r") as f:
                    profiles = json.load(f)
                    validated_profiles = {}
                    for profile_name, profile_data in profiles.items():
                        validated_profile = self._validate_pid_profile(
                            profile_data
                        )
                        if validated_profile:
                            validated_profiles[profile_name] = (
                                validated_profile
                            )
                        else:
                            logging.warning(
                                "Invalid PID profile '%s' in JSON file"
                                " '%s', skipping",
                                profile_name,
                                json_filename,
                            )
                    return validated_profiles
        except Exception as e:
            logging.warning(
                "Failed to load PID profiles from JSON (%s): %s. Using config"
                " values and will recreate JSON.",
                json_filename,
                e,
            )
        return None

    def _save_heater_pid_profiles_to_json(self, json_filename, profiles):
        try:
            os.makedirs(os.path.dirname(json_filename), exist_ok=True)
            json_content = json.dumps(profiles, indent=2)
            queuefile.async_write_file(
                json_filename, json_content, flush=True, safe_write=True
            )
        except Exception as e:
            logging.warning(
                "Failed to save PID profiles to JSON (%s): %s",
                json_filename,
                e,
            )

    def calculate_output(self, read_time, temp, target_temp, max_power=None):
        time_diff = read_time - self.prev_temp_time
        # Calculate change of temperature
        temp_diff = temp - self.prev_temp
        if time_diff >= self.min_deriv_time:
            temp_deriv = temp_diff / time_diff
        else:
            temp_deriv = (
                self.prev_temp_deriv * (self.min_deriv_time - time_diff)
                + temp_diff
            ) / self.min_deriv_time
        # Calculate accumulated temperature "error"
        temp_err = target_temp - temp
        temp_integ = self.prev_temp_integ + temp_err * time_diff
        temp_integ = max(0.0, min(self.temp_integ_max, temp_integ))
        # Calculate output
        co = self.Kp * temp_err + self.Ki * temp_integ - self.Kd * temp_deriv
        # logging.debug("pid: %f@%.3f -> diff=%f deriv=%f err=%f integ=%f co=%d",
        #    temp, read_time, temp_diff, temp_deriv, temp_err, temp_integ, co)
        if max_power is None:
            max_power = self.heater_max_power
        bounded_co = max(0.0, min(max_power, co))
        # Store state for next measurement
        self.prev_temp = temp
        self.prev_temp_time = read_time
        self.prev_temp_deriv = temp_deriv
        if co == bounded_co:
            self.prev_temp_integ = temp_integ

        return co, bounded_co

    def temperature_update(self, read_time, temp, target_temp):
        # Snapmaker: honour the dynamic max power of idle toolheads
        heater_max_power = self.heater_max_power
        if (
            self.heater.idle_hold_max_power is not None
            or self.heater.active_hold_max_power is not None
        ):
            heater_max_power = min(
                heater_max_power, self.heater.get_dynamic_max_power()
            )

        # Snapmaker: full power / zero power thresholds
        if target_temp > 0:
            if self.zero_power_threshold is not None and (
                temp - target_temp > self.zero_power_threshold
            ):
                self.heater.set_pwm(read_time, 0.0)
                # Continue updating PID state variables
                time_diff = read_time - self.prev_temp_time
                temp_diff = temp - self.prev_temp
                if time_diff >= self.min_deriv_time:
                    temp_deriv = temp_diff / time_diff
                else:
                    temp_deriv = (
                        self.prev_temp_deriv * (self.min_deriv_time - time_diff)
                        + temp_diff
                    ) / self.min_deriv_time
                temp_err = target_temp - temp
                temp_integ = self.prev_temp_integ + temp_err * time_diff
                temp_integ = max(0.0, min(self.temp_integ_max, temp_integ))
                self.prev_temp = temp
                self.prev_temp_time = read_time
                self.prev_temp_deriv = temp_deriv
                self.prev_temp_integ = temp_integ
                return

            if self.full_power_threshold is not None and (
                target_temp - temp > self.full_power_threshold
            ):
                self.heater.set_pwm(read_time, heater_max_power)
                self.prev_temp = temp
                self.prev_temp_time = read_time
                self.prev_temp_deriv = 0.0
                self.prev_temp_integ = 0.0
                return

        # Normal PID control
        _, bounded_co = self.calculate_output(
            read_time, temp, target_temp, heater_max_power
        )
        self.heater.set_pwm(read_time, bounded_co)

    def check_busy(self, eventtime, smoothed_temp, target_temp):
        temp_diff = target_temp - smoothed_temp
        return (
            abs(temp_diff) > self.settle_delta
            or abs(self.prev_temp_deriv) > self.settle_slope
        )

    def set_pid_profile(self, profile):
        # Snapmaker: switch between the config/JSON pid profiles
        if profile not in self.pid_profiles:
            raise self.heater.printer.command_error(
                "Unknown PID profile: %s" % (profile,)
            )
        gcode = self.heater.printer.lookup_object("gcode", None)
        if gcode is not None:
            gcode.respond_info(
                "set pid profile: {}\n{}".format(
                    profile, self.pid_profiles[profile]
                )
            )
        self._apply_snapmaker_pid_profile(profile)
        # Reset PID state when switching profiles
        self.prev_temp = AMBIENT_TEMP
        self.prev_temp_time = 0.0
        self.prev_temp_deriv = 0.0
        self.prev_temp_integ = 0.0

    def update_smooth_time(self):
        self.smooth_time = self.heater.get_smooth_time()  # smoothing window

    def get_profile(self):
        return self.profile

    def get_type(self):
        return "pid"


######################################################################
# Velocity (PID) control algo
######################################################################


class ControlVelocityPID:
    def __init__(self, profile, heater, load_clean=False):
        self.profile = profile
        self.heater = heater
        self.heater_max_power = heater.get_max_power()
        self.Kp = profile["pid_kp"] / PID_PARAM_BASE
        self.Ki = profile["pid_ki"] / PID_PARAM_BASE
        self.Kd = profile["pid_kd"] / PID_PARAM_BASE
        smooth_time = (
            self.heater.get_smooth_time()
            if profile["smooth_time"] is None
            else profile["smooth_time"]
        )
        self.heater.set_inv_smooth_time(1.0 / smooth_time)
        self.smooth_time = smooth_time  # smoothing window
        self.temps = (
            ([AMBIENT_TEMP] * 3)
            if load_clean
            else (
                [self.heater.get_temp(self.heater.reactor.monotonic())[0]] * 3
            )
        )
        self.times = [0.0] * 3  # temperature reading times
        self.d1 = 0.0  # previous smoothed 1st derivative
        self.d2 = 0.0  # previous smoothed 2nd derivative
        self.pwm = 0.0 if load_clean else self.heater.last_pwm_value

    def temperature_update(self, read_time, temp, target_temp):
        # update the temp and time lists
        self.temps.pop(0)
        self.temps.append(temp)
        self.times.pop(0)
        self.times.append(read_time)

        # calculate the 1st derivative: p part in velocity form
        # note the derivative is of the temp and not the error
        # this is to prevent derivative kick
        d1 = self.temps[-1] - self.temps[-2]

        # calculate the error : i part in velocity form
        error = self.times[-1] - self.times[-2]
        error = error * (target_temp - self.temps[-1])

        # calculate the 2nd derivative: d part in velocity form
        # note the derivative is of the temp and not the error
        # this is to prevent derivative kick
        d2 = self.temps[-1] - 2.0 * self.temps[-2] + self.temps[-3]
        d2 = d2 / (self.times[-1] - self.times[-2])

        # smooth both the derivatives using a modified moving average
        # that handles unevenly spaced data points
        n = max(1.0, self.smooth_time / (self.times[-1] - self.times[-2]))
        self.d1 = ((n - 1.0) * self.d1 + d1) / n
        self.d2 = ((n - 1.0) * self.d2 + d2) / n

        # calculate the output
        p = self.Kp * -self.d1  # invert sign to prevent derivative kick
        i = self.Ki * error
        d = self.Kd * -self.d2  # invert sign to prevent derivative kick

        self.pwm = max(0.0, min(self.heater_max_power, self.pwm + p + i + d))
        if target_temp == 0.0:
            self.pwm = 0.0

        # update the heater
        self.heater.set_pwm(read_time, self.pwm)

    def check_busy(self, eventtime, smoothed_temp, target_temp):
        temp_diff = target_temp - smoothed_temp
        return (
            abs(temp_diff) > PID_SETTLE_DELTA or abs(self.d1) > PID_SETTLE_SLOPE
        )

    def update_smooth_time(self):
        self.smooth_time = self.heater.get_smooth_time()  # smoothing window

    def get_profile(self):
        return self.profile

    def get_type(self):
        return "pid_v"


######################################################################
# Dual Loop PID control algo
######################################################################

# Secondary Loop monitors the heater / transfer medium
# Primary Loop monitors the surface / medium


class ControlInnerPID(ControlPID):
    """
    PID Controller for the inner loop of dual loop pid
    """

    def __init__(self, profile, heater, load_clean=False):
        super().__init__(profile, heater, load_clean)

        self.Kp = profile["inner_pid_kp"] / PID_PARAM_BASE
        self.Ki = profile["inner_pid_ki"] / PID_PARAM_BASE
        self.Kd = profile["inner_pid_kd"] / PID_PARAM_BASE

        if self.Ki:
            self.temp_integ_max = self.heater_max_power / self.Ki


class ControlDualLoopPID:
    def __init__(self, profile, heater, load_clean=False):
        self.profile = profile
        self.heater = heater
        self.heater_max_power = heater.get_max_power()

        # Outer (primary) loop - e.g. bed surface
        self.primary_pid = ControlPID(
            profile=profile,
            heater=heater,
            load_clean=load_clean,
        )

        # Inner (secondary) loop - e.g. heater element
        self.secondary_pid = ControlInnerPID(
            profile=profile,
            heater=heater,
            load_clean=load_clean,
        )

        self.inner_target_temp = lookup_dual_loop_pid_inner_target_temp(
            self.heater.config
        )

    def temperature_update(
        self,
        read_time,
        primary_temp,
        target_temp,
        secondary_temp,
    ):
        if secondary_temp is None:
            raise ValueError("Secondary temperature must be provided!")

        primary_prev_temp_integ = self.primary_pid.prev_temp_integ
        primary_co, _ = self.primary_pid.calculate_output(
            read_time,
            primary_temp,
            target_temp,
        )

        secondary_prev_temp_integ = self.secondary_pid.prev_temp_integ
        secondary_co, _ = self.secondary_pid.calculate_output(
            read_time,
            secondary_temp,
            self.inner_target_temp,
        )

        co = min(primary_co, secondary_co)
        bounded_co = max(0.0, min(self.heater_max_power, co))

        # If the other loop reduced the final heater output, don't let this
        # loop retain an integrator update based on power that was never
        # actually applied to the heater.
        if primary_co != bounded_co:
            self.primary_pid.prev_temp_integ = primary_prev_temp_integ
        if secondary_co != bounded_co:
            self.secondary_pid.prev_temp_integ = secondary_prev_temp_integ

        self.heater.set_pwm(read_time, bounded_co)

    def check_busy(self, eventtime, smoothed_temp, target_temp):
        return self.primary_pid.check_busy(
            eventtime,
            smoothed_temp,
            target_temp,
        )

    def update_smooth_time(self):
        self.smooth_time = self.heater.get_smooth_time()  # smoothing window

    def get_profile(self):
        return self.profile

    def get_type(self):
        return "dual_loop_pid"


######################################################################
# Sensor and heater lookup
######################################################################

# Snapmaker: only a limited number of extruders may heat at the same time
MAX_HEATING_EXTRUDERS = 2
INACTIVE_EXTRUDER_TEMP_DELTA = 2.0


class PrinterHeaters:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.sensor_factories = {}
        self.heaters = {}
        self.gcode_id_to_sensor = {}
        self.available_heaters = []
        self.available_sensors = []
        self.available_monitors = []
        self.has_started = self.have_load_sensors = False
        self.active_heating_extruders = []
        self.pending_extruders = []
        self.extruder_list = []
        self.reactor = self.printer.get_reactor()
        self.heater_check_timer = None
        self.max_heating_extruders = MAX_HEATING_EXTRUDERS
        self.printer.register_event_handler("klippy:ready", self._handle_ready)
        self.printer.register_event_handler(
            "gcode:request_restart", self.turn_off_all_heaters
        )
        # Register commands
        self.gcode = self.printer.lookup_object("gcode")
        self.gcode.register_command(
            "TURN_OFF_HEATERS",
            self.cmd_TURN_OFF_HEATERS,
            desc=self.cmd_TURN_OFF_HEATERS_help,
        )
        self.gcode.register_command("M105", self.cmd_M105, when_not_ready=True)
        self.gcode.register_command(
            "TEMPERATURE_WAIT",
            self.cmd_TEMPERATURE_WAIT,
            desc=self.cmd_TEMPERATURE_WAIT_help,
        )

    def load_config(self, config):
        self.have_load_sensors = True
        # Load default temperature sensors
        pconfig = self.printer.lookup_object("configfile")
        dir_name = os.path.dirname(__file__)
        filename = os.path.join(dir_name, "temperature_sensors.cfg")
        try:
            dconfig = pconfig.read_config(filename)
        except Exception:
            logging.exception("Unable to load temperature_sensors.cfg")
            raise config.error("Cannot load config '%s'" % (filename,))
        for c in dconfig.get_prefix_sections(""):
            self.printer.load_object(dconfig, c.get_name())

    def add_sensor_factory(self, sensor_type, sensor_factory):
        self.sensor_factories[sensor_type] = sensor_factory

    def setup_heater(self, config, gcode_id=None):
        heater_name = config.get_name().split()[-1]
        if heater_name in self.heaters:
            raise config.error("Heater %s already registered" % (heater_name,))

        # Setup sensor (primary/outer sensor for dual loop)
        sensor = self.setup_sensor(config)

        # Setup inner sensor (inner/secondary sensor only for dual loop pid)
        inner_sensor = None
        inner_sensor_name = config.get("inner_sensor_name", None)
        if inner_sensor_name is not None:
            full_name = "temperature_sensor " + inner_sensor_name
            inner_sensor = self.printer.lookup_object(full_name)

        # Create heater
        if inner_sensor is not None:
            heater = DualSensorHeater(
                config=config,
                primary_sensor=sensor,
                secondary_sensor=inner_sensor,
            )
        else:
            heater = Heater(config=config, sensor=sensor)

        self.heaters[heater_name] = heater
        self.register_sensor(config, heater, gcode_id)
        self.available_heaters.append(config.get_name())
        return heater

    def get_all_heaters(self):
        return self.available_heaters

    def lookup_heater(self, heater_name):
        if " " in heater_name:
            heater_name = heater_name.split(" ", 1)[1]
        if heater_name not in self.heaters:
            raise self.printer.config_error(
                "Unknown heater '%s'" % (heater_name,)
            )
        return self.heaters[heater_name]

    def setup_sensor(self, config):
        if not self.have_load_sensors:
            self.load_config(config)
        sensor_type = config.get("sensor_type")
        if sensor_type not in self.sensor_factories:
            raise self.printer.config_error(
                "Unknown temperature sensor '%s'" % (sensor_type,)
            )
        return self.sensor_factories[sensor_type](config)

    def register_sensor(self, config, psensor, gcode_id=None):
        self.available_sensors.append(config.get_name())
        if gcode_id is None:
            gcode_id = config.get("gcode_id", None)
            if gcode_id is None:
                return
        if gcode_id in self.gcode_id_to_sensor:
            raise self.printer.config_error(
                "G-Code sensor id %s already registered" % (gcode_id,)
            )
        self.gcode_id_to_sensor[gcode_id] = psensor

    def register_monitor(self, config):
        self.available_monitors.append(config.get_name())

    def get_status(self, eventtime):
        return {
            "available_heaters": self.available_heaters,
            "available_sensors": self.available_sensors,
            "available_monitors": self.available_monitors,
        }

    def turn_off_all_heaters(self, print_time=0.0):
        # Snapmaker: clear all extruder heating state
        self.active_heating_extruders = []
        self.pending_extruders = []
        # Turn off all heaters
        for heater in self.heaters.values():
            heater.set_temp(0.0)

    cmd_TURN_OFF_HEATERS_help = "Turn off all heaters"

    def cmd_TURN_OFF_HEATERS(self, gcmd):
        self.turn_off_all_heaters()

    # G-Code M105 temperature reporting
    def _handle_ready(self):
        self.has_started = True
        # Snapmaker: extruder heating queue + dynamic power management
        if self.heater_check_timer is None:
            self.heater_check_timer = self.reactor.register_timer(
                self._check_heater_queue, self.reactor.NOW
            )
        self.extruder_list = self.printer.lookup_object("extruder_list", [])

    def _get_temp(self, eventtime):
        # Tn:XXX /YYY B:XXX /YYY
        out = []
        if self.has_started:
            for gcode_id, sensor in sorted(self.gcode_id_to_sensor.items()):
                cur, target = sensor.get_temp(eventtime)
                out.append("%s:%.1f /%.1f" % (gcode_id, cur, target))
        if not out:
            return "T:0"
        return " ".join(out)

    def cmd_M105(self, gcmd):
        # Get Extruder Temperature
        reactor = self.printer.get_reactor()
        msg = self._get_temp(reactor.monotonic())
        did_ack = gcmd.ack(msg)
        if not did_ack:
            gcmd.respond_raw(msg)

    def _wait_for_temperature(self, heater):
        # Helper to wait on heater.check_busy() and report M105 temperatures

        if self.printer.get_start_args().get("debugoutput") is not None:
            return
        # Snapmaker: keep the lookahead flushed while waiting
        toolhead = self.printer.lookup_object("toolhead")
        gcode = self.printer.lookup_object("gcode")
        reactor = self.printer.get_reactor()
        eventtime = reactor.monotonic()
        while not self.printer.is_shutdown() and heater.check_busy(eventtime):
            toolhead.get_last_move_time()
            gcode.respond_raw(self._get_temp(eventtime))
            eventtime = reactor.pause(eventtime + 1.0)

    def _check_heater_queue(self, eventtime):
        # Check active heaters
        self.active_heating_extruders = [
            h for h in self.active_heating_extruders
            if self.heaters[h].last_temp < \
                (self.heaters[h].target_temp - INACTIVE_EXTRUDER_TEMP_DELTA)
        ]

        # Start pending heaters if slots available
        while (self.pending_extruders and
               len(self.active_heating_extruders) < self.max_heating_extruders):
            heater_name, temp = self.pending_extruders.pop(0)
            self.active_heating_extruders.append(heater_name)
            self.heaters[heater_name].set_temp(temp)

        try:
            if self.extruder_list and len(self.extruder_list) > 0:
                toolhead = self.printer.lookup_object('toolhead')
                for i in range(len(self.extruder_list)):
                    name = self.extruder_list[i].get_name()
                    heater = self.heaters[name]
                    if heater.idle_hold_max_power is not None or heater.active_hold_max_power is not None:
                        dynamic_max_power = heater.get_max_power()
                        if not name in self.active_heating_extruders:
                            if toolhead.get_extruder().get_name() == name and heater.active_hold_max_power is not None:
                                dynamic_max_power = heater.active_hold_max_power
                            elif heater.idle_hold_max_power is not None:
                                dynamic_max_power = heater.idle_hold_max_power
                        heater.set_dynamic_max_power(dynamic_max_power)
        except Exception as e:
            logging.info("Error during dynamic power management: %s", str(e))

        return eventtime + 1.0

    def update_pending_extruder(self, heater_name, temp):
        existing_entry_index = None
        for i, (name, t) in enumerate(self.pending_extruders):
            if name == heater_name:
                existing_entry_index = i
                break

        if existing_entry_index is not None:
            self.pending_extruders[existing_entry_index] = (heater_name, temp)
            logging.debug("Updated pending extruder %s with new temp %.1f", heater_name, temp)
        else:
            self.pending_extruders.append((heater_name, temp))
            logging.debug("Added new pending extruder %s with temp %.1f", heater_name, temp)
    def remove_pending_extruder(self, heater_name):
        for i, (name, temp) in enumerate(self.pending_extruders):
            if name == heater_name:
                del self.pending_extruders[i]
                logging.debug("Removed pending extruder %s", heater_name)
                return True
        return False

    def set_temperature(self, heater, temp, wait=False):
        toolhead = self.printer.lookup_object("toolhead")
        toolhead.register_lookahead_callback((lambda pt: None))
        heater_name = heater.get_name()
        virtual_sdcard = self.printer.lookup_object('virtual_sdcard', None)
        if virtual_sdcard is not None:
            virtual_sdcard.record_pl_print_temperature_env({heater.short_name: temp})
        # Only apply limit to extruder heaters
        if not heater_name.startswith('extruder'):
            heater.set_temp(temp)
            if wait and temp:
                self._wait_for_temperature(heater)
            return
        # Handle extruder heating
        if temp > 0:
            if heater_name in self.active_heating_extruders:
                # Already heating - just update target temp
                heater.set_temp(temp)
                if wait:
                    self._wait_for_temperature(heater)
                return

            if len(self.active_heating_extruders) < self.max_heating_extruders:
                # Start heating immediately
                self.active_heating_extruders.append(heater_name)
                heater.set_temp(temp)
                if wait:
                    self._wait_for_temperature(heater)
            else:
                current_temp = self.heaters[heater_name].smoothed_temp
                if current_temp + INACTIVE_EXTRUDER_TEMP_DELTA >= temp:
                    self.remove_pending_extruder(heater_name)
                    heater.set_temp(temp)
                    if wait:
                        self._wait_for_temperature(heater)
                    return

                logging.info("concurrently heating %d extruders, "
                            "waiting for %s to finish",
                            len(self.active_heating_extruders),
                            self.active_heating_extruders[0])
                # Add to pending queue
                if wait:
                    # If waiting, block until heater is active
                    # self.pending_extruders.append((heater_name, temp))
                    self.update_pending_extruder(heater_name, temp)
                    while (heater_name, temp) in self.pending_extruders:
                        self.reactor.pause(self.reactor.monotonic() + 0.2)

                    while heater_name in self.active_heating_extruders:
                        self._wait_for_temperature(self.heaters[heater_name])
                        self.reactor.pause(self.reactor.monotonic() + 0.2)
                else:
                    # Non-blocking - just add to queue
                    self.update_pending_extruder(heater_name, temp)
                    # self.pending_extruders.append((heater_name, temp))
        else:
            # Cooling down
            if heater_name in self.active_heating_extruders:
                logging.info("cancel active heater %s", heater_name)
                self.active_heating_extruders.remove(heater_name)
            self.remove_pending_extruder(heater_name)
            heater.set_temp(temp)

    cmd_TEMPERATURE_WAIT_help = "Wait for a temperature on a sensor"

    def cmd_TEMPERATURE_WAIT(self, gcmd):
        sensor_name = gcmd.get("SENSOR")
        if sensor_name not in self.available_sensors:
            raise gcmd.error("Unknown sensor '%s'" % (sensor_name,))
        min_temp = gcmd.get_float("MINIMUM", float("-inf"))
        max_temp = gcmd.get_float("MAXIMUM", float("inf"), above=min_temp)
        error_on_cancel = gcmd.get("ALLOW_CANCEL", None) is None
        if min_temp == float("-inf") and max_temp == float("inf"):
            raise gcmd.error(
                "Error on 'TEMPERATURE_WAIT': missing MINIMUM or MAXIMUM."
            )
        if self.printer.get_start_args().get("debugoutput") is not None:
            return
        if sensor_name in self.heaters:
            sensor = self.heaters[sensor_name]
        else:
            sensor = self.printer.lookup_object(sensor_name)

        def check(eventtime):
            temp, _ = sensor.get_temp(eventtime)
            if temp >= min_temp and temp <= max_temp:
                return False
            gcmd.respond_raw(self._get_temp(eventtime))
            return True

        self.printer.wait_while(check, error_on_cancel)


def load_config(config):
    return PrinterHeaters(config)
