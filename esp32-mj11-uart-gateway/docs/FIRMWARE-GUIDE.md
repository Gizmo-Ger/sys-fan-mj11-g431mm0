# Building the ESP32 Firmware: MJ11 BMC UART Gateway

This guide covers the complete process from installing ESP-IDF to flashing,
testing and maintaining the ESP32 MJ11 BMC UART gateway.

## 1. Architecture and result

```text
Browser/WebSocket ─┐
                   ├── ESP32 UART2 ── MJ11 BMC UART
PuTTY/Raw TCP 2323 ┘

Browser/Redfish dashboard ── ESP32 HTTPS client ── MJ11 BMC Redfish
```

The finished firmware provides:

- Wi-Fi station mode with reconnect
- UART2 on GPIO16/RX2 and GPIO17/TX2
- 115200 baud, 8 data bits, no parity, 1 stop bit
- raw TCP UART bridge on port 2323
- browser terminal over WebSocket
- first-boot gateway account stored as a salted PBKDF2 hash in NVS
- authenticated web UI, WebSocket, OTA and downloads
- password-protected raw TCP bridge
- Redfish dashboard for BIOS, BMC, network, NIC inventory and sensors
- Redfish credentials held only in RAM
- German/English web UI
- firmware version and build time in the header
- ESP32 Wi-Fi, uptime, heap, client, UART and log status
- 32 KB UART RAM ring buffer and download
- 8 KB ESP32 runtime log and download
- two-slot browser OTA update with automatic page reload
- task watchdog on the UART data path

The implementation uses ESP-IDF components only. It has no Arduino framework,
AsyncTCP or third-party web-server dependency.

## 2. Safety and wiring

ESP32 GPIOs accept **3.3 V logic only**. Verify the MJ11 service header before
connecting it.

```text
MJ11 TX  ─────> ESP32 RX2 / GPIO16
MJ11 RX  <───── ESP32 TX2 / GPIO17
MJ11 GND ─────  ESP32 GND
MJ11 VCC        do not connect
```

Important:

- TX and RX must be crossed.
- Power the ESP32 separately through USB or a regulated 5 V supply.
- Leave the MJ11 VCC pin unconnected.
- Do not trust a photo or its viewing direction alone.
- With the board unpowered, find GND by continuity to board ground.
- Apply standby power only after the continuity test.
- Measure DC voltage against the verified GND pin.
- Confirm that TX/RX use 3.3 V TTL levels.
- Never use resistance or continuity mode on a powered board.

In the commonly circulated photo orientation, the corrected sequence is:

```text
GND | TX | RX | VCC
```

The source photo incorrectly labels both outer pins as GND and shows an
MJ11-EC1. Repeat the measurements on an MJ11-EC0 rather than relying solely on
that image. The four-pin connector is used as a UART console even though some
sources call it “JTAG”.

Keep the MJ11 header disconnected for the initial flash and Wi-Fi test.

## 3. Project layout

```text
esp32-mj11-uart-gateway/
├── CMakeLists.txt
├── partitions.csv
├── sdkconfig.defaults
├── test_project.py
├── main/
│   ├── CMakeLists.txt
│   ├── config.example.h
│   ├── config.h
│   ├── index.html
│   ├── setup.html
│   └── main.c
└── docs/
    └── FIRMWARE-GUIDE.md
```

| File | Purpose |
| --- | --- |
| `main/main.c` | Wi-Fi, UART, TCP, HTTP, WebSocket, Redfish, OTA and watchdog |
| `main/index.html` | authenticated terminal, dashboard, status and OTA UI |
| `main/setup.html` | first-boot gateway account setup |
| `main/config.example.h` | public configuration template without credentials |
| `main/config.h` | local Wi-Fi and hardware settings |
| `partitions.csv` | NVS, OTA metadata and two application slots |
| `sdkconfig.defaults` | target defaults, TLS options, watchdog and partition table |
| `test_project.py` | structural and fixed-hardware checks used by CI |

Never publish `main/config.h`, `sdkconfig`, build directories or firmware
images containing private Wi-Fi credentials.

## 4. Install ESP-IDF on Windows

New installations should use ESP-IDF 6.0.2 through the Espressif Installation
Manager:

1. Install the current Espressif Installation Manager.
2. Add ESP-IDF **v6.0.2**.
3. Include the classic **ESP32** target.
4. Select **Manage Installations → v6.0.2 → Open IDF Terminal**.
5. Verify the environment:

```powershell
idf.py --version
```

Expected output:

```text
ESP-IDF v6.0.2
```

An existing ESP-IDF 5.5.4 installation may remain installed because CI checks
both versions. Do not load one version's `export.ps1` into another version's
terminal, and keep separate build directories:

```text
C:\tmp\mj11-idf55
C:\tmp\mj11-idf60
```

Official references:

- [ESP-IDF 6.0.2 installation and getting started](https://docs.espressif.com/projects/esp-idf/en/v6.0.2/esp32/get-started/index.html)
- [ESP-IDF 6.0.2 Windows command line](https://docs.espressif.com/projects/esp-idf/en/v6.0.2/esp32/get-started/windows-start-project.html)

### Avoid long Windows paths

ESP-IDF creates deeply nested object paths. Build outside a long repository
path:

```powershell
$buildDir = "C:\tmp\mj11-idf60"
idf.py -B $buildDir build
```

## 5. Install ESP-IDF on Ubuntu

Install the packages required by ESP-IDF 6.0.2:

```bash
sudo apt update
sudo apt install -y git wget flex bison gperf python3 python3-pip \
  python3-venv cmake ninja-build ccache libffi-dev libssl-dev \
  dfu-util libusb-1.0-0
```

Install and activate ESP-IDF:

```bash
mkdir -p "$HOME/esp"
cd "$HOME/esp"
git clone --recursive --branch v6.0.2 \
  https://github.com/espressif/esp-idf.git
cd esp-idf
./install.sh esp32
. ./export.sh
idf.py --version
```

Activate the same environment in every new shell:

```bash
. "$HOME/esp/esp-idf/export.sh"
```

If the serial port is inaccessible:

```bash
sudo usermod -aG dialout "$USER"
```

Log out and back in after changing group membership.

Official reference:

- [ESP-IDF 6.0.2 Linux installation](https://docs.espressif.com/projects/esp-idf/en/v6.0.2/esp32/get-started/linux-macos-setup-legacy.html)

## 6. Configure the project

Create the private configuration:

### Windows

```powershell
Copy-Item ".\main\config.example.h" ".\main\config.h"
notepad ".\main\config.h"
```

### Ubuntu

```bash
cp main/config.example.h main/config.h
nano main/config.h
```

Configure:

```c
#define GATEWAY_WIFI_SSID       "your-wifi"
#define GATEWAY_WIFI_PASSWORD   "your-wifi-password"
#define GATEWAY_HOSTNAME        "mj11-bmc-console"
#define GATEWAY_UART_BAUD       115200
#define GATEWAY_UART_RX_GPIO    16
#define GATEWAY_UART_TX_GPIO    17
#define GATEWAY_TCP_PORT        2323
```

Keep GPIO16 and GPIO17 for the labelled RX2/TX2 pins on the 30-pin DevKit.
UART0 on GPIO1/GPIO3 remains available to the onboard CP210x.

Do not define the gateway account in this file. It is created interactively on
first boot.

When releasing a new firmware version, update `PROJECT_VER` in the root
`CMakeLists.txt`.

## 7. Select the target and build

### Windows

```powershell
Set-Location "PATH\TO\esp32-mj11-uart-gateway"
$buildDir = "C:\tmp\mj11-idf60"

idf.py -B $buildDir set-target esp32
idf.py -B $buildDir build
```

### Ubuntu

```bash
cd /path/to/esp32-mj11-uart-gateway
BUILD_DIR="$HOME/esp-build/mj11-idf60"

idf.py -B "$BUILD_DIR" set-target esp32
idf.py -B "$BUILD_DIR" build
```

Important output files:

```text
mj11_uart_gateway.bin
mj11_uart_gateway-vX.Y.Z.bin
bootloader/bootloader.bin
partition_table/partition-table.bin
ota_data_initial.bin
```

`X.Y.Z` is taken from `PROJECT_VER`. The versioned file is the browser OTA
image; the unversioned file remains available to ESP-IDF flash tools.

## 8. Flash through USB

Leave the MJ11 UART disconnected.

### Windows

Find the CP210x port:

```powershell
Get-PnpDevice -Class Ports | Select-Object FriendlyName, InstanceId
```

Flash and monitor:

```powershell
idf.py -B "C:\tmp\mj11-idf60" -p COM5 flash monitor
```

### Ubuntu

Use the stable by-id path where available:

```bash
ls -l /dev/serial/by-id/
idf.py -B "$HOME/esp-build/mj11-idf60" \
  -p /dev/serial/by-id/YOUR_CP210X_DEVICE flash monitor
```

Exit the monitor with `Ctrl+]`.

If automatic reset fails, hold **BOOT**, press and release **EN**, start
flashing, and release **BOOT** when writing begins.

## 9. Test without the MJ11

The serial monitor should report a successful Wi-Fi connection, the assigned
IPv4 address and a TCP bridge listening on port 2323.

Open:

```text
http://ESP32-IP/
```

First boot displays account setup. Create a username and a gateway password of
at least 12 characters. Only a salted PBKDF2 hash is stored in NVS. The account
protects the web UI, WebSocket, OTA and downloads. The same password protects
the raw TCP bridge.

After setup, the browser displays an HTTP Basic authentication dialog. The
header shows firmware version, build time and ESP32 status. With the UART
disconnected, the terminal should stay empty.

Browser processes commonly cache HTTP Basic credentials. Reloading the page or
performing OTA therefore does not necessarily display the login dialog again.
Use a private window for an independent authentication test.

## 10. Use the Redfish dashboard

On **Overview**, enter the BMC IPv4 address, BMC username and BMC password.
These credentials remain only in RAM and must be entered again after an ESP32
restart. **Disconnect Redfish** removes them immediately.

Credential submission returns immediately. The first dashboard query validates
the credentials against `/redfish/v1/Systems/Self`. HTTP 401 removes the
credentials automatically.

The MJ11 uses a self-signed HTTPS certificate. Traffic is encrypted, but the
firmware does not verify that certificate. Use Redfish only on a trusted
management network.

The dashboard displays the data exposed by the BMC:

- board model and power state
- BIOS version, including FirmwareInventory fallback
- CPU and memory summary
- BMC firmware, health and time
- BMC address and network data
- detected host NICs
- temperatures and fan speeds
- voltages and power consumption when the associated sensors are enabled

This AMI Redfish version reports host-NIC administrative state and health, but
not the physical link state.

## 11. Connect the MJ11 UART

1. Disconnect power from both devices.
2. Verify the service-header GND pin by continuity.
3. Verify voltage and 3.3 V TTL levels.
4. Leave VCC unconnected.
5. Connect GND, MJ11 TX to RX2 and MJ11 RX to TX2.
6. Power the ESP32 and apply standby power to the MJ11.
7. Open the browser terminal before booting or resetting the BMC.

Expected output includes BMC startup messages followed by a prompt similar to:

```text
AMI... login:
```

The known BMC console account is `sysadmin`; use the password configured in the
BMC/IPMI interface. Treat this console as privileged access.

## 12. Use PuTTY or netcat

PuTTY settings:

```text
Connection type: Raw
Host:            ESP32-IP
Port:            2323
```

Authenticate immediately after connecting:

```text
AUTH your-gateway-password
```

Expected response:

```text
OK
```

After `OK`, the session is a transparent UART bridge. `DENIED` means the
gateway password is wrong or the command format is invalid. Use the first-boot
gateway password, not the IPMI password.

The firmware normalizes PuTTY `CR+LF` input to one carriage return, preventing
commands from being executed twice.

Netcat example:

```bash
nc ESP32-IP 2323
```

## 13. OTA update

Upload only the versioned application image:

```text
C:\tmp\mj11-idf60\mj11_uart_gateway-vX.Y.Z.bin
```

or:

```text
$HOME/esp-build/mj11-idf60/mj11_uart_gateway-vX.Y.Z.bin
```

Do not upload:

- `bootloader.bin`
- `partition-table.bin`
- `ota_data_initial.bin`
- a merged full-flash image

The application is written to the inactive OTA slot and selected as the next
boot partition. After a successful upload, the ESP32 restarts and the page
reloads automatically.

The current firmware does not confirm a healthy boot for automatic rollback.
A valid image that fails at runtime may require recovery through USB.

After OTA:

1. Check the version and build time in the header.
2. Test the WebSocket terminal.
3. Test raw TCP on port 2323.
4. Test BMC login and bidirectional UART.
5. Download the ESP32 system log if anything is slow or fails.

## 14. Logs and ESP32 status

The web header updates every ten seconds and displays:

- Wi-Fi signal strength
- uptime
- free and minimum free heap
- connected TCP and WebSocket clients
- UART baud rate and RX/TX byte counters
- UART ring-buffer use and collapsed-line count

**Download UART log** returns the current 32 KB RAM history. Consecutive
identical complete lines are collapsed in the download to avoid repetitive BMC
messages filling the buffer. Live WebSocket and TCP clients still receive every
UART byte.

**Download ESP32 system log** returns the latest 8 KB of ESP-IDF runtime
messages, including Wi-Fi connection, assigned address, HTTP/TLS errors,
Redfish endpoint status and request times. Both logs are RAM-only and restart
empty after an ESP32 reset.

## 15. Troubleshooting

### `idf.py` is not found

The ESP-IDF environment is not active.

- Windows: open **IDF Terminal** for v6.0.2 in the Installation Manager.
- Ubuntu:

  ```bash
  . "$HOME/esp/esp-idf/export.sh"
  ```

### The compiler is missing from PATH

The selected installation may not include the classic ESP32 toolchain, or an
IDF environment may have been mixed with another source tree. Add the `esp32`
target in the Installation Manager and open a new IDF terminal.

### Windows warns about long object paths

Use a short build path:

```powershell
idf.py -B "C:\tmp\mj11-idf60" build
```

### The build directory is not a valid CMake directory

Do not reuse the damaged directory. Choose a new short directory such as:

```powershell
idf.py -B "C:\tmp\mj11-idf60-new" set-target esp32
idf.py -B "C:\tmp\mj11-idf60-new" build
```

### Flashing remains at `Connecting...`

Check the COM port and USB cable, close other serial programs, and use the BOOT
and EN sequence described in the flashing section.

### The web terminal displays replacement characters

If the MJ11 is not connected, check that GPIO16/RX2 is not floating and that
the hardened build with its pull-up is installed. If connected, verify common
ground, crossed TX/RX and 115200 8N1.

### PuTTY returns `DENIED`

Send exactly:

```text
AUTH your-gateway-password
```

Use a Raw connection rather than Telnet. The password is the gateway password,
not the BMC password.

### Enter is executed twice

Use a current firmware. It normalizes PuTTY's `CR+LF` line ending to one
carriage return.

### The browser does not request credentials after OTA

This is normal HTTP Basic credential caching. Verify the firmware version in
the header, use `Ctrl+F5`, close the browser completely or open a private
window.

### The gateway password is lost

Erase the flash and install the firmware again:

```powershell
idf.py -B "C:\tmp\mj11-idf60" -p COM5 erase-flash
idf.py -B "C:\tmp\mj11-idf60" -p COM5 flash
```

This removes all NVS data. Normal flashing and OTA preserve the account.

### Redfish is slow or fails

Download the ESP32 system log. It records endpoint duration, HTTP status and
ESP-IDF transport errors. Check BMC reachability and Wi-Fi signal strength.
The dashboard performs multiple sequential BMC requests, so the complete page
can take several seconds even when each request succeeds.

## 16. Release checklist

Before releasing a build:

- update `PROJECT_VER`
- keep real credentials out of source control
- build with a clean IDF-specific build directory
- verify the header voltage and wiring
- test without the MJ11 first
- test browser and raw TCP UART in both directions
- test Wi-Fi disconnect and reconnect
- test OTA from the previous release
- confirm the new version in the web header
- archive the application image and SHA-256 checksum

Windows checksum:

```powershell
Get-FileHash "C:\tmp\mj11-idf60\mj11_uart_gateway-vX.Y.Z.bin" `
  -Algorithm SHA256
```

Ubuntu checksum:

```bash
sha256sum "$HOME/esp-build/mj11-idf60/mj11_uart_gateway-vX.Y.Z.bin"
```

## 17. Possible extensions

### Configuration and access

- NVS configuration for Wi-Fi, hostname and UART baud rate
- protected factory reset
- temporary setup access point
- mDNS hostname

### Security and OTA

- HTTPS and secure WebSocket for the gateway
- encrypted raw TCP or SSH transport
- BMC certificate pinning or a trusted CA
- signed images and secure boot
- OTA healthy-boot confirmation and rollback
- configurable session expiry and rate limiting

### Terminal and diagnostics

- persistent flash or SD-card logs with wear limits
- timestamps, filtering, search and bookmarks
- dropped-byte counters
- authenticated MQTT, syslog or webhook alerts
- BMC boot-pattern detection

### Hardware control

- electrically isolated power or reset control
- controlled BMC reset only when the board circuitry is verified

Never drive motherboard signals directly from an ESP32 GPIO without first
checking voltage, polarity, current and the need for isolation.
