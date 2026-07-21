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

**Vendor changelog confirms all of this directly.** Gigabyte's own
`BMC_Release_Note_126139.doc` (the release notes shipped with SMT firmware
12.61.39, released 2025/07/02) spells out the exact version history behind
the lockout:

- **12.60.41** — `[defect] Always block sysadmin login via ssh.` This is
  the changelog entry for the `DenyUsers sysadmin` line documented above —
  straight from the vendor, not just inferred from the config diff.
- **12.60.39** (one version earlier) — two relevant entries:
  `[feature] Modify default password for sysadmin.` and
  `[feature] Add gbt oem cmd to enable/disable ssh.` The second one is
  worth chasing separately — a Gigabyte OEM IPMI command that toggles SSH
  on/off. If it's still present and unrestricted on a board running
  anywhere in the 12.60.39–12.61.38 range (i.e. after this command was
  added but before SSH was removed outright), it could be a legitimate,
  vendor-supported way to re-enable SSH without touching JFFS2 at all —
  worth probing via `ipmitool raw`/OEM command discovery before falling
  back to the config-partition repack below. **Found and GET-tested — see
  "The OEM `AMISetServiceConf` command" further down.**
- **12.61.27** — `[feature] Hide SSH-related features on Web UI.` This is
  the vendor's own confirmation of the cosmetic UI masking documented
  further down (Services SSH toggle and SSH-key upload fields disappearing
  from the web UI while the Redfish backend stays live) — it was a
  deliberate UI-only change, not a coincidence.
- **12.61.39** — `[feature] Remove SSH service.` SSH goes from
  blocked-for-sysadmin-only to fully removed at this version. Confirms
  directly what Peter reported: SSH access still works on firmware prior
  to 12.61.39, and stops working entirely from 12.61.39 onward — not just
  for `sysadmin`, for anyone, because the service itself is gone. On a
  board already on 12.61.39+, the JFFS2 `DenyUsers` edit below won't bring
  SSH back on its own, since there's no `sshd` left to re-exec — that fix
  only applies to boards in the 12.60.41–12.61.38 window where SSH is
  present but blocked, not to boards past 12.61.39 where it's absent.

**Fix** — pull the JFFS2 config partition apart, drop the `DenyUsers` line,
repack with `mkfs.jffs2`, write it back. (Only applicable pre-12.61.39 —
see version notes above.)

**Important caveat, added after digging into the actual firmware** (see
"What `Remove SSH service` actually does" further down): this fix only
ever mattered for logging in as the literal `sysadmin` account. The
`admin` account people actually use isn't touched by `DenyUsers sysadmin`
at all, on any version — so if `sshd` is running, `admin` can already SSH
in regardless of this line. On 12.61.39+ specifically, this edit alone
won't restore SSH access anyway, and isn't even the relevant blocker —
see below.

**Correction**: an earlier version of this section said this "generalizes
directly" from the `SKU.xml` pipeline via `-sku` — that's not accurate.
`build_sku_bin.sh`'s `-sku` route only ever compiles and writes back the
single `SKU.xml` record through `bmcprog`; it's not a full-partition
rewrite, so it can't carry an `ssh_server_config` edit along with it (more
on why in the note below). Writing back a fully repacked JFFS2 config
partition needs whatever `gigaflash` write mode actually accepts a whole
partition image — not `-sku` — which hasn't been identified/verified here
yet. Until that's nailed down, this route is unverified; the SOL/serial
in-place edit below is the only confirmed-working method.

If a full-partition write mode is confirmed to work: `sshd` is already
running on port 22 for everyone — `DenyUsers` only filters the `sysadmin`
user at auth time, it doesn't stop the daemon — so no extra reload step
should be needed beyond whatever reset that write mode triggers.

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

**Why this isn't a `build_sku_bin.sh` flag**: it might look like an obvious
addition — the script already extracts and parses this same JFFS2 config
partition to get at `SKU.xml`, so an `--enable-ssh` switch seems like a
natural bolt-on. It isn't, for the reason above: the script's whole output
path (`bmcprog` → `SKU.BIN` → `gigaflash -sku`) is scoped to that one XML
record, not the partition as a whole. There's no full-partition repack step
in that script to hook an `ssh_server_config` edit into — adding one would
mean building and verifying a separate write mechanism, which is exactly
the open, unverified question above. So this stays a manual, documented
fix rather than a script flag.

## What "Remove SSH service" (12.61.39) actually does — sshd isn't gone, it's stopped on purpose

Everything above about `DenyUsers sysadmin` is real, but it turned out not
to be the actual barrier to general SSH access on 12.61.39+, and the
changelog wording ("Remove SSH service") is misleading. Extracted and
mounted the two `cramfs` partitions from production's own firmware dump
(same method `build_sku_bin.sh` already uses to pull `bmcprog` — the
partitions were already sliced out from a prior session; mounting them
read-only via `sudo mount -t cramfs -o loop,ro` on a Linux box was enough,
no cramfs userspace extractor needed). Findings:

- **`/usr/sbin/sshd`, `/etc/ssh/ssh_host_*_key`, `ssh-keygen`, the full
  `sshd_config` chain — all still present and intact** in the 12.61.39
  rootfs. Nothing was deleted. `/etc/ssh/sshd_config` is still a symlink to
  `/conf/ssh_server_config` on the writable JFFS2 config partition, exactly
  as documented above.

- **The actual change is two lines in `/etc/init.d/ssh-main`**, dated one
  week before the 12.61.39 release (2025/07/02):

  ```sh
  # Sam.C 2025/06/24: Disable SSH port by default.
  /etc/init.d/ssh start
  /etc/init.d/ssh stop
  ```

  Every boot, `sshd` is started (regenerating host keys the first time)
  and then immediately stopped again, a few lines later, in the same init
  script. That's the entire "removal" — a deliberate start-then-kill added
  to the boot sequence, not a removed daemon. This is also why the TCP
  port-22 scan against production (above) shows nothing listening: the
  daemon genuinely isn't running *after boot completes* — but the binary,
  keys, and config are all one command away from working again.

- **`DenyUsers sysadmin` was never the practical blocker for a human
  login.** It's re-applied unconditionally by `check_conf_presence()`
  inside `/etc/init.d/ssh`'s own `start` case (`sed -i '/DenyUsers
  sysadmin/d' ...; echo "DenyUsers sysadmin" >> ...`) — so it comes back
  every time `ssh start` runs, regardless of any JFFS2 edit made
  beforehand. But it only ever denies the literal Unix user `sysadmin`
  (an internal service account). The account a person actually logs in
  as — `admin`, the same one used for the web UI — isn't a static
  `/etc/passwd` entry at all; it's resolved live through
  `libnss_ipmi.so` (present and untouched in this rootfs) via the `ipmi`
  source in `nsswitch.conf`. No `AllowUsers`/`DenyUsers` line anywhere in
  `/etc/defconfig/ssh_server_config` restricts `admin`. So on a board
  where `sshd` is actually running, logging in as `admin` was never
  blocked by anything documented in this repo — `DenyUsers sysadmin` and
  the daemon-liveness question are two independent issues that happen to
  live in the same file.

- **Practical upshot for a board already on 12.61.39+, once you have any
  one-time console access (SOL/UART/JTAG)**: running

  ```sh
  /etc/init.d/ssh start
  ```

  directly (not via `ssh-main`, and without rebooting afterward) starts
  `sshd` and leaves it running — `admin` can then SSH in normally. No
  reflash, no signature bypass, no JFFS2 repack required. The catch: this
  by itself doesn't survive a reboot, because `ssh-main` runs its
  `start; stop` sequence again on every boot, and that script lives in the
  **signed, read-only main cramfs rootfs** — not something this repo's
  tooling can patch without defeating the firmware signature check (the
  same wall PeterF hit with his own full-firmware modifications; see his
  u-boot theory below).

  **That said, this one-boot version isn't actually the end of the story
  — see "A persistent fix without touching the signed firmware" right
  below.** There's a way to make SSH survive reboots that never touches
  the signed rootfs at all.

## A persistent fix without touching the signed firmware: `@reboot` cron (DOES NOT WORK — live-tested and failed, kept for the reasoning + the negative result)

**Status: tested live on the spare board, including across a genuine BMC
reboot, and it failed both times — see full results below. Do not use
this. The pieces it's built on are each individually real and correctly
verified (writable crontab, correct boot ordering, genuine `@reboot`
gating logic in the cron binary), but something prevents cron from
actually dispatching *any* job on this firmware, including its own
stock jobs. Root cause unknown.** Left the reasoning and the test writeup
in place since the individual facts are still accurate and useful context
for whoever eventually root-causes this — just not as a working fix.

The `/etc/init.d/ssh start` trick above gets SSH working immediately, but
only until the next reboot, because the boot-time kill lives in the
signed main rootfs. But bringing `sshd` back up doesn't have to happen
*during* that same boot sequence — it just has to happen *some time*
after `ssh-main` kills it, and cron already gives us exactly that, using
nothing but the writable JFFS2 config partition this repo's tooling
already knows how to edit.

**The pieces, all already confirmed present and working on 12.61.39:**

- `/etc/crontab` is a symlink to `/conf/crontab` — i.e. it lives on the
  writable config partition, not the signed rootfs. Editing it is the
  same kind of operation as the `SKU.xml`/`ssh_server_config` edits
  already documented in this file.
- The cron daemon (`/usr/sbin/cron`, vixie/ISC cron, not busybox `crond`)
  starts at `S89cron` in the boot sequence — well after `ssh-main` runs
  its forced `start; stop` at `S16ssh`. Nothing later in `rc3.d` (checked
  the full ordered listing through `S99zz-rc-init-complete`) touches
  `sshd` again.
- `@reboot` support isn't theoretical here — `/conf/crontab` **already
  has live `@reboot` entries** (for `logrotate`), proving the mechanism
  is real and actively used by the stock firmware on this exact board.
- Cron jobs run as whatever user the crontab line specifies, completely
  independent of `sshd`/PAM — `DenyUsers sysadmin` has no bearing on a
  cron job, even one that runs as `sysadmin` (confirmed UID 0 already).

**The fix** — add one line to `/conf/crontab`:

```
@reboot sysadmin sleep 15 && /etc/init.d/ssh start
```

(the `sleep` is just cheap insurance against any startup-ordering edge
case; cron already starting at `S89` vs. ssh-main's `S16` should make it
unnecessary in practice.)

Once that line is in place, `sshd` gets restarted a few seconds into
every boot, right after cron itself comes up, and nothing downstream
stops it again — no reflash needed after the one edit, no signature to
defeat, because the change never touches anything outside the JFFS2
config partition.

**How to apply it**, in order of preference:

1. **If you already have a live shell** (SOL/UART, or SSH brought up
   temporarily via the `/etc/init.d/ssh start` trick above): just
   `echo '@reboot sysadmin sleep 15 && /etc/init.d/ssh start' >>
   /conf/crontab`. This is a live edit to flash-backed data, so it's
   already persistent from that point on — done in one shot, never needs
   repeating.

   **Correction**: an earlier version of this section said a `kill -HUP`
   on cron would "force it immediately." That's wrong for `@reboot`
   specifically. This board's `/usr/sbin/cron` is a genuine ISC/vixie-cron
   binary — confirmed by the `/var/run/crond.reboot` marker string inside
   it — and that binary's whole point is to gate `@reboot` jobs to run
   **once per boot**: it only runs them if that marker file is absent,
   then creates it. A HUP/reload picks up new *timed* (minute/hour)
   entries fine, but won't retroactively run a newly-added `@reboot` line
   mid-uptime. To test it without a full reboot: `rm -f
   /var/run/crond.reboot && /etc/init.d/cron restart`. To actually confirm
   it survives a real reboot, there's no shortcut — you have to reboot the
   BMC and check.
2. **If you only have offline JFFS2 access** (no shell at all, board on
   12.61.39+ with no other console): extend the same `jefferson` extract
   → edit → `mkfs.jffs2` repack → write-back pipeline this repo already
   uses for `SKU.xml`, adding this line to the extracted `crontab` file
   before repacking. This is exactly the "full-partition write mode"
   question left open elsewhere in this doc — needed here too, since
   `-sku` only writes the single `SKU.xml` record, not the whole
   partition.

**Verify it worked**: after a reboot, an SSH connection to `admin` should
succeed without needing console access again. If it doesn't, check
`/var/log/cron.log` (or wherever this board routes cron's log output) via
console for whether the `@reboot` line actually fired.

### Live test on spare (12.49.06) — negative result, including across a real reboot

Before touching production with this, tested it on the spare board over
SSH (which already has a real, long-standing `@reboot` entry for
`logrotate` in its own `/conf/crontab`). Backed up `/conf/crontab` first;
everything below was cleaned up and the original file restored afterward
(verified by hash) — spare was left exactly as found.

What happened:

- Appended a harmless test line (`@reboot sysadmin echo ... >>
  /tmp/reboot_test.log`), then removed `/var/run/crond.reboot` and ran
  `/etc/init.d/cron restart` to force a re-check without a real reboot.
  The job did **not** run. Pulling strings from the actual `/usr/sbin/cron`
  binary explains why: it contains `"Skipping @reboot jobs -- not system
  startup"` alongside `"Running @reboot jobs"` — this cron build
  deliberately detects genuine system boot vs. a mere process restart, and
  correctly refused to treat our forced restart as the real thing. That
  part is reassuring, not concerning — it means the gating logic is
  real and intentional, and a true reboot should still trigger it.

- To rule out a live-reload quirk instead, tried a plain `* * * * *`
  (every-minute, no `@reboot` involved at all) test line, added fresh and
  followed by a full `/etc/init.d/cron restart` — this should have nothing
  to do with the startup-detection logic above. It never fired either,
  checked over 130+ seconds (well past two minute boundaries).

- Went further and checked whether cron's **own pre-existing** minute job
  (`logrotate`, present in the stock crontab, no editing involved at all)
  was actually running: `/var/lib/logrotate/` has never contained a status
  file, and polling `ps -ef` every 5 seconds for a full 60 seconds never
  once caught a `logrotate` process. No `/etc/cron.allow` or
  `/etc/cron.deny` exists to explain a silent block, `sysadmin` is
  confirmed UID 0, and the crontab file itself is syntactically clean
  (verified byte-for-byte, no missing newlines, no corruption from the
  edits).

**Net effect: cron does not appear to be actually executing scheduled
jobs on this board at all right now, independent of anything this repo
did to it.** That's a bigger and stranger finding than "the new line
doesn't work."

**Follow-up: tested across a genuine reboot too, not just a process
restart.** Added a fresh `@reboot` test line, backed up `/conf/crontab`
again, and issued an actual `reboot` of the spare BMC (not just
`/etc/init.d/cron restart`). The board came back after ~85 seconds. Result:
the test job still did not run — and neither did the vendor's own
pre-existing `logrotate` @reboot/minute job, which should unconditionally
fire within the first minute of any fresh boot (its guard condition,
"logrotate isn't already running," is trivially true right after a
reboot). `/var/run/crond.reboot` was freshly created at the correct
boot-time timestamp (cron did correctly detect this as a genuine startup
this time), and the `cron` process itself was healthy afterward — alive,
sleeping normally, no crash, correct `cwd` of `/var/spool/cron`. It just
never appears to actually dispatch any job, `@reboot` or scheduled,
real reboot or not.

**Conclusion: this isn't a persistence-timing quirk, it's cron itself not
executing jobs on this board, root cause unidentified.** Whatever gates
actual job dispatch (as opposed to the daemon starting and the boot-marker
logic, both of which work correctly) hasn't been found — could be
something in this specific board's state, a missing dependency the daemon
silently no-ops without, or a further internal check beyond the
"@reboot vs. not system startup" one already found. Not enough evidence
yet to point at a specific cause. **Treat the entire `@reboot`-cron
persistence idea as not viable until this is root-caused** — it isn't a
matter of getting the crontab syntax right, cron does not appear to
dispatch jobs on this firmware at all, including jobs it ships with by
default. The one-boot `/etc/init.d/ssh start` method above remains the
only empirically working method in this document. Both live tests were
performed on the spare board only, with `/conf/crontab` backed up before
each attempt and byte-for-byte restored (hash-verified) afterward —
production was never touched by any of this.

### Survey of every other boot/event mechanism that could fire `/etc/init.d/ssh start` from a writable location

Since cron is a dead end (for now), went looking for any other trigger —
anything that (a) can be configured from the writable JFFS2 config
partition alone, and (b) actually gets invoked in practice, unlike cron.
All of this is static analysis on production's mounted 12.61.39 rootfs
(read-only, no board touched). Checked and ruled out:

- **`/etc/inittab`** — read directly by `/sbin/init` (PID 1), which is
  where `sshd`-independent respawn entries would normally go. It's a
  real file inside the signed cramfs rootfs (not a symlink to `/conf`,
  unlike almost everything else this repo edits), so adding a
  `respawn:` line here needs the same signed-firmware patch as
  `ssh-main` itself. No win.

- **All `rc0.d`–`rc9.d` and `rcS.d` directories** — real directories
  inside the signed rootfs, not symlinks to anything writable. Can't
  drop a new `S*` script in without patching the signed image.

- **`inetd`** (`/usr/sbin/inetd` exists) — not started anywhere in any
  `rc*.d`, and `/etc/inetd.conf` doesn't even exist. Would need a
  one-time launch to be useful at all, which brings no benefit over
  just running `/etc/init.d/ssh start` directly during that same console
  session.

- **Network event hooks** (`/etc/network/{if-up,if-down,if-pre-up,
  if-post-down,udhcpc.d}/*`) — real directories in the signed rootfs
  (can't add new scripts), and every existing script in them only reads
  plain config *values* from `/conf` (DDNS on/off, a redfish CA URL,
  routing feature flags) — none of them execute an arbitrary path or
  scan a writable directory for extra scripts to run. `udhcpc.script`
  does glob `/etc/network/udhcpc.d/*` dynamically, but that directory
  itself is read-only, so nothing can be added to the glob.

- **rsyslog's `omprog` action module** (would let a syslog rule execute
  an arbitrary external command) — `/etc/rsyslog.conf` genuinely is a
  symlink to `/conf/rsyslog.conf` and is fully writable, but
  `/usr/lib/rsyslog/` on this firmware only ships `imklog.so`,
  `immark.so`, `imuxsock.so`, and the network/compression modules —
  no `omprog.so`. Without that module, rsyslog can't be configured to
  execute a program on a log event here, no matter what the writable
  config says.

- **AMI's own `sync-agent` inotify-watch framework**
  (`subagents/notify.lua`, `notify_fn_map.lua`, `notify_mask_map.lua`)
  — this one's real and does execute shell commands via `os.execute()`
  on file-change events (confirmed in the decompiled-bytecode strings,
  e.g. an `IN_MODIFY` watch on some file mapped to
  `touch /tmp/reload-notify`), and even supports an "extensions" system
  (`extend_notify_map`, `get_modules` from an `extensions` directory).
  But the watch/action mapping and the extension modules are all
  precompiled LuaJIT bytecode living in the signed rootfs
  (`/usr/local/sync-agent/*`), not read from anywhere on `/conf`. Same
  wall as everything else on this list — flexible mechanism, no writable
  entry point into it found.

**Conclusion so far**: every boot-time or event-driven trigger mechanism
on this firmware either lives entirely inside the signed rootfs, or (in
cron's case) is theoretically reachable from the writable JFFS2 partition
but doesn't actually fire for reasons still unexplained. Nothing found
gives a writable-only path to persistent SSH that doesn't ultimately run
into either "patch the signed rootfs" (ties back to PeterF's u-boot
theory) or "figure out why cron is inert" (still open). If anyone finds
another angle — a different daemon, a different config file with a
program-execution hook — it's worth adding to this list either way,
confirmed or ruled out.

## The OEM `AMISetServiceConf` command — a console-free way to bring SSH up (GET confirmed, SET untested)

The `[feature] Add gbt oem cmd to enable/disable ssh` changelog entry
(12.60.39, see the version timeline above) turned out to be real, findable,
and — unlike the cron approach — **doesn't require any console access at
all**, since it's invoked over IPMI, which is reachable both locally (KCS,
from whatever host owns the board) and over the network (IPMI-over-LAN,
port 623 — already confirmed open on both boards via `NetworkProtocol`
above).

**Where it lives**: `/usr/local/lib/libipmiamioemserviceconf.so` on both
boards' rootfs (same file size on production 12.61.39 and spare 12.49.06 —
this feature has been stable across a huge version range). Exported
symbols `AMIGetServiceConf` / `AMISetServiceConf`, registered in a small
command table (`g_ServiceConf_CmdHndlr`) found at a fixed offset in the
library's `.rodata`. The string table in the same library contains, among
other things, the literal shell commands this thing runs:

```
sed -i '/DenyUsers sysadmin/d' /conf/ssh_server_config
/etc/init.d/ssh restart &
echo DenyUsers s...
```

— i.e. it's built on exactly the same `check_conf_presence()`-style logic
already documented above — and a second string,
`/etc/init.d/ssh force-stop` / `/etc/init.d/ssh start &`, matching a
generic "restart this service" path shared with other services
(`hdserver`, etc.) in a sibling library.

**Reverse-engineered from the command table + live GET probing (no
disassembler needed, just `nm -D`, `readelf`, and raw byte inspection)**:

- **netFn = `0x32`**, **cmd = `0x69`** (Get), **cmd = `0x6a`** (Set) — found
  by noting `0x32`/`0x69` was the only netFn/cmd pair out of several
  candidates that returned a *specific* completion code (`0xC7`, request
  data length invalid) instead of the generic `0xC1` (invalid command)
  every wrong guess returned.
- **Request payload = 4 bytes: `[ServiceID, 0x00, 0x00, 0x00]`** — found
  by testing payload lengths 1–4; only length 4 stopped returning `0xC7`
  (moved to `0xCC`, invalid data field, meaning the length was now right
  and only the value was wrong).
- **ServiceID `0x20` (32) = SSH** — confirmed by decoding the GET response:
  the returned struct includes a port field that reads `22` (`0x0016`)
  only for this ID. Other valid IDs found: `0x01`/`0x02`/`0x04`/`0x10`
  (all web-related services on ports 80/443 — lighttpd, Redfish, KVM/HTML5,
  and a fourth unidentified one); `0x08` consistently returns a distinct
  `0xFF` "unspecified error" rather than a clean success or rejection —
  unexplained, possibly a service ID that exists in the enum but isn't
  wired up correctly on this hardware.
- Tested **read-only** (`0x69`, Get) against spare (12.49.06) first. On
  spare, SSH's `Enable` byte in the response reads `1` — consistent with
  its `sshd` actually being reachable. What it actually changes given
  `sshd`'s boot-time state is separately controlled by `ssh-main` on
  12.61.39+ (see above) — plausible this only gives the same *one-boot*
  bring-up as running `/etc/init.d/ssh start` manually, not persistence,
  since the underlying action is the same init script. Set (`0x6a`) was
  explored afterward — see below.

**How this GET was actually reached**, since it's not a KCS/local-only
trick: the BMC's own `ipmitool` build only supports `lan`/`lanplus`
interfaces (no local/loopback mode), and its own OS-level `sysadmin` SSH
account **is not a valid IPMI-over-LAN user at all** —
`/conf/BMC1/UserConfig.ini` only has one named entry, `admin`. So this was
done via `ipmitool -I lanplus -H <bmc-ip> -U admin -P <password> raw 0x32
0x69 0x20 0x00 0x00 0x00`, run from a separate Linux box on the same LAN,
authenticating as the web-UI `admin` account over IPMI's own protocol —
completely independent of `sshd`'s state, which is exactly why this is
promising: it works even when SSH itself is fully down.

**Status on production (12.61.39): confirmed, run manually by the board
owner directly (not through automation — this session's auto-mode
classifier reasonably blocks raw IPMI commands aimed at production).**
The response is **byte-for-byte identical** to spare's:

```
20 00 00 00 01 62 6f 6e 64 30 00 00 00 00 00 00
00 00 00 00 00 00 ff ff ff ff 16 00 00 00 58 02
00 00 ff 80 3c 00 00 00 08 07 00 00
```

Same `Enable=1`, same port `22` (`16 00 00 00`), same interface `bond0`,
same timeouts. This is clean, direct confirmation of the prediction: the
config-level "Enable" flag for `SSH_SERVICE` reads enabled on production
even though `sshd` is definitively not listening (confirmed earlier by
the TCP port-22 scan). `ssh-main`'s boot-time `start; stop` overrides this
config state unconditionally — the OEM command's stored "should be
enabled" intent and the daemon's actual runtime state are just
disconnected from each other on this firmware version. One more piece of
evidence, on top of the `DenyUsers`/Redfish/cron findings above, that the
config layer and the boot-time enforcement layer on 12.61.39 don't agree
with each other anywhere they overlap.

### The Set command (`0x6a`) — length found, exact payload format unsolved

Explored on spare only, never attempted on production. Every step below
returned a non-zero completion code, meaning the request was rejected
before any `system()` call could fire — same safety property as every
other rejected attempt in this document; nothing on spare changed state
at any point.

- Naively replaying spare's own 44-byte GET response verbatim as the Set
  payload (`ServiceID=0x20`, `Enable=1`, same everything) returned `0xC7`
  (request data length invalid) — so Set's expected length isn't 44, and
  isn't the same as GET's response shape.
- Bisected by truncating that same payload to shorter lengths (8, 12, 16,
  20, 24, 28, 32, 36 bytes). Lengths 8–32 all returned `0xC7`. **Length 36
  returned a different code, `0x82`** — meaning 36 is the correct (or at
  least an accepted) request length; something changed between 32 and 36.
- Traced `0x82` via disassembly (Capstone, ARM mode, no source needed) to
  `libipmiamioemserviceconf.so`+`0x28ac`:
  ```
  mvn  r3, #0x7d      ; r3 = 0x82 — the actual completion code returned
  mov  r0, #0x82      ; unrelated: severity arg for the debug-log call below
  strb r3, [r6]       ; store completion code into the response
  ```
  reached via `bne #0x28ac` after a call at `0x2410` (`bl #0x13d0`) that
  takes the ServiceID byte and a byte from near the end of the request
  buffer — almost certainly a port-validation check (`isPortAllowed` /
  `isValidStandardPort`, both imported by this library). So: **length is
  right, content isn't** — most likely because GET's response field
  order/offsets and Set's expected request field order don't match
  (e.g. GET may include an echoed field Set doesn't expect, shifting
  every later field by a few bytes and landing garbage where the port
  value needs to be).

**Stopping here, documented as an unsolved lead rather than continued
guessing.** What's confirmed: netFn `0x32`, cmd `0x6a`, exactly 36 bytes,
first 4 bytes are `[ServiceID, 0, 0, 0]` same as Get. What's still open:
the exact byte layout of the remaining 32 bytes — almost certainly
`Enable` + interface name + port + timeout fields similar to what Get
returns, just not in the same arrangement. Solving it fully would need
tracing the byte-shuffle sequence between the function's entry and the
`0x2410` validation call in full (a few dozen more instructions than
covered here) — real additional reverse-engineering work, not a quick
guess. Whoever picks this up: start from `AMISetServiceConf` at file
offset matching symbol address `0x210c` in `libipmiamioemserviceconf.so`,
same technique as above (Capstone, ARM mode — Thumb mode disassembles to
garbage on this binary, ARM mode is correct).

**If Set is eventually solved and does turn out to only give a one-boot
bring-up** (plausible, since the underlying action found earlier is
literally `/etc/init.d/ssh force-stop; /etc/init.d/ssh start &`, the same
one-shot script as the console method): that would still fully replace
the SOL/UART/JTAG console requirement in the "one-time fix" section
above — an authenticated IPMI-over-LAN or local-KCS call is a much lower
bar than physical/serial console access. It would not solve persistence
(still needs PeterF's u-boot theory or a cron root-cause, per the
sections above), but it would make the one-boot workaround usable
remotely, any time, without hands on the hardware.

## Would a BMC firmware downgrade re-enable SSH, and would it even flash?

If a persistent fix stays out of reach, the obvious blunt alternative is
downgrading the whole BMC firmware to a version before the lockout ever
existed. Worth being precise about what's actually confirmed here versus
still genuinely unknown, since this is a real flash operation — much
higher stakes than anything else explored in this document so far.

**Would it re-enable SSH? Yes, definitely, if it boots.** Every version
finding above points the same way: below 12.60.41 there's no `DenyUsers
sysadmin` line at all; below 12.61.39 `sshd` is never force-stopped by
`ssh-main`; and `admin` (the account anyone would actually log in as)
was never blocked by any of this at any version — only the internal
`sysadmin` account ever was, starting at 12.60.41. So any firmware below
12.61.39 gets you a normally-running `sshd` with unrestricted `admin`
login, and below 12.60.41 even `sysadmin` works too. This part isn't in
doubt.

**Would `gigaflash` even accept an older image? Likely yes.** Checked all
three host-side tool binaries (`gigaflash`, `gigaflash_x64`,
`gigaflash_arm`) for any version-comparison/anti-rollback logic —
found none. What *is* there, right next to Gigabyte's embedded RSA
public key: the tool's own error strings are `Verify signature fail` /
`Update fail`, appearing directly after `Loading Firmware...` in the
flash sequence. That's a **pure cryptographic signature check** —
authenticity, not recency. An older *official, Gigabyte-signed* firmware
image should pass this check exactly as well as the current one, since
it's signed with the same key. (Searched the entire firmware blob too,
not just the tool, for `downgrade`/`rollback`/`SVN`/"secure version"
strings — nothing beyond OpenSSL's own unrelated `sslv3 rollback attack`
boilerplate and a handful of coincidental byte-matches. Absence of a
string doesn't prove absence of a check, but it's a real negative
signal.)

**What's still genuinely unknown: whether the board actually *boots*
that older image afterward.** A signature-only check at flash time says
nothing about whether `u-boot` (or a separate secure-boot stage) enforces
a monotonic version/rollback counter before jumping to it — that's a
different, later checkpoint this investigation hasn't reached. If such a
check exists and blocks it, the failure mode could range from "refuses
to boot, falls back automatically" (see below — likely, on this
hardware) to something worse. This is the real open question, not
whether `gigaflash` will *write* the older image.

**Why the risk is lower than it sounds on this specific board: it's
dual-image.** `gigaflash`'s own usage text takes a `-cs <0|1>` address
argument — 0=Active, 1=Backup — confirmed by `DualImageCfg.ini`
(`FwUploadSelector`) already present in the config partition. The
changelog additionally documents, across several versions: a Redfish
`uploadSelector` supporting `image1`/`image2`/`both`/`autoInactive` for
"dual image BMC update," an OEM IPMI command to read the *backup* image's
version specifically, and — most relevant to safety — **an increased
watchdog (WDT2) timeout specifically for dual-image platforms, described
as triggering automatically "when some error occurred,"** strongly
implying an automatic fail-back-to-the-other-bank mechanism if one image
hangs or fails to come up. That means the sane way to ever try this is:
flash the older, legitimately-signed firmware to the **backup** bank
(`-cs 1`) only, leave the current, working 12.61.39 image untouched on
the active bank, and see whether it boots and whether SSH comes up —
with the current known-good state never actually at risk unless a
manual, deliberate switch to the backup bank is made afterward.

**Not attempted, and shouldn't be without more groundwork first**:
sourcing an actual older, officially-signed firmware image (this repo
only has 12.61.39 and 12.49.06 — the latter is spare's *current* running
version, not a spare downgrade target; an older signed image for
production's exact board model would need to come from Gigabyte's own
download archive, and its authenticity/signature should be verified
before ever touching real hardware with it), and understanding the exact
bank-switch/failover mechanism (GPIO-based per an old changelog entry —
`"check set gpio low to get second image"` — not yet read in detail)
well enough to know how to verify the backup bank booted *without*
already having SSH into it to check.

## Community lead: manual `SKU.BIN` construction, and a u-boot unsigned-flash theory (PeterF)

PeterF (see attribution at top) shared further detail via forum PM on his
original investigation, worth recording here for anyone picking up the
open threads above:

- **`SKU.BIN` format, confirmed independently.** Before tools like
  `gigaflash -sku` existed, he built `SKU.BIN` files by hand: it's a
  gzip-compressed `SKU.xml` wrapped in a container with pointers and
  checksums. Matches this repo's own `build_sku_bin.sh` structure. One
  caveat worth flagging explicitly: **you can't build a `SKU.BIN` from
  scratch** — it has to start from a dump of your own board, because
  board-unique fields (serials, MACs) live inside it. Same constraint this
  repo already follows (Path B never touches those fields), just confirms
  it's a hard requirement, not caution.

- **JTAG + serial console** were his main tools for understanding BMC
  bootup behavior — reading the boot log over UART taught him most of what
  he knew about the boot sequence. This repo hasn't used JTAG at all; the
  `sysadmin` lockout work above relied on SOL/Redfish/offline JFFS2
  extraction instead. Worth keeping in mind as an avenue if a board ever
  needs lower-level debugging than SOL can offer.

- **Full BMC firmware image: disassembled, patched, never flashed.** He
  went further than the JFFS2 config-partition work here — took apart the
  *entire* BMC flash image, rebuilt the filesystems inside it, and added
  his own hacks directly (telnet, `nc`, extra user/password entries). He
  could never get it to flash, because he never found a way around the
  firmware's **signature verification**. This is a different, harder
  barrier than the config-partition question left open above (that one is
  about which `gigaflash` write mode accepts a full partition image, not
  about defeating a signature check on the main firmware itself) — the two
  shouldn't be conflated.

- **Theory, untested: raw unsigned flash from the u-boot prompt.** His
  suspicion is that the signature check lives in the normal boot/flash-tool
  path, not in u-boot itself — so a raw, unsigned image might flash
  successfully if written directly from the u-boot prompt, bypassing
  whatever validates it later. He never tested this (only has the one
  board, and bricking it isn't worth the risk solo). Flagging it here as a
  lead for anyone with a spare board and UART/JTAG access willing to try —
  if it works, it's a plausible route to the still-unverified full-partition
  write mentioned in the SSH lockout section above, and potentially a route
  to a persistent (reflash-proof) SSH fix instead of the current manual
  per-boot edit.

- He's run his modified system for **2.5 years continuously** without
  updating BMC firmware, specifically to keep SSH access — same tradeoff
  this repo documents (older firmware = SSH still works; newer firmware =
  locked out via `DenyUsers`).

## The missing web-UI SSH controls are cosmetic, not functional

On the production board's web UI, **Settings → Services** (which on the
spare board has an SSH enable/disable toggle) is missing entirely, and
**Settings → User Management** is missing the "Existing SSH Key / Upload SSH
Key / Delete" fields for the `admin` user. Both turned out to be UI-only
removals — the backend for each is fully intact and functional on production:

- **SSH-key field**: AMI's own IPMI user database (`UserConfig.ini`,
  `UserEncPswd.ini`, `FixedUserInfo.ini` under `/conf/BMC1/`) has no SSH-key
  fields at all, on either board — the upload feature was never backed by
  that database. It's plain OpenSSH convention
  (`AuthorizedKeysFile /conf/user_home/%u/.ssh/authorized_keys`), and that
  exact path/file already exists on production, empty, identical to the
  spare board. The storage location the button would write to is there;
  only the button is gone.

- **Services SSH toggle**: the backend is the standard Redfish
  `ManagerNetworkProtocol` resource. Querying it directly on production,
  bypassing the web UI entirely:

  ```powershell
  curl.exe -k -u admin:<password> https://<production-ip>/redfish/v1/Managers/Self/NetworkProtocol
  ```

  returns (trimmed):
  ```json
  "SSH": { "Port": 22, "ProtocolEnabled": true }
  ```

  Digging into the compiled Lua behind it
  (`/usr/local/redfish/redfish/manager/network-protocol.lua` — binary
  bytecode, read with `grep -a` since `cat` mangles the terminal) shows a
  fully implemented property: `SSH.Port`, `SSH.ProtocolEnabled`, PATCH
  support with type validation, backed by a Redis key
  (`Redfish:Managers:Self:NetworkProtocol:SSH`, matching the
  `redis-dump.rdb.gz` / `RedisdbChecksum` files already present in the
  config partition). None of this lives in any `.ini` file — it's Redis
  state, a separate subsystem from everything else checked in this doc.

**Correction, now that production is confirmed on 12.61.39**: an earlier
version of this section read the `ProtocolEnabled: true` response above as
proof the SSH daemon itself was alive and reachable, just gated by
`DenyUsers`. That's wrong for this specific board. A direct TCP check
against production (`Test-NetConnection <production-ip> -Port 22`) fails —
**nothing is listening on port 22 at all**. That lines up exactly with the
`[feature] Remove SSH service.` changelog entry for 12.61.39 documented
above: `sshd` isn't blocked here, it's gone. The Redfish `SSH` object is
leftover Redis state that was never cleared when the service was pulled —
cosmetic in a different, more misleading way than the missing UI buttons:
the UI omission is honest about SSH being unavailable, while the Redfish
field actively claims it's enabled when it demonstrably isn't listening.
Don't trust `ProtocolEnabled` on this resource as a signal of whether
`sshd` is actually running — check the port directly.

The `authorized_keys` path and IPMI user DB findings above are unaffected
by this correction — those are genuinely inert-but-present regardless of
SSH daemon state. **On boards still in the 12.60.41–12.61.38 window**
(daemon present, only `sysadmin` blocked), the original reading holds: the
daemon really is live on port 22 for every other account, and
`ManagerNetworkProtocol` accurately reflects that. The distinction only
matters once a board reaches 12.61.39, where the field goes stale.

**Net effect**: on production firmware (12.61.39), Gigabyte pulled the
web-UI control surface *and* the SSH daemon itself, but left
`authorized_keys` plumbing and the Redfish/Redis `SSH` descriptor behind as
inert leftovers — none of which can be used to bring SSH back without
either a full-partition JFFS2 restore to pre-12.61.39 firmware or,
per the u-boot theory noted above (PeterF's community lead), a way to
write an older or modified image directly.

As a final check, a `PATCH` to `SSH/ProtocolEnabled` (via `If-Match` with a
fresh ETag) was sent to the same production endpoint to confirm the write
path, not just the read path, is live:

```json
{"error":{"@Message.ExtendedInfo":[{"Message":"Cannot patch the value which already applied","MessageArgs":["true","SSH/ProtocolEnabled"],"MessageId":"SyncAgent.1.0.PatchValueAlreadyExists"}]}}
```

`PatchValueAlreadyExists` is the exact string found in the compiled Lua
earlier — the ETag precondition passed and the handler evaluated the request
for real, then rejected it only because `true` was already the current value.
That's full end-to-end confirmation the backend is a live, functional
resource, not a UI stub sitting in front of something removed.
