# Enabling SYS_FAN Sensors on Gigabyte MJ11-EC1/G431-MM0 BMC

**Platform:** AMI MegaRAC, ASPEED AST2500

Credit to Oliver Obenland, who first identified and wrote up the underlying
identity-gating issue on this board:
https://oliver.obenland.it/gigabyte-mj11-ec1-alle-luefter-per-pwm-steuern/

## Background

Gigabyte's MJ11-EC1 baseboard ships inside the G431-MM0 GPU mining chassis under a different reported product identity (`G431-MM0-OT`) than its real board model (`MJ11-EC1-OT`).

The BMC firmware ties fan **presence detection** for the two or three onboard `SYS_FAN` headers to this reported product identity. Under the `G431-MM0-OT` identity, the `SYS_FAN` sensors report `Absent` over IPMI/Redfish even when fans are physically connected and spinning. Only `CPU_FAN` works normally.

This is not a wiring issue and is not caused by the active fan-profile *content*. The default profile already references the correct fan sensor IDs. It is purely identity-gated firmware behavior.

### Fix

Change the BMC's reported product identity from `G431-MM0-OT` to a different but hardware-compatible SKU string, such as `MJ11-EC0-00`, which belongs to a sibling board in the same family. Then update `FanPolicy/FanProfile` to a matching profile.

This unlocks presence detection for `SYS_FAN1` and `SYS_FAN2` and, as a side effect, several other suppressed sensors:

- `VR_P0_TEMP`
- `VR_DIMMG0_TEMP`
- `MB_TEMP`

The identity swap was confirmed by A/B testing on spare hardware. The change alone is both necessary and sufficient, and it is reversible in both directions.

## Where the identity lives

The relevant file is:

```text
/conf/BMC1/wolfpass/SKU.xml
```

It resides on a JFFS2-backed 2 MB partition at flash offset `0x50000`, with a size of `0x200000`.

The file contains `FRU` and `PROJECT` sections. Each section includes:

- `BoardProductName`: the real board model
- `ProductName`: the marketing or chassis SKU

It also contains `FanPolicy/FanProfile`, which selects a JSON fan-curve file from:

```text
/etc/FanProfile/*.json
```

## Gigaflash modes and critical caveats

Gigabyte's `gigaflash` utility ships as an `.efi` binary for the UEFI shell and as Linux and Windows binaries. It has four relevant modes:

- `-dump`
- `-backup`
- `-restore`
- `-sku`

The syntax below comes from the binary's own usage strings. Do not guess the flags: selector flags such as `-bmc` or `-bios` do **not** exist.

```text
./gigaflash <-dump> <output file>
./gigaflash <-backup> <output file>
./gigaflash <-restore> <input file>
./gigaflash <bin> <-sku> <-2500> <-wt> <wait time> <-no-reboot> <-cs> <bmc address>
```

Only `-sku` accepts a remote target through `-cs <bmc address>`.

The `-dump`, `-backup`, and `-restore` modes communicate only with the **local** BMC through KCS. They must therefore run on the host itself, such as the Proxmox host, and not from a separate workstation over the network.

### Caveat: an interrupted `-dump` can temporarily wedge the BMC

This was observed on production hardware. A `-dump` operation was interrupted by a console or session drop during the read. It was not a software crash. Afterward:

- the BMC was unreachable;
- the host remained at fans-spinning/no-POST/no-video.

The AST2500 BMC gates host power sequencing through signals such as `PS_ON` and power-good. A wedged BMC can therefore strand the host before POST even though nothing was written to flash.

A `-dump` operation is read-only and cannot corrupt the flash.

**Recovery:** remove AC power completely. Unplug the PSU cable or cables, wait 60 seconds for the standby rail to discharge, and reconnect power. A host reset or normal power-button cycle is insufficient because the BMC remains powered by the standby rail.

The board returned normally on the next boot. Repeating `-dump` to completion confirmed that the interrupted session, not the read itself, caused the problem.

### Behavior of `-backup` and `-restore`

```text
-backup <file>
-restore <file>
```

These modes operate on the raw 2 MB configuration partition.

`-restore` deliberately does **not** modify FRU/SKU identity data. It may report success and correctly restore other settings, including:

- network configuration;
- users;
- the Redis-backed fan-profile selector.

This is likely an intentional safety feature to prevent a generic settings restore from cloning one board's identity onto another.

> **Do not use `-restore` to change the board identity.** It silently leaves that part unchanged. This was confirmed on both spare and production hardware.

### Behavior of `-sku`

```text
<SKU.BIN> -sku -2500
```

This is the only mode that actually writes FRU/SKU identity data.

It requires a **compiled `SKU.BIN`**, not raw XML. The file is produced by the BMC-side tool `bmcprog`.

Tests on spare hardware confirmed that this method can switch the identity in both directions, broken to fixed and fixed to broken, with the corresponding change in fan presence detection each time.

## Path A: BMC shell access through SSH

This method works when the installed BMC firmware still permits SSH login. Older firmware generally allows this; newer Gigabyte firmware, such as version `126139`, disables it.

Run the following commands on the BMC itself:

```sh
cd /tmp
cp /conf/BMC1/wolfpass/SKU.xml /tmp/SKU.xml
cp SKU.xml SKU.xml.bak

sed -i 's/<old-ProductName>/<new-ProductName>/g' SKU.xml
sed -i 's/<old-BoardProductName>/<new-BoardProductName>/g' SKU.xml
sed -i 's/<old-FanProfile>/<new-FanProfile>/g' SKU.xml

bmcprog WS=FULL_AREA   # Compiles SKU.BIN from SKU.xml
skurw w flash SKU.BIN  # Writes SKU.BIN to flash
rm SKU.xml
skupioneer             # Regenerates FRU, SDR, and Redis state
reboot                 # A full reboot is required
```

### Verification

On the BMC:

```sh
skuinfo
cat /conf/BMC1/wolfpass/SKU.xml
```

From any workstation, query the Redfish thermal endpoint:

```sh
curl -k -u 'admin:<password>' \
  'https://<bmc-ip>/redfish/v1/Chassis/Self/Thermal'
```

Check `SYS_FAN1` and `SYS_FAN2`, or `SYS_FAN_1`, `SYS_FAN_2`, and `SYS_FAN_3`, depending on the selected identity.

The expected state is:

```text
Status.State = Enabled
```

## Path B: no BMC shell access

This applies to newer firmware with SSH disabled.

Run `-sku` from the host side instead, either from the UEFI shell or with Linux `gigaflash_x64` on a live host OS connected to the BMC management interface. The Linux method does not require a host reboot.

The problem is that `-sku` requires a compiled `SKU.BIN`, while `bmcprog` is a BMC-side ARM utility with no supplied host-side equivalent.

There are two ways around this.

### Option 1: compile on another board of the same family

When shell access is available on any compatible board, such as a spare unit:

1. Compile the target `SKU.BIN` there with `bmcprog`.
2. Transfer it from the BMC.
3. Write it to the shell-less board with `-sku`.

Stripped BMC BusyBox environments may not provide `scp` or `base64`. In that case, transfer the file as hexadecimal and decode it locally, for example:

```sh
hexdump -v -e '1/1 "%02x"' file | ssh ...
```

### Option 2: extract and run `bmcprog` under ARM emulation

This method requires no SSH access to any BMC.

`bmcprog` does not have to run on an actual BMC. It only needs a compatible ARM execution environment. Extract it from an existing full firmware dump and execute it through QEMU user-mode emulation.

#### 1. Dump the full BMC firmware

Create a full firmware dump of approximately 64 MB. The image contains one or more `cramfs` partitions.

Detect a `cramfs` superblock by its magic bytes:

```text
45 3d cd 28
```

The four-byte field immediately after the magic contains the partition size in bytes. Use that value to extract an exact-size slice with `dd`; do not guess the partition size.

#### 2. Work in a disposable VM

Do the extraction and emulation work in a disposable VM, not on the production hypervisor. This avoids mounting an unfamiliar filesystem or running an unverified foreign-architecture binary on the machine hosting the actual VMs.

```sh
sudo modprobe cramfs
sudo mount -t cramfs -o loop rootfs_main.cramfs /mnt/rootfs_main

find /mnt/rootfs_main \
  -iname '*bmcprog*' -o \
  -iname '*skurw*' -o \
  -iname '*skupioneer*'

# Expected files include:
# /usr/local/bin/bmcprog
# /usr/local/bin/skurw
# /usr/local/bin/skupioneer
# /usr/local/bin/skuinfo

file /mnt/rootfs_main/usr/local/bin/bmcprog
```

Expected result:

```text
ELF 32-bit ARM, statically linked
```

The static build is important because it does not require reproducing the BMC's shared-library environment.

#### 3. Run `bmcprog` with QEMU

On newer Ubuntu or Debian releases, the package containing the `qemu-arm` binary is named `qemu-user`. The older name `qemu-user-static` may now be a virtual package pointing to `qemu-user-binfmt`.

```sh
cp /mnt/rootfs_main/usr/local/bin/bmcprog ~/bmcprog
cd ~
cp /path/to/edited/SKU.xml ./SKU.xml
qemu-arm ~/bmcprog WS=FULL_AREA
```

The input file must be named exactly `SKU.xml` and must be present in the current working directory.

For this board family, the expected output is:

```text
./SKU.BIN
```

with a size of 1664 bytes.

#### 4. Validate the compiled file

Before using the result, compare its size and header with a known-good sample such as:

```text
dumps/SKU_known_good.BIN
```

The source XML is embedded in gzip form in this board family's `SKU.BIN`. The gzip data begins at offset `0x200` and starts with the magic bytes `1f 8b`.

Use the following check:

```python
import gzip

with open("SKU.BIN", "rb") as file:
    data = file.read()

xml = gzip.decompress(data[0x200:]).decode()
print(xml)
```

Confirm that the decompressed XML contains the intended changes.

This method is preferable to reverse-engineering the binary format manually. It uses the original compiler and avoids the risk of generating a subtly invalid hand-built file.

### Write `SKU.BIN`

From the UEFI shell:

```text
gigaflash.efi <path-to-SKU.BIN> -sku -2500
```

From a live Linux host:

```sh
./gigaflash_x64 <path-to-SKU.BIN> -sku -2500
```

The Linux method does not require a host reboot.

## Always back up first

Before changing anything, create both a full firmware dump and a configuration backup:

```text
gigaflash.efi -dump bmc_full_dump.bin
# Approximately 64 MB; full firmware, maximum rollback option

gigaflash.efi -backup bmc_config.bin
# Approximately 2 MB; configuration partition
```

Create two copies of each and compare their hashes.

Static BIOS or flash-chip content should match byte for byte. Live BMC dumps may differ because SEL logs and counters continue to change. Such differences are normal and do not necessarily indicate a bad read.

## Tuning the fan curve

This is separate from the identity fix.

After the `SYS_FAN` sensors are enabled, the fan curve is stored in a plain JSON document. Download it from the web interface under **Settings → Fan Profile**, edit it locally, and upload it again through the web interface.

No SSH access or Redfish PATCH operations are required for this step. The identity correction is the difficult part; editing the fan curve itself is straightforward.

### Structure

`arrProfile` is a list of named profiles, such as `default` and `quiet`.

`strMode` selects the active profile.

Each profile contains one or more `arrPolicy` entries. Each policy defines a temperature-to-duty curve that controls one or more fans.

```json
{
  "iPolicyType": 2,
  "iInSDR": 1,
  "iSensorCode": 1,
  "iInitDuty": 20,
  "iCpuTdp": 0,
  "arrSensor": [4, 8, 14, 16],
  "arrFanSensor": [185, 186],
  "arrRef": [30, 36, 42, 48, 54, 60, 66, 72],
  "arrDuty": [20, 24, 30, 38, 48, 60, 78, 100],
  "iHysteresis": 0
}
```

### Field notes

The following notes were derived by surveying every shipped profile in `/etc/FanProfile/*.json` inside the firmware root filesystem: approximately 7000 policies across roughly 250 board profiles.

- **`arrRef` / `arrDuty`:** These arrays define the curve itself, with up to eight points. Some stock Gigabyte profiles use all eight. The firmware interpolates linearly between points. Adding a point directly on an existing straight segment changes nothing; extra points matter only when they alter the curve shape.

- **`arrSensor`:** This lists the sensor IDs that drive the policy. When more than one sensor is listed, `iSensorCode` must be `3` for multi-sensor mode, not `1` for single-sensor mode. This correlated with all 300 multi-sensor policies found in the firmware, with no exceptions. Live testing showed that `iSensorCode: 1` with four sensors behaved as though only the first sensor was read. Setting it to `3` caused the policy to react to whichever listed sensor was hottest.

- **`arrFanSensor`:** This lists the fans controlled by the policy. It can be left as `[]`, meaning any fans not assigned to another policy, but explicit sensor IDs are clearer and were used here.

- **`iPolicyType`:** Use `2` for a normal sensor-threshold policy. Value `1` appears only together with `arrHexVendorID` and `arrHexDeviceID` and is used for policies activated by the presence of a particular PCIe device, such as a GPU or HBA.

- **`iCpuTdp`:** Nonzero values appear only on Intel boards using TDP-aware curve variants. This is irrelevant for AMD or ordinary threshold policies and should remain `0`.

- **`iInitDuty`:** This is the fan duty applied before the BMC receives a valid sensor reading, usually briefly during boot. Match it to the curve's first point to avoid a sudden speed change.

- **`iHysteresis`:** The value was `0` in 6829 of approximately 7066 surveyed policies and is therefore effectively unused by Gigabyte. To avoid oscillation, use a smoother curve with more gradual steps rather than relying on a hysteresis band.

### Useful sensor IDs

The following IDs were obtained from the Redfish `Thermal` endpoint:

| Sensor ID | Sensor |
|---:|---|
| `1` | `CPU0_TEMP` |
| `4` | `DIMMG0_TEMP` |
| `8` | `MB_TEMP1` |
| `14` | `VR_P0_TEMP` |
| `16` | `VR_DIMMG0_TEMP` |
| `184` | `CPU0_FAN` |
| `185` | `SYS_FAN1` |
| `186` | `SYS_FAN2` |

### Verified production behavior

A two-zone `quiet` profile was tested successfully in production:

- CPU zone driven by sensor `1`;
- system zone driven by sensors `4`, `8`, `14`, and `16` with `iSensorCode: 3`.

The system zone reacted to whichever monitored sensor was hottest. During testing, `VR_DIMMG0_TEMP` reached 61 °C and drove `SYS_FAN1` and `SYS_FAN2` to approximately 1350 and 900 RPM. This was well above the previous single-sensor curve's baseline of roughly 750 to 1050 RPM at similar temperatures.

## Validation status

### Spare hardware

MJ11-EC1 board reporting as `G431-MM0-OT`:

- fix fully validated;
- reversible in both directions with `-sku`.

### Production hardware

Firmware `126139`, with no BMC shell access:

- fix fully validated and active;
- full firmware and configuration backups created and verified before modification;
- expected sizes confirmed: 64 MB and 2 MB;
- production `SKU.xml` extracted from the configuration backup;
- `ProductName` changed from `G431-MM0-OT` to `MJ11-EC0-00`;
- `FanProfile` changed from `G431_MM0` to `MJ11`;
- board-specific values, including serial numbers and MAC addresses, left unchanged;
- `SKU.BIN` compiled through Path B, Option 2, without SSH access to any BMC;
- compiled file structurally verified against a known-good sample;
- `-sku` write performed locally on the Proxmox host with `gigaflash_x64` over KCS, not through network `-cs`.

### Post-flash verification

All checks were performed through Redfish, without BMC shell access:

- `Systems/Self` and `Chassis/Self` report `Model: MJ11-EC0-00`.
- `Thermal` reports `SYS_FAN1` and `SYS_FAN2` as `Status.State: Enabled`, with live RPM readings.
- Additional sensors `VR_P0_TEMP`, `VR_DIMMG0_TEMP`, and `MB_TEMP1` are also `Enabled`.
- `FanprofileService/Fanprofile` reports active mode `"quiet"`.
- The active profile uses a dual-zone policy: one CPU-sensor zone and one zone for the remaining fans.
- The UUID's trailing bytes match the production board's actual MAC address (e.g. a UUID ending `...aa11bb22cc34` next to a NIC MAC of `AA:11:BB:22:CC:34`), confirming that the board retained its own identity rather than receiving a clone of the spare board's data.
- Proxmox uptime remained uninterrupted throughout the operation.
- All three VMs, TrueNAS, HAOS, and `ai-server`, continued running.
- The BMC reset during `-sku` application did not affect the host, as expected for a separate management controller.

### Earlier unrelated incident

During the rollout, an interrupted `-dump` left the BMC unreachable and the host stuck at fans-spinning/no-POST. Full AC power removal resolved the issue.

This incident was unrelated to the identity write. The cause was BMC-gated power sequencing, not flash corruption. The `-dump` operation is read-only and cannot corrupt flash contents.
