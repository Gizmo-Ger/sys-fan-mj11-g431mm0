# ESP32 MJ11 BMC UART gateway — quick start

The source project in [`esp32-mj11-uart-gateway/`](esp32-mj11-uart-gateway/)
turns a 30-pin ESP32 DevKit V1 into a Wi-Fi gateway for the MJ11 BMC console.
It provides a browser terminal, a raw TCP bridge on port 2323, OTA updates,
a 32 KB RAM log and a Redfish status dashboard. The bilingual web UI also
shows ESP32 status values, offers protected UART and ESP32 system-log
downloads, and reloads automatically after a successful OTA update.

## Wiring

Verify the service header and its voltage before connecting it. ESP32 GPIOs
accept **3.3 V TTL only** — not 5 V TTL and not RS-232.

| MJ11 BMC header | ESP32 DevKit V1 |
| --- | --- |
| TX | RX2 / GPIO16 |
| RX | TX2 / GPIO17 |
| GND | GND |
| VCC | **do not connect** |

In the commonly circulated photo orientation, the corrected signal sequence
is `GND | TX | RX | VCC`; that photo incorrectly labels both outer pins as
GND. Do not infer the physical orientation from text or a photo alone.
Identify GND by continuity to a known ground point and verify the remaining
pin voltages before wiring.

Power the ESP32 through USB or a suitable regulated 5 V supply. Never power it
from the header's unknown VCC pin.

## Configure

Copy the example before building:

```powershell
Copy-Item .\esp32-mj11-uart-gateway\main\config.example.h `
  .\esp32-mj11-uart-gateway\main\config.h
notepad .\esp32-mj11-uart-gateway\main\config.h
```

Set the Wi-Fi SSID, Wi-Fi password and hostname. UART defaults to 115200 8N1
on GPIO16/GPIO17. `config.h` is ignored by Git and must never be committed.
The gateway account is created in the browser on first boot.

## Build and flash on Windows

ESP-IDF 6.0.2 is the recommended local build environment. Install it with the
Espressif Installation Manager, include the `esp32` target, then choose
**Manage Installations → ESP-IDF v6.0.2 → Open IDF Terminal**. Verify the
activated terminal:

```powershell
idf.py --version
```

The result should be `ESP-IDF v6.0.2`. Do not mix an IDF 5.5 environment with
an IDF 6.0.2 source tree or reuse a build directory created by another IDF
version.

From the repository root, use a short build path to avoid Windows path-length
problems:

```powershell
Set-Location .\esp32-mj11-uart-gateway
idf.py -B "C:\tmp\mj11-build" set-target esp32
idf.py -B "C:\tmp\mj11-build" build
idf.py -B "C:\tmp\mj11-build" -p COM5 flash monitor
```

Replace `COM5` if necessary. Leave the monitor with `Ctrl+]`. If the compiler
is missing, add the classic `esp32` target to the selected Installation Manager
installation and open a new IDF terminal.

## Build and flash on Ubuntu

After installing and activating ESP-IDF 6.0.2:

```bash
cd esp32-mj11-uart-gateway
cp main/config.example.h main/config.h
nano main/config.h
idf.py set-target esp32
idf.py build
idf.py -p /dev/serial/by-id/YOUR_CP210X_DEVICE flash monitor
```

The complete ESP-IDF installation instructions are in the
[firmware guide](esp32-mj11-uart-gateway/docs/FIRMWARE-GUIDE.md).

## Connect

Open `http://ESP32-IP/`. On first boot, create the gateway account. The browser
then uses that account for HTTP Basic authentication, protecting the web UI,
WebSocket, OTA and downloads. The same gateway password protects the raw TCP
bridge.

The **Overview** page accepts the BMC IP address and separate Redfish
credentials. They are kept in RAM only and must be entered again after an
ESP32 restart. A failed HTTP 401 login clears them automatically. The dashboard
shows the board model, BIOS and BMC firmware, BMC network, detected host NICs,
temperatures, fan speeds, voltages and power data exposed by this MJ11
firmware.

For PuTTY choose **Raw**, enter the ESP32 IP and port **2323**, then send:

```text
AUTH your-gateway-password
```

After `OK`, the connection is a transparent UART bridge. Keep the gateway on
a trusted management network: HTTP, WebSocket and TCP traffic are not protected
by TLS. Redfish uses HTTPS, but the firmware does not verify the BMC's
self-signed certificate, so it does not protect against an active attacker in
the management network.

The web header shows Wi-Fi signal strength, uptime, heap usage, connected
clients, UART counters and RAM-log usage. Use **Download UART log** for the
32 KB console history and **Download ESP32 system log** for the latest 8 KB of
Wi-Fi, TLS and HTTP diagnostics.

## CI policy

GitHub Actions builds the example configuration with ESP-IDF 5.5.4 and 6.0.2
as compile checks. It does **not** upload or publish a firmware binary. Build
your board-specific image locally after creating `main/config.h`.
