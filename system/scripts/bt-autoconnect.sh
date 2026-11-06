#!/bin/bash
# bt-autoconnect.sh v12 (2026-11-06) - łączy iPhone'a z Pi i sam naprawia dźwięk z Bluetooth.
# v12: pauza na telefonie jest szanowana. Radio nie ma przycisku pauzy, więc pauzuje się na iPhonie,
#      a radio dalej "chce grać" - v9-v11 brały to za awarię i po 30-120 s wznawiały muzykę.
#      Teraz: połączenie działa + iPhone zgłasza pauzę = decyzja użytkownika, nic nie robimy.
#      Play wysyłamy tylko (a) po powrocie zerwanego połączenia, jeśli tuż przed zerwaniem grało
#      (iOS sam pauzuje, gdy znika mu głośnik Bluetooth), albo (b) gdy iPhone gra, a dźwięk nie płynie.
# v11: co ~20 s pytamy układ Bluetooth o wersję (hciconfig hci0 version). Po nagłym zerwaniu łącza
#      (wyjście z zasięgu, zakłócenia w aucie) układ potrafi się zawiesić: nie odpowiada na polecenia,
#      a jądro dalej pokazuje iPhone'a jako połączonego. Dwa brak odpowiedzi z rzędu = od razu krok 3
#      (przeładowanie hci_uart resetuje układ), bez względu na stan radia.
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
    1) log "samonaprawa 1: łączę profil audio (Play: $RESUME)"
       [ "$RESUME" = 1 ] && play_when_ready
       btctl connect $MAC $A2DP_SRC >/dev/null ;;
    2) log "samonaprawa 2: rozłączam iPhone'a, łączę od nowa (Play: $RESUME)"
       btctl disconnect $MAC >/dev/null; sleep 3
       btctl connect $MAC >/dev/null; sleep 2
       btctl connect $MAC $A2DP_SRC >/dev/null
       [ "$RESUME" = 1 ] && play_when_ready ;;
    3) log "samonaprawa 3: restart całego Bluetooth (bluetoothd, sterownik hci_uart, bluealsa), połączenie (Play: $RESUME)"
       systemctl stop bluetooth
       modprobe -r hci_uart 2>/dev/null; sleep 2; modprobe hci_uart; sleep 5
       systemctl restart bluetooth; sleep 3
       systemctl restart bluealsa; sleep 2
       systemctl restart bt-to-ipod
       for i in $(seq 1 30); do btctl show | grep -q "Audio Sink" && break; sleep 1; done
       btctl connect $MAC >/dev/null; sleep 2
       btctl connect $MAC $A2DP_SRC >/dev/null
       [ "$RESUME" = 1 ] && play_when_ready ;;
  esac
}

# układ Bluetooth odpowiada na polecenie HCI (Read Local Version)?
controller_alive() { timeout 8 hciconfig hci0 version 2>&1 | grep -q "HCI Version"; }

until btctl show | grep -q "Audio Sink"; do sleep 1; done
noaudio=0; last_ok=$(date +%s); stage=0; cooldown_until=0
probe_n=0; probe_fail=0
# start Pi (odpalenie auta) traktujemy jak powrót po zerwaniu, kiedy grało: iOS pauzuje muzykę przy
# zgaszeniu auta, a po starcie ma grać sama (mostek też wysyła wtedy Play - podwójne nie szkodzi)
trouble=0; resume=0; last_playing_at=$(date +%s); RESUME=0
# grało w ciągu ostatnich 10 s? (iOS pauzuje sekundę-dwie przed zamknięciem połączenia audio)
was_playing() { [ $(( $(date +%s) - last_playing_at )) -le 10 ]; }
while true; do
  now=$(date +%s)
  # adapter z niewłaściwym adresem = iPhone go "nie zna" (sparowany z $ADAPTER)
  addr=$(btctl show | awk '/^Controller/{print $2; exit}')
  if [ -n "$ADAPTER" ] && [ -n "$addr" ] && [ "$addr" != "$ADAPTER" ]; then
    log "adapter ma adres $addr zamiast $ADAPTER"
  fi

  # czy układ Bluetooth w ogóle żyje (co ~20 s)
  probe_n=$((probe_n+1))
  if [ $probe_n -ge 7 ]; then
    probe_n=0
    if controller_alive; then
      probe_fail=0
    else
      probe_fail=$((probe_fail+1))
      log "układ Bluetooth nie odpowiada na polecenia ($probe_fail/2)"
      if [ $probe_fail -ge 2 ]; then
        diag
        RESUME=0; was_playing && radio_wants_audio && RESUME=1
        heal 3
        probe_fail=0
        continue
      fi
    fi
  fi

  # stan połączenia audio i odtwarzacza iPhone'a
  t=$(obj 'sep[0-9]+/fd[0-9]+'); p=$(obj 'player[0-9]+')
  pstatus=$( [ -n "$p" ] && prop "$p" org.bluez.MediaPlayer1 Status)
  if [ -n "$t" ]; then
    if [ $trouble -eq 1 ]; then
      trouble=0
      if [ $resume -eq 1 ] && radio_wants_audio; then
        log "połączenie audio z iPhone'em wróciło - przed zerwaniem grało, wysyłam Play"
        play_when_ready
      else
        log "połączenie audio z iPhone'em wróciło"
      fi
      resume=0
    fi
    [ "$pstatus" = "playing" ] && last_playing_at=$now
  elif [ $trouble -eq 0 ]; then
    trouble=1; resume=0; was_playing && resume=1
    log "połączenie audio z iPhone'em zerwane (grało: $resume)"
  fi

  # utrzymanie połączenia
  if [ -z "$t" ]; then
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

  # samonaprawa: radio chce grać, a dźwięku z iPhone'a nie ma - chyba że to pauza na telefonie
  # (połączenie działa, iPhone zgłasza pauzę/stop) - wtedy to decyzja użytkownika
  user_pause=0
  [ -n "$t" ] && [ $trouble -eq 0 ] && [ -n "$pstatus" ] && [ "$pstatus" != "playing" ] && user_pause=1
  if ! radio_wants_audio || [ $user_pause -eq 1 ] || audio_flowing; then
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
      RESUME=0; { [ "$pstatus" = "playing" ] || [ $resume -eq 1 ]; } && RESUME=1
      heal $next
      stage=$next
    fi
  fi
  sleep 3
done
