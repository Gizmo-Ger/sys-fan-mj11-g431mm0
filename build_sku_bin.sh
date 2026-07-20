#!/usr/bin/env bash
# Credit to PeterF (ServeTheHome, Jan 2024) and Oliver Obenland (Feb 2024,
# independently), who documented the underlying identity-gating issue on
# this board family:
# https://forums.servethehome.com/index.php?threads/gigabyte-mj11-ec1-epyc-3151-mystery.41395/post-407547
# https://oliver.obenland.it/gigabyte-mj11-ec1-alle-luefter-per-pwm-steuern/
#
# Compiles a Gigabyte BMC SKU.xml into a flashable SKU.BIN, with no SSH access
# to any BMC required. Extracts SKU.xml from a config backup, applies the
# identity edit, then extracts the ARM bmcprog compiler out of a firmware
# dump's cramfs rootfs and runs it under qemu-arm emulation.
#
# Run this in a disposable VM, not on a hypervisor you care about — it mounts
# an untrusted filesystem image and executes a foreign-arch binary.
#
# Usage (auto-extract + auto-edit SKU.xml from a config backup):
#   ./build_sku_bin.sh [input_dir] --product-name NEW-NAME --fan-profile NewProfile [--yes]
#
# Usage (bring your own pre-edited SKU.xml, skip extraction/editing):
#   ./build_sku_bin.sh [input_dir]
#
# input_dir (default: current directory) must contain:
#   bmc_full_dump.bin     - full BMC firmware dump (`gigaflash -dump`)
#   EITHER:
#     bmc_config_backup.bin  - config partition (`gigaflash -backup`), used
#                              with --product-name/--fan-profile to auto-edit
#   OR:
#     SKU.xml                - already-edited XML, used as-is if present
#                              (takes priority over auto-extraction)
#
# Output:
#   ./sku_build/SKU.BIN  - compiled, ready for `gigaflash -sku`
#   ./sku_build/SKU.xml  - the XML that was actually compiled (for the record)

set -euo pipefail

IN_DIR="."
NEW_PRODUCT_NAME=""
NEW_FAN_PROFILE=""
AUTO_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --product-name) NEW_PRODUCT_NAME="$2"; shift 2 ;;
    --fan-profile)  NEW_FAN_PROFILE="$2"; shift 2 ;;
    --yes)          AUTO_YES=1; shift ;;
    *)              IN_DIR="$1"; shift ;;
  esac
done

DUMP="$IN_DIR/bmc_full_dump.bin"
CONFIG_BACKUP="$IN_DIR/bmc_config_backup.bin"
XML="$IN_DIR/SKU.xml"
WORK="$(mktemp -d)"
OUT_DIR="./sku_build"
MOUNT_DIR="$WORK/mnt"

cleanup() {
  if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    sudo umount "$MOUNT_DIR" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Checking inputs"
[ -f "$DUMP" ] || { echo "ERROR: $DUMP not found. Run 'gigaflash -dump bmc_full_dump.bin' on the target BMC first."; exit 1; }
echo "    dump: $DUMP ($(stat -c%s "$DUMP" 2>/dev/null || stat -f%z "$DUMP") bytes)"

echo "==> Checking dependencies"
NEED_PKGS=()
command -v python3 >/dev/null || NEED_PKGS+=(python3)
command -v dd >/dev/null || NEED_PKGS+=(coreutils)
command -v qemu-arm >/dev/null || NEED_PKGS+=(qemu-user)
if [ ! -f "$XML" ] && [ -f "$CONFIG_BACKUP" ]; then
  python3 -c "import pip" >/dev/null 2>&1 || NEED_PKGS+=(python3-pip)
fi
if [ "${#NEED_PKGS[@]}" -gt 0 ]; then
  echo "    installing: ${NEED_PKGS[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y "${NEED_PKGS[@]}"
fi
sudo modprobe cramfs 2>/dev/null || echo "    (cramfs module unavailable — will try mounting anyway; some kernels build it in)"
mkdir -p "$MOUNT_DIR" "$OUT_DIR"

# ---------------------------------------------------------------------------
# Stage 0: get SKU.xml — either use one already provided, or extract+edit one
# from a config backup.
# ---------------------------------------------------------------------------
if [ -f "$XML" ]; then
  echo "==> Using provided SKU.xml as-is (found in $IN_DIR, skipping extraction/edit)"
  cp "$XML" "$WORK/SKU.xml"
else
  [ -f "$CONFIG_BACKUP" ] || { echo "ERROR: neither $XML nor $CONFIG_BACKUP found. Provide one of them (run 'gigaflash -backup bmc_config_backup.bin' to get the latter)."; exit 1; }
  [ -n "$NEW_PRODUCT_NAME" ] && [ -n "$NEW_FAN_PROFILE" ] || { echo "ERROR: no SKU.xml provided, so --product-name and --fan-profile are required to auto-edit one from $CONFIG_BACKUP."; exit 1; }

  echo "==> Extracting SKU.xml from $CONFIG_BACKUP"
  python3 -m pip show jefferson >/dev/null 2>&1 || { echo "    installing jefferson (JFFS2 extractor)"; python3 -m pip install --quiet --break-system-packages jefferson 2>/dev/null || python3 -m pip install --quiet jefferson; }

  # JFFS2 doesn't start at byte 0 of the config partition — locate its magic
  # (0x1985 LE = bytes 85 19) rather than assuming a fixed offset.
  JFFS2_OFFSET="$(python3 -c "
data = open('$CONFIG_BACKUP','rb').read()
i = data.find(b'\x85\x19')
if i == -1:
    raise SystemExit('no JFFS2 magic found')
print(i)
")"
  echo "    JFFS2 filesystem starts at offset $JFFS2_OFFSET"
  tail -c +"$((JFFS2_OFFSET + 1))" "$CONFIG_BACKUP" > "$WORK/conf_body.jffs2"

  jefferson "$WORK/conf_body.jffs2" -d "$WORK/extracted" -f >/dev/null 2>&1 || true
  ORIG_XML="$(find "$WORK/extracted" -iname 'SKU.xml' | head -1)"
  [ -n "$ORIG_XML" ] || { echo "ERROR: SKU.xml not found inside extracted config partition. jefferson output may have failed — inspect $WORK/extracted manually."; exit 1; }
  echo "    found: $ORIG_XML"

  echo "==> Applying identity edit"
  echo "    ProductName -> $NEW_PRODUCT_NAME"
  echo "    FanProfile  -> $NEW_FAN_PROFILE"
  sed -E "s#(<ProductName>)[^<]*(</ProductName>)#\1${NEW_PRODUCT_NAME}\2#g; s#(<FanProfile>)[^<]*(</FanProfile>)#\1${NEW_FAN_PROFILE}\2#g" \
    "$ORIG_XML" > "$WORK/SKU.xml"

  echo "==> Diff (identity fields only — everything else, including serials/MACs, is untouched)"
  python3 -c "
import re
old = open('$ORIG_XML').read()
new = open('$WORK/SKU.xml').read()
for field in ['ProductName', 'BoardProductName', 'FanProfile', 'BoardSerialNumber', 'ProductSerialNumber', 'MacAddr0']:
    ov = re.findall(f'<{field}>([^<]*)</{field}>', old)
    nv = re.findall(f'<{field}>([^<]*)</{field}>', new)
    marker = ' *** CHANGED ***' if ov != nv else ''
    print(f'    {field}: {ov} -> {nv}{marker}')
"

  # Hard safety check: board-unique fields must never change here, regardless
  # of what the sed pattern above matches — catch a bad --fan-profile/
  # --product-name value colliding with something it shouldn't before it
  # ever reaches bmcprog.
  python3 -c "
import re, sys
old = open('$ORIG_XML').read()
new = open('$WORK/SKU.xml').read()
for field in ['BoardSerialNumber', 'ProductSerialNumber', 'MacAddr0']:
    if re.findall(f'<{field}>([^<]*)</{field}>', old) != re.findall(f'<{field}>([^<]*)</{field}>', new):
        print(f'ERROR: {field} changed — this should never happen. Aborting.', file=sys.stderr)
        sys.exit(1)
"

  if [ "$AUTO_YES" != "1" ]; then
    read -r -p "Proceed with compiling this SKU.xml? [y/N] " REPLY
    case "$REPLY" in
      [yY]|[yY][eE][sS]) ;;
      *) echo "Aborted."; exit 1 ;;
    esac
  fi
fi

echo "==> Locating cramfs partitions in firmware dump"
mapfile -t OFFSETS < <(python3 - "$DUMP" <<'PYEOF'
import struct, sys
data = open(sys.argv[1], 'rb').read()
magic = b'\x45\x3d\xcd\x28'
i = 0
while True:
    i = data.find(magic, i)
    if i == -1:
        break
    try:
        m, size, flags, future = struct.unpack_from('<IIII', data, i)
        sig = data[i+16:i+32]
        if sig == b'Compressed ROMFS' and 0 < size <= len(data) - i:
            print(i, size)
    except Exception:
        pass
    i += 1
PYEOF
)

if [ "${#OFFSETS[@]}" -eq 0 ]; then
  echo "ERROR: no cramfs partitions found in $DUMP. This board/firmware may use a different filesystem (squashfs/jffs2/ubifs) — extraction logic needs updating."
  exit 1
fi
echo "    found ${#OFFSETS[@]} cramfs partition(s)"

echo "==> Extracting bmcprog"
BMCPROG=""
for entry in "${OFFSETS[@]}"; do
  offset="${entry% *}"
  size="${entry#* }"
  slice="$WORK/slice_${offset}.cramfs"
  echo "    trying partition at offset $offset, size $size bytes"
  dd if="$DUMP" of="$slice" bs=1M skip="$offset" count="$size" iflag=skip_bytes,count_bytes status=none

  if sudo mount -t cramfs -o loop,ro "$slice" "$MOUNT_DIR" 2>/dev/null; then
    if [ -f "$MOUNT_DIR/usr/local/bin/bmcprog" ]; then
      cp "$MOUNT_DIR/usr/local/bin/bmcprog" "$WORK/bmcprog"
      BMCPROG="$WORK/bmcprog"
    fi
    sudo umount "$MOUNT_DIR"
  fi
  [ -n "$BMCPROG" ] && break
done

if [ -z "$BMCPROG" ]; then
  echo "ERROR: bmcprog not found in any cramfs partition. Check /usr/local/bin/ under each mounted partition manually."
  exit 1
fi
chmod +x "$BMCPROG"
echo "    bmcprog extracted: $(file -b "$BMCPROG")"

echo "==> Compiling SKU.BIN"
BUILD_DIR="$WORK/build"
mkdir -p "$BUILD_DIR"
cp "$WORK/SKU.xml" "$BUILD_DIR/SKU.xml"
( cd "$BUILD_DIR" && qemu-arm "$BMCPROG" WS=FULL_AREA )

if [ ! -f "$BUILD_DIR/SKU.BIN" ]; then
  echo "ERROR: bmcprog ran but produced no SKU.BIN — check the output above for errors."
  exit 1
fi

echo "==> Validating output"
python3 - "$BUILD_DIR/SKU.BIN" <<'PYEOF'
import gzip, sys
data = open(sys.argv[1], 'rb').read()
assert data[:8] == b'GIGABYTE', f"bad header magic: {data[:8]!r}"
gi = data.find(b'\x1f\x8b')
assert gi != -1, "no gzip section found"
xml = gzip.decompress(data[gi:]).decode()
assert '<GSSKU>' in xml, "embedded XML doesn't look like a SKU document"
print(f"    OK: {len(data)} bytes, header valid, embedded XML decompresses ({len(xml)} bytes)")
PYEOF

cp "$BUILD_DIR/SKU.BIN" "$OUT_DIR/SKU.BIN"
cp "$WORK/SKU.xml" "$OUT_DIR/SKU.xml"
echo ""
echo "=================================================================="
echo "SUCCESS: $OUT_DIR/SKU.BIN"
echo "=================================================================="
echo ""
echo "Next steps:"
echo "  1. Copy SKU.BIN and gigaflash_x64 onto the target host (the machine"
echo "     with KCS access to the BMC you're changing — e.g. the Proxmox"
echo "     host for a production board):"
echo "       scp $OUT_DIR/SKU.BIN gigaflash_x64 user@target-host:~/"
echo ""
echo "  2. On that host, write the identity (BMC will reset itself to apply;"
echo "     the host stays up, expect 1-3 min of BMC unavailability):"
echo "       ./gigaflash_x64 SKU.BIN -sku -2500"
echo ""
echo "  3. Verify via Redfish once the BMC is back:"
echo "       curl -k -u admin:<password> https://<bmc-ip>/redfish/v1/Systems/Self"
echo "       curl -k -u admin:<password> https://<bmc-ip>/redfish/v1/Chassis/Self/Thermal"
echo "     Check Model matches your intended identity, and SYS_FAN sensors"
echo "     report Status.State: Enabled."
echo ""
echo "  Keep a full '-backup'/'-dump' of the target taken BEFORE this, for"
echo "  rollback (revert = build a SKU.BIN from the original SKU.xml the"
echo "  same way and -sku it back)."
