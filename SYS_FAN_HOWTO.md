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
  back to the config-partition repack below. Not yet tested here.
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
