#!/bin/bash
# bt-autoconnect.sh v10 (2026-11-06) - łączy iPhone'a z Pi i sam naprawia dźwięk z Bluetooth.
# v10: "dźwięk przychodzi" = dane z iPhone'a faktycznie trafiają na kartę USB radia (rośnie appl_ptr);
#      bluealsa PCM1.Running zostawało true, gdy łącze radiowe stało. Po ponownym połączeniu (krok 2 i 3)
#      wysyłamy Play - iOS pauzuje muzykę, gdy wyjście Bluetooth zniknie, i sam jej nie wznawia.
#
# Zasada: jeśli radio chce grać (źródło iPod, ostatnie polecenie z radia = graj), a z iPhone'a
# przez 30 s nie przychodzi dźwięk - naprawiamy, bez względu na to, co zgłasza iPhone.
#   1. (30 s)  Play do iPhone'a + połączenie profilu audio
#   2. (60 s)  rozłączenie iPhone'a, połączenie od nowa, Play
#   3. (120 s) restart całego Bluetooth w Pi (bluetoothd, sterownik, bluealsa), połączenie, Play
# Po trzech nieudanych krokach przerwa 5 min (np. iPhone poza autem albo z wyłączonym Bluetooth).
#
# Stan radia zapisuje mostek (bt.go): /run/c4-aircross-ipod/radio-state = playing | paused.
# "Radio chce grać" = plik mówi playing i radio ma włączone audio USB (ostatnio "audio start").
# "Dźwięk przychodzi" = bt-to-ipod zapisuje dane na kartę iPodUSB (appl_ptr rośnie między sprawdzeniami).
#
# Oprócz tego, jak w poprzednich wersjach: łączy iPhone'a, gdy nie jest połączony, a gdy jest
# połączony bez profilu audio, łączy sam profil Audio Source (iPhone potrafi odrzucić pierwszy
# endpoint jako zajęty - SEP_IN_USE - a BlueZ przy kolejnej próbie bierze inny).
CONF=/etc/default/c4-aircross-ipod
[ -r "$CONF" ] && . "$CONF"
MAC=${IPHONE_MAC:?ustaw IPHONE_MAC w $CONF}
ADAPTER=${ADAPTER_MAC:-}
STATE=${IPOD_STATE_FILE:-/run/c4-aircross-ipod/radio-state}
DEVPATH=dev_${MAC//:/_}
A2DP_SRC=0000110a-0000-1000-8000-00805f9b34fb
HEAL1=30; HEAL2=60; HEAL3=120   # sekundy bez dźwięku, gdy radio chce grać
COOLDOWN=300

log() { logger -t bt-autoconnect "$*"; }
btctl() { timeout 20 bluetoothctl "$@" 2>&1; }
obj() { timeout 5 busctl tree org.bluez --list 2>/dev/null | grep -E "/$DEVPATH/$1\$" | head -1; }
prop() { timeout 5 busctl get-property org.bluez "$1" "$2" "$3" 2>/dev/null | awk '{print $2}' | tr -d '"'; }
baprop() {
  local p; p=$(timeout 5 busctl tree org.bluealsa --list 2>/dev/null | grep -E "/$DEVPATH/a2dpsnk/source\$" | head -1)
  [ -n "$p" ] && timeout 5 busctl get-property org.bluealsa "$p" org.bluealsa.PCM1 "$1" 2>/dev/null | awk '{print $2}' | tr -d '"'
}

radio_wants_audio() {
  [ "$(cat "$STATE" 2>/dev/null)" = "playing" ] &&
    [ "$(dmesg | grep -oE "ipod-gadget-audio: audio (start|stop)" | tail -1)" = "ipod-gadget-audio: audio start" ]
}
CARD=/proc/asound/iPodUSB/pcm0p/sub0/status
appl_ptr() { grep -oE "^appl_ptr *: *[0-9]+" $CARD 2>/dev/null | grep -oE "[0-9]+\$"; }
last_appl=""
audio_flowing() {
  local a r=1
  a=$(appl_ptr)
  [ -n "$a" ] && [ -n "$last_appl" ] && [ "$a" != "$last_appl" ] && r=0
  last_appl=$a
  return $r
}

# Play do iPhone'a, gdy pojawi się jego odtwarzacz AVRCP (po ponownym połączeniu trwa to kilka sekund)
play_when_ready() {
  local p i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    p=$(obj 'player[0-9]+')
    if [ -n "$p" ]; then
      timeout 5 busctl call org.bluez "$p" org.bluez.MediaPlayer1 Play >/dev/null 2>&1 && return 0
    fi
    sleep 1
  done
  return 1
}

# stan do logu w chwili problemu - żeby było widać przyczynę
diag() {
  local info t p
  info=$(btctl info $MAC | grep -E "Paired|Trusted|Connected" | tr -s ' \t\n' ' ')
  t=$(obj 'sep[0-9]+/fd[0-9]+'); p=$(obj 'player[0-9]+')
  log "diag: adapter: $(btctl show | awk '/^Controller/{print $2; exit}') | iPhone: ${info:-brak} | transport: ${t##*/} $( [ -n "$t" ] && prop "$t" org.bluez.MediaTransport1 State) | AVRCP: $( [ -n "$p" ] && prop "$p" org.bluez.MediaPlayer1 Status) | bluealsa: $(baprop Codec) running=$(baprop Running) | karta USB: $(awk '/^state/{print $2}' $CARD 2>/dev/null || echo zamknięta) appl_ptr=$(appl_ptr) | radio: $(cat "$STATE" 2>/dev/null)"
}

heal() {
  local i
  case $1 in
    1) log "samonaprawa 1: Play do iPhone'a i łączę profil audio"
       play_when_ready
       btctl connect $MAC $A2DP_SRC >/dev/null ;;
    2) log "samonaprawa 2: rozłączam iPhone'a, łączę od nowa i wysyłam Play"
       btctl disconnect $MAC >/dev/null; sleep 3
       btctl connect $MAC >/dev/null; sleep 2
       btctl connect $MAC $A2DP_SRC >/dev/null
       play_when_ready ;;
    3) log "samonaprawa 3: restart całego Bluetooth (bluetoothd, sterownik hci_uart, bluealsa), połączenie i Play"
       systemctl stop bluetooth
       modprobe -r hci_uart 2>/dev/null; sleep 2; modprobe hci_uart; sleep 5
       systemctl restart bluetooth; sleep 3
       systemctl restart bluealsa; sleep 2
       systemctl restart bt-to-ipod
       for i in $(seq 1 30); do btctl show | grep -q "Audio Sink" && break; sleep 1; done
       btctl connect $MAC >/dev/null; sleep 2
       btctl connect $MAC $A2DP_SRC >/dev/null
       play_when_ready ;;
  esac
}

until btctl show | grep -q "Audio Sink"; do sleep 1; done
noaudio=0; last_ok=$(date +%s); stage=0; cooldown_until=0
while true; do
  now=$(date +%s)
  # adapter z niewłaściwym adresem = iPhone go "nie zna" (sparowany z $ADAPTER)
  addr=$(btctl show | awk '/^Controller/{print $2; exit}')
  if [ -n "$ADAPTER" ] && [ -n "$addr" ] && [ "$addr" != "$ADAPTER" ]; then
    log "adapter ma adres $addr zamiast $ADAPTER"
  fi

  # utrzymanie połączenia
  if [ -z "$(obj 'sep[0-9]+/fd[0-9]+')" ]; then
    if ! btctl info $MAC | grep -q "Connected: yes"; then
      btctl connect $MAC >/dev/null
      noaudio=0
    else
      noaudio=$((noaudio+1))
      if [ $noaudio -ge 2 ]; then
        res=$(btctl connect $MAC $A2DP_SRC | grep -oE "Connection successful|Failed to connect: .*" | tail -1)
        log "iPhone bez profilu audio - łączę: ${res:-brak odpowiedzi}"
        noaudio=0
        sleep 5
      fi
    fi
  else
    noaudio=0
  fi

  # samonaprawa: radio chce grać, a dźwięku z iPhone'a nie ma
  if ! radio_wants_audio || audio_flowing; then
    if [ $stage -gt 0 ]; then log "dźwięk z iPhone'a wrócił (po samonaprawie $stage)"; fi
    stage=0; last_ok=$now
  elif [ $now -ge $cooldown_until ]; then
    gap=$(( now - last_ok ))
    next=0
    if   [ $stage -lt 1 ] && [ $gap -ge $HEAL1 ]; then next=1
    elif [ $stage -lt 2 ] && [ $gap -ge $HEAL2 ]; then next=2
    elif [ $stage -lt 3 ] && [ $gap -ge $HEAL3 ]; then next=3
    elif [ $stage -ge 3 ] && [ $gap -ge $((HEAL3 + 30)) ]; then
      log "samonaprawa nie pomogła (iPhone poza autem albo Bluetooth w nim wyłączony?) - przerwa ${COOLDOWN}s"
      cooldown_until=$(( now + COOLDOWN ))
      stage=0; last_ok=$cooldown_until
    fi
    if [ $next -gt 0 ]; then
      diag
      heal $next
      stage=$next
    fi
  fi
  sleep 3
done
