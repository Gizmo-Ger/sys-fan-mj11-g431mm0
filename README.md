# sys-fan-mj11-g431mm0

Unlocking `SYS_FAN` sensors (and setting up custom fan curves) on Gigabyte
MJ11-EC1 baseboards shipped inside G431-MM0-family chassis, where the BMC
firmware gates fan presence-detection on the reported product identity.

Credit to Oliver Obenland and PeterF, who independently wrote up the
underlying issue (unclear who found it first):
- https://oliver.obenland.it/gigabyte-mj11-ec1-alle-luefter-per-pwm-steuern/
- https://forums.servethehome.com/index.php?threads/gigabyte-mj11-ec1-epyc-3151-mystery.41395/post-407547

## Files

- **[SYS_FAN_HOWTO.md](SYS_FAN_HOWTO.md)** — the full writeup: root cause, all
  gotchas, both the SSH and no-SSH paths, and fan-curve tuning.
- **[QUICKSTART.md](QUICKSTART.md)** — condensed, command-first version: just
  the steps and expected output.
- **[build_sku_bin.sh](build_sku_bin.sh)** — automates the no-SSH path:
  extracts `SKU.xml` from a config backup, applies your identity edit,
  extracts and runs the BMC's own `bmcprog` compiler under `qemu-arm`
  emulation, and outputs a ready-to-flash `SKU.BIN`. Run in a disposable VM.

## Quick summary

The BMC ties `SYS_FAN` presence-detection to the board's reported
`ProductName` (e.g. `G431-MM0-OT`), not to actual wiring. Changing it to a
hardware-compatible sibling SKU (e.g. `MJ11-EC0-00`) unlocks the sensors as a
side effect. See `SYS_FAN_HOWTO.md` for the full explanation and
`QUICKSTART.md` to just get it done.
