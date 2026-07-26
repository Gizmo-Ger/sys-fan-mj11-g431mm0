# ESP32 MJ11-BMC UART-Gateway

Kabellose, bidirektionale UART-Bridge für ein ESP32 DevKit V1 (30 Pin) und
die BMC-Konsole des Gigabyte MJ11-EC0. Das Projekt verwendet ausschließlich
Bestandteile von ESP-IDF: TCP, HTTP/WebSocket, OTA und Task-Watchdog.
Die mitgelieferte Zwei-Slot-OTA-Partitionierung setzt die bei diesen DevKits
üblichen **4 MB Flash** voraus.

Das Projekt wird mit ESP-IDF 5.5.4 und 6.0.2 für das Ziel `esp32` geprüft.
Für neue lokale Installationen wird ESP-IDF 6.0.2 empfohlen.

Die vollständige Anleitung von der Installation bis zur fertigen Firmware
steht in [docs/FIRMWARE-ANLEITUNG.md](docs/FIRMWARE-ANLEITUNG.md).

## Sicherheit und Verdrahtung

Vor dem Anschluss den Service-Header mit Multimeter oder Logic Analyzer prüfen.
Der ESP32 verträgt nur **3,3-V-TTL**, keine 5 V und keine echten RS-232-Pegel.

| MJ11-EC0 BMC-Header | ESP32 DevKit V1 |
| --- | --- |
| GND | GND |
| TX | RX2 / GPIO16 |
| RX | TX2 / GPIO17 |
| VCC | **nicht verbinden** |

Kurz: **MJ11 TX → ESP32 RX2**, **MJ11 RX → ESP32 TX2** und
**MJ11 GND → ESP32 GND**. **VCC bleibt unverbunden.** Die vier Signale sind:

```text
GND | TX | RX | VCC
```

Die Lage nicht allein aus dem
[verlinkten Pinout-Foto](https://oliver.obenland.it/gigabyte-mj11-ec1-alle-luefter-per-pwm-steuern/)
ableiten: Dort ist der VCC-Pin fälschlich als zweiter GND-Pin beschriftet.
Außerdem zeigt die Quelle ein MJ11-EC1. Beim MJ11-EC0 daher zuerst stromlos
den einzelnen GND-Pin per Durchgangsmessung gegen Boardmasse bestimmen und
anschließend bei Standbyversorgung die Spannungen gegen diesen GND messen.

Den ESP32 separat über seinen USB-Anschluss versorgen.
Der onboard CP210x wird nur zum Flashen und für die ESP32-Debugausgabe benutzt;
ein weiterer USB-TTL-Adapter ist nicht nötig.

## Funktionen im Überblick

- UART2 auf GPIO16/GPIO17, standardmäßig 115200 8N1
- interner Pull-up auf RX2 gegen Störzeichen bei offenem Header
- WLAN-Client mit automatischem Reconnect (1 bis 30 Sekunden Backoff)
- TCP-Bridge auf Port 2323, mit Passwortanmeldung
- Webterminal per WebSocket
- Redfish-Dashboard für System, BIOS, BMC, Netzwerk, Host-NIC-Inventar, Temperaturen, Lüfter und Spannungen
- Mainboardmodell aus Redfish automatisch im Seitenkopf und Browser-Tab
- deutsche und englische Weboberfläche mit gespeicherter Sprachauswahl
- BMC-Zugangsdaten ausschließlich im RAM, mit Redfish-Abmeldebutton
- Firmwareversion und Build-Zeit im Webterminal-Header
- 32-KB-RAM-Ringpuffer mit Zusammenfassung identischer Folgezeilen
- geschützter UART-Logdownload beim UART-Terminal
- geschützter 8-KB-ESP32-Systemlog für WLAN-, TLS- und HTTP-Diagnose
- kompakte ESP32-Statuswerte im Header: WLAN-Balken, Laufzeit, Heap, Clients und UART-Zähler
- Firmware-Upload im Browser (OTA, zwei App-Partitionen)
- einmalige Konto-Ersteinrichtung im Browser; Passwort-Hash in NVS
- HTTP-Basic-Authentifizierung für Webterminal, WebSocket und OTA
- ESP-IDF Task-Watchdog für den UART-Datenpfad
- je ein TCP- und WebSocket-Client gleichzeitig

## Was kann ich mit dem Gateway machen?

Der ESP32 ersetzt einen dauerhaft angeschlossenen USB-TTL-Adapter und macht
die serielle BMC-Konsole im WLAN erreichbar. Sobald das MJ11 Standby-Strom
hat und der BMC läuft, kann das Gateway dessen UART-Ausgabe empfangen und
Eingaben zurücksenden.

| Aufgabe | Zugriff | Verwendung |
| --- | --- | --- |
| BMC-Boot beobachten | Webbrowser oder TCP | Bootloader-, Kernel- und Startmeldungen live verfolgen |
| BMC-Konsole bedienen | Webbrowser oder TCP | Am seriellen Login anmelden und Shellbefehle eingeben |
| Hardware überwachen | Webbrowser | BIOS/BMC-Version, BMC-IP, Temperaturen, Lüfter und Spannungen über Redfish anzeigen |
| ESP32 überwachen | Webbrowser | WLAN-Signal, Laufzeit, Speicher, Clients und UART-Zähler anzeigen |
| UART-Verlauf sichern | Webbrowser | Den komprimierten 32-KB-UART-Verlauf als Textdatei herunterladen |
| Fehler untersuchen | Webbrowser oder TCP | Start- und Fehlermeldungen sehen, auch wenn der Host nicht vollständig bootet |
| Firmware aktualisieren | Webbrowser | Neues ESP32-Anwendungsimage ohne USB-Kabel per OTA hochladen |
| ESP32 diagnostizieren | USB/CP210x | WLAN-IP, Reconnects und interne ESP32-Meldungen im IDF-Monitor sehen |

### Webterminal

Beim ersten Start `http://ESP32-IP/` öffnen und dort Benutzername sowie ein
Passwort mit mindestens 12 Zeichen festlegen. Das Konto gilt für Webterminal,
OTA und TCP-Bridge. Danach fordert der Browser diese Zugangsdaten an.

In die schwarze Terminalfläche klicken; Tastatureingaben und
eingefügter Text werden unmittelbar an den BMC-UART gesendet. Unterstützt
werden unter anderem Enter, Rücktaste, Tabulator, Pfeiltasten und
Strg-Buchstabenkombinationen.

Das Webterminal ist absichtlich einfach und kein vollständiger
VT100/ANSI-Emulator. Für Programme mit komplexer Bildschirmsteuerung ist
PuTTY über die TCP-Bridge geeigneter.

### TCP-Bridge

Mit PuTTY eine Verbindung vom Typ **Raw** zur ESP32-IP auf Port **2323**
öffnen. Als erste Zeile senden:

```text
AUTH dein-passwort
```

Nach `OK` arbeitet die Verbindung transparent: Daten vom Netzwerk gehen an
UART2, UART-Daten zurück an den TCP-Client. Alternativ funktionieren
`nc`/Netcat oder andere einfache TCP-Terminals.

Ein WebSocket-Client und ein TCP-Client können gleichzeitig verbunden sein
und empfangen dieselbe UART-Ausgabe. Beide dürfen auch senden; deshalb nicht
gleichzeitig in beiden Terminals tippen.

### Automatisches Verhalten

- Bei einem WLAN-Abbruch verbindet sich der ESP32 selbstständig erneut.
- Offene Netzwerkverbindungen werden nach dem Abbruch sauber verworfen und
  müssen vom Browser beziehungsweise Terminal neu aufgebaut werden.
- Das Webterminal versucht seine WebSocket-Verbindung automatisch erneut.
- Der Task-Watchdog startet den ESP32 neu, falls der UART-Datenpfad hängenbleibt.
- UART-Baudrate, WLAN-Daten und Hostname werden vor dem Build in
  `main/config.h` festgelegt.
- Das bei der Ersteinrichtung angelegte Konto bleibt bei normalen
  Firmware- und OTA-Updates erhalten.
- Die Übersicht aktualisiert die ESP32-Statuswerte alle zehn Sekunden.
- Der Logdownload enthält bis zu 32 KB vom BMC empfangenen UART-Verlauf.
  Direkt aufeinanderfolgende identische Zeilen werden im Log zusammengefasst;
  Live-Terminal und TCP-Ausgabe bleiben vollständig unverändert. Der Puffer
  liegt nur im RAM, verursacht keinen Flashverschleiß und ist nach einem
  ESP32-Neustart leer.

### Grenzen der aktuellen Firmware

- nur 32 KB flüchtiger UART-Verlauf; keine dauerhafte Aufzeichnung
- keine HTTPS-/TLS-Verschlüsselung
- nur ein Administratorkonto; keine Rollen oder getrennten TCP-Zugangsdaten
- keine dauerhafte Speicherung der Redfish-Zugangsdaten; nach ESP32-Neustart erneut anmelden
- keine Prüfung des selbstsignierten BMC-Zertifikats
- keine Steuerung von Power- oder Reset-Tastern
- keine Änderung der Konfiguration über die Weboberfläche
- kein garantierter DNS- oder `.local`-Name; die IP-Adresse funktioniert immer
- kein automatischer Rollback nach einem zwar gültigen, aber defekten OTA-Image

## Mögliche spätere Erweiterungen

Die folgenden Funktionen sind **nicht Bestandteil der aktuellen Firmware**,
können aber auf derselben Basis ergänzt werden.

### Besonders sinnvoll

| Erweiterung | Nutzen | Voraussetzung oder Grenze |
| --- | --- | --- |
| Zeitstempel per NTP | Konsolenausgaben zeitlich zuordnen | funktionierende Netzwerk- und Zeitserververbindung |
| Konfiguration im Browser | WLAN, Hostname und Baudrate ohne Neubuild ändern | sichere Speicherung in NVS und geschützter Reset auf Werkseinstellungen |
| OTA-Rollback | Bei einer nicht startfähigen neuen Firmware automatisch zurückkehren | neue Firmware muss ihren erfolgreichen Start ausdrücklich bestätigen |
| mDNS | Zugriff beispielsweise über `mj11-bmc-console.local` | mDNS-Unterstützung im verwendeten Netzwerk |

### Für dauerhaften Serverbetrieb

| Erweiterung | Nutzen | Voraussetzung oder Grenze |
| --- | --- | --- |
| Syslog- oder MQTT-Weiterleitung | BMC-Meldungen zentral archivieren und auswerten | externer Server/Broker; sensible Konsolendaten schützen |
| microSD-Protokollierung | Lange Boot- und Konsolenmitschnitte lokal speichern | SD-Modul, zusätzliche GPIOs und kontrollierte Dateisystemzugriffe |
| Schreibschutz pro Client | Mehrere Beobachter, aber nur ein steuernder Benutzer | Sitzungsverwaltung und eindeutige Besitzübergabe |
| Ereignisalarme | Bei Texten wie Kernel-Panic oder Bootfehler benachrichtigen | einfache, klar begrenzte Suchregeln |
| TLS oder VPN-Anbindung | Zugangsdaten und UART-Verkehr verschlüsseln | Zertifikatsverwaltung oder bestehendes Management-VPN |

### Optionale Hardwaresteuerung

| Erweiterung | Nutzen | Sicherheitsanforderung |
| --- | --- | --- |
| Power-Taster auslösen | Host aus der Ferne ein- oder ausschalten | galvanisch geeigneter Optokoppler oder Open-Drain-Schaltung |
| BMC-/Board-Reset auslösen | Hängendes System aus der Ferne neu starten | Schaltung und Impulsdauer müssen vorher am Board geprüft werden |
| Zweiten Service-UART anbinden | Beispielsweise einen separaten NIC-Debugport überwachen | Pinbelegung und Logikpegel jedes Headers separat messen |

Power-, Reset- oder unbekannte Service-Signale dürfen nicht direkt mit einem
ESP32-GPIO verbunden werden, bevor Pegel, Beschaltung und zulässige Belastung
geprüft wurden. Für Schaltsignale ist eine elektrisch geeignete Entkopplung
vorzusehen.

Die Gateway-Authentifizierung läuft ohne TLS. Das Gateway deshalb nur in einem
vertrauenswürdigen, getrennten Management-LAN verwenden; Benutzername,
Passwort und UART-Daten sind im WLAN sonst lesbar.

### Redfish-Dashboard

Unter **Übersicht** BMC-IP, BMC-Benutzer und BMC-Passwort eingeben. Diese
Daten werden nicht im Flash gespeichert und gehen beim ESP32-Neustart oder
mit **Redfish abmelden** verloren. Die Firmware fragt ausschließlich die
bestätigten MJ11-Endpunkte für System, Manager, Thermal, Power und
Manager-Netzwerk ab. Zuerst wird die Anmeldung einmal gegen den Manager-
Endpunkt geprüft; die übrigen Dashboard-Abfragen starten nur nach erfolgreicher
Authentifizierung.

Die Verbindung zum BMC verwendet HTTPS. Weil dessen werkseitiges Zertifikat
selbstsigniert ist, wird es derzeit nicht verifiziert. Die Verbindung ist
verschlüsselt, aber nicht gegen einen aktiven Angreifer im Management-LAN
authentisiert. Die vom MJ11 gemeldete Leistungsaufnahme wird nur angezeigt,
wenn der zugehörige Sensor aktiviert ist; `0 W` bei `State: Disabled` gilt
bewusst als nicht verfügbar.

Erkannte Host-NICs erscheinen mit Name, MAC-Adresse, administrativem Zustand
und Gesundheit. Da diese AMI-Version keinen physischen Linkstatus liefert,
kennzeichnet die Oberfläche ihn ausdrücklich als nicht bereitgestellt.

## Konfiguration

```bash
cd esp32-mj11-uart-gateway
cp main/config.example.h main/config.h
nano main/config.h
```

Mindestens die WLAN-Daten ändern:

```c
#define GATEWAY_WIFI_SSID       "mein-wlan"
#define GATEWAY_WIFI_PASSWORD   "mein-wlan-passwort"
#define GATEWAY_HOSTNAME        "mj11-bmc-console"
#define GATEWAY_UART_BAUD       115200
```

Die Datei `main/config.h` ist absichtlich in `.gitignore`, damit die
WLAN-Zugangsdaten nicht versehentlich eingecheckt werden. Das Gateway-Konto
steht nicht in der Firmware-Konfiguration, sondern wird beim ersten Aufruf
angelegt und als gesalzener PBKDF2-Hash im NVS gespeichert. Der Hostname wird per DHCP bekannt
gegeben; ob `http://mj11-bmc-console/` auflösbar ist, hängt vom Router ab.
Die IP-Adresse steht auch im seriellen ESP32-Log.

### Konto zurücksetzen

Es gibt absichtlich keinen ungeschützten Reset-Schalter in der
Weboberfläche. Falls das Gateway-Passwort vergessen wurde, den ESP32 per USB
anschließen und den gesamten Flash löschen:

```powershell
idf.py -p COM5 erase-flash
idf.py -B "C:\tmp\mj11-build" -p COM5 flash
```

Danach erscheint wieder die Ersteinrichtung. Das Löschen entfernt auch alle
anderen NVS-Daten des ESP32. Ein normales Flashen oder OTA-Update löscht das
Konto nicht.

## ESP-IDF unter Windows aktivieren

ESP-IDF 6.0.2 wird unter Windows bevorzugt mit dem Espressif Installation
Manager (EIM) installiert:

```powershell
winget install Espressif.EIM
```

Im EIM unter **New Installation** eine benutzerdefinierte Installation von
**v6.0.2** anlegen. Anschließend unter **Manage Installations** bei v6.0.2
**Open IDF Terminal** wählen und prüfen:

```powershell
idf.py --version
```

Erwartet wird `ESP-IDF v6.0.2`. Die vorhandene 5.5.4-Installation kann
parallel bestehen bleiben. Für jede IDF-Version einen eigenen Buildordner
verwenden, beispielsweise `C:\tmp\mj11-idf55` und `C:\tmp\mj11-idf60`.

Falls `idf.py set-target esp32` anschließend
`xtensa-esp32-elf-gcc was not found in the PATH` meldet, wurde die lokale
Legacy-ESP-IDF-Installation nur für ein RISC-V-Ziel wie `esp32c6` registriert.
Einmalig das klassische ESP32-Ziel nachtragen:

```powershell
cd "D:\esp\esp-idf"
.\install.ps1 esp32
```

Danach eine neue PowerShell öffnen und ESP-IDF wie oben erneut aktivieren.
Zum sofortigen Fortsetzen in der bereits geöffneten PowerShell genügt:

```powershell
$env:Path = "C:\Users\shs\.espressif\tools\xtensa-esp-elf\esp-14.2.0_20260121\xtensa-esp-elf\bin;$env:Path"
Get-Command xtensa-esp32-elf-gcc
```

Danach ESP32 per USB anschließen, den COM-Port im Geräte-Manager prüfen und
im Projektordner bauen und flashen:

```powershell
cd "C:\Users\shs\Documents\Codex\2026-07-24\referenced-chatgpt-conversation-this-is-untrusted\outputs\sys-fan-mj11-g431mm0\esp32-mj11-uart-gateway"
$buildDir = "C:\tmp\mj11-idf60"
idf.py -B $buildDir set-target esp32
idf.py -B $buildDir build
idf.py -B $buildDir -p COM5 flash monitor
```

`COM5` bei Bedarf ersetzen. Falls beim Verbindungsaufbau nur Punkte
erscheinen, die **BOOT-Taste** gedrückt halten, bis das Flashen beginnt.
Den Monitor mit `Ctrl+]` verlassen. Der kurze Buildpfad vermeidet unter
Windows Warnungen oder Fehler durch zu lange Objektdateipfade.

Falls ein zuvor abgebrochener Build bei `idf.py set-target esp32` meldet,
der Ordner `build` sei kein gültiges CMake-Buildverzeichnis, ausschließlich
diesen erzeugten Ordner entfernen und den Befehl wiederholen:

```powershell
Remove-Item -LiteralPath ".\build" -Recurse -Force
idf.py set-target esp32
idf.py build
```

## ESP-IDF unter Ubuntu installieren

Die Firmware wird mit ESP-IDF 6.0.2 geprüft. Installation nach Espressif:

```bash
sudo apt update
sudo apt install -y git wget flex bison gperf python3 python3-pip \
  python3-venv cmake ninja-build ccache libffi-dev libssl-dev dfu-util \
  libusb-1.0-0
mkdir -p ~/esp
cd ~/esp
git clone --recursive --branch v6.0.2 \
  https://github.com/espressif/esp-idf.git esp-idf-v6.0.2
cd esp-idf-v6.0.2
./install.sh esp32
. ./export.sh
```

In jeder neuen Shell zuerst `. ~/esp/esp-idf-v6.0.2/export.sh` ausführen.

## Unter Ubuntu bauen und per USB flashen

ESP32 anschließen und den Port ermitteln:

```bash
ls -l /dev/serial/by-id/
```

Dann im Projektordner:

```bash
idf.py set-target esp32
idf.py build
idf.py -p /dev/serial/by-id/DEIN_CP210X_GERAET flash monitor
```

Den Monitor mit `Ctrl+]` verlassen. Falls der serielle Port nicht zugänglich
ist, den Benutzer einmalig zur passenden Gruppe hinzufügen und neu anmelden:

```bash
sudo usermod -aG dialout "$USER"
```

## Test

Zuerst ohne MJ11-Verbindung flashen. Im Monitor müssen WLAN-IP und
`TCP-Bridge lauscht auf Port 2323` erscheinen.

TCP-Test mit PuTTY:

1. Verbindungstyp **Raw**, Port **2323**, Ziel ist die ESP32-IP.
2. Als erste Zeile `AUTH dein-passwort` eingeben.
3. Nach `OK` ist die Verbindung transparent; Enter sendet an die BMC-Konsole.

Alternativ mit `nc`:

```bash
nc ESP32-IP 2323
AUTH dein-passwort
```

Webterminal: `http://ESP32-IP/` öffnen, HTTP-Basic-Zugangsdaten eingeben und
in die schwarze Terminalfläche klicken. Eingaben und eingefügter Text werden
direkt an UART2 gesendet. Einfügen funktioniert mit `Strg+V` oder über das
Kontextmenü. Browser speichern HTTP-Basic-Zugangsdaten bis zum Beenden des
Browserprozesses; ein Reload oder Firmwareupdate fragt sie daher nicht erneut
ab. Die Versions- und Build-Anzeige im Header sowie `Cache-Control: no-store`
machen sichtbar, welche Firmware tatsächlich läuft.

Vor dem MJ11-Anschluss nochmals prüfen:

- MJ11 TX → GPIO16/RX2
- MJ11 RX → GPIO17/TX2
- MJ11 GND → ESP32 GND
- MJ11 VCC nicht verbinden
- GND-Pin vorab stromlos per Durchgangsmessung gegen Boardmasse bestätigen
- gemessener Signalpegel ist 3,3-V-TTL

Bei eingeschaltetem BMC sollte die Login-Konsole mit 115200 8N1 erscheinen.
Falls nicht, zuerst TX/RX-Zuordnung und Masse prüfen, danach erst andere
Baudraten in `main/config.h` testen.

Der kleine lokale Strukturtest benötigt nur Python:

```bash
python3 test_project.py
```

## OTA-Update

Nach einem erfolgreichen Build liegt das OTA-Image hier:

```text
build/mj11_uart_gateway-v1.9.0.bin
```

Zusätzlich bleibt `mj11_uart_gateway.bin` für die ESP-IDF-Flashwerkzeuge
erhalten. Der versionierte Dateiname wird automatisch aus `PROJECT_VER`
gebildet.

Im Webterminal auf **OTA-Firmware** klicken, diese `.bin`-Datei auswählen und
bestätigen. Der ESP32 prüft das Image, schaltet auf die zweite OTA-Partition um
und startet neu. Für eine erste Installation ist weiterhin USB nötig.

Bei einem fehlgeschlagenen Upload bleibt die bislang gestartete Firmware
unverändert aktiv. Ein automatischer Rollback nach einem zwar gültigen, aber
zur Laufzeit defekten Update ist nicht eingerichtet; dafür wäre eine explizite
Selbstbestätigung der neuen Firmware nötig.
