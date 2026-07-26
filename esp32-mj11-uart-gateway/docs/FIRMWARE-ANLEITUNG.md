# ESP32-Firmware erstellen: MJ11-BMC-UART-Gateway

Diese Anleitung beschreibt den vollständigen Weg von einem neuen
Entwicklungsrechner bis zur getesteten Firmware für ein ESP32 DevKit V1 mit
klassischem ESP32, 30 Pins und onboard CP210x.

Die konkrete Firmware verbindet UART2 des ESP32 mit der BMC-Konsole eines
Gigabyte MJ11-EC0:

```text
Browser/WebSocket ─┐
                   ├─ WLAN ─ ESP32 ─ UART2 ─ MJ11-BMC
PuTTY/Raw TCP 2323 ┘
```

## 1. Ergebnis und vorhandene Funktionen

Die fertige Firmware bietet:

- UART2 auf GPIO16/RX2 und GPIO17/TX2
- 115200 Baud, 8 Datenbits, keine Parität, 1 Stoppbit
- WLAN-Client ohne Powersave, mit Reconnect und wachsendem Retry-Abstand
- transparente TCP-UART-Bridge auf Port 2323
- Webterminal per WebSocket
- Redfish-Dashboard für BIOS/BMC, Netzwerk, Host-NIC-Inventar, Temperaturen, Lüfter und Spannungen
- Mainboardmodell aus Redfish automatisch im Seitenkopf und Browser-Tab
- deutsche und englische Weboberfläche mit lokal gespeicherter Sprachauswahl
- Redfish-Zugangsdaten nur im RAM und explizites Abmelden
- einmalige Konto-Ersteinrichtung im Browser
- HTTP-Basic-Authentifizierung für Weboberfläche, WebSocket und OTA
- Passwortabfrage mit demselben Konto für die Raw-TCP-Verbindung
- OTA-Upload der App-Firmware im Browser
- zwei OTA-App-Partitionen auf einem 4-MB-Flash
- Task-Watchdog für den UART-Datenpfad
- Firmwareversion und Build-Zeit im Webheader
- 32-KB-RAM-Ringpuffer mit Zeilen-Deduplizierung und geschütztem Logdownload
- geschützter 8-KB-ESP32-Systemlog für WLAN-, TLS- und HTTP-Diagnose
- kompakte ESP32-Statuswerte im Header für WLAN, Laufzeit, Heap, Clients und UART-Zähler
- Schutz gegen veraltetes HTML durch `Cache-Control: no-store`

Die Implementierung verwendet ausschließlich ESP-IDF-Komponenten. Es werden
keine Arduino-Bibliotheken und keine externen Webserver-Bibliotheken benötigt.

## 2. Sicherheit und Verdrahtung

Der ESP32 verträgt an seinen GPIOs nur 3,3-V-Logik. Vor dem Anschluss muss der
MJ11-Serviceheader geprüft werden.

```text
MJ11 TX  ─────> ESP32 RX2 / GPIO16
MJ11 RX  <───── ESP32 TX2 / GPIO17
MJ11 GND ─────  ESP32 GND
MJ11 VCC        nicht verbinden
```

Wichtig:

- TX und RX werden gekreuzt.
- Der ESP32 wird separat über USB versorgt.
- VCC des MJ11-Headers bleibt immer frei.
- Nicht allein auf ein Foto oder dessen Blickrichtung vertrauen.
- GND am stromlosen Board per Durchgangsmessung gegen Boardmasse bestimmen.
- Anschließend bei Standbyversorgung Gleichspannung gegen GND messen.
- Signalpegel TX/RX muss zu 3,3-V-TTL passen.
- Niemals Widerstand oder Durchgang am versorgten Board messen.
- Das in manchen Quellen verwendete Wort „JTAG“ ist für diesen vierpoligen
  Anschluss technisch irreführend; genutzt wird eine UART-Konsole.

Für den ersten Flash- und WLAN-Test bleibt der MJ11-Header vollständig
abgesteckt. Erst nach erfolgreichem Grundtest wird UART verbunden.

## 3. Projektaufbau

```text
esp32-mj11-uart-gateway/
├── CMakeLists.txt
├── partitions.csv
├── sdkconfig.defaults
├── README.md
├── test_project.py
├── docs/
│   └── FIRMWARE-ANLEITUNG.md
└── main/
    ├── CMakeLists.txt
    ├── config.example.h
    ├── config.h
    ├── index.html
    ├── setup.html
    └── main.c
```

Die Rollen der Dateien:

| Datei | Aufgabe |
| --- | --- |
| `CMakeLists.txt` | Projektname und Firmwareversion |
| `main/main.c` | WLAN, UART, TCP, HTTP, WebSocket, OTA und Watchdog |
| `main/index.html` | eingebettete Weboberfläche |
| `main/setup.html` | einmalige Ersteinrichtung des Gateway-Kontos |
| `main/config.example.h` | Vorlage ohne echte Zugangsdaten |
| `main/config.h` | lokale WLAN-Daten und Hardwareparameter |
| `partitions.csv` | NVS, OTA-Metadaten und zwei App-Slots |
| `sdkconfig.defaults` | 4-MB-Flash, WebSocket, Watchdog und Partitionstabelle |

`main/config.h`, `sdkconfig`, Buildordner und Binärdateien gehören nicht in
ein öffentliches Quellarchiv. `config.h` enthält die WLAN-Daten im Klartext.

## 4. ESP-IDF unter Windows installieren

Das Projekt wird in GitHub Actions mit ESP-IDF 5.5.4 und 6.0.2 geprüft.
Für neue lokale Installationen ist ESP-IDF 6.0.2 vorgesehen. Espressif
empfiehlt ab IDF 6 den ESP-IDF Installation Manager (EIM):

```powershell
winget install Espressif.EIM
```

Danach:

1. EIM öffnen.
2. Unter **New Installation** eine benutzerdefinierte Installation starten.
3. ESP-IDF **v6.0.2** und das Ziel ESP32 auswählen.
4. Unter **Manage Installations** bei v6.0.2 **Open IDF Terminal** wählen.
5. Version prüfen:

```powershell
idf.py --version
```

Erwartet wird:

```text
ESP-IDF v6.0.2
```

Eine vorhandene Legacy-Installation von 5.5.4 darf parallel bestehen
bleiben. Nicht deren `export.ps1` in das IDF-6-Terminal laden. Getrennte
Buildordner verhindern vermischte CMake-Caches:

```text
C:\tmp\mj11-idf55
C:\tmp\mj11-idf60
```

Referenzen:

- [ESP-IDF 6.0.2: Installation und Einstieg](https://docs.espressif.com/projects/esp-idf/en/v6.0.2/esp32/get-started/index.html)
- [ESP-IDF 6.0.2: Windows-Kommandozeile](https://docs.espressif.com/projects/esp-idf/en/v6.0.2/esp32/get-started/windows-start-project.html)

### Windows-Pfadlänge vermeiden

ESP-IDF erzeugt tief verschachtelte Objektpfade. Deshalb wird für dieses
Projekt ein kurzer separater Buildpfad verwendet:

```text
C:\tmp\mj11-build
```

Der Quellordner kann an seiner bisherigen Stelle bleiben.

## 5. ESP-IDF unter Ubuntu installieren

Die folgenden Pakete entsprechen der offiziellen ESP-IDF-6.0.2-Anleitung:

```bash
sudo apt update
sudo apt install git wget flex bison gperf python3 python3-pip python3-venv \
  cmake ninja-build ccache libffi-dev libssl-dev dfu-util libusb-1.0-0
```

ESP-IDF 6.0.2 installieren:

```bash
mkdir -p "$HOME/esp"
cd "$HOME/esp"
git clone --recursive --branch v6.0.2 \
  https://github.com/espressif/esp-idf.git esp-idf-v6.0.2
cd esp-idf-v6.0.2
./install.sh esp32
```

Vor jeder Arbeitssitzung die Umgebung aktivieren:

```bash
. "$HOME/esp/esp-idf-v6.0.2/export.sh"
idf.py --version
```

Referenz:

- [Offizielle ESP-IDF-6.0.2-Installation für Linux](https://docs.espressif.com/projects/esp-idf/en/v6.0.2/esp32/get-started/linux-macos-setup-legacy.html)

Für den seriellen Port benötigt der Benutzer unter Ubuntu meist die Gruppe
`dialout`:

```bash
sudo usermod -aG dialout "$USER"
```

Danach einmal ab- und wieder anmelden.

## 6. Projekt konfigurieren

In den Projektordner wechseln und die lokale Konfiguration anlegen.

Windows:

```powershell
Copy-Item ".\main\config.example.h" ".\main\config.h"
notepad ".\main\config.h"
```

Ubuntu:

```bash
cp main/config.example.h main/config.h
nano main/config.h
```

Beispiel ohne echte Zugangsdaten:

```c
#pragma once

#define GATEWAY_WIFI_SSID       "mein-wlan"
#define GATEWAY_WIFI_PASSWORD   "mein-wlan-passwort"
#define GATEWAY_HOSTNAME        "mj11-bmc-console"

#define GATEWAY_UART_BAUD       115200
#define GATEWAY_UART_RX_GPIO    16
#define GATEWAY_UART_TX_GPIO    17
#define GATEWAY_TCP_PORT        2323
```

Regeln:

- Keine echten Passwörter in `config.example.h`, README oder Quellarchive
  schreiben.
- GPIO16 und GPIO17 nicht ändern, solange das 30-Pin-DevKit über RX2/TX2
  angeschlossen wird.
- UART0 auf GPIO1/GPIO3 bleibt für den onboard CP210x frei.
- Bei einer neuen Firmwareversion `PROJECT_VER` in `CMakeLists.txt` erhöhen.

## 7. Ziel setzen und Firmware bauen

### Windows

In der aktivierten ESP-IDF-PowerShell:

```powershell
cd "PFAD\ZU\esp32-mj11-uart-gateway"
$buildDir = "C:\tmp\mj11-idf60"

idf.py -B $buildDir set-target esp32
idf.py -B $buildDir build
```

### Ubuntu

```bash
cd /pfad/zu/esp32-mj11-uart-gateway
BUILD_DIR="$HOME/esp-build/mj11-idf60"

idf.py -B "$BUILD_DIR" set-target esp32
idf.py -B "$BUILD_DIR" build
```

Die wichtigsten Ausgabedateien sind:

```text
mj11_uart_gateway.bin
mj11_uart_gateway-v1.9.1.bin
bootloader/bootloader.bin
partition_table/partition-table.bin
ota_data_initial.bin
```

`idf.py build` erzeugt Bootloader, Partitionstabelle und Anwendung. Das ist
auch in Espressifs
[Windows-Projektanleitung](https://docs.espressif.com/projects/esp-idf/en/v6.0.2/esp32/get-started/windows-start-project.html#build-the-project)
beschrieben.

## 8. ESP32 erstmals über USB flashen

1. MJ11-UART noch nicht anschließen.
2. ESP32 per Daten-USB-Kabel verbinden.
3. Im Windows-Geräte-Manager den CP210x-COM-Port bestimmen, beispielsweise
   `COM5`.
4. Unter Ubuntu den Port mit `ls /dev/ttyUSB*` bestimmen.

Windows:

```powershell
idf.py -B "C:\tmp\mj11-build" -p COM5 flash monitor
```

Ubuntu:

```bash
idf.py -B "$HOME/esp-build/mj11-build" -p /dev/ttyUSB0 flash monitor
```

Der onboard CP210x setzt ein übliches DevKit automatisch in den Bootloader.
Falls `Connecting...` nicht weiterläuft:

1. Taste `BOOT` gedrückt halten.
2. Taste `EN` kurz drücken.
3. `BOOT` loslassen, sobald das Schreiben beginnt.

Der ESP32-ROM-Bootloader wird über GPIO0 ausgewählt; viele DevKits erledigen
das automatisch über DTR/RTS. Siehe
[Espressif: Boot Mode Selection](https://docs.espressif.com/projects/esptool/en/latest/esp32/advanced-topics/boot-mode-selection.html).

Den Monitor mit `Ctrl+]` beenden.

## 9. Grundfunktion ohne MJ11 prüfen

Im Monitor müssen mindestens folgende Zustände erkennbar sein:

- Firmware startet ohne Reset-Schleife.
- WLAN wird verbunden.
- Eine IP-Adresse wird ausgegeben.
- Die TCP-Bridge lauscht auf Port 2323.
- Der Watchdog löst nicht aus.

Im Browser öffnen:

```text
http://ESP32-IP/
```

Beim ersten Aufruf erscheint die Ersteinrichtung. Einen Benutzernamen und ein
eigenes Gateway-Passwort mit mindestens 12 Zeichen festlegen. Die Firmware
speichert nur einen gesalzenen PBKDF2-Passwort-Hash im NVS, nicht das
Klartextpasswort. Danach erscheint die HTTP-Basic-Anmeldung. Das Konto schützt
Weboberfläche, WebSocket, OTA und TCP-Port 2323.

Nach der Anmeldung zeigt der Header Firmwareversion und Build-Zeit.
Der Terminalbereich bleibt ohne angeschlossenen UART erwartungsgemäß leer.

Auf der Seite **Übersicht** anschließend BMC-IP, BMC-Benutzer und
BMC-Passwort eingeben. Diese Redfish-Zugangsdaten bleiben nur im RAM und
müssen nach jedem ESP32-Neustart erneut eingegeben werden. **Redfish
abmelden** löscht sie sofort.

Das MJ11 verwendet ein selbstsigniertes HTTPS-Zertifikat. Die Firmware
verschlüsselt die Verbindung, prüft dieses Zertifikat in der aktuellen
Version aber nicht. Das ist nur in einem vertrauenswürdigen Management-LAN
vertretbar. Für ein fremdes oder gemeinsam genutztes Netz muss später das
konkrete BMC-Zertifikat beziehungsweise dessen CA eingebunden werden.

Browser speichern HTTP-Basic-Zugangsdaten normalerweise bis zum vollständigen
Beenden des Browserprozesses. Ein Reload fragt sie deshalb nicht erneut ab.
Für einen unabhängigen Test ein privates/Inkognito-Fenster verwenden.

## 10. MJ11 anschließen und UART testen

1. MJ11-Header und ESP32 stromlos machen.
2. Nur GND, TX und RX verbinden.
3. VCC unverbunden lassen.
4. ESP32 per USB versorgen.
5. MJ11 zunächst nur mit Standbyspannung versorgen.
6. Webterminal öffnen.

Bei korrekter Verdrahtung erscheinen BMC-Bootmeldungen und später ein
Loginprompt. Die bestätigte Einstellung ist:

```text
115200 8N1
```

Typischer Login:

```text
AMI... login: sysadmin
Password:
```

Das BMC-Passwort wird normalerweise nicht angezeigt. Sichtbare
Passworteingaben in PuTTY deuten auf aktiviertes lokales Echo hin.

## 11. PuTTY über TCP verwenden

PuTTY-Einstellungen:

```text
Host Name:        IP-Adresse des ESP32
Port:             2323
Connection type:  Raw
```

Nicht „Telnet“ wählen, da Telnet Steuerbytes in den UART-Datenstrom einfügen
kann.

Nach dem Verbindungsaufbau:

```text
AUTH dein-gateway-passwort
OK
```

Erst danach folgt die transparente BMC-Konsole. Das Gateway-Passwort wurde
bei der Ersteinrichtung festgelegt und ist nicht das IPMI-Passwort.

Unter `Terminal` einstellen:

```text
Local echo:         Force off
Local line editing: Force off
```

Dadurch werden Befehle nicht doppelt angezeigt und Passwörter nicht lokal
eingeblendet.

## 12. OTA-Update

Nach dem Erstflash kann die App über die Weboberfläche aktualisiert werden.
Im Browser „OTA-Firmware“ wählen und ausschließlich diese Datei hochladen:

Windows:

```text
C:\tmp\mj11-build\mj11_uart_gateway-v1.9.1.bin
```

Ubuntu:

```text
$HOME/esp-build/mj11-build/mj11_uart_gateway-v1.9.1.bin
```

Der Dateiname wird aus `PROJECT_VER` erzeugt. Die unversionierte Datei bleibt
für `idf.py flash` bestehen.

Nicht über das Webformular hochladen:

- `bootloader.bin`
- `partition-table.bin`
- `ota_data_initial.bin`
- zusammengeführte Komplettimages

Die App wird in den jeweils freien OTA-Slot geschrieben und danach als
Bootpartition gesetzt. Die zwei Slots ermöglichen Updates ohne Überschreiben
der gerade laufenden App. Die aktuelle Firmware implementiert jedoch keine
automatische Funktionsprüfung mit Rollback; ein fehlerhaft startendes Update
kann weiterhin einen USB-Reflash erforderlich machen.

Nach dem Neustart:

1. Browser mit `Ctrl+F5` neu laden.
2. Version und Build-Zeit im Header kontrollieren.
3. WebSocket-Terminal testen.
4. PuTTY auf Port 2323 testen.
5. BMC-Login und Ein-/Ausgabe prüfen.

## 13. Firmware fertigstellen und archivieren

Vor einer Freigabe:

- `PROJECT_VER` erhöhen.
- Keine Standardpasswörter verwenden.
- `config.h` nicht verteilen.
- Ersttest ohne MJ11 durchführen.
- Verdrahtung und 3,3-V-Pegel dokumentieren.
- Webterminal und Raw-TCP jeweils bidirektional testen.
- WLAN-Trennung und Reconnect testen.
- OTA von der vorherigen Version testen.
- Build-Version nach OTA kontrollieren.
- Binärdatei mit Prüfsumme archivieren.

Windows:

```powershell
Get-FileHash "C:\tmp\mj11-build\mj11_uart_gateway-v1.9.1.bin" -Algorithm SHA256
```

Ubuntu:

```bash
sha256sum "$HOME/esp-build/mj11-build/mj11_uart_gateway-v1.9.1.bin"
```

Ein Freigabepaket sollte enthalten:

```text
Quellcode ohne main/config.h
main/config.example.h
README.md
docs/FIRMWARE-ANLEITUNG.md
mj11_uart_gateway-v1.9.1.bin
SHA256-Prüfsumme
Versionsnummer
```

## 14. Häufige Fehler

### `idf.py` wurde nicht gefunden

Die ESP-IDF-Umgebung ist in diesem Terminal nicht aktiviert.

Windows: Im EIM bei der Installation v6.0.2 **Open IDF Terminal** wählen.

Ubuntu:

```bash
. "$HOME/esp/esp-idf-v6.0.2/export.sh"
```

### Compiler wurde nicht im PATH gefunden

`export.ps1` beziehungsweise `export.sh` erneut ausführen. Unter Windows
bevorzugt die vom Installer angelegte „ESP-IDF PowerShell Environment“
verwenden.

### Windows warnt vor zu langen Objektpfaden

Mit einem kurzen externen Buildordner neu konfigurieren:

```powershell
idf.py -B "C:\tmp\mj11-build" set-target esp32
idf.py -B "C:\tmp\mj11-build" build
```

### Buildordner sei kein gültiges CMake-Verzeichnis

Nicht einen beschädigten Ordner mit `fullclean` erzwingen. Einen neuen kurzen
Buildordner verwenden, beispielsweise `C:\tmp\mj11-build-neu`.

### Flashen bleibt bei `Connecting...`

- anderes Daten-USB-Kabel testen
- richtigen COM-Port prüfen
- seriellen Monitor schließen
- niedrigere Flash-Baudrate verwenden
- BOOT/EN-Sequenz aus Abschnitt 8 verwenden

### Webterminal zeigt Zeichensalat

- RX2 bei offenem Header nicht als echte Datenquelle bewerten
- gemeinsame Masse prüfen
- TX/RX-Zuordnung prüfen
- 3,3-V-Pegel prüfen
- 115200 8N1 verwenden

### PuTTY antwortet mit `DENIED`

Die erste Zeile muss exakt lauten:

```text
AUTH dein-gateway-passwort
```

Groß-/Kleinschreibung und das einzelne Leerzeichen sind relevant.

### Browser fragt Zugangsdaten nach OTA nicht erneut ab

Das ist HTTP-Basic-Caching des Browsers, kein Hinweis auf eine alte Firmware.
Version und Build-Zeit im Header prüfen oder ein privates Fenster öffnen.

### Gateway-Passwort vergessen

Es gibt keinen ungeschützten Kontoreset in der Weboberfläche. ESP32 per USB
anschließen, den Flash vollständig löschen und die Firmware neu schreiben:

```powershell
idf.py -p COM5 erase-flash
idf.py -B "C:\tmp\mj11-build" -p COM5 flash
```

Danach erscheint die Ersteinrichtung erneut. Normales Flashen und OTA
behalten das Konto.

### RAM-Log und ESP32-Status

Der Header zeigt WLAN-Signal als Balkensymbol, Laufzeit, freien und minimalen
Heap, verbundene TCP-/WebSocket-Clients, UART-Baudrate sowie empfangene und
gesendete Bytes. Die Werte werden alle zehn Sekunden automatisch aktualisiert.

**UART-Log herunterladen** speichert bis zu 32 KB UART-Verlauf als
`mj11-uart-log.txt`. Direkt aufeinanderfolgende identische Zeilen werden nur
einmal gespeichert und durch eine Zeile wie
`[previous line repeated 1842 additional times]` ergänzt. Diese Verdichtung
betrifft ausschließlich den RAM-Log; WebSocket- und TCP-Terminal erhalten
weiterhin jedes UART-Byte. Der Ringpuffer belastet den Flash nicht und ist nach
einem ESP32-Neustart leer. Der Zähler `↻` im Header zeigt die insgesamt
zusammengefassten Zeilen seit dem Neustart.

**ESP32-Systemlog herunterladen** speichert die letzten 8 KB der
ESP-IDF-Laufzeitmeldungen als `esp32-system-log.txt`. Darin stehen unter
anderem WLAN-Reconnects sowie TLS- und HTTP-Client-Fehler. Auch dieser
Ringpuffer liegt nur im RAM, schreibt nicht in den Flash und beginnt nach
jedem Neustart leer.

## 15. Erweiterungsmöglichkeiten

### Sinnvolle nächste Ausbaustufe

| Erweiterung | Nutzen | Aufwand/Risiko |
| --- | --- | --- |
| Konfiguration in NVS | WLAN, Hostname und Baudrate ohne Neubau ändern | mittel; sichere Rücksetzung nötig |
| Einrichtungs-Access-Point | Erstkonfiguration ohne Quellcodeänderung | mittel; Portal absichern |
| Logdateien im Flash | Bootverläufe dauerhaft abrufen | mittel; Flashverschleiß begrenzen |
| mDNS | Zugriff über `mj11-bmc-console.local` | niedrig |
| Baudrate im Webinterface | andere Service-UARTs ohne Neubau testen | mittel; Eingaben validieren |

### Sicherheit

Die aktuelle HTTP-Basic- und Raw-TCP-Anmeldung ist nicht verschlüsselt.
Passwörter und BMC-Daten können im lokalen Netz mitgelesen werden.

Mögliche Verbesserungen:

- Management-WLAN oder separates VLAN
- Firewallbeschränkung auf einzelne Administrationsrechner
- HTTPS und WSS
- TLS-gesicherte TCP-Bridge
- richtige Loginseite mit kurzlebiger Sitzung und Abmeldefunktion
- Rate-Limit und Wartezeit nach Fehlversuchen
- nur ein schreibender Client, weitere Clients ausschließlich lesend
- signierte OTA-Images
- Secure Boot und Flash Encryption

Secure Boot und Flash Encryption verändern eFuses und müssen auf einem
separaten Testboard geplant werden. Sie sollten nicht als erster
Sicherheitsschritt aktiviert werden.

### Terminal und Bedienung

- ANSI/VT100-Auswertung statt einfacher Textfläche
- `xterm.js` für Cursorsteuerung, Farben und Vollbildprogramme
- auswählbare Zeilenenden
- Schaltfläche für Break-Signal
- Makrotasten für häufige Befehle
- wählbarer Schreibzugriff bei mehreren Beobachtern
- automatische Hervorhebung wichtiger Boot- und Fehlermeldungen

### Diagnose und Benachrichtigungen

- Erkennung von Bootstart, Kernel Panic und Loginprompt
- Benachrichtigung per MQTT, Syslog oder Webhook
- Weiterleitung von UART-Logs an einen zentralen Syslog-Server
- Zeitstempel aus SNTP
- Zähler für verlorene UART-, TCP- und WebSocket-Bytes
- Download eines Diagnosepakets mit Status und letztem Bootlog

### Hardwaresteuerung

Mit galvanisch beziehungsweise elektrisch sauber getrennten Ausgängen:

- BMC-Reset auslösen
- Host-Power-Taster kurzzeitig simulieren
- Host-Reset-Taster simulieren
- zweiten Service-UART überwachen
- Status-LED oder kleinen OLED-Bildschirm ergänzen

Power- und Reset-Leitungen dürfen nicht direkt und ungeprüft mit einem
ESP32-GPIO verbunden werden. Open-Drain-Schaltung, Transistor oder Optokoppler
sowie die elektrische Funktion des Mainboard-Signals müssen vorher geprüft
werden.

### Empfohlene Reihenfolge

1. NVS-Konfiguration mit sicherer Rücksetzung
2. persistente, begrenzte Bootlogs
3. Clientrollen: ein Schreiber, mehrere Leser
4. Netzwerkschutz durch VLAN/VPN oder TLS
5. erst danach Power/Reset-Hardware

Diese Reihenfolge verbessert zuerst Diagnose und Bedienbarkeit, ohne früh
zusätzliche Risiken an Mainboardleitungen oder ESP32-eFuses einzuführen.
