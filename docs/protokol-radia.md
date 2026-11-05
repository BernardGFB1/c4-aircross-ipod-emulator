<!-- protokol-radia.md v2 (2026-11-05) -->
# Jak radio C4 Aircross rozmawia z „iPodem”

Ustalenia z logów zebranych podczas budowy emulatora (wrzesień–listopad 2026). Radio:
fabryczne radio Citroëna C4 Aircross 2013 z wejściem USB/iPod (bliźniak Mitsubishi ASX).
Pi Zero 2W udaje iPoda przez USB (iAP po HID + karta dźwiękowa USB Audio Class).

Wszystko poniżej to obserwacje z tego jednego radia. Inne radia z iAP mogą się zachowywać inaczej.

## Spis treści

1. [Połączenie i start](#1-połączenie-i-start)
2. [Zmiana utworu z kierownicy](#2-zmiana-utworu-z-kierownicy)
3. [Pauza i gaszenie auta](#3-pauza-i-gaszenie-auta)
4. [Udawana baza utworów](#4-udawana-baza-utworów)
5. [Stan odtwarzania](#5-stan-odtwarzania)
6. [Ekran „teraz gra”](#6-ekran-teraz-gra)
7. [Dźwięk przez USB](#7-dźwięk-przez-usb)
8. [Zakłócenia i resety USB](#8-zakłócenia-i-resety-usb)
9. [Strona iPhone'a (Bluetooth)](#9-strona-iphonea-bluetooth)
10. [Otwarte pytania](#10-otwarte-pytania)

## 1. Połączenie i start

- Radio przedstawia się dwa razy z rzędu (`IdentifyDeviceLingoes` ×2), potem sprawdza
  certyfikat (`RetDevAuthenticationInfo`), wersje lingo, nazwę i numer seryjny iPoda,
  wchodzi w `EnterRemoteUIMode` i korzysta z lingo **Extended Remote (0x04)**.
- Od podania prądu do pierwszego dźwięku mija ~30 s: ~18 s to start Pi do zgłoszenia się
  jako iPod, ~11 s to inicjalizacja po stronie radia (na nią nie mamy wpływu).
- **Sekwencja startowa:** radio wysyła `PlayCurrentSelection(0)` i w ~1 ms `PlayControl 0x01`
  (Toggle). Czasem kolejność jest odwrotna: Toggle, a potem wybór **tego samego** numeru utworu.
  To nie jest kliknięcie użytkownika i nie wolno na nie reagować przełączeniem utworu.
- Radio potrafi wysłać ten sam `PlayCurrentSelection` kilka razy pod rząd (widziane 6× w 17 ms),
  bo powtarza polecenie, gdy potwierdzenie dochodzi za późno. Duplikaty trzeba pomijać.
- Ta sama sekwencja startowa przychodzi także **bez restartu Pi**: po resecie USB po stronie
  radia (patrz pkt 8). Mostek liczy więc okno startowe od każdego `IdentifyDeviceLingoes`,
  a nie od startu programu.

## 2. Zmiana utworu z kierownicy

- „Następny” i „poprzedni” wyglądają tak samo na początku:
  `PlayControl 0x01` (Toggle), a **~1,05 s później** `PlayCurrentSelection(idx)`,
  gdzie `idx = (bieżący ± 1) mod liczba_utworów`. Kierunek widać dopiero z różnicy indeksów.
- Między Toggle a wyborem utworu radio **samo wycisza dźwięk**. Wysłanie radiu „zatrzymane”
  niczego tu nie zmienia, a sekundy opóźnienia z tego powodu nie da się skrócić.
- **Strategia mostka („Next na zgadywanie”):** po Toggle odczekaj 0,3 s (patrz pkt 3).
  Jeśli radio nie zapytało o stan, wyślij iPhone'owi Next od razu, nie czekając na wybór
  utworu. Kiedy radio odciszy dźwięk, nowy utwór już gra. Gdy wybór okaże się „poprzednim”,
  cofnij się dwa razy (Previous, Previous, z odstępem 0,3 s). Gdy wybór w ogóle nie przyjdzie
  (przez 1,5 s), to była pauza: Previous + Pause.
- Pauza na iPhonie przed cofaniem (Pause, Previous, Previous, Play) **nie działa**:
  zapauzowany iPhone wykonuje polecenia AVRCP z opóźnieniem i sam przeskakuje utwory.

## 3. Pauza i gaszenie auta

- Prawdziwa pauza (także przy gaszeniu auta) to ten sam Toggle co przy zmianie utworu,
  ale radio **~0,14 s po nim pyta o stan** (`GetPlayStatus`). Przy zmianie utworu
  w ~22 zarejestrowanych przypadkach nie zapytało ani razu przed wyborem utworu.
- Mostek czeka więc 0,3 s z wysłaniem zgadywanego Next. Jeśli w tym czasie przyjdzie
  `GetPlayStatus`, wysyła zwykłe Pause, a utwór zostaje w tym samym miejscu.
- Uwaga: radio pyta o stan także **tuż przed** Toggle, i to w obu przypadkach. Liczy się
  tylko pytanie **po** Toggle.
- AVRCP nie ma przewijania do konkretnej sekundy, więc każde cofnięcie się po złym zgadnięciu
  (Previous) zaczyna utwór od początku. Dlatego tak ważne jest rozpoznanie pauzy przed Next.

## 4. Udawana baza utworów

- Mostek udaje bazę z **3 utworami** (kategoria 5) i po 1 pozycji w pozostałych kategoriach.
  Trzy wystarczą, żeby z różnicy indeksów odróżnić „następny” od „poprzedniego”.
- Przy 1000 pozycjach radio wieszało się na „potwierdzanie mediów”, bo przy potwierdzaniu
  czyta całą bazę.
- `RetrieveCategorizedDatabaseRecords` musi **zawsze** zwrócić co najmniej jeden rekord,
  także dla przesunięcia poza końcem bazy. Inaczej radio ponawia zapytanie co 5 s
  i wisi na „potwierdzanie mediów”.
- Biblioteka `oandrew/ipod` miała pole nazwy rekordu o stałej długości 16 bajtów, co ucinało
  dłuższe napisy. Protokół przewiduje tu zwykły napis zakończony zerem, więc pole ma teraz
  zmienną długość.

## 5. Stan odtwarzania

- `GetPlayStatus` musi zwracać stan **z punktu widzenia radia** (grało czy było zapauzowane
  według poleceń od radia), a nie chwilowy stan iPhone'a. Jeśli iPhone na moment pauzuje
  przy zmianie utworu i radio to zobaczy, zamyka strumień audio USB.
- **Długość utworu** podawana jest z zapasem 10 minut. Po szybkim Next iPhone może jeszcze
  przez chwilę zgłaszać długość **poprzedniego** utworu, a radio, gdy czas go przekroczy,
  „kończy” utwór i samo przełącza na następny. Do następnego utworu iPhone przejdzie sam.
  Radio na ekranie pokazuje tylko upływający czas, więc zapasu nie widać.

## 6. Ekran „teraz gra”

- Bez powiadomień o pozycji ekran stoi na **„Track00 / BRAK NAZWY / BRAK TYTUŁU”**
  i 00'00", choć radio pyta o tytuł, wykonawcę i album i dostaje poprawne odpowiedzi.
- **Kluczowe:** ekran zaczyna działać dopiero, gdy iPod co ~1 s wysyła
  `PlayStatusChangeNotification` typu `0x04` (pozycja w ms). Wtedy biegnie czas,
  a w polach pojawiają się napisy z `GetIndexedPlayingTrackTitle/ArtistName/AlbumName`.
- Radio pyta o tytuł **tylko raz**, ~60 ms po swoim `PlayCurrentSelection`. Na powiadomienie
  o zmianie utworu (`0x01` + indeks) nie dopytuje, a włączenie tego powiadomienia psuło
  przełączanie utworów. Przy zgadywanym Next iPhone nie zdąży jeszcze podać nowego tytułu,
  dlatego mostek wysyła **stałe napisy** (ustawiane w `/etc/default/c4-aircross-ipod`).
- Radio wycina apostrofy i dokleja przed tytułem numer utworu („02 …”).
- Pułapka przy diagnozie: radio pamięta ostatnie napisy, więc stary tytuł może wisieć
  na ekranie po restartach, aż radio dostanie nowe odpowiedzi.

## 7. Dźwięk przez USB

- Radio pobiera dźwięk jako **PCM 16 bit / 44,1 kHz stereo** przez izochroniczny endpoint
  USB Audio. Ten odcinek jest bezstratny.
- `PCM write error: Input/output error` w `bluealsa-aplay` oznacza, że radio nie ma otwartego
  strumienia: źródło nie jest ustawione na iPod albo radio uważa, że jest pauza.
- **Błąd sterownika (poprawiony):** w `ipod_audio.c` z `oandrew/ipod-gadget` paczka ISO
  zakończona błędem (np. `-61`, ENODATA, widziane przy każdym starcie strumienia) wypadała
  z obiegu na zawsze. Po kilku takich błędach strumień stawał (`hw_ptr` = 0), a radio nie
  dostawało żadnej próbki, dopóki nie przełączyło trybu audio. Poprawka: paczkę z błędem
  odsyłamy dalej z ciszą, a blokadę inicjujemy raz, a nie przy każdym `pcm_open`.
  Szczegóły w `patches/`.
- Na wszelki wypadek działa też strażnik (`usb-audio-watchdog`). Jeśli radio ma włączony
  tryb audio, iPhone gra, karta USB jest otwarta, a `hw_ptr` stoi przez 10 s, restartuje gadżet.
  Zamknięta karta (brak dźwięku z iPhone'a) to sprawa Bluetooth, nie radia. Wcześniejsza wersja
  strażnika restartowała wtedy gadżet i niepotrzebnie rozłączała radio.

## 8. Zakłócenia i resety USB

- Radio zrywa połączenie USB przy zakłóceniach elektrycznych: przy otwieraniu szyb
  i przy wyższych obrotach. W `dmesg` widać `ipod_disconnect()`, a potem kilka prób
  ponownego połączenia. Radio wraca samo po ~7–11 s, a iPhone zostaje połączony z Pi.
- Pi Zero ma oba gniazda micro-USB spięte z tą samą szyną 5 V. Zasilane jednocześnie z radia
  (kabel danych) i z gniazda zapalniczki ma dwa źródła połączone przez siebie. Zasilanie
  z zapalniczki wyraźnie zmniejszyło liczbę zerwań. Do sprawdzenia: przejściówka
  „USB power blocker” na kablu do radia (dane tak, 5 V nie) i ferryt na kablu.
- Wpięcie drugiego zasilania, gdy Pi już działa, potrafi je zrestartować. Kabel z zapalniczki
  najlepiej trzymać wpięty na stałe.

## 9. Strona iPhone'a (Bluetooth)

- iPhone odrzuca konfigurację A2DP kodem **`SEP_IN_USE`**, gdy jego pierwszy endpoint SBC
  jest zajęty, np. przez wbudowany Bluetooth radia. Pomaga ponowne połączenie samego profilu
  `0000110a-…` (Audio Source): BlueZ unieważnia zapamiętany endpoint i wybiera następny.
  Rozłączanie całego połączenia w pętli nie pomaga.
- **AAC:** jeśli Pi go oferuje, iPhone sam go wybiera. Debianowa `bluez-alsa` 4.3.1 ma tylko
  SBC, więc trzeba ją skompilować z `fdk-aac` (`docs/aac.md`). Dekodowanie zajmuje ~3% jednego
  rdzenia Pi Zero 2W.
- Siri idzie przez A2DP w pełnej jakości (Pi nie ma HFP). Rozmowy telefoniczne idą przez
  telefon.
- AVRCP `Previous` w ciągu ~3 s od początku utworu przechodzi do poprzedniego utworu,
  a później wraca na początek bieżącego.
- iPhone pamięta nazwę urządzenia z chwili parowania. Zmiana nazwy Pi (`bluetoothctl system-alias`)
  nie odświeża jej w telefonie, trzeba ją zmienić ręcznie w ustawieniach Bluetooth.
- **iPhone potrafi przestać wysyłać dźwięk, choć połączenie trwa,** a AVRCP dalej zgłasza `playing`
  (widziane raz po ~30 min jazdy, przyczyna nieznana: iPhone albo zawieszona bluealsa). Samo istnienie
  transportu nie świadczy więc o zdrowiu. `bt-autoconnect` (v8) uznaje za awarię sytuację, w której
  iPhone zgłasza `playing`, a transport BlueZ nie jest `active` albo strumień bluealsa nie ma
  `Running=true`.
- Przy każdym starcie układ Bluetooth Pi przez chwilę ma domyślny adres (`43:43:a1:…`),
  który BlueZ potem poprawia. `bt-autoconnect` zapisuje w logu, gdy adres się nie zgadza.

## 10. Otwarte pytania

- **Przewijanie na iPhonie.** Po cofnięciu utworu na telefonie radio ~0,3 s po powiadomieniu
  o pozycji zapytało o stan i wysłało Toggle, co mostek wziął za kliknięcie. Hipoteza: radio
  reaguje na nagłe cofnięcie pozycji. Mostek v23 zapisuje skoki pozycji w logu, żeby to potwierdzić.
- **Przyczyna zerwań USB:** wspólna masa / dwa zasilania czy zakłócenia na kablu danych.
