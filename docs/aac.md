<!-- aac.md v2 (2026-11-06) -->
# AAC zamiast SBC

iPhone wysyła dźwięk przez Bluetooth w jednym z dwóch kodeków: **SBC** albo **AAC**. Oba są
stratne. Bezstratnie przez Bluetooth z iPhone'a się nie da. AAC to natywny kodek iPhone'a
(~256 kb/s), ma bardzo dobry koder i brzmi wyraźnie lepiej niż SBC, szczególnie w wysokich
tonach. Odcinek Pi → radio przez USB jest bezstratny niezależnie od kodeka.

```
iPhone --[Bluetooth: SBC albo AAC]--> Pi --[USB: PCM 16 bit / 44,1 kHz, bezstratnie]--> radio
```

Debianowa `bluez-alsa-utils` 4.3.1 ma tylko SBC (sprawdzisz to w `bluealsa --help`, w sekcji
„Available BT audio codecs”). AAC wymaga skompilowania tej samej wersji z biblioteką `fdk-aac`.

## Kompilacja (na Pi)

```bash
sudo apt-get install -y --no-install-recommends build-essential git autoconf automake libtool \
  pkg-config libasound2-dev libbluetooth-dev libdbus-1-dev libglib2.0-dev libsbc-dev libfdk-aac-dev
mkdir -p ~/src && cd ~/src
git clone --depth 1 --branch v4.3.1 https://github.com/arkq/bluez-alsa.git
cd bluez-alsa && autoreconf --install && mkdir -p build && cd build
../configure --prefix=/usr/local --enable-aac
nice make -j1        # na Pi Zero 2W kilkanaście–kilkadziesiąt minut; -j1 oszczędza RAM
sudo make install
```

`libfdk-aac-dev` jest w repozytorium `non-free`, włączonym domyślnie w Raspberry Pi OS.

Sprawdzenie: w sekcji kodeków `/usr/local/bin/bluealsa --help` muszą być `SBC, AAC`.

Wersja z `/usr/local` zapisuje ustawienia (np. głośność) w `/usr/local/var/lib/bluealsa`. Utwórz ten katalog,
inaczej w logu pojawia się „Couldn't save storage”: `sudo mkdir -p /usr/local/var/lib/bluealsa`.

`make install` nadpisuje przy okazji wtyczki ALSA `libasound_module_{ctl,pcm}_bluealsa`
i `/usr/share/dbus-1/system.d/bluealsa.conf` z pakietu Debiana. To ta sama wersja,
a z wtyczek ALSA ten projekt nie korzysta.

## Przełączenie usługi

`system/systemd/bluealsa.service.d/override.conf` uruchamia wersję z `/usr/local` z oboma
kodekami (SBC zostaje jako zapas):

```ini
[Service]
ExecStart=
ExecStart=/usr/local/bin/bluealsa -p a2dp-sink -c SBC -c AAC
```

Potem:

```bash
sudo systemctl daemon-reload && sudo systemctl restart bluealsa bt-to-ipod
bluetoothctl disconnect <MAC iPhone'a>   # iPhone połączy się od nowa i wybierze kodek
bluealsa-aplay -L                        # powinno być: A2DP (AAC): S16_LE 2 channels 44100 Hz
```

## Powrót do SBC z Debiana

W pliku override zamień ścieżkę z powrotem na `/usr/bin/bluealsa -p a2dp-sink`, a potem
`sudo systemctl daemon-reload && sudo systemctl restart bluealsa bt-to-ipod`.

## Obciążenie

Dekodowanie AAC zajmuje ~3% jednego rdzenia Pi Zero 2W, czyli poniżej 1% całego procesora.
Temperatura się nie zmienia.
