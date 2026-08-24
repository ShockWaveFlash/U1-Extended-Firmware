# Printer cooling fan
#
# Copyright (C) 2016-2020  Kevin O'Connor <kevin@koconnor.net>
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import copy
import logging

from . import pulse_counter

FAN_MIN_TIME = 0.100


class Fan:
    def __init__(self, config, default_shutdown_speed=0.0):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.last_fan_value = self.last_req_value = 0.0
        self.last_pwm_value = 0.0
        self.last_fan_time = 0.0
        self.last_enable_value = 0.0
        # Read config
        self.kick_start_time = config.getfloat(
            "kick_start_time", 0.1, minval=0.0
        )
        self.min_power = config.getfloat(
            "min_power", default=None, minval=0.0, maxval=1.0
        )
        self.off_below = config.getfloat(
            "off_below", default=None, minval=0.0, maxval=1.0
        )
        if self.off_below is not None:
            config.deprecate("off_below")
        self.initial_speed = config.getfloat(
            "initial_speed", default=None, minval=0.0, maxval=1.0
        )

        # handles switchover of variable
        # if new var is not set, and old var is, set new var to old var
        # if new var is not set and neither is old var, set new var to default of 0.0
        # if new var is set, use new var
        if self.min_power is not None and self.off_below is not None:
            raise config.error(
                "min_power and off_below are both set. Remove one!"
            )
        if self.min_power is None:
            if self.off_below is None:
                # both unset, set to 0.0
                self.min_power = 0.0
            else:
                self.min_power = self.off_below

        self.max_power = config.getfloat(
            "max_power", 1.0, above=0.0, maxval=1.0
        )
        if self.min_power > self.max_power:
            raise config.error(
                "min_power=%f can't be larger than max_power=%f"
                % (self.min_power, self.max_power)
            )

        cycle_time = config.getfloat("cycle_time", 0.010, above=0.0)
        hardware_pwm = config.getboolean("hardware_pwm", False)
        shutdown_speed = config.getfloat(
            "shutdown_speed", default_shutdown_speed, minval=0.0, maxval=1.0
        )
        # Setup pwm object
        ppins = self.printer.lookup_object("pins")
        self.mcu_fan = ppins.setup_pin("pwm", config.get("pin"))
        self.mcu_fan.setup_max_duration(0.0)
        self.mcu_fan.setup_cycle_time(cycle_time, hardware_pwm)

        if hardware_pwm:
            shutdown_power = max(0.0, min(self.max_power, shutdown_speed))
        else:
            # the config allows shutdown_power to be > 0 and < 1, but it is validated
            # in MCU_pwm._build_config().
            shutdown_power = max(0.0, shutdown_speed)

        self.mcu_fan.setup_start_value(0.0, shutdown_power)
        self.enable_pin = None
        enable_pin = config.get("enable_pin", None)
        if enable_pin is not None:
            self.enable_pin = ppins.setup_pin("digital_out", enable_pin)
            self.enable_pin.setup_max_duration(0.0)

        # Setup tachometer
        self.tachometer = FanTachometer(config)

        # Register callbacks
        self.printer.register_event_handler(
            "gcode:request_restart", self._handle_request_restart
        )
        self.printer.register_event_handler("klippy:ready", self._handle_ready)

    def get_mcu(self):
        return self.mcu_fan.get_mcu()

    def _apply_speed(self, print_time, value, control_enable=True):
        # Kalico: Skalierung zwischen min_power und max_power
        if value > 0:
            value = min(value, 1.0)
            pwm_value = (
                value * (self.max_power - self.min_power) + self.min_power
            )
        else:
            value = 0.0
            pwm_value = 0.0

        # Snapmaker: enable_pin nur schalten, wenn control_enable gesetzt ist
        enable_value = None
        if value > 0 and self.last_fan_value == 0:
            enable_value = 1
        elif value == 0 and self.last_fan_value > 0:
            enable_value = 0

        if value == self.last_fan_value and (
            not self.enable_pin
            or not control_enable
            or enable_value == self.last_enable_value
        ):
            return

        print_time = max(self.last_fan_time + FAN_MIN_TIME, print_time)
        if self.enable_pin and control_enable and enable_value is not None:
            self.enable_pin.set_digital(print_time, enable_value)
            self.last_enable_value = enable_value

        if (
            value
            and value < 1.0
            and self.kick_start_time
            and (not self.last_fan_value or value - self.last_fan_value > 0.5)
        ):
            # Run fan at full speed for specified kick_start_time
            self.mcu_fan.set_pwm(print_time, self.max_power, FAN_MIN_TIME)
            print_time += self.kick_start_time
        self.mcu_fan.set_pwm(print_time, pwm_value, FAN_MIN_TIME)
        self.last_fan_time = print_time
        self.last_fan_value = self.last_req_value = value
        self.last_pwm_value = pwm_value

    def set_speed(self, value, print_time=None, control_enable=True):
        if print_time is None:
            system_time = self.reactor.monotonic() + FAN_MIN_TIME
            print_time = self.get_mcu().estimated_print_time(system_time)
        self._apply_speed(print_time, value, control_enable)

    def set_speed_from_command(self, value, control_enable=True):
        self.set_speed(value, None, control_enable)

    def _handle_request_restart(self, print_time):
        self.set_speed(0.0, print_time)

    def _handle_ready(self):
        if self.initial_speed:
            self.set_speed_from_command(self.initial_speed)

    def get_status(self, eventtime):
        tachometer_status = self.tachometer.get_status(eventtime)
        return {
            "power": self.last_pwm_value,
            "value": self.last_req_value,
            "speed": self.last_req_value * self.max_power,
            "rpm": tachometer_status["rpm"],
        }


class FanTachometer:
    def __init__(self, config):
        printer = config.get_printer()
        self._freq_counter = None

        pin = config.get("tachometer_pin", None)
        if pin is not None:
            self.ppr = config.getint("tachometer_ppr", 2, minval=1)
            poll_time = config.getfloat(
                "tachometer_poll_interval", 0.0015, above=0.0
            )
            sample_time = 1.0
            self._freq_counter = pulse_counter.FrequencyCounter(
                printer, pin, sample_time, poll_time
            )

    def get_status(self, eventtime):
        if self._freq_counter is not None:
            rpm = self._freq_counter.get_frequency() * 30.0 / self.ppr
        else:
            rpm = None
        return {"rpm": rpm}


class PrinterFan:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.fan = Fan(config)
        self.extendable_fan = {}

        # Auxiliary cooling fan
        aux_cool_fan = config.get("aux_cool_fan", None)
        aux_cool_fan_id = config.getint("aux_cool_fan_id", None)
        if aux_cool_fan is not None and aux_cool_fan_id is not None:
            self.extendable_fan[aux_cool_fan_id] = aux_cool_fan

        # exhaust fan / purifier fan
        self.exhaust_fan_id = None
        tmp_fan = config.get("exhaust_fan", None)
        tmp_fan_id = config.getint("exhaust_fan_id", None)
        if tmp_fan is not None and tmp_fan_id is not None:
            if tmp_fan_id in self.extendable_fan:
                raise config.error("fan_id is repetitive!")
            self.extendable_fan[tmp_fan_id] = tmp_fan
            self.exhaust_fan_id = tmp_fan_id

        # Register commands
        gcode = config.get_printer().lookup_object("gcode")
        gcode.register_command("M106", self.cmd_M106)
        gcode.register_command("M107", self.cmd_M107)
        wh = config.get_printer().lookup_object('webhooks')
        wh.register_endpoint("control/main_fan", self._handle_control_main_fan)
    def _handle_control_main_fan(self, web_request):
        try:
            speed = web_request.get_float('S', 0)
            if speed > 100:
                speed = 100
            if speed < 0:
                speed = 0
            self.fan.set_speed_from_command(speed / 100.0)
            web_request.send({'state': 'success'})
        except Exception as e:
            logging.error(f'failed to set fan speed of main fan{str(e)}')
            web_request.send({'state': 'error', 'message': str(e)})

    def get_all_fan_speed(self):
        fan_speed_dict = {}
        fan_speed_dict['main_fan'] = self.fan.last_fan_value
        fan_speed_dict['extendable_fan'] = {}
        for fan_id in self.extendable_fan:
            fan_obj = self.printer.lookup_object("fan_generic {}".format(self.extendable_fan[fan_id]), None)
            if fan_obj is not None:
                fan_speed_dict['extendable_fan'][fan_id] = fan_obj.fan.last_fan_value
            else:
                logging.error("No fan found with ID {}".format(fan_id))
        return copy.deepcopy(fan_speed_dict)

    def resume_all_fan_speed(self, fan_speed_dict):
        if 'main_fan' in fan_speed_dict:
            self.fan.set_speed_from_command(fan_speed_dict['main_fan'])
        if 'extendable_fan' in fan_speed_dict:
            for fan_id, fan_speed in fan_speed_dict['extendable_fan'].items():
                fan_obj = self.printer.lookup_object("fan_generic {}".format(self.extendable_fan[fan_id]), None)
                if fan_obj is not None:
                    fan_obj.fan.set_speed_from_command(fan_speed)
                else:
                    logging.error("No fan found with ID {}".format(fan_id))

    def get_status(self, eventtime):
        return self.fan.get_status(eventtime)

    def cmd_M106(self, gcmd):
        # Set fan speed
        value = gcmd.get_float('S', 255., minval=0.) / 255.
        fan_id = gcmd.get_int('P', None)
        if fan_id is not None:
            if fan_id in self.extendable_fan:
                fan_obj = self.printer.lookup_object("fan_generic {}".format(self.extendable_fan[fan_id]), None)
                if fan_obj is not None:
                    fan_obj.fan.set_speed_from_command(value)
                else:
                    gcmd.respond_info("M106: No fan found with ID {}".format(fan_id))
            else:
                gcmd.respond_info("M106: Unsupported fan ID: {}".format(fan_id))
        else:
            self.fan.set_speed_from_command(value)
    def cmd_M107(self, gcmd):
        # Turn fan off
        fan_id = gcmd.get_int('P', None)
        if fan_id is not None:
            if fan_id in self.extendable_fan:
                fan_obj = self.printer.lookup_object("fan_generic {}".format(self.extendable_fan[fan_id]), None)
                if fan_obj is not None:
                    fan_obj.fan.set_speed_from_command(0.)
                else:
                    gcmd.respond_info("M107: No fan found with ID {}".format(fan_id))
            else:
                gcmd.respond_info("M107: Unsupported fan ID: {}".format(fan_id))
        else:
            self.fan.set_speed_from_command(0.)

def load_config(config):
    return PrinterFan(config)
