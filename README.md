<!-- README.md v3 (2026-11-06) -->
# Emulator iPoda dla radia Citroëna C4 Aircross


Raspberry Pi Zero 2W podłączone kablem USB do fabrycznego radia udaje iPoda,
a iPhone wysyła do niego muzykę przez Bluetooth. Radio myśli, że gra z iPoda,
więc przyciski na kierownicy i ekran działają jak z prawdziwym iPodem.

**Po co:** wbudowany Bluetooth w radiu ma ~3 s opóźnienia przy każdej zmianie utworu i słabą jakość dzwięku.
Przez emulator przycisk „następny utwór” działa od razu, a dźwięk jest przesyłany w formacie AAC.

Testowane w Citroënie C4 Aircross 2013. Radio jest bliźniakiem z radiem w Mitsubishi ASX (wersja radia C11)
```
iPhone ──Bluetooth (AAC/A2DP + AVRCP)──▶ Pi Zero 2W ──USB (iAP + USB Audio, bezstratnie)──▶ radio
       ◀──────── przyciski z kierownicy (radio → iAP → Pi → AVRCP → iPhone) ─────────────
```

## Co działa

- muzyka z iPhone'a przez radio, źródło „iPod”, w **AAC** (patrz [docs/aac.md](docs/aac.md)),
- **następny / poprzedni** z kierownicy, następny bez opóźnienia,
- **pauza i gaszenie auta**: utwór zostaje w tym samym miejscu,
- **zimny start**: muzyka gra sama ~30 s po włączeniu zapłonu, bez dotykania telefonu,
- ekran radia pokazuje **czas utworu** i stałe napisy (ustawiane w pliku konfiguracyjnym),
- **samonaprawa Bluetooth**: gdy iPhone długo się nie łączy albo gra, ale dźwięk nie dociera do Pi, Pi samo naprawia połączenie w trzech krokach,
- **strażnik USB**: gdy radio przestaje pobierać dźwięk, Pi samo restartuje gadżet iPoda.

Jak to wszystko działa po stronie radia (i dlaczego właśnie tak), opisuje
[docs/protokol-radia.md](docs/protokol-radia.md).

## Sprzęt

- **Raspberry Pi Zero 2W** z kartą microSD,
- kabel micro-USB → USB-A do radia, podłączony do gniazda **USB** Pi (nie PWR),
- **zasilanie z gniazda zapalniczki** (ładowarka ≥ 2,4 A na porcie, krótki kabel) do gniazda PWR.
  Samo zasilanie z radia przez kabel danych działa, ale przy zakłóceniach (szyby, obroty) radio
  częściej zrywa USB. Kabel z zapalniczki wpinaj przed uruchomieniem, nie w trakcie pracy.
- opcjonalnie: przejściówka „USB power blocker” na kablu do radia (dane tak, 5 V nie) i ferryt na kablach.

## Oprogramowanie

Testowane na Raspberry Pi OS na bazie Debiana 13 (trixie):

| składnik | wersja |
|---|---|
| jądro | `6.12.47+rpt-rpi-v8` (zablokowane, bo moduły gadżetu są skompilowane pod nie) |
| Go | 1.24 |
| BlueZ | 5.82 |
| bluez-alsa | 4.3.1 (z Debiana albo skompilowana z AAC) |

## Struktura repozytorium

```
ipod/            klient iAP z mostkiem Bluetooth (na bazie oandrew/ipod)
  cmd/ipod/bt.go   mostek radio ↔ iPhone - cała logika z docs/protokol-radia.md
ipod-gadget/     moduły jądra udające iPoda po USB (na bazie oandrew/ipod-gadget, z poprawką audio)
patches/         nasze zmiany jako patche względem oryginałów
system/
  config/        wzór ustawień, journald
  scripts/       bt-autoconnect.sh (łączenie + samonaprawa), usb-audio-watchdog.sh
  systemd/       usługi i ustawienia bluealsa
docs/            protokół radia, AAC
```

## Instalacja

Wszystko na Pi, jako zwykły użytkownik z `sudo`.

### 1. Pakiety i zablokowanie jądra

```bash
sudo apt-get update
sudo apt-get install -y git golang-go build-essential linux-headers-rpi-v8 bluez bluez-alsa-utils
sudo apt-mark hold linux-image-rpi-v8 linux-headers-rpi-v8
```

Po aktualizacji jądra moduły gadżetu trzeba skompilować od nowa (krok 4), dlatego jądro jest zablokowane.

### 2. Tryb USB „urządzenie” i Bluetooth

W `/boot/firmware/config.txt`, w sekcji `[all]`:

```ini
dtoverlay=dwc2,dr_mode=peripheral
```

Jeśli jest tam `dtoverlay=disable-bt`, zakomentuj go. Potem:

```bash
echo dwc2 | sudo tee -a /etc/modules
sudo rfkill unblock bluetooth
sudo reboot
```

Na obrazie z pulpitem PipeWire przechwytuje dźwięk z Bluetooth, zanim dostanie go bluealsa.
Wyłącz go dla swojego użytkownika:

```bash
systemctl --user mask pipewire pipewire.socket pipewire-pulse pipewire-pulse.socket wireplumber
```

### 3. Repozytorium

```bash
sudo git clone https://github.com/BernardGFB1/c4-aircross-ipod-emulator.git /opt/c4-aircross-ipod
sudo chown -R "$USER" /opt/c4-aircross-ipod
```

Usługi zakładają ścieżki `/opt/c4-aircross-ipod/ipod` i `/opt/c4-aircross-ipod/ipod-gadget`.
Jeśli trzymasz kod gdzie indziej, zrób tam dowiązania (`sudo ln -s …`).

### 4. Kompilacja

```bash
cd /opt/c4-aircross-ipod/ipod-gadget/gadget && make
cd /opt/c4-aircross-ipod/ipod && GOGC=50 GOMAXPROCS=1 go build -p 1 ./cmd/ipod
```

Pi Zero 2W ma 416 MB RAM. Kompilacja Go z domyślną równoległością potrafi je zawiesić,
dlatego jest tu `-p 1`.

### 5. Ustawienia

```bash
cd /opt/c4-aircross-ipod
sudo cp system/config/c4-aircross-ipod.example /etc/default/c4-aircross-ipod
sudo nano /etc/default/c4-aircross-ipod      # IPHONE_MAC wpiszesz po sparowaniu (krok 8)
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --groups audio c4ipod
```

### 6. bluealsa

```bash
sudo mkdir -p /etc/systemd/system/bluealsa.service.d
sudo cp system/systemd/bluealsa.service.d/*.conf /etc/systemd/system/bluealsa.service.d/
sudo systemctl disable --now bluealsa-aplay    # debianowy odtwarzacz - zastępuje go bt-to-ipod
```

`override.conf` uruchamia bluealsa skompilowaną z AAC (`/usr/local/bin/bluealsa`). Kompilację opisuje
[docs/aac.md](docs/aac.md). Jeśli na razie wystarczy Ci SBC z Debiana, zamień w nim linię na:

```ini
ExecStart=/usr/bin/bluealsa -p a2dp-sink
```

### 7. Skrypty i usługi

```bash
sudo install -m 755 system/scripts/*.sh /usr/local/bin/
sudo install -m 644 system/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now bluealsa ipod-gadget bt-to-ipod bt-autoconnect usb-audio-watchdog wifi-car-mode
```

`wifi-car-mode` wyłącza Wi-Fi, gdy Pi jest podłączone do radia, i włącza je po minucie bez radia.
Wi-Fi i Bluetooth w Pi Zero 2W dzielą jeden układ i antenę, a w aucie Pi szuka sieci i zabiera
antenę Bluetooth. Jeśli chcesz mieć Pi w sieci także w aucie (np. przez hotspot), nie włączaj tej usługi.

Jeśli nazwa systemu wraca po restarcie do tej z obrazu, nadpisuje ją cloud-init. Zmień `hostname:`
w `/boot/firmware/user-data` i skopiuj `system/config/cloud.cfg.d/99-c4-aircross.cfg` do `/etc/cloud/cloud.cfg.d/`.

Opcjonalnie trwały dziennik, który przetrwa utratę zasilania (bardzo pomaga w diagnozie):

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo cp system/config/journald.conf.d/persistent.conf /etc/systemd/journald.conf.d/
sudo systemctl restart systemd-journald
```

### 8. Parowanie iPhone'a

```bash
bluetoothctl
  power on
  agent on
  default-agent
  pairable on
  discoverable on
```

Na iPhonie wybierz Pi w Ustawienia → Bluetooth i potwierdź kod. Potem w `bluetoothctl`:

```
devices                    # odczytaj MAC iPhone'a
trust AA:BB:CC:DD:EE:FF
discoverable off
system-alias "C4 Aircross" # opcjonalnie: nazwa widoczna dla nowych urządzeń
quit
```

Wpisz MAC iPhone'a do `IPHONE_MAC` w `/etc/default/c4-aircross-ipod` i zrestartuj usługi:

```bash
sudo systemctl restart bt-autoconnect usb-audio-watchdog ipod-gadget
```

## Używanie

- W radiu wybierz źródło **iPod** (USB). Na iPhonie jako wyjście audio wybierz Pi.
- **Wbudowany Bluetooth radia** potrafi zająć audio iPhone'a. Wtedy Pi łączy się bez dźwięku,
  bo iPhone odpowiada „SEP_IN_USE”. Najprościej wyłączyć Bluetooth w menu radia, bo parowanie zostaje.
- Gdy iPhone po zerwaniu USB nie łączy się z Pi, **odczekaj ~2,5 minuty**, zanim odepniesz kable.
  Samonaprawa Bluetooth zadziała w trzech krokach (45 s, 90 s, 150 s).
- **Nazwa w iPhonie:** iOS pamięta nazwę z chwili parowania. Nową nazwę ustawisz w telefonie
  (Ustawienia → Bluetooth → (i) → Nazwa).

## Diagnostyka

```bash
journalctl -u ipod-gadget -b | grep "bt: "          # decyzje mostka (zgadywanie Next, pauzy, napisy)
journalctl -t bt-autoconnect -b                      # łączenie z iPhone'em i samonaprawa (z diagnostyką)
journalctl -t usb-audio-watchdog -b                  # restarty gadżetu przez strażnika USB
journalctl -b -1                                     # poprzednie uruchomienie (z trwałym dziennikiem)
dmesg | grep -E "ipod_disconnect|audio (start|stop)" # zerwania USB po stronie radia
bluealsa-aplay -L                                    # kodek: A2DP (AAC) albo A2DP (SBC)
```

W aucie Pi zwykle nie synchronizuje zegara, więc daty w logach z jazdy są fałszywe.
Kolejne uruchomienia rozpoznasz po kolejności i czasie trwania (`journalctl --list-boots`).

## Ograniczenia

- **Tytułów utworów na ekranie nie ma**, są stałe napisy: radio pyta o tytuł raz, zanim iPhone poda nowy.
- **„Poprzedni”** na chwilę pokazuje na telefonie zgadnięty następny utwór. To cena za natychmiastowy „następny”.
- **Pauza, której radio nie potwierdzi pytaniem o stan**, cofa utwór na początek (AVRCP nie ma
  przewijania do sekundy).
- **Przewijanie na iPhonie** może wywołać takie cofnięcie. To jeszcze nie jest potwierdzone
  (docs/protokol-radia.md, pkt 10).
- **Pi traci zasilanie przy gaszeniu auta** i nie ma ochrony karty SD. Tryb tylko do odczytu (overlayfs)
  przy 416 MB RAM bez pliku wymiany doprowadził do przeciążenia, więc nie jest używany.
- **Brak rozmów telefonicznych** przez radio: Pi obsługuje tylko A2DP.

## Licencja

MIT, patrz [LICENSE](LICENSE). Kod w `ipod/` i `ipod-gadget/` pochodzi z projektów
[oandrew/ipod](https://github.com/oandrew/ipod) i
[oandrew/ipod-gadget](https://github.com/oandrew/ipod-gadget) Andrew Onyshchuka (MIT),
z naszymi zmianami (`patches/`).
