#!/usr/bin/env bash
# Credit to PeterF (ServeTheHome, Jan 2024, plus a follow-up on the
# SSH-lockout problem in Apr 2024) and Oliver Obenland (Feb 2024,
# independently), who documented the underlying identity-gating issue on
# this board family:
# https://forums.servethehome.com/index.php?threads/gigabyte-mj11-ec1-epyc-3151-mystery.41395/post-407547
# https://forums.servethehome.com/index.php?threads/gigabyte-mj11-ec1-epyc-3151-mystery.41395/post-424378
# https://oliver.obenland.it/gigabyte-mj11-ec1-alle-luefter-per-pwm-steuern/
#
# Compiles a Gigabyte BMC SKU.xml into a flashable SKU.BIN, with no SSH access
# to any BMC required. Extracts SKU.xml from a config backup, applies the
# identity edit, then extracts the ARM bmcprog compiler out of a firmware
# dump's cramfs rootfs and runs it under qemu-arm emulation.
#
# SECURITY REQUIREMENT, not just a suggestion: run this in a disposable,
# network-isolated VM with no shared folders or credentials exposed. It
# mounts an untrusted filesystem image through the kernel cramfs driver and
# executes a foreign-arch binary (bmcprog) extracted from it under qemu-arm
# user-mode emulation. The script will prompt before that step (unless
# --yes); the prompt is a safety gate, not a formality.
#
# Platform requirements: Linux (kernel cramfs mount support), Bash 4+, GNU
# coreutils (the `dd ... iflag=skip_bytes,count_bytes` usage is GNU-specific).
# Tested on Debian/Ubuntu. Required tools are checked explicitly at startup;
# the script aborts with a concrete list rather than installing anything at
# the system level. The only auto-installed dependency is `jefferson`
# (JFFS2 extractor, not a Debian package), installed at a pinned version
# into an isolated venv under the script's own temp directory — nothing is
# installed into the system Python.
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
# --yes skips BOTH confirmation prompts: the SKU.xml identity-edit review,
# and the untrusted-mount/qemu-exec warning. Only use it once you've already
# reviewed both manually on a prior run.
#
# Output:
#   ./sku_build/SKU.BIN  - compiled, ready for `gigaflash -sku`
#   ./sku_build/SKU.xml  - the XML that was actually compiled (for the record)

set -euo pipefail
umask 077

if [ "$(uname -s)" != "Linux" ]; then
  echo "ERROR: this script requires Linux (kernel cramfs mount support, qemu-arm user-mode emulation)." >&2
  exit 1
fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "ERROR: this script requires Bash 4 or newer." >&2
  exit 1
fi

IN_DIR="."
IN_DIR_SET=0
NEW_PRODUCT_NAME=""
NEW_FAN_PROFILE=""
AUTO_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --product-name)
      [ $# -ge 2 ] || { echo "ERROR: --product-name requires a value" >&2; exit 1; }
      NEW_PRODUCT_NAME="$2"; shift 2 ;;
    --fan-profile)
      [ $# -ge 2 ] || { echo "ERROR: --fan-profile requires a value" >&2; exit 1; }
      NEW_FAN_PROFILE="$2"; shift 2 ;;
    --yes)
      AUTO_YES=1; shift ;;
    -*)
      echo "ERROR: unknown option: $1" >&2; exit 1 ;;
    *)
      if [ "$IN_DIR_SET" = "1" ]; then
        echo "ERROR: unexpected extra argument: $1 (input_dir already set to $IN_DIR)" >&2
        exit 1
      fi
      IN_DIR="$1"; IN_DIR_SET=1; shift ;;
  esac
done

DUMP="$IN_DIR/bmc_full_dump.bin"
CONFIG_BACKUP="$IN_DIR/bmc_config_backup.bin"
XML="$IN_DIR/SKU.xml"
WORK="$(mktemp -d)"
OUT_DIR="./sku_build"
MOUNT_DIR="$WORK/mnt"

SUCCESS=0
cleanup() {
  if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    sudo umount "$MOUNT_DIR" 2>/dev/null || true
  fi
  if [ "$SUCCESS" = "1" ]; then
    rm -rf "$WORK"
  else
    echo "NOTE: leaving working directory for inspection: $WORK" >&2
  fi
}
trap cleanup EXIT

echo "==> Checking inputs"
[ -f "$DUMP" ] || { echo "ERROR: $DUMP not found. Run 'gigaflash -dump bmc_full_dump.bin' on the target BMC first."; exit 1; }
echo "    dump: $DUMP ($(stat -c%s "$DUMP" 2>/dev/null || stat -f%z "$DUMP") bytes)"

echo "==> Checking dependencies"
REQUIRED_TOOLS=(python3 dd qemu-arm sudo mountpoint mount umount modprobe find tail file stat)
MISSING=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: missing required tool(s): ${MISSING[*]}" >&2
  echo "  On Debian/Ubuntu: sudo apt-get install coreutils qemu-user util-linux kmod findutils file python3" >&2
  exit 1
fi

NEED_JEFFERSON=0
JEFFERSON="jefferson"
if [ ! -f "$XML" ] && [ -f "$CONFIG_BACKUP" ]; then
  NEED_JEFFERSON=1
  python3 -m venv --help >/dev/null 2>&1 || {
    echo "ERROR: python3-venv is required to install jefferson in an isolated environment." >&2
    echo "  On Debian/Ubuntu: sudo apt-get install python3-venv" >&2
    exit 1
  }
fi

sudo modprobe cramfs 2>/dev/null || echo "    (cramfs module unavailable — will try mounting anyway; some kernels build it in)"
mkdir -p "$MOUNT_DIR"

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

  if [ "$NEED_JEFFERSON" = "1" ]; then
    echo "==> Installing jefferson (JFFS2 extractor) into an isolated venv (pinned version, no system-wide changes)"
    python3 -m venv "$WORK/venv"
    "$WORK/venv/bin/pip" install --quiet "jefferson==0.4.7"
    JEFFERSON="$WORK/venv/bin/jefferson"
  fi

  echo "==> Extracting SKU.xml from $CONFIG_BACKUP"

  # JFFS2 doesn't start at byte 0 of the config partition — locate its magic
  # (0x1985 LE = bytes 85 19) rather than assuming a fixed offset.
  JFFS2_OFFSET="$(python3 - "$CONFIG_BACKUP" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read()
i = data.find(b'\x85\x19')
if i == -1:
    raise SystemExit('no JFFS2 magic found')
print(i)
PYEOF
)"
  echo "    JFFS2 filesystem starts at offset $JFFS2_OFFSET"
  tail -c +"$((JFFS2_OFFSET + 1))" "$CONFIG_BACKUP" > "$WORK/conf_body.jffs2"

  JEFFERSON_STATUS=0
  "$JEFFERSON" "$WORK/conf_body.jffs2" -d "$WORK/extracted" -f >"$WORK/jefferson.log" 2>&1 || JEFFERSON_STATUS=$?
  if [ "$JEFFERSON_STATUS" != "0" ]; then
    echo "ERROR: jefferson exited with status $JEFFERSON_STATUS. Log:" >&2
    cat "$WORK/jefferson.log" >&2
    echo "Working directory (preserved for inspection): $WORK" >&2
    exit 1
  fi
  ORIG_XML="$(find "$WORK/extracted" -iname 'SKU.xml' -print -quit)"
  [ -n "$ORIG_XML" ] || { echo "ERROR: SKU.xml not found inside extracted config partition. jefferson output may have failed — inspect $WORK/extracted manually."; exit 1; }
  echo "    found: $ORIG_XML"

  echo "==> Applying identity edit"
  echo "    ProductName -> $NEW_PRODUCT_NAME"
  echo "    FanProfile  -> $NEW_FAN_PROFILE"
  python3 - "$ORIG_XML" "$WORK/SKU.xml" "$NEW_PRODUCT_NAME" "$NEW_FAN_PROFILE" <<'PYEOF'
import re, sys
from xml.sax.saxutils import escape

orig_path, out_path, new_product_name, new_fan_profile = sys.argv[1:5]
old = open(orig_path, encoding='utf-8').read()

def replace_one(text, tag, new_value):
    pattern = re.compile(f'(<{tag}>)([^<]*)(</{tag}>)')
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        sys.exit(f"ERROR: expected exactly one <{tag}> element, found {len(matches)}")
    escaped = escape(new_value)
    m = matches[0]
    return text[:m.start()] + f'<{tag}>{escaped}</{tag}>' + text[m.end():]

new = replace_one(old, 'ProductName', new_product_name)
new = replace_one(new, 'FanProfile', new_fan_profile)

def normalize(text):
    text = re.sub(r'(<ProductName>)[^<]*(</ProductName>)', r'\1\2', text)
    text = re.sub(r'(<FanProfile>)[^<]*(</FanProfile>)', r'\1\2', text)
    return text

# Verify the edit touched nothing outside these two fields.
if normalize(old) != normalize(new):
    sys.exit("ERROR: edit touched content outside ProductName/FanProfile — aborting")

open(out_path, 'w', encoding='utf-8').write(new)
print(f"    wrote {out_path}")
PYEOF

  echo "==> Diff (identity fields only — everything else, including serials/MACs, is untouched)"
  python3 - "$ORIG_XML" "$WORK/SKU.xml" <<'PYEOF'
import re, sys
old = open(sys.argv[1], encoding='utf-8').read()
new = open(sys.argv[2], encoding='utf-8').read()
for field in ['ProductName', 'BoardProductName', 'FanProfile', 'BoardSerialNumber', 'ProductSerialNumber', 'MacAddr0']:
    ov = re.findall(f'<{field}>([^<]*)</{field}>', old)
    nv = re.findall(f'<{field}>([^<]*)</{field}>', new)
    marker = ' *** CHANGED ***' if ov != nv else ''
    print(f"    {field}: {ov} -> {nv}{marker}")
PYEOF

  # Hard safety check: board-unique fields must never change here, regardless
  # of what the edit above matched — catch a bad --fan-profile/--product-name
  # value colliding with something it shouldn't before it ever reaches bmcprog.
  # (Belt-and-suspenders alongside the normalize() check inside the edit step
  # above, which already verifies this more generally.)
  python3 - "$ORIG_XML" "$WORK/SKU.xml" <<'PYEOF'
import re, sys
old = open(sys.argv[1], encoding='utf-8').read()
new = open(sys.argv[2], encoding='utf-8').read()
for field in ['BoardSerialNumber', 'ProductSerialNumber', 'MacAddr0']:
    if re.findall(f'<{field}>([^<]*)</{field}>', old) != re.findall(f'<{field}>([^<]*)</{field}>', new):
        print(f"ERROR: {field} changed — this should never happen. Aborting.", file=sys.stderr)
        sys.exit(1)
PYEOF

  if [ "$AUTO_YES" != "1" ]; then
    read -r -p "Proceed with compiling this SKU.xml? [y/N] " REPLY
    case "$REPLY" in
      [yY]|[yY][eE][sS]) ;;
      *) echo "Aborted."; exit 1 ;;
    esac
  fi
fi

if [ "$AUTO_YES" != "1" ]; then
  echo ""
  echo "WARNING: the next step mounts an untrusted cramfs filesystem parsed"
  echo "from $DUMP via the kernel driver, then runs the foreign-arch bmcprog"
  echo "binary extracted from it under qemu-arm emulation. This is a real"
  echo "security boundary, not just a recommendation — only continue in a"
  echo "disposable, network-isolated VM with no shared folders or"
  echo "credentials exposed to it."
  read -r -p "Continue? [y/N] " REPLY
  case "$REPLY" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
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
python3 - "$BUILD_DIR/SKU.BIN" "$WORK/SKU.xml" <<'PYEOF'
import gzip, re, sys
bin_path, xml_path = sys.argv[1], sys.argv[2]
data = open(bin_path, 'rb').read()
assert data[:8] == b'GIGABYTE', f"bad header magic: {data[:8]!r}"
gi = data.find(b'\x1f\x8b')
assert gi != -1, "no gzip section found"
embedded_xml = gzip.decompress(data[gi:]).decode()
assert '<GSSKU>' in embedded_xml, "embedded XML doesn't look like a SKU document"

compiled_xml = open(xml_path, encoding='utf-8').read()

def field(text, tag):
    m = re.search(f'<{tag}>([^<]*)</{tag}>', text)
    return m.group(1) if m else None

for tag in ['ProductName', 'FanProfile']:
    expected = field(compiled_xml, tag)
    actual = field(embedded_xml, tag)
    assert expected == actual, f"{tag} mismatch: SKU.BIN has {actual!r}, expected {expected!r}"

print(f"    OK: {len(data)} bytes, header valid, embedded XML matches compiled SKU.xml "
      f"(ProductName={field(embedded_xml, 'ProductName')!r}, FanProfile={field(embedded_xml, 'FanProfile')!r})")
PYEOF

echo "==> Publishing output"
if [ -L "$OUT_DIR" ]; then
  echo "ERROR: $OUT_DIR exists and is a symlink — refusing to publish through it." >&2
  exit 1
fi
STAGE_DIR="$(mktemp -d "./sku_build.XXXXXX")"
cp "$BUILD_DIR/SKU.BIN" "$STAGE_DIR/SKU.BIN"
cp "$WORK/SKU.xml" "$STAGE_DIR/SKU.xml"
rm -rf "$OUT_DIR"
mv "$STAGE_DIR" "$OUT_DIR"

SUCCESS=1

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
