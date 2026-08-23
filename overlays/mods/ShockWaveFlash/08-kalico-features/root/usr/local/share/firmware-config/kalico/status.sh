#!/bin/sh
# Zeigt, welcher Klipper-Baum laeuft und welche Kalico-Schalter aktiv sind.
CFG=/oem/printer_data/config/extended/klipper

echo "Klipper-Baum:"
PID=$(pgrep -f klippy.py | head -1)
if [ -n "$PID" ] && [ -r "/proc/$PID/cmdline" ]; then
    BAUM=$(tr '\0' ' ' < "/proc/$PID/cmdline" | tr ' ' '\n' | grep 'klippy\.py' | head -1)
    case "$BAUM" in
        */kalico/*) echo "  KALICO aktiv  ($BAUM)" ;;
        *)          echo "  Snapmaker Stock  ($BAUM)" ;;
    esac
else
    echo "  Klipper laeuft nicht"
fi
if [ -f /oem/.klipper-tree ]; then
    echo "  Umschalter /oem/.klipper-tree -> $(cat /oem/.klipper-tree)"
else
    echo "  Umschalter /oem/.klipper-tree nicht gesetzt (= Stock)"
fi

echo ""
echo "Kalico-Schalter:"

if [ -f "$CFG/kalico_shaper.cfg" ]; then
    echo "  Input Shaper       : $(grep -m1 '^shaper_type_x' "$CFG/kalico_shaper.cfg" | awk '{print $2}')"
else
    echo "  Input Shaper       : classic (stock)"
fi

if [ -f "$CFG/kalico_pa.cfg" ]; then
    echo "  Pressure Advance   : $(grep -m1 '^pressure_advance_model' "$CFG/kalico_pa.cfg" | awk '{print $2}')"
else
    echo "  Pressure Advance   : linear (stock)"
fi

if [ -f "$CFG/kalico_mpc.cfg" ]; then
    echo "  Hotend-Regelung    : MPC"
else
    echo "  Hotend-Regelung    : PID (stock)"
fi

echo ""
echo "High-Precision Stepping: nur per MCU-Flash schaltbar (CONFIG_HIGH_PREC_STEP),"
echo "  nicht ueber diese Oberflaeche."
