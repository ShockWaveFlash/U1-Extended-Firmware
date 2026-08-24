#!/bin/sh
# Erklaert den Rahmenthermistor-Pico fuer Klipper als entbehrlich.
# Aufruf: set-pico-noncritical.sh on|off
#
# Hintergrund: Am U1 haengt ein zweiter Mikrocontroller (Raspberry Pi Pico) am
# einzigen freien USB-Port, der die Rahmentemperatur misst. Klipper behandelt jeden
# konfigurierten MCU als lebenswichtig: fehlt er beim Start, startet Klipper gar
# nicht - und da der U1 nur diesen einen USB-Port hat, ist genau das jedes Mal der
# Fall, wenn der Port fuer einen Recovery-Stick gebraucht wird.
# Kalicos [mcu] is_non_critical dreht das um: der Pico darf fehlen, abgezogen und
# wieder angesteckt werden, ohne dass der Drucker stehenbleibt.
#
# ⚠ Der Preis: Faellt der Pico waehrend eines Drucks aus, merkt Klipper das nicht
# mehr als Fehler. Alles, was auf die Rahmentemperatur baut (die Z-Drift-Korrektur),
# rechnet dann mit dem letzten bekannten Wert weiter.
set -e

ZIEL=/oem/printer_data/config/extended/klipper/kalico_pico_optional.cfg

case "$1" in
    on)
        mkdir -p "$(dirname "$ZIEL")"
        {
            echo "# Erzeugt von firmware-config (Kalico -> Rahmen-Pico entbehrlich)."
            echo "# Nicht von Hand aendern."
            echo "#"
            echo "# Klipper startet auch ohne den Pico und nimmt ihn wieder an, sobald"
            echo "# er wieder da ist. Ohne diese Zeile ist ein fehlender Pico ein"
            echo "# Startfehler: \"mcu 'pico': Unable to open serial port\"."
            echo ""
            echo "[mcu pico]"
            echo "is_non_critical: True"
        } > "$ZIEL"
        chown lava:lava "$ZIEL" 2>/dev/null || true
        chmod 644 "$ZIEL"
        echo "Der Rahmen-Pico gilt jetzt als entbehrlich - Klipper startet auch ohne ihn."
        ;;
    off)
        rm -f "$ZIEL"
        echo "Der Rahmen-Pico ist wieder Pflicht - fehlt er, startet Klipper nicht."
        ;;
    *)
        echo "Aufruf: set-pico-noncritical.sh on|off" >&2; exit 1 ;;
esac
