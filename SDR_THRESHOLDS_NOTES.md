# Fan RPM thresholds (SDR.dat) — reverse-engineering notes

Exploratory notes on where `SYS_FAN1`/`SYS_FAN2`/`CPU0_FAN` RPM thresholds
(lower-critical, lower-non-critical) live and how the BMC's own tooling
generates them. Mechanism is fully verified end-to-end in emulation; **not**
applied to any real board — see "Status" below.

## Where the thresholds live

`/conf/BMC1/wolfpass/SDR.dat` — a flat file of raw IPMI SDR ("Sensor Data
Record") entries, one per sensor. For a Fan-type Full Sensor Record, byte
offsets from the start of the record data (1-indexed per the IPMI spec) are:

| Byte | Field |
|---|---|
| 13 | Sensor Type (`0x04` = Fan) |
| 19-20 | Readable/Settable Threshold Mask |
| 25 | M (scaling factor) — `150` on this board, i.e. `RPM = 150 × raw` |
| 32-33 | Normal Max/Min reading (raw) |
| 37-42 | UNR / UCR / UNC / LNR / **LCR** / **LNC** (raw) |
| 43-44 | Positive/negative hysteresis (raw) |
| 48+ | ID string type/length + sensor name |

Confirmed by cross-checking decoded values against `ipmitool sdr get
SYS_FAN1` (Nominal 7500, Normal Max 38250, Normal Min 1350 — exact match).
Mask is `0x03` (only LCR/LNC actually implemented) — UNR/UCR/UNC read back
as fixed `0xFF` and are not really settable, regardless of what the mask
theoretically allows.

## Runtime IPMI path: doesn't work here

- `ipmitool sensor thresh <name> lcr <val>` — rejected client-side
  ("Invalid Threshold data values") even with the sensor's *own current*
  value, because ipmitool's sanity check treats the unreadable UNC as `0`
  and then sees `lcr > unc`. Not fixable by picking a different value.
- Raw `ipmitool raw 0x04 0x28 <sensor#> <mask> <6 threshold bytes>` (Set
  Sensor Thresholds) — correct length per spec, but the firmware itself
  rejects it with completion code `0xC7` (Request data length invalid).
  Runtime threshold-set for this sensor appears to be dead on this
  firmware build, not just an ipmitool quirk.

## Vendor tool path: `sdrgen`

`/usr/local/bin/sdrgen` (ARM, dynamically linked, not stripped) is the
same class of tool as `bmcprog`/`SKU.xml` in this repo's no-SSH path: a
vendor ARM binary, extracted from the firmware, run under `qemu-arm`
against the firmware's own `/lib` as sysroot.

```
usage: sdrgen <SDR file> [<DEBUG mode>]
```

It reads `/tmp/devmap.xml` (present on a live board — the boot process
renders it from `/etc/devmaps/<chipset>/<board>.xml` + `SKU.xml`), which
maps each physical sensor to a **named template**, e.g.:

```xml
<TACH chnl="2">
    <SENSOR name="SYS_FAN1" no="0xb9" scan="ON,2" sdr="OB_FAN" />
</TACH>
```

`devmap.xml` carries no numeric thresholds at all — just name, IPMI sensor
number, and the template name (`OB_FAN`, shared by all three fan headers).
The actual bytes come from a table of ~219 pre-built raw SDR records
compiled directly into `sdrgen`'s `.data` section (found via Ghidra:
`main` → `xml_scan(cb_map_to_repo)` → `repo_to_dat` → `sdrgen()`, which
`strcmp`s the template name against the table and `memcpy`s the matching
32/48-byte template). For `OB_FAN` specifically (verified in the uploaded
binary):

| Field | File offset in `sdrgen` |
|---|---|
| M factor | `0x27B0` |
| Normal Max / Min | `0x27B8` / `0x27B9` |
| UNR / UCR / UNC | `0x27BC` – `0x27BE` |
| LNR | `0x27BF` |
| **LCR** | `0x27C0` |
| **LNC** | `0x27C1` |
| Hysteresis +/- | `0x27C2` / `0x27C3` |

Patching those bytes and re-running `sdrgen <file>` (append-mode, needs an
existing valid SDR.dat, not an empty one) regenerates the record with
correct length/ID-string byte — no manual checksum math needed, since the
tool builds the record fresh.

## The catch — don't just re-run `sdrgen` on the whole file

`sdrgen` regenerates **every** sensor named in `devmap.xml` from its
generic template, not just the ones you care about. Tested end-to-end on
the spare board (real `/conf/BMC1/wolfpass/SDR.dat` + real `/tmp/devmap.xml`,
patched `sdrgen` under `qemu-arm`): all 27 sensors got fresh records, and
for most of them that's a harmless no-op — but for at least 6 of them
(non-fan sensors), the generic template didn't match the board's original,
presumably factory-calibrated values. Observed collateral damage before
this was reverted:

- Several sensors' Lower-Critical raw value silently changed to the
  template default (e.g. one sensor's LCR raw byte: `0x00` → `0xF6`).
- One sensor's **M scaling factor itself** changed (`106` → `126`).
- Threshold mask widened from the real `0x03` (LCR/LNC only) to a generic
  `0x3F` (all six thresholds) on several sensors — advertises threshold
  support the hardware doesn't actually have.

None of this touched the fan sensors incorrectly — it's what happens to
everything else that happens to share a name with something in
`devmap.xml`. The change was caught by a full old-vs-new record diff
before it was left in place, and reverted from a pre-change backup; no
live board was left in this state.

**Safer approach, not yet executed**: don't run `sdrgen` against a live
file at all. Instead, byte-patch only the LCR/LNC bytes of the three
existing fan records directly, in place, inside the current `SDR.dat`
(record-relative bytes 41/42 per the table above) — a true one-byte edit,
zero risk to any other sensor.

## Status

Reverse-engineered and validated in emulation only (`qemu-arm` on a VM
copy of the firmware, byte-diffed against the real decoded values). Spare
board's live `SDR.dat` was briefly overwritten during testing and has
since been restored from backup, verified byte-identical. No threshold
change is currently applied to any board.
