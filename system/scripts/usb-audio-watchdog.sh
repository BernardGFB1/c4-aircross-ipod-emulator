#!/bin/bash
# usb-audio-watchdog.sh v3 (2026-11-05) - pilnuje toru audio Pi -> radio (USB, karta iPodUSB)
# v2: adres iPhone'a z /etc/default/c4-aircross-ipod zamiast wpisanego na sztywno.
# v3: zawieszenie liczy się tylko przy otwartej karcie (hw_ptr jest liczbą). Zamknięta karta
#     (hw_ptr=brak) znaczy, że nie ma dźwięku z iPhone'a - to sprawa Bluetooth (bt-autoconnect),
#     a restart gadżetu tylko rozłączał wtedy radio.
# Objaw po zimnym starcie: radio włącza audio (ipod_audio_set_alt(1,1) / "audio start"),
# ale nie pobiera próbek (hw_ptr stoi), a przełączenie źródła w radiu nie pomaga.
# Jeśli tak jest przez STUCK_SEC, a iPhone gra - restartujemy gadżet iPoda (radio inicjuje go od nowa).
CONF=/etc/default/c4-aircross-ipod
[ -r "$CONF" ] && . "$CONF"
MAC=${IPHONE_MAC:?ustaw IPHONE_MAC w $CONF}
PLAYER=/org/bluez/hci0/dev_${MAC//:/_}/player0
STATUS=/proc/asound/iPodUSB/pcm0p/sub0/status
STUCK_SEC=10
COOLDOWN_SEC=60
last_ptr=""
stuck=0
last_fix=0
while true; do
  sleep 2
  # radio ma włączony tryb audio? (ostatnie zdarzenie gadżetu audio to "audio start")
  ev=$(dmesg | grep -oE "ipod-gadget-audio: audio (start|stop)" | tail -1)
  # iPhone gra?
  st=$(busctl get-property org.bluez $PLAYER org.bluez.MediaPlayer1 Status 2>/dev/null)
  ptr=$(grep -oE "^hw_ptr *: *[0-9]+" $STATUS 2>/dev/null | grep -oE "[0-9]+$")
  if [ "$ev" = "ipod-gadget-audio: audio start" ] && [ "$st" = 's "playing"' ] && [ -n "$ptr" ] && [ "$ptr" = "$last_ptr" ]; then
    stuck=$((stuck+2))
  else
    stuck=0
  fi
  last_ptr=$ptr
  now=$(date +%s)
  if [ $stuck -ge $STUCK_SEC ] && [ $((now-last_fix)) -ge $COOLDOWN_SEC ]; then
    logger -t usb-audio-watchdog "radio nie pobiera dzwieku przez ${stuck}s (hw_ptr=${ptr:-brak}) - restart gadzetu iPoda"
    systemctl restart ipod-gadget
    sleep 2
    systemctl restart bt-to-ipod
    last_fix=$now
    stuck=0
    last_ptr=""
  fi
done
