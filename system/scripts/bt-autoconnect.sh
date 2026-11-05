#!/bin/bash
# bt-autoconnect.sh v8 (2026-11-05) - łączy iPhone'a z Pi, pilnuje transportu audio (A2DP)
# i sam naprawia Bluetooth, gdy iPhone długo nie gra do Pi (zamiast odpinania kabli).
# v6: adresy MAC z /etc/default/c4-aircross-ipod zamiast wpisanych na sztywno.
# v7: awaria to także "iPhone mówi, że gra (AVRCP playing), a transport audio nie jest aktywny"
#     - wcześniej samo istnienie transportu uchodziło za zdrowie, więc samonaprawa się nie włączała;
#     nowa kolejność naprawy (najpierw bluealsa, potem połączenie, na końcu sterownik), timeouty
#     na wszystkich wywołaniach bluetoothctl/busctl, pełniejsza diagnostyka w logu.
# v8: zdrowie wymaga też, żeby strumień bluealsa pracował (PCM1.Running) - łapie zawieszoną bluealsa,
#     gdy po stronie Bluetooth transport jest nadal aktywny.
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
HEAL1=45    # restart bluealsa + bt-to-ipod, połączenie profilu audio
HEAL2=90    # rozłączenie i ponowne połączenie iPhone'a, restart adaptera
HEAL3=150   # restart bluetoothd + przeładowanie sterownika układu Bluetooth
COOLDOWN=300  # po pełnym cyklu czekamy (np. iPhone po prostu daleko / BT wyłączony)

log() { logger -t bt-autoconnect "$*"; }
btctl() { timeout 20 bluetoothctl "$@" 2>&1; }
obj() { timeout 5 busctl tree org.bluez --list 2>/dev/null | grep -E "/$DEVPATH/$1\$" | head -1; }
prop() { timeout 5 busctl get-property org.bluez "$1" "$2" "$3" 2>/dev/null | awk '{print $2}' | tr -d '"'; }
# strumień bluealsa dla iPhone'a: Running (true/false) i Codec
bapcm() { timeout 5 busctl tree org.bluealsa --list 2>/dev/null | grep -E "/$DEVPATH/a2dpsnk/source\$" | head -1; }
baprop() { local p; p=$(bapcm); [ -n "$p" ] && timeout 5 busctl get-property org.bluealsa "$p" org.bluealsa.PCM1 "$1" 2>/dev/null | awk '{print $2}' | tr -d '"'; }

# stan do logu w chwili problemu - żeby następnym razem było widać przyczynę
diag() {
  local show info t p codec
  show=$(btctl show | grep -E "Controller|Powered|Pairable" | tr -s ' \t\n' ' ')
  info=$(btctl info $MAC | grep -E "Paired|Trusted|Connected" | tr -s ' \t\n' ' ')
  t=$(obj 'sep[0-9]+/fd[0-9]+'); p=$(obj 'player[0-9]+')
  log "diag: adapter: ${show:-brak} | iPhone: ${info:-brak} | transport: ${t##*/} $( [ -n "$t" ] && prop "$t" org.bluez.MediaTransport1 State) | AVRCP: $( [ -n "$p" ] && prop "$p" org.bluez.MediaPlayer1 Status) | bluealsa: $(baprop Codec) running=$(baprop Running) | hci: $(ls /sys/class/bluetooth 2>/dev/null | tr '\n' ' ')"
}

restart_audio() {
  systemctl restart bluealsa
  sleep 2
  systemctl restart bt-to-ipod
  sleep 2
}

heal() {
  case $1 in
    1) log "samonaprawa 1: restart bluealsa i bt-to-ipod, łączę profil audio"
       restart_audio
       btctl connect $MAC $A2DP_SRC >/dev/null ;;
    2) log "samonaprawa 2: rozłączam iPhone'a, restart adaptera, łączę od nowa"
       btctl disconnect $MAC >/dev/null; sleep 2
       btctl power off >/dev/null; sleep 2; btctl power on >/dev/null; sleep 2
       btctl connect $MAC >/dev/null ;;
    3) log "samonaprawa 3: restart bluetoothd i przeładowanie sterownika Bluetooth (hci_uart)"
       systemctl stop bluetooth
       modprobe -r hci_uart 2>/dev/null; sleep 2; modprobe hci_uart; sleep 5
       systemctl restart bluetooth; sleep 3
       restart_audio ;;
  esac
}

until btctl show | grep -q "Audio Sink"; do sleep 1; done
noaudio=0
silent=0
last_ok=$(date +%s)
stage=0
cooldown_until=0
while true; do
  now=$(date +%s)
  # adapter z niewłaściwym adresem = iPhone go "nie zna" (sparowany z $ADAPTER)
  addr=$(btctl show | awk '/^Controller/{print $2; exit}')
  if [ -n "$ADAPTER" ] && [ -n "$addr" ] && [ "$addr" != "$ADAPTER" ]; then
    log "adapter ma adres $addr zamiast $ADAPTER"
  fi
  t=$(obj 'sep[0-9]+/fd[0-9]+')
  if [ -n "$t" ]; then
    # jest transport audio - ale czy płynie nim dźwięk, gdy iPhone twierdzi, że gra?
    tstate=$(prop "$t" org.bluez.MediaTransport1 State)
    p=$(obj 'player[0-9]+')
    pstatus=$( [ -n "$p" ] && prop "$p" org.bluez.MediaPlayer1 Status)
    running=$(baprop Running)
    if [ "$pstatus" = "playing" ] && { [ "$tstate" != "active" ] || [ "$running" != "true" ]; }; then
      if [ $silent -eq 0 ]; then log "iPhone gra (AVRCP), ale dźwięk nie płynie (transport $tstate, bluealsa running=${running:-brak}) - czekam"; fi
      silent=1
    else
      if [ $stage -gt 0 ] || [ $silent -eq 1 ]; then log "iPhone znowu gra do Pi (samonaprawa $stage)"; fi
      noaudio=0; silent=0; stage=0; last_ok=$now
    fi
  elif ! btctl info $MAC | grep -q "Connected: yes"; then
    btctl connect $MAC >/dev/null
    noaudio=0
  else
    noaudio=$((noaudio+1))
    if [ $noaudio -ge 2 ]; then
      res=$(btctl connect $MAC $A2DP_SRC | grep -oE "Connection successful|Failed to connect: .*" | tail -1)
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
