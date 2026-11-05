#!/bin/bash
# bt-autoconnect.sh v6 (2026-11-05) - łączy iPhone'a z Pi, pilnuje transportu audio (A2DP)
# i sam naprawia Bluetooth, gdy iPhone długo się nie łączy (zamiast odpinania kabli).
# v6: adresy MAC z /etc/default/c4-aircross-ipod zamiast wpisanych na sztywno.
# Gdy jest połączenie bez dźwięku, nie rozłączamy - łączymy sam profil Audio Source
# (iPhone potrafi odrzucić pierwszy endpoint jako zajęty, BlueZ przy kolejnej próbie bierze inny).
# adresy z pliku ustawień (wzór: system/config/c4-aircross-ipod.example)
CONF=/etc/default/c4-aircross-ipod
[ -r "$CONF" ] && . "$CONF"
MAC=${IPHONE_MAC:?ustaw IPHONE_MAC w $CONF}
ADAPTER=${ADAPTER_MAC:-}
DEVPATH=dev_${MAC//:/_}
A2DP_SRC=0000110a-0000-1000-8000-00805f9b34fb
# progi samonaprawy (sekundy bez dźwięku z iPhone'a)
HEAL1=45    # wyłącz/włącz adapter
HEAL2=90    # restart bluetoothd + bluealsa
HEAL3=150   # przeładowanie sterownika układu Bluetooth
COOLDOWN=300  # po pełnym cyklu czekamy (np. iPhone po prostu daleko / BT wyłączony)

log() { logger -t bt-autoconnect "$*"; }

# stan do logu w chwili problemu - żeby następnym razem było widać przyczynę
diag() {
  local show info
  show=$(bluetoothctl show 2>&1 | grep -E "Controller|Powered|Discoverable|Pairable" | tr -s ' \t\n' ' ')
  info=$(bluetoothctl info $MAC 2>&1 | grep -E "Paired|Bonded|Trusted|Connected" | tr -s ' \t\n' ' ')
  log "diag: adapter: ${show:-brak} | iPhone: ${info:-brak} | hci: $(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' ')"
}

restart_audio_stack() {
  systemctl restart bluetooth
  sleep 3
  systemctl restart bluealsa
  sleep 2
  systemctl restart bt-to-ipod
}

heal() {
  case $1 in
    1) log "samonaprawa 1: wyłączam i włączam adapter"
       bluetoothctl power off >/dev/null 2>&1; sleep 2; bluetoothctl power on >/dev/null 2>&1 ;;
    2) log "samonaprawa 2: restart bluetoothd i bluealsa"
       restart_audio_stack ;;
    3) log "samonaprawa 3: przeładowanie sterownika Bluetooth (hci_uart)"
       systemctl stop bluetooth
       modprobe -r hci_uart 2>/dev/null; sleep 2; modprobe hci_uart; sleep 5
       restart_audio_stack ;;
  esac
}

until bluetoothctl show 2>/dev/null | grep -q "Audio Sink"; do sleep 1; done
noaudio=0
last_ok=$(date +%s)
stage=0
cooldown_until=0
while true; do
  now=$(date +%s)
  # adapter z niewłaściwym adresem = iPhone go "nie zna" (sparowany z $ADAPTER)
  addr=$(bluetoothctl show 2>/dev/null | awk '/^Controller/{print $2; exit}')
  if [ -n "$ADAPTER" ] && [ -n "$addr" ] && [ "$addr" != "$ADAPTER" ]; then
    log "adapter ma adres $addr zamiast $ADAPTER"
  fi
  if busctl tree org.bluez 2>/dev/null | grep -q "$DEVPATH/.*fd"; then
    # jest dźwięk z iPhone'a
    if [ $stage -gt 0 ]; then log "iPhone znowu gra (po samonaprawie $stage)"; fi
    noaudio=0; stage=0; last_ok=$now
  elif ! bluetoothctl info $MAC 2>/dev/null | grep -q "Connected: yes"; then
    bluetoothctl connect $MAC >/dev/null 2>&1
    noaudio=0
  else
    noaudio=$((noaudio+1))
    if [ $noaudio -ge 2 ]; then
      res=$(timeout 20 bluetoothctl connect $MAC $A2DP_SRC 2>&1 | grep -oE "Connection successful|Failed to connect: .*" | tail -1)
      log "iPhone bez dzwieku - lacze profil audio: ${res:-brak odpowiedzi}"
      noaudio=0
      sleep 5
    fi
  fi
  # samonaprawa: długo bez dźwięku z iPhone'a
  if [ $now -ge $cooldown_until ]; then
    gap=$(( $(date +%s) - last_ok ))
    next=0
    if   [ $stage -lt 1 ] && [ $gap -ge $HEAL1 ]; then next=1
    elif [ $stage -lt 2 ] && [ $gap -ge $HEAL2 ]; then next=2
    elif [ $stage -lt 3 ] && [ $gap -ge $HEAL3 ]; then next=3
    elif [ $stage -ge 3 ]; then
      log "samonaprawa nie pomogła (iPhone daleko albo Bluetooth w nim wyłączony?) - przerwa ${COOLDOWN}s"
      cooldown_until=$(( $(date +%s) + COOLDOWN ))
      stage=0; last_ok=$cooldown_until
    fi
    if [ $next -gt 0 ]; then
      diag
      heal $next
      stage=$next
      sleep 5
    fi
  fi
  sleep 3
done
