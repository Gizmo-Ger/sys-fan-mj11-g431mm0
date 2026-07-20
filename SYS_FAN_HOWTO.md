# Enabling SYS_FAN Sensors on Gigabyte MJ11-EC1/G431-MM0 BMC (AMI MegaRAC, AST2500)

Credit to PeterF, who first documented the underlying identity-gating issue
on ServeTheHome (January 2024), and later explored a different workaround
for SSH being locked out on newer firmware (April 2024, editing
`passwd`/`shadow` directly on the writable `/conf` partition — this repo's
Path B takes a different, fully offline route to the same problem):
https://forums.servethehome.com/index.php?threads/gigabyte-mj11-ec1-epyc-3151-mystery.41395/post-407547
https://forums.servethehome.com/index.php?threads/gigabyte-mj11-ec1-epyc-3151-mystery.41395/post-424378
(profile: https://forums.servethehome.com/index.php?members/peterf.2796/)

Also credit to Oliver Obenland, who wrote up the same issue independently
(February 2024):
https://oliver.obenland.it/gigabyte-mj11-ec1-alle-luefter-per-pwm-steuern/

## Background

Gigabyte's MJ11-EC1 baseboard ships inside the G431-MM0 GPU mining chassis under a
different reported product identity (`G431-MM0-OT`) than its real board model
(`MJ11-EC1-OT`). The BMC firmware ties fan **presence-detection** for the two/three
onboard `SYS_FAN` headers to this reported product identity — under the
`G431-MM0-OT` identity, `SYS_FAN` sensors report `Absent` over IPMI/Redfish even
with fans physically connected and spinning. Only `CPU_FAN` works normally.

This is not a wiring issue and not caused by the active fan-profile *content* —
the default profile already references the correct fan sensor IDs. It is purely
an identity-gated firmware behavior.

**Fix**: change the BMC's reported product identity away from `G431-MM0-OT` to a
different but hardware-compatible SKU string (e.g. `MJ11-EC0-00`, a sibling board
in the same family), and update `FanPolicy/FanProfile` to a matching profile. This
unlocks the `SYS_FAN1`/`SYS_FAN2` presence-detection and (as a side effect) several
other suppressed sensors (`VR_P0_TEMP`, `VR_DIMMG0_TEMP`, `MB_TEMP`).

Confirmed via A/B testing on spare hardware: the identity swap alone is both
necessary and sufficient. Verified reversible in both directions.

## Where the identity lives

`/conf/BMC1/wolfpass/SKU.xml` (JFFS2-backed, 2MB partition, flash offset `0x50000`,
size `0x200000`) — contains `FRU` and `PROJECT` sections, each with
`BoardProductName` (real board model) and `ProductName` (marketing/chassis SKU).
Also contains `FanPolicy/FanProfile`, which selects a JSON curve file from
`/etc/FanProfile/*.json`.

## Two tools, two very different behaviors — the critical gotcha

Gigabyte's `gigaflash` utility (ships as `.efi` for UEFI shell and as Linux/Windows
binaries) has four modes: `-dump`, `-backup`, `-restore`, `-sku`. Exact syntax,
pulled from the binary's own usage strings (don't guess at flags — `-bmc`/`-bios`
selector flags do **not** exist, a mistake made during this writeup):

```
./gigaflash <-dump> <output file>
./gigaflash <-backup> <output file>
./gigaflash <-restore> <input file>
./gigaflash <bin> <-sku> <-2500> <-wt> <wait time> <-no-reboot> <-cs> <bmc address>
```

Only `-sku` takes a remote target (`-cs <bmc address>`); `-dump`/`-backup`/`-restore`
only talk to the *local* BMC via KCS, so they must run on the host itself (e.g. the
Proxmox host), not from a separate workstation over the network.

**Gotcha #2 — a plain `-dump` can transiently wedge the BMC.** Observed on
production hardware: a `-dump` read got interrupted (console/session drop mid-read,
not a crash), and afterward the BMC was unreachable *and* the host sat at
fans-spinning/no-POST/no-video. Root cause: the AST2500 BMC gates host power
sequencing (PS_ON/power-good), so a wedged BMC can strand the host pre-POST even
though nothing was written to flash — a `-dump` is read-only and cannot corrupt
anything. **Fix: full AC power removal** (unplug PSU cord(s), wait 60s to drain
standby rail, replug) — not just a host reset/reboot, since the BMC's standby power
persists through a normal power-button cycle. Board came back clean on the
next boot; re-running `-dump` to completion afterward confirmed a plain read was
never the actual risk, the interrupted session was.

- **`-backup <file>` / `-restore <file>`**: operate on the raw 2MB config
  partition. `-restore` **deliberately does not touch FRU/SKU identity data**,
  even though it reports success and does correctly restore other settings
  (network, users, the Redis-backed fan-profile picker). This is almost certainly
  an intentional safety feature — a generic "restore my settings" shouldn't let you
  accidentally clone one board's identity onto another. **Do not use `-restore` to
  try to change identity — it will silently no-op that part, confirmed on both
  spare and production hardware.**
- **`-sku <bin> -sku -2500`**: the only mode that actually writes FRU/SKU identity.
  Takes a **compiled `SKU.BIN`** (not raw XML), produced by the BMC-side tool
  `bmcprog`. Proven on spare hardware to correctly flip identity in both
  directions (broken→fixed and fixed→broken), triggering the same fan
  presence-detection change each time.

## Path A — if you have BMC shell access (SSH)

Works if the board's BMC firmware still allows SSH login (older firmware; newer
Gigabyte firmware, e.g. 126139, closes this).

```sh
# on the BMC itself, via ssh
cd /tmp
cp /conf/BMC1/wolfpass/SKU.xml /tmp/SKU.xml
cp SKU.xml SKU.xml.bak

sed -i s/<old-ProductName>/<new-ProductName>/g SKU.xml
sed -i s/<old-BoardProductName>/<new-BoardProductName>/g SKU.xml
sed -i s/<old-FanProfile>/<new-FanProfile>/g SKU.xml

bmcprog WS=FULL_AREA        # compiles SKU.BIN from SKU.xml
skurw w flash SKU.BIN       # writes it to flash
rm SKU.xml
skupioneer                  # applies it (regenerates FRU/SDR/redis state)
reboot                      # full reboot required to complete
```

Verify:
```sh
skuinfo
cat /conf/BMC1/wolfpass/SKU.xml
```
And via Redfish (from any workstation):
```
curl -k -u admin:<password> https://<bmc-ip>/redfish/v1/Chassis/Self/Thermal
```
Check `SYS_FAN1`/`SYS_FAN2` (or `SYS_FAN_1/2/3` depending on identity)
`Status.State` = `Enabled`.

## Path B — no BMC shell access (e.g. newer firmware with SSH disabled)

Use `-sku` from the *host* side instead (UEFI shell, or Linux `gigaflash_x64` run
directly on a live host OS with the BMC's management interface — no host reboot
needed for the Linux variant).

The catch: `-sku` needs a **compiled `SKU.BIN`**, and `bmcprog` (the compiler) is a
BMC-side ARM tool with no host-side equivalent shipped. Two ways around this:

1. **If you have shell access on *any* board of the same family** (e.g. a spare
   unit), compile the target `SKU.BIN` there via `bmcprog`, pull it off over SSH
   (binary-safe — `scp`/`base64` often aren't available on stripped BMC busybox
   images; fall back to `hexdump -v -e '1/1 "%02x"' file | ssh ...` and decode
   the hex locally), then push it to the shell-less board via `-sku`.

2. **If no shell access anywhere (proven method, no SSH to any BMC required):**
   `bmcprog` doesn't need to run *on* a BMC at all — it just needs an ARM
   environment. Extract it from a **firmware dump** you already have (a plain
   `-dump` needs no shell either) and run it under emulation:

   a. `-dump` the full firmware image (~64MB). It contains one or more `cramfs`
      partitions (detect via magic bytes `45 3d cd 28` at the start of a
      superblock; the 4-byte field right after the magic is the partition's
      size in bytes — use that to `dd` out an exact-sized slice, don't guess).

   b. Do the extraction/emulation work in a **disposable VM**, not on the
      production hypervisor itself — mounting an unfamiliar filesystem and
      running an unverified foreign-arch binary are both things you don't want
      touching the box that's actually running your VMs.
      ```sh
      sudo modprobe cramfs
      sudo mount -t cramfs -o loop rootfs_main.cramfs /mnt/rootfs_main
      find /mnt/rootfs_main -iname '*bmcprog*' -o -iname '*skurw*' -o -iname '*skupioneer*'
      # -> /usr/local/bin/bmcprog, skurw, skupioneer, skuinfo
      file /mnt/rootfs_main/usr/local/bin/bmcprog
      # -> ELF 32-bit ARM, statically linked  (this is the one that matters —
      #    static means no need to reproduce the BMC's shared-lib environment)
      ```

   c. Install `qemu-user` (Ubuntu/Debian: the package providing the static
      `qemu-arm` binary is named `qemu-user`, *not* `qemu-user-static` on newer
      releases — that name is now a virtual package pointing at
      `qemu-user-binfmt`). Then just run the extracted binary directly:
      ```sh
      cp /mnt/rootfs_main/usr/local/bin/bmcprog ~/bmcprog
      cd ~ && cp /path/to/edited/SKU.xml ./SKU.xml   # must be named exactly SKU.xml, in cwd
      qemu-arm ~/bmcprog WS=FULL_AREA
      # -> produces ./SKU.BIN, 1664 bytes for this board family
      ```

   d. Sanity-check the output before trusting it: compare byte length and
      header against a known-good sample (`dumps/SKU_known_good.BIN`), and
      confirm the gzip-embedded copy of the source XML (magic `1f 8b`, found
      at offset `0x200` in this board family's `SKU.BIN`) decompresses and
      contains your intended edits:
      ```python
      import gzip
      data = open('SKU.BIN','rb').read()
      xml = gzip.decompress(data[0x200:]).decode()
      # grep the fields you changed out of `xml` and confirm
      ```

   This is strictly better than reverse-engineering the binary format from
   scratch (the fallback originally documented here) — it uses the real
   compiler, so there's no risk of a hand-rolled format being subtly wrong.

Command from UEFI shell:
```
gigaflash.efi <path-to-SKU.BIN> -sku -2500
```
Or from a live Linux host (no reboot needed):
```
./gigaflash_x64 <path-to-SKU.BIN> -sku -2500
```

## Always back up first

Before touching anything:
```
gigaflash.efi -dump bmc_full_dump.bin      # 64MB, full firmware, nuclear rollback
gigaflash.efi -backup bmc_config.bin       # 2MB config partition
```
Take two of each and hash-compare — BIOS/static chip content should match
byte-for-byte; live BMC dumps won't (SEL logs/counters drift), that's normal, not
a bad read.

## Tuning the fan curve itself (separate from the identity fix)

Once `SYS_FAN` sensors are unlocked, the curve that drives them is a plain JSON
document — download it from the webui (Settings → Fan Profile), edit locally,
re-upload via webui. No SSH, no Redfish PATCH juggling needed; the identity fix
above is what's hard, this part is easy.

Structure: `arrProfile` is a list of named profiles (e.g. `default`, `quiet`);
`strMode` picks which one is active. Each profile has one or more `arrPolicy`
entries — each policy is one temperature→duty curve driving one or more fans.

```json
{
  "iPolicyType": 2,
  "iInSDR": 1,
  "iSensorCode": 1,
  "iInitDuty": 20,
  "iCpuTdp": 0,
  "arrSensor": [4, 8, 14, 16],
  "arrFanSensor": [185, 186],
  "arrRef":  [30, 36, 42, 48, 54, 60, 66, 72],
  "arrDuty": [20, 24, 30, 38, 48, 60, 78, 100],
  "iHysteresis": 0
}
```

Field notes (derived by surveying every shipped profile in
`/etc/FanProfile/*.json` inside the firmware's rootfs — ~7000 policies across
~250 board profiles):

- **`arrRef` / `arrDuty`**: the curve itself, up to 8 points (confirmed — some
  stock Gigabyte profiles use exactly 8). Firmware linearly interpolates
  between points, so inserting a point exactly on an existing straight segment
  changes nothing — more points only matter if the *shape* changes too.
- **`arrSensor`**: which sensor ID(s) drive this policy. **Gotcha**: if you
  list more than one sensor, `iSensorCode` must be `3` (multi-sensor), not `1`
  (single-sensor) — confirmed by 100% correlation across all 300 multi-sensor
  policies found in the firmware, zero exceptions. Verified live: leaving
  `iSensorCode: 1` with a 4-sensor `arrSensor` list produced behavior
  consistent with only reading the first sensor; setting it to `3` correctly
  reacted to whichever of the listed sensors ran hottest.
- **`arrFanSensor`**: which fan(s) this policy controls. Can be left `[]` to
  mean "whatever fans aren't claimed by another policy," but explicit sensor
  IDs are clearer and were used here.
- **`iPolicyType`**: `2` for a plain sensor-threshold policy (what you want).
  `1` only appears alongside `arrHexVendorID`/`arrHexDeviceID` — it's for
  policies gated on a specific PCIe device (GPU/HBA) being present.
- **`iCpuTdp`**: nonzero only on Intel boards using TDP-aware curve variants;
  irrelevant for AMD/plain-threshold policies, leave `0`.
- **`iInitDuty`**: duty applied before the BMC has a live sensor reading
  (briefly at boot). Match it to the curve's first point to avoid a jump.
- **`iHysteresis`**: `0` in 6829 of ~7066 surveyed policies — essentially
  never used by Gigabyte. Rely on curve smoothness (more, gentler steps)
  instead of a hysteresis band if you want to avoid oscillation.

Useful sensor IDs on this board (from the Redfish `Thermal` endpoint):
`1`=CPU0_TEMP, `4`=DIMMG0_TEMP, `8`=MB_TEMP1, `14`=VR_P0_TEMP,
`16`=VR_DIMMG0_TEMP, `184`=CPU0_FAN, `185`=SYS_FAN1, `186`=SYS_FAN2.

Verified live on production: a two-zone `quiet` profile (CPU zone on sensor 1,
system zone aggregating sensors 4/8/14/16 via `iSensorCode: 3`) correctly
responds to whichever tracked sensor is hottest — confirmed when
`VR_DIMMG0_TEMP` (61°C, the hottest of the four) drove `SYS_FAN1`/`SYS_FAN2` to
1350/900 RPM, well above the old single-sensor curve's baseline (750-1050 RPM)
at similar temperatures.

## Status

- Spare hardware (MJ11-EC1 board, reporting under `G431-MM0-OT`): **fix fully
  validated**, reversible both directions via `-sku`.
- Production (firmware 126139, no BMC shell access): **fix fully validated and
  live.** Full firmware/config backups taken and verified (64MB / 2MB, exact
  expected sizes) before touching anything. Production's own `SKU.xml`
  extracted from the config backup, edited (`ProductName` `G431-MM0-OT`→
  `MJ11-EC0-00`, `FanProfile` `G431_MM0`→`MJ11`; all board-unique fields —
  serials, MACs — left untouched), compiled to `SKU.BIN` via Path B step 2 (no
  SSH to any BMC used at any point), verified structurally correct against the
  known-good sample before deployment. `-sku` write executed via
  `gigaflash_x64` locally on the Proxmox host (KCS, not network `-cs`).

  Post-flash verification, all via Redfish (still no BMC shell access needed):
  - `Systems/Self` and `Chassis/Self` both report `Model: MJ11-EC0-00`.
  - `Thermal`: `SYS_FAN1`/`SYS_FAN2` both `Status.State: Enabled` with live RPM
    readings, plus the bonus sensors (`VR_P0_TEMP`, `VR_DIMMG0_TEMP`,
    `MB_TEMP1`) all `Enabled`.
  - `FanprofileService/Fanprofile` shows active mode `"quiet"` — dual-zone
    policy (CPU-sensor zone + a second zone covering the remaining fans),
    matching the profile validated on spare.
  - UUID's trailing bytes match production's own real MAC (e.g. a UUID ending
    `...aa11bb22cc34` next to a NIC MAC of `AA:11:BB:22:CC:34`), confirming
    this is production's genuine identity, not an accidental clone of spare's.
  - Host sanity: Proxmox uptime continuous through the whole operation, all 3
    VMs (TrueNAS, haos, ai-server) never interrupted — confirms the BMC reset
    during `-sku` apply did not affect the host, as expected (separate
    controller).

  One earlier scare during this rollout, unrelated to the identity write
  itself: an interrupted `-dump` (session/console drop mid-read, not a crash)
  left the BMC unreachable and the host stuck at fans-spinning/no-POST. Fixed
  by a full AC power removal (not just a host reset) — see the gotcha under
  "Two tools, two very different behaviors" above. Root cause was BMC-gated
  power sequencing, not flash corruption — `-dump` is read-only and cannot
  corrupt anything.

## `sysadmin` SSH lockout — root cause confirmed

**Update:** confirmed by comparing the locked board's extracted config
against a spare board where SSH still works. `sysadmin` is not disabled at
the account level on either board — `passwd` entry intact (UID 0, GID 0),
`shadow` has a normal, unlocked password hash, and `sysadmin`'s cron jobs run
fine on both. Only one thing differs.

**PAM ruled out.** `/etc/pam.d/sshd` is a symlink to `/etc/pam_withunix` on
both boards, byte-identical content, includes `pam_unix.so` for
auth/account/password/session — local password auth is fully wired up
either way. `nsswitch.conf` (`passwd: files rsvdusers ipmi ldap ad radius`)
is also identical on both. Neither is the blocker.

**The actual blocker** is a single line in `ssh_server_config`:

```
DenyUsers sysadmin
```

Confirmed by pulling `ssh_server_config` off the working spare board over
its live SSH session and grepping for `deny` — the line simply isn't there.
Everything else (PAM stack, nsswitch, passwd/shadow layout) matches. That
file lives in the same writable JFFS2 config partition as `SKU.xml` — not
the signed, read-only main firmware image.

**Fix** — same extract → edit → repack → write pipeline used for `SKU.xml`
in this repo generalizes directly: pull the JFFS2 partition apart, drop the
`DenyUsers` line, repack with `mkfs.jffs2`, push it back.

**If you already have a shell on the board through some other channel** —
serial-over-LAN (SOL) or the physical UART console (these authenticate
through `login`/`pam_withunix`, not `sshd`, so `DenyUsers` never applies to
them) — the file can be edited in place and `sshd` re-exec'd to pick it up
without a reflash:

```sh
sed -i '/DenyUsers sysadmin/d' /etc/ssh/ssh_server_config
kill -HUP $(cat /var/run/sshd.pid)
```

This does **not** work over SSH itself — SSH is exactly what's locked out,
so there's no shell to run it from until you already have one some other
way. Root isn't a usable shortcut either: on the boards checked, `/etc/shadow`
has no entry for `root` at all and `root`'s `.ssh/` is empty, so root login
isn't practically available despite `PermitRootLogin yes`. If SOL/serial
isn't available on your board, the offline JFFS2 repack path above is the
only route.

Still open: whether `-restore` already touches this file on its own (it's
documented as restoring "users" config while skipping FRU/SKU identity —
`ssh_server_config` may already fall under "users" and survive a restore
with the edit intact). Untested — if you've tried it, open an issue with
the result.
