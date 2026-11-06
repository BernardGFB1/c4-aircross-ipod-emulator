#!/bin/bash
# wifi-car-mode.sh v1 (2026-11-06) - wyłącza Wi-Fi, gdy Pi jest podłączone do radia (w aucie),
# i włącza je z powrotem po minucie bez radia (w domu).
#
# Powód: Pi Zero 2W ma Wi-Fi i Bluetooth w jednym układzie, z jedną anteną. W aucie Pi zwykle nie ma
# znanej sieci i co jakiś czas jej szuka, a skanowanie Wi-Fi zabiera antenę Bluetooth - w logach
# widać wtedy zgubione pakiety audio (Missing RTP packets) i zawieszenia łącza (link tx timeout).
#
# "Radio jest" = istnieje plik stanu radia, który mostek (bt.go) tworzy, gdy radio się przedstawi.
# Znika, gdy klient iAP kończy pracę (odłączenie kabla od radia), bo usługa ipod-gadget ma
# RuntimeDirectory=c4-aircross-ipod.
CONF=/etc/default/c4-aircross-ipod
[ -r "$CONF" ] && . "$CONF"
STATE=${IPOD_STATE_FILE:-/run/c4-aircross-ipod/radio-state}
ON_AFTER=60   # sekundy bez radia, po których włączamy Wi-Fi z powrotem

log() { logger -t wifi-car-mode "$*"; }
wifi() { timeout 10 nmcli radio wifi "$@" 2>/dev/null; }

last_radio=$(date +%s)   # po starcie dajemy radiu minutę na przedstawienie się
while true; do
  now=$(date +%s)
  if [ -e "$STATE" ]; then
    last_radio=$now
    if [ "$(wifi)" = "enabled" ]; then
      log "radio podłączone - wyłączam Wi-Fi (żeby nie przeszkadzało Bluetooth)"
      wifi off
    fi
  elif [ $((now - last_radio)) -ge $ON_AFTER ] && [ "$(wifi)" = "disabled" ]; then
    log "brak radia od ${ON_AFTER}s - włączam Wi-Fi"
    wifi on
  fi
  sleep 5
done
