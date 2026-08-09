# sys-fan-mj11-g431mm0

Unlocking `SYS_FAN` sensors (and setting up custom fan curves) on Gigabyte
MJ11-EC1 baseboards shipped inside G431-MM0-family chassis, where the BMC
firmware gates fan presence-detection on the reported product identity.

Credit to PeterF, who first documented the underlying issue on ServeTheHome
(January 2024) and later explored the SSH-lockout problem on newer firmware
(April 2024), and Oliver Obenland, who wrote it up independently
(February 2024):
- https://forums.servethehome.com/index.php?threads/gigabyte-mj11-ec1-epyc-3151-mystery.41395/post-407547
- https://forums.servethehome.com/index.php?threads/gigabyte-mj11-ec1-epyc-3151-mystery.41395/post-424378
- https://oliver.obenland.it/gigabyte-mj11-ec1-alle-luefter-per-pwm-steuern/

## Files

- **[SYS_FAN_HOWTO.md](SYS_FAN_HOWTO.md)** — the full writeup: root cause, all
  gotchas, both the SSH and no-SSH paths, and fan-curve tuning.
- **[QUICKSTART.md](QUICKSTART.md)** — condensed, command-first version: just
  the steps and expected output.
- **[build_sku_bin.sh](build_sku_bin.sh)** — automates the no-SSH path:
  extracts `SKU.xml` from a config backup, applies your identity edit,
  extracts and runs the BMC's own `bmcprog` compiler under `qemu-arm`
  emulation, and outputs a ready-to-flash `SKU.BIN`. Run in a disposable VM.
- **[ESP32_UART_GATEWAY.md](ESP32_UART_GATEWAY.md)** — short wiring, build,
  flash and connection guide for the wireless BMC UART gateway.
- **[esp32-mj11-uart-gateway/](esp32-mj11-uart-gateway/)** — ESP-IDF 5.5.4
  source for the ESP32 DevKit V1 gateway. GitHub Actions compiles it as a
  check but deliberately does not publish a firmware binary.

## Quick summary

The BMC ties `SYS_FAN` presence-detection to the board's reported
`ProductName` (e.g. `G431-MM0-OT`), not to actual wiring. Changing it to a
hardware-compatible sibling SKU (e.g. `MJ11-EC0-00`) unlocks the sensors as a
side effect. See `SYS_FAN_HOWTO.md` for the full explanation and
`QUICKSTART.md` to just get it done.

## Fan PWM/RPM calibration tool

- **[Calibrate-FanCurve.ps1](Calibrate-FanCurve.ps1)** — sweeps PWM duty per
  fan zone (CPU / System) on the BMC and records the resulting RPM to a CSV,
  using an isolated `calibration` fan-profile collection so it never touches
  the live `default`/`quiet` profiles.

### Required parameters

**`-BmcHost` (required)** — The IP address or hostname of the target BMC. The
tool is now generalized to any BMC, not bound to a single IP. Zone
configuration is saved and reused per BMC instance.

### One-time setup on a fresh BMC

The `calibration` fan-profile collection must exist before the script's API
calls will succeed. Create it once with this POST request:

```
POST /api/settings/fanprofile/collection
Content-Type: application/json
{"strName":"calibration","strVersion":"1.00","arrPolicy":[]}
```

Use your logged-in browser session's cookie + X-CSRFTOKEN header. The script's
preflight check will fail fast with an explicit error if this collection is
missing, rather than silently failing mid-sweep.

### Zone configuration and `-NewDevice`

On the first run against a new BMC (or any BMC without a saved zone config),
the script launches an interactive wizard to map fan sensors to PWM lines and
temp sensors. Zone configuration is then saved to `bmc-zones-<host>.json`
(gitignored) and reused automatically on all subsequent runs.

**`-NewDevice` (switch)** — Force the zone wizard to run again, discarding the
saved config. Use this after swapping hardware (fans, temp sensors) or when
reconfiguring fan zones. Without this flag, the saved config is always
preferred.

## Open question — help wanted

The `sysadmin` SSH lockout on newer firmware looks like it might be just a
`DenyUsers sysadmin` line in a config file, not an actually-disabled account
— unverified, see "Open questions" in `SYS_FAN_HOWTO.md`. If you have SSH
still open on your board and want to test it, open an issue.
