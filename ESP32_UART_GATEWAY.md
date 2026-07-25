# ESP32 MJ11 BMC UART gateway — quick start

The source project in [`esp32-mj11-uart-gateway/`](esp32-mj11-uart-gateway/)
turns a 30-pin ESP32 DevKit V1 into a Wi-Fi gateway for the MJ11 BMC console.
It provides a browser terminal, a raw TCP bridge on port 2323, OTA updates,
a 32 KB RAM log and a Redfish status dashboard.

## Wiring

Verify the service header and its voltage before connecting it. ESP32 GPIOs
accept **3.3 V TTL only** — not 5 V TTL and not RS-232.

| MJ11 BMC header | ESP32 DevKit V1 |
| --- | --- |
| TX | RX2 / GPIO16 |
| RX | TX2 / GPIO17 |
| GND | GND |
| VCC | **do not connect** |

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

Open the ESP-IDF 5.5 PowerShell, or activate an existing installation:

```powershell
$env:Path = "C:\Users\shs\.espressif\python_env\idf5.5_py3.14_env\Scripts;$env:Path"
. "D:\esp\esp-idf\export.ps1"
idf.py --version
```

From the repository root, use a short build path to avoid Windows path-length
problems:

```powershell
Set-Location .\esp32-mj11-uart-gateway
idf.py -B "C:\tmp\mj11-build" set-target esp32
idf.py -B "C:\tmp\mj11-build" build
idf.py -B "C:\tmp\mj11-build" -p COM5 flash monitor
```

Replace `COM5` if necessary. Leave the monitor with `Ctrl+]`. If the compiler
is missing, install the ESP32 toolchain once with `D:\esp\esp-idf\install.ps1
esp32`, then open a new ESP-IDF shell.

## Build and flash on Ubuntu

After installing and activating ESP-IDF 5.5.4:

```bash
cd esp32-mj11-uart-gateway
cp main/config.example.h main/config.h
nano main/config.h
idf.py set-target esp32
idf.py build
idf.py -p /dev/serial/by-id/YOUR_CP210X_DEVICE flash monitor
```

The complete ESP-IDF installation instructions are in the
[firmware guide](esp32-mj11-uart-gateway/docs/FIRMWARE-ANLEITUNG.md).

## Connect

Open `http://ESP32-IP/`, create the gateway account and use the web terminal.
For PuTTY choose **Raw**, enter the ESP32 IP and port **2323**, then send:

```text
AUTH your-gateway-password
```

After `OK`, the connection is a transparent UART bridge. Keep the gateway on
a trusted management network: HTTP, WebSocket and TCP traffic are not protected
by TLS.

## CI policy

GitHub Actions builds the example configuration as a compile check. It does
**not** upload or publish a firmware binary. Build your board-specific image
locally after creating `main/config.h`.
