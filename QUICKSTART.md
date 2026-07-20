# SYS_FAN Fix — Quickstart

Practical companion to `SYS_FAN_HOWTO.md` (that one has the full why; this one
is just the commands). For Gigabyte MJ11-EC1/G431-MM0-family boards with BMC
SSH disabled.

Credit to PeterF (ServeTheHome, Jan 2024, plus a follow-up on the SSH-lockout
problem in Apr 2024) and Oliver Obenland (Feb 2024, independently), who
documented the underlying identity-gating issue:
https://forums.servethehome.com/index.php?threads/gigabyte-mj11-ec1-epyc-3151-mystery.41395/post-407547
https://forums.servethehome.com/index.php?threads/gigabyte-mj11-ec1-epyc-3151-mystery.41395/post-424378
https://oliver.obenland.it/gigabyte-mj11-ec1-alle-luefter-per-pwm-steuern/

## What you need before starting

| Thing | How to get it | Notes |
|---|---|---|
| `bmc_full_dump.bin` | `./gigaflash_x64 -dump bmc_full_dump.bin`, run on the host with KCS access to the target BMC | ~64MB. No SSH needed — read-only, but don't interrupt it (see gotcha below) |
| `bmc_config_backup.bin` | `./gigaflash_x64 -backup bmc_config_backup.bin`, same host | ~2MB, contains `SKU.xml` |
| A disposable Linux VM | any Debian/Ubuntu, x86_64 | do NOT do this on the hypervisor itself |

**Gotcha**: if a `-dump`/`-backup` gets interrupted (SSH/console session
drops), the BMC can wedge and strand the host at fans-spinning/no-POST even
though nothing was written. Fix: full AC power removal (unplug PSU, wait 60s,
replug) — not just a reboot. Let dumps run to completion; don't background or
disconnect mid-run.

## Step 1 — compile (on the disposable VM)

The script extracts `SKU.xml` from `bmc_config_backup.bin`, applies the
identity edit, then compiles it — all in one command. It never touches
`BoardSerialNumber`, `ProductSerialNumber`, or `MacAddr0` (this board's real,
unique identity) regardless of what you pass, and hard-aborts if that ever
changed unexpectedly.

```sh
scp bmc_full_dump.bin bmc_config_backup.bin build_sku_bin.sh you@disposable-vm:~/
ssh you@disposable-vm
./build_sku_bin.sh . --product-name MJ11-EC0-00 --fan-profile MJ11
```

It'll print a diff of exactly what's changing and ask you to confirm before
compiling (skip the prompt with `--yes` for non-interactive/scripted runs).

Already have a hand-edited `SKU.xml`? Drop it in the same folder instead of
`bmc_config_backup.bin` — the script uses it as-is and skips the
extract/edit step entirely (no `--product-name`/`--fan-profile` needed then).

Expected output (abbreviated):
```
==> Checking inputs
    dump: ./bmc_full_dump.bin (67108864 bytes)
==> Checking dependencies
==> Extracting SKU.xml from ./bmc_config_backup.bin
    JFFS2 filesystem starts at offset 65536
    found: /tmp/.../BMC1/wolfpass/SKU.xml
==> Applying identity edit
    ProductName -> MJ11-EC0-00
    FanProfile  -> MJ11
==> Diff (identity fields only — everything else, including serials/MACs, is untouched)
    ProductName: ['G431-MM0-OT', 'G431-MM0-OT'] -> ['MJ11-EC0-00', 'MJ11-EC0-00'] *** CHANGED ***
    BoardProductName: ['MJ11-EC1-OT', 'MJ11-EC1-OT'] -> ['MJ11-EC1-OT', 'MJ11-EC1-OT']
    FanProfile: ['G431_MM0'] -> ['MJ11'] *** CHANGED ***
    BoardSerialNumber: ['AB1U9988776', '...'] -> ['AB1U9988776', '...']
    ProductSerialNumber: ['GXY9U1234B567', '...'] -> ['GXY9U1234B567', '...']
    MacAddr0: ['AA:11:BB:22:CC:33', 'AA:11:BB:22:CC:34'] -> ['AA:11:BB:22:CC:33', 'AA:11:BB:22:CC:34']
Proceed with compiling this SKU.xml? [y/N] y
==> Locating cramfs partitions in firmware dump
    found 2 cramfs partition(s)
==> Extracting bmcprog
    trying partition at offset 5636096, size 41058304 bytes
    bmcprog extracted: ELF 32-bit LSB executable, ARM, EABI5 ... statically linked
==> Compiling SKU.BIN
bmcprog.exe Version 0.22
...
              Board ID     : 0x100a
             Rand Code     : <matches your board's RandCode>
==> Validating output
    OK: 1664 bytes, header valid, embedded XML decompresses (NNNN bytes)

SUCCESS: ./sku_build/SKU.BIN
```

If it stops at "no cramfs partitions found" — this board/firmware uses a
different filesystem for its rootfs (squashfs/ubifs); the script needs a new
extraction branch, ask for one rather than improvising blind.

If it stops at "bmcprog not found" — the binary may live at a different path
on this firmware version; `sudo mount -t cramfs -o loop <slice> /mnt` each
found partition manually and `find /mnt -iname bmcprog` to locate it, then
adjust the script's path.

If it stops at "SKU.xml not found inside extracted config partition" —
`jefferson` failed to parse the JFFS2 image; inspect the extracted directory
path printed just before the error manually.

## Step 2 — deploy

```sh
scp sku_build/SKU.BIN gigaflash_x64 you@target-host:~/
ssh you@target-host
./gigaflash_x64 SKU.BIN -sku -2500
```

Expect 1-3 minutes of BMC unavailability while it resets to apply — this is
normal, don't interrupt or re-run. The host itself (Proxmox, VMs) stays up;
the BMC is a separate controller.

## Step 3 — verify (Redfish, no BMC shell needed)

```sh
curl -k -u admin:<password> https://<bmc-ip>/redfish/v1/Systems/Self
curl -k -u admin:<password> https://<bmc-ip>/redfish/v1/Chassis/Self/Thermal
```

Expected:
- `Model` reads your new `ProductName` string.
- `Thermal.Fans[]` shows the previously-`Absent` fans now
  `"Status":{"State":"Enabled"}` with real RPM readings.

## Rollback

Keep `bmc_full_dump.bin` / `bmc_config_backup.bin` from *before* you started.
To revert: rerun Step 1 pointing `--product-name`/`--fan-profile` back at the
**original** values (or just drop the original config backup back in with no
flags, so the script uses its unedited `SKU.xml` as-is), then `-sku` it back
(Step 2). Proven bidirectional.
