# ESP32 MJ11 BMC UART Gateway

A bidirectional Wi-Fi UART bridge for a 30-pin ESP32 DevKit V1 and the BMC
console of the Gigabyte MJ11-EC0. The firmware uses only ESP-IDF components
for TCP, HTTP/WebSocket, OTA and the task watchdog.

The project is compiled in CI with ESP-IDF 5.5.4 and 6.0.2 for the classic
`esp32` target. ESP-IDF 6.0.2 is recommended for new local installations.
The two-slot OTA partition layout requires the 4 MB flash normally fitted to
these DevKits.

See [docs/FIRMWARE-GUIDE.md](docs/FIRMWARE-GUIDE.md) for the complete guide
from ESP-IDF installation to a finished firmware image.

## Safety and wiring

Verify the MJ11 service header with a multimeter or logic analyzer before
connecting it. ESP32 GPIOs accept **3.3 V TTL only**—not 5 V TTL and not
RS-232 levels.

| MJ11 BMC header | ESP32 DevKit V1 |
| --- | --- |
| GND | GND |
| TX | RX2 / GPIO16 |
| RX | TX2 / GPIO17 |
| VCC | **do not connect** |

In the commonly circulated photo orientation, the corrected signal sequence
is:

```text
GND | TX | RX | VCC
```

The [referenced pinout photo](https://oliver.obenland.it/gigabyte-mj11-ec1-alle-luefter-per-pwm-steuern/)
incorrectly labels both outer pins as GND and shows an MJ11-EC1. Do not infer
the physical orientation from a photo alone. With the board unpowered, identify
the single GND pin by continuity to board ground. Then apply standby power and
measure the remaining pins against that verified GND.

Connect **MJ11 TX → ESP32 RX2**, **MJ11 RX → ESP32 TX2** and
**MJ11 GND → ESP32 GND**. Leave MJ11 VCC unconnected.

Power the ESP32 separately through USB or a suitable regulated 5 V supply.
The onboard CP210x is used for flashing and the local ESP32 debug console; no
additional USB-to-TTL adapter is required.

## Features

- UART2 on GPIO16/RX2 and GPIO17/TX2, defaulting to 115200 8N1
- transparent raw TCP-to-UART bridge on port 2323
- browser terminal over WebSocket
- automatic Wi-Fi and WebSocket reconnect
- one simultaneous raw TCP client and one WebSocket client
- first-boot gateway account setup; salted PBKDF2 hash stored in NVS
- HTTP Basic authentication for the web UI, WebSocket, OTA and downloads
- password authentication for the raw TCP bridge
- Redfish dashboard for system, BIOS, BMC, BMC network, host NIC inventory,
  temperatures, fans, voltages and power data
- dynamic board model in the page title from Redfish
- Redfish credentials stored only in RAM with an explicit disconnect button
- German/English language selector in the web UI
- firmware version and build time in the web header
- Wi-Fi signal, uptime, heap, client and UART counters in the web header
- 32 KB UART RAM ring buffer with repeated-line collapsing
- protected UART log download
- protected 8 KB ESP32 system-log download
- browser OTA upload with two application slots and automatic page reload
- task watchdog on the UART data path
- no Arduino framework or third-party web-server library

## What the gateway can do

| Task | Interface | Result |
| --- | --- | --- |
| Watch the BMC boot | Browser or TCP | Capture bootloader, kernel and init output |
| Use the BMC shell | Browser or TCP | Log in as `sysadmin` and run console commands |
| Diagnose the ESP32 | Browser | Inspect Wi-Fi, heap, clients, counters and system log |
| Review missed output | Browser | Download the current 32 KB UART history |
| Monitor the board | Browser | Display the Redfish data exposed by the MJ11 BMC |
| Update the gateway | Browser | Upload a new application image through OTA |

The RAM log survives temporary browser or TCP disconnects, but not an ESP32
reset. It does not write continuously to flash.

## Current limitations

- Wi-Fi client mode only; no setup access point
- WLAN SSID, WLAN password, hostname and UART baud rate are compile-time
  settings in `main/config.h`
- no TLS for the gateway web UI, WebSocket or raw TCP bridge
- Redfish uses HTTPS but does not verify the BMC's self-signed certificate
- Redfish credentials are not persisted across ESP32 restarts
- one TCP and one WebSocket client at a time
- no hardware flow control
- no persistent UART log
- no automatic rollback after a valid but non-working OTA image
- host-NIC physical link status is not available from this MJ11 Redfish
  implementation; detected NICs still show name, MAC address, state and health

Use the gateway only on a trusted, isolated management network. Gateway
credentials and UART traffic can otherwise be observed by another system on
the network. Redfish traffic is encrypted, but without certificate validation
it is not protected against an active attacker.

## Configure the project

Create the local configuration file:

### Windows

```powershell
Copy-Item .\main\config.example.h .\main\config.h
notepad .\main\config.h
```

### Ubuntu

```bash
cp main/config.example.h main/config.h
nano main/config.h
```

At minimum, change:

```c
#define GATEWAY_WIFI_SSID       "your-wifi"
#define GATEWAY_WIFI_PASSWORD   "your-wifi-password"
#define GATEWAY_HOSTNAME        "mj11-bmc-console"
#define GATEWAY_UART_BAUD       115200
```

The fixed hardware defaults are:

```c
#define GATEWAY_UART_RX_GPIO    16
#define GATEWAY_UART_TX_GPIO    17
#define GATEWAY_TCP_PORT        2323
```

`main/config.h` contains clear-text Wi-Fi credentials, is ignored by Git and
must never be committed. Do not place real credentials in
`main/config.example.h`.

The gateway username and password are deliberately not defined in
`config.h`. They are created in the browser on first boot. Only a salted
PBKDF2 password hash is stored in NVS.

## Build with ESP-IDF 6.0.2

### Windows

Install ESP-IDF 6.0.2 with the Espressif Installation Manager, including the
classic `esp32` target. Open the installation's **IDF Terminal** and verify:

```powershell
idf.py --version
```

Use a short external build directory to avoid Windows object-path limits:

```powershell
Set-Location "PATH\TO\esp32-mj11-uart-gateway"
idf.py -B "C:\tmp\mj11-idf60" set-target esp32
idf.py -B "C:\tmp\mj11-idf60" build
```

Do not mix an IDF 5.5 environment with an IDF 6.0.2 source tree and do not
reuse a build directory between IDF versions.

### Ubuntu

After installing and activating ESP-IDF 6.0.2:

```bash
cd /path/to/esp32-mj11-uart-gateway
idf.py set-target esp32
idf.py build
```

## Flash and test

Leave the MJ11 UART disconnected for the first flash:

```powershell
idf.py -B "C:\tmp\mj11-idf60" -p COM5 flash monitor
```

or on Ubuntu:

```bash
idf.py -p /dev/serial/by-id/YOUR_CP210X_DEVICE flash monitor
```

Replace the serial port as required. Exit the monitor with `Ctrl+]`.

Expected output includes the assigned IP address and confirms that the TCP
bridge is listening on port 2323.

Open `http://ESP32-IP/`. On first boot, create a gateway username and a
password of at least 12 characters. The browser then requests those credentials
through HTTP Basic authentication.

The header should show the firmware version, build time and ESP32 status. With
the MJ11 UART still disconnected, the terminal should remain empty rather than
displaying replacement characters.

## Redfish dashboard

On the **Overview** page, enter:

- BMC IPv4 address
- BMC username
- BMC password

The firmware acknowledges the credentials immediately and then validates them
with the first request to `/redfish/v1/Systems/Self`. HTTP 401 clears them
automatically. Credentials remain only in RAM and are also cleared by
**Disconnect Redfish** or an ESP32 restart.

The firmware queries only endpoints verified on this MJ11:

- `/redfish/v1/Systems/Self`
- `/redfish/v1/Managers/Self`
- `/redfish/v1/Chassis/Self/Thermal`
- `/redfish/v1/Chassis/Self/Power`
- `/redfish/v1/Managers/Self/EthernetInterfaces?$expand=.`
- `/redfish/v1/Systems/Self/EthernetInterfaces?$expand=.`
- `/redfish/v1/UpdateService/FirmwareInventory?$expand=.` as the BIOS fallback

The BMC firmware may need several seconds for each endpoint. The dashboard
shows progress while the requests run sequentially.

## Raw TCP bridge

Configure PuTTY as:

```text
Connection type: Raw
Host:            ESP32-IP
Port:            2323
```

After connecting, send:

```text
AUTH your-gateway-password
```

The response must be:

```text
OK
```

The connection then becomes a transparent BMC UART session. The gateway
normalizes PuTTY `CR+LF` input to one carriage return so Enter is executed only
once.

Netcat works as well:

```bash
nc ESP32-IP 2323
```

The TCP gateway password is the password created during first-boot setup, not
the BMC/IPMI password.

## OTA update

The build creates:

```text
build/mj11_uart_gateway.bin
build/mj11_uart_gateway-vX.Y.Z.bin
```

`X.Y.Z` comes from `PROJECT_VER` in `CMakeLists.txt`. Use the versioned
application image in the browser's **OTA firmware** control. Do not upload the
bootloader, partition table, OTA metadata or a merged full-flash image.

After a successful upload, the ESP32 switches to the other OTA slot, restarts
and the browser reloads automatically. Initial installation and recovery from
a firmware that no longer boots still require USB.

## Reset the gateway account

Erasing NVS removes the gateway account and all other ESP32 NVS data:

```powershell
idf.py -B "C:\tmp\mj11-idf60" -p COM5 erase-flash
idf.py -B "C:\tmp\mj11-idf60" -p COM5 flash
```

A normal flash or OTA update keeps the account.

## Project check

CI copies `main/config.example.h` to `main/config.h`, runs:

```bash
python3 test_project.py
idf.py set-target esp32
idf.py build
```

and compiles the project with ESP-IDF 5.5.4 and 6.0.2. It does not publish a
firmware binary because Wi-Fi configuration is board-specific.

## Possible extensions

Useful future additions include:

- browser-based NVS configuration with a protected factory reset
- temporary setup access point
- mDNS hostname
- persistent flash logs with wear limits
- signed OTA images and secure boot
- automatic OTA rollback confirmation
- TLS for the gateway interfaces
- BMC certificate pinning
- configurable UART baud rate in the web UI
- UART timestamping, filtering and search
- authenticated MQTT, syslog or webhook alerts
- electrically isolated GPIO control for power or reset

Do not connect ESP32 GPIOs directly to power, reset or other motherboard
signals before their voltage, polarity and electrical requirements have been
verified.
