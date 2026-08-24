# Laesst Klipper wahlweise aus Snapmakers Baum oder aus dem Kalico-Baum starten.
#
# /etc/init.d/S60klipper sourct dieses Verzeichnis, bevor es die Aktion
# behandelt -- wir teilen uns also die Shell und koennen KLIPPER setzen.
# (Das ist der vorgesehene Erweiterungsweg der Extended Firmware; Vorbild ist
# 10-spoollink.sh. ⚠️ Ein eigenes /etc/init.d/S6x-Skript taeugt NICHT: der
# rcS-Glob wird vor dem pivot_root expandiert, neue Init-Skripte laufen dann
# beim Booten nie.)
#
# Umschalter ist /oem/.klipper-tree -- eine Datei mit dem Pfad zum gewuenschten
# Baum. Sie liegt bewusst direkt auf /oem: das ist eine eigene ext4-Partition
# und ueberlebt den Overlay-Reset beim Booten. Fehlt sie, ist sie leer oder
# zeigt sie ins Leere, bleibt es bei Snapmakers Klipper -- der Rueckweg ist
# also immer offen, auch wenn der Kalico-Baum beschaedigt ist.
# /oem/.no-kalico ist die gemeinsame Notbremse mit S49ykalico: sie haelt nicht
# nur das Ausrollen an, sondern schickt Klipper auch zurueck auf Snapmakers Baum.
# Ohne das hier haette ein beschaedigter Kalico-Baum nicht abgeschaltet werden
# koennen, ohne /oem/.klipper-tree anzufassen.
if [ -f /oem/.klipper-tree ] && [ ! -f /oem/.no-kalico ]; then
    _kt_pfad=$(cat /oem/.klipper-tree 2>/dev/null)
    if [ -n "$_kt_pfad" ] && [ -f "$_kt_pfad/klippy/klippy.py" ]; then
        KLIPPER="$_kt_pfad/klippy/klippy.py"
    fi
    unset _kt_pfad
fi

# Wohin SAVE_CONFIG schreibt. Ohne diese Marke verhaelt sich Kalico wie
# Klipper und haengt den Block hinten an die printer.cfg -- dort findet ihn
# auch Snapmakers Baum wieder (Bettnetz, Hotend-PIDs).
if [ -f /oem/.kalico-separate-autosave ]; then
    export KALICO_SEPARATE_AUTOSAVE=1
fi
