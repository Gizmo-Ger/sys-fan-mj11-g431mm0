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
# SECURITY REQUIREMENT, not just a suggestion: run this in a disposable VM
# with no shared folders or credentials exposed, ever. The specific step
# that needs to be network-isolated too is the untrusted-cramfs-mount +
# foreign-arch-binary-execution step (mounting $DUMP through the kernel
# cramfs driver, then running bmcprog, extracted from it, under qemu-arm
# emulation) — the script prompts before that exact step (unless --yes);
# that prompt is a safety gate, not a formality. The one earlier step that
# does need network access — installing `jefferson` from PyPI — happens
# before the untrusted dump is ever touched, and is separately hardened via
# pinned versions + verified hashes (--require-hashes) rather than isolation,
# since its threat model (a compromised PyPI package) differs from executing
# an arbitrary foreign firmware binary. If you need the whole run offline,
# pre-populate the venv's package cache before disconnecting the VM.
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
# --yes skips all three confirmation prompts: the SKU.xml identity-edit
# review, the network-isolation reminder before jefferson parses the
# untrusted config backup, and the untrusted-mount/qemu-exec warning. Only
# use it once you've already reviewed all three manually on a prior run.
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
OUT_DIR="./sku_build"

echo "==> Checking inputs"
[ -f "$DUMP" ] || { echo "ERROR: $DUMP not found. Run 'gigaflash -dump bmc_full_dump.bin' on the target BMC first."; exit 1; }
echo "    dump: $DUMP ($(stat -c%s "$DUMP" 2>/dev/null || stat -f%z "$DUMP") bytes)"

echo "==> Checking dependencies"
REQUIRED_TOOLS=(python3 dd qemu-arm sudo mountpoint mount umount modprobe find tail file stat uname mktemp cp mv rm mkdir chmod cat)
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
  # jefferson 0.4.7's dependency chain (click 8.4.2, dissect.cstruct 4.7)
  # requires Python >=3.10; the pinned lzallright wheel is glibc/x86_64-only.
  # Checked explicitly here (only when jefferson is actually needed) rather
  # than just requiring "some python3", since an older-Python or
  # non-x86_64 host would otherwise fail confusingly deep into the
  # hash-pinned install below.
  PYVER="$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || echo 0.0)"
  PYVER_MAJOR="${PYVER%%.*}"
  PYVER_MINOR="${PYVER#*.}"
  if [ "$PYVER_MAJOR" -lt 3 ] || { [ "$PYVER_MAJOR" -eq 3 ] && [ "$PYVER_MINOR" -lt 10 ]; }; then
    echo "ERROR: extracting SKU.xml from a config backup needs Python 3.10+ (found: ${PYVER:-none}) for the pinned jefferson/click/dissect.cstruct versions." >&2
    exit 1
  fi
  if [ "$(uname -m)" != "x86_64" ]; then
    echo "ERROR: jefferson's pinned lzallright dependency ships a compiled x86_64 wheel; $(uname -m) isn't supported by the pinned hash." >&2
    exit 1
  fi
fi

# Only create the working directory (and register cleanup) once the cheap,
# no-side-effect checks above have passed — an early usage mistake (missing
# dump file, missing tool) shouldn't leave anything behind under /tmp.
WORK="$(mktemp -d)"
MOUNT_DIR="$WORK/mnt"
STAGE_DIR=""
LOCK_DIR_HELD=""
SUCCESS=0
cleanup() {
  if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    sudo umount "$MOUNT_DIR" 2>/dev/null || true
  fi
  if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
    rm -rf "$STAGE_DIR"
  fi
  if [ -n "$LOCK_DIR_HELD" ] && [ -d "$LOCK_DIR_HELD" ]; then
    rmdir "$LOCK_DIR_HELD" 2>/dev/null || true
  fi
  if [ "$SUCCESS" = "1" ]; then
    rm -rf "$WORK"
  else
    echo "NOTE: leaving working directory for inspection: $WORK" >&2
  fi
}
trap cleanup EXIT

if [ "$NEED_JEFFERSON" = "1" ]; then
  # `python3 -m venv --help` succeeds even when the venv module can't
  # actually create a working environment (e.g. ensurepip missing) — the
  # only reliable check is to actually create one.
  VENV_PROBE="$WORK/venv-probe"
  if ! python3 -m venv "$VENV_PROBE" >/dev/null 2>&1; then
    echo "ERROR: python3 -m venv is required (to install jefferson in an isolated environment) but failed to create a working venv." >&2
    echo "  On Debian/Ubuntu: sudo apt-get install python3-venv" >&2
    exit 1
  fi
  rm -rf "$VENV_PROBE"
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
    echo "==> Installing jefferson (JFFS2 extractor) into an isolated venv (pinned version + hash-verified, no system-wide changes)"
    python3 -m venv "$WORK/venv"
    # Every package in jefferson 0.4.7's dependency chain, pinned to an exact
    # version and hash (obtained via `pip install --dry-run --report` against
    # the real package, not transcribed from a webpage). --require-hashes
    # makes pip refuse to install anything not listed here, so this also
    # catches a compromised/substituted package on PyPI's end, not just a
    # version drift. lzallright ships a compiled x86_64 wheel — these hashes
    # are for that architecture, matching the tested-platform note above; a
    # non-x86_64 host needs different hashes for that one package.
    cat > "$WORK/jefferson-requirements.txt" <<'REQEOF'
jefferson==0.4.7 --hash=sha256:161bbd4ee24ab0322bb04b22cb212ae9902e8d87fe659bf201f9c2e633545900
click==8.4.2 --hash=sha256:e6f9f66136c816745b9d65817da91d61d957fb16e02e4dcd0552553c5a197b76
dissect.cstruct==4.7 --hash=sha256:0427621ce67baa3106df2dc63a320d0a7f5c2da88ba3faf2ef5886a1a6b458fd
lzallright==0.2.6 --hash=sha256:bad91a3b9dde691a1aef2201f5d5dfa478ded10095383f76504532859a84fb48
REQEOF
    "$WORK/venv/bin/pip" install --quiet --require-hashes -r "$WORK/jefferson-requirements.txt"
    JEFFERSON="$WORK/venv/bin/jefferson"
  fi

  if [ "$AUTO_YES" != "1" ]; then
    echo ""
    echo "WARNING: dependency installation is done — the next step parses"
    echo "$CONFIG_BACKUP (untrusted binary data) with a third-party JFFS2"
    echo "extractor. If you're isolating this VM's network for the untrusted-"
    echo "data steps in this script, now is the point to disconnect it — no"
    echo "further network access is needed for the rest of this run."
    read -r -p "Continue? [y/N] " REPLY
    case "$REPLY" in
      [yY]|[yY][eE][sS]) ;;
      *) echo "Aborted."; exit 1 ;;
    esac
  fi

  echo "==> Extracting SKU.xml from $CONFIG_BACKUP"

  # JFFS2 doesn't start at byte 0 of the config partition — locate its magic
  # (0x1985 LE = bytes 85 19) rather than assuming a fixed offset. A bare
  # 2-byte match can occur by coincidence in unrelated data ahead of the
  # real filesystem, so require the 12-byte node header found there to
  # declare a plausible length that lands exactly on a second valid magic
  # (or cleanly on the end of the data) — verified against this project's
  # own real config backup, where node 1 (offset 65536, totlen=12) chains
  # directly to node 2's magic at 65548.
  JFFS2_OFFSET="$(python3 - "$CONFIG_BACKUP" <<'PYEOF'
import struct, sys

data = open(sys.argv[1], 'rb').read()

def node_ok(off):
    if off + 12 > len(data):
        return False
    magic, nodetype, totlen = struct.unpack_from('<HHI', data, off)
    if totlen < 12 or off + totlen > len(data):
        return False
    next_off = (off + totlen + 3) & ~3
    if next_off >= len(data):
        return True  # ran cleanly off the end - plausible last node
    return data[next_off:next_off + 2] == b'\x85\x19'

i = 0
while True:
    i = data.find(b'\x85\x19', i)
    if i == -1:
        raise SystemExit('no JFFS2 magic found (or none chain-validated)')
    if node_ok(i):
        print(i)
        break
    i += 1
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
  # -type f: jefferson preserves symlinks from the JFFS2 archive verbatim,
  # and a crafted config backup could plant a "SKU.xml" symlink pointing
  # anywhere on the filesystem — restrict to regular files so we never
  # read (or later overwrite) through one. Also require exactly one match
  # rather than silently taking whichever candidate the filesystem happens
  # to traverse first.
  mapfile -t XML_CANDIDATES < <(find "$WORK/extracted" -type f -iname 'SKU.xml')
  if [ "${#XML_CANDIDATES[@]}" -eq 0 ]; then
    echo "ERROR: SKU.xml not found inside extracted config partition. jefferson output may have failed — inspect $WORK/extracted manually."
    exit 1
  fi
  if [ "${#XML_CANDIDATES[@]}" -gt 1 ]; then
    echo "ERROR: found ${#XML_CANDIDATES[@]} SKU.xml files inside the extracted config partition, expected exactly one:" >&2
    printf '  %s\n' "${XML_CANDIDATES[@]}" >&2
    exit 1
  fi
  ORIG_XML="${XML_CANDIDATES[0]}"
  echo "    found: $ORIG_XML"

  echo "==> Applying identity edit"
  echo "    ProductName -> $NEW_PRODUCT_NAME"
  echo "    FanProfile  -> $NEW_FAN_PROFILE"
  python3 - "$ORIG_XML" "$WORK/SKU.xml" "$NEW_PRODUCT_NAME" "$NEW_FAN_PROFILE" <<'PYEOF'
import re, sys
from xml.sax.saxutils import escape

orig_path, out_path, new_product_name, new_fan_profile = sys.argv[1:5]
old = open(orig_path, encoding='utf-8').read()

def replace_all_uniform(text, tag, new_value):
    # SKU.xml legitimately repeats ProductName in both its <FRU> (live board
    # data) and <PROJECT> (template) sections. Require every existing
    # occurrence to already agree with each other before touching any of
    # them — if they don't, that's pre-existing inconsistency worth failing
    # loudly on rather than silently picking one.
    pattern = re.compile(f'(<{tag}>)([^<]*)(</{tag}>)')
    matches = list(pattern.finditer(text))
    if not matches:
        sys.exit(f"ERROR: expected at least one <{tag}> element, found 0")
    existing_values = {m.group(2) for m in matches}
    if len(existing_values) != 1:
        sys.exit(f"ERROR: <{tag}> occurrences disagree with each other before editing: {sorted(existing_values)!r} — refusing to guess which is right")
    escaped = escape(new_value)
    # Callable replacement, not an f-string: pattern.sub() treats a string
    # replacement's backslashes as backreferences (\2 would resolve to the
    # OLD value, silently reverting the edit for any new_value containing
    # e.g. a literal "\2"). A callable's return value is used verbatim.
    replaced = pattern.sub(lambda _m: f'<{tag}>{escaped}</{tag}>', text)
    if re.findall(f'<{tag}>([^<]*)</{tag}>', replaced) != [escaped] * len(matches):
        sys.exit(f"ERROR: <{tag}> replacement didn't take effect as expected — aborting")
    return replaced

def replace_single(text, tag, new_value):
    pattern = re.compile(f'(<{tag}>)([^<]*)(</{tag}>)')
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        sys.exit(f"ERROR: expected exactly one <{tag}> element, found {len(matches)}")
    escaped = escape(new_value)
    m = matches[0]
    replaced = text[:m.start()] + f'<{tag}>{escaped}</{tag}>' + text[m.end():]
    if re.findall(f'<{tag}>([^<]*)</{tag}>', replaced) != [escaped]:
        sys.exit(f"ERROR: <{tag}> replacement didn't take effect as expected — aborting")
    return replaced

new = replace_all_uniform(old, 'ProductName', new_product_name)
new = replace_single(new, 'FanProfile', new_fan_profile)

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

# Structural sanity check on $WORK/SKU.xml regardless of which path produced
# it (auto-edited above, or brought in as-is by the user) — a hand-provided
# SKU.xml was skipping this entirely before. Parse-only (not a
# reserialize-and-rewrite), to avoid the bmcprog-compatibility risk of
# reformatting the file. Uses expat directly with DOCTYPE rejected outright
# (blocks both XXE and billion-laughs, both of which require a DTD) rather
# than xml.etree.ElementTree, whose default entity handling isn't hardened
# against a maliciously crafted input file.
python3 - "$WORK/SKU.xml" <<'PYEOF'
import sys
import xml.parsers.expat

def _reject_doctype(*_args):
    raise ValueError("DOCTYPE declarations are not allowed in SKU.xml")

content = open(sys.argv[1], encoding='utf-8').read()
parser = xml.parsers.expat.ParserCreate()
parser.StartDoctypeDeclHandler = _reject_doctype
try:
    parser.Parse(content, True)
except (xml.parsers.expat.ExpatError, ValueError) as e:
    sys.exit(f"ERROR: {sys.argv[1]} is not well-formed XML: {e}")
PYEOF

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
# Uses explicit if/sys.exit rather than `assert` throughout: assert
# statements are silently stripped when Python runs with -O or
# PYTHONOPTIMIZE=1, which would turn every check below into a no-op and
# publish an unverified SKU.BIN as "OK".
python3 - "$BUILD_DIR/SKU.BIN" "$WORK/SKU.xml" <<'PYEOF'
import gzip, re, sys

bin_path, xml_path = sys.argv[1], sys.argv[2]
data = open(bin_path, 'rb').read()

if data[:8] != b'GIGABYTE':
    sys.exit(f"ERROR: bad header magic: {data[:8]!r}")

gi = data.find(b'\x1f\x8b')
if gi == -1:
    sys.exit("ERROR: no gzip section found in SKU.BIN")

embedded_xml = gzip.decompress(data[gi:]).decode()
if '<GSSKU>' not in embedded_xml:
    sys.exit("ERROR: embedded XML doesn't look like a SKU document")

compiled_xml = open(xml_path, encoding='utf-8').read()

# Every identity-relevant field bmcprog is fed must come back out unchanged
# in the compiled binary. Verified against a real build's actual embedded
# output (bmcprog reformats whitespace but preserves every field and the
# FRU+PROJECT structure) rather than assumed. Fields that legitimately
# repeat (FRU + PROJECT sections both carry these) are compared as the
# full ordered list of values, not just the first match.
FIELDS = [
    'ChassisSerialNumber', 'BoardManufacturerName', 'BoardProductName',
    'BoardSerialNumber', 'BoardPartNumber', 'ProductManufacturerName',
    'ProductName', 'ProductPartNumber', 'ProductVersion',
    'ProductSerialNumber', 'AssetTag', 'MacAddr0', 'FanProfile',
]

problems = []
for tag in FIELDS:
    expected = re.findall(f'<{tag}>([^<]*)</{tag}>', compiled_xml)
    actual = re.findall(f'<{tag}>([^<]*)</{tag}>', embedded_xml)
    if not expected:
        # A field missing from the *input* we compiled is a bug in this
        # script's own field list, not a bmcprog problem - fail loudly
        # rather than let it silently compare as "matching" against an
        # equally-absent field in the output.
        problems.append(f"{tag}: expected to find this field in the compiled SKU.xml but didn't")
        continue
    if expected != actual:
        problems.append(f"{tag}: SKU.BIN has {actual!r}, expected {expected!r}")

if problems:
    sys.exit("ERROR: SKU.BIN validation failed:\n  " + "\n  ".join(problems))

# The named-field list above only proves those specific fields survived -
# it wouldn't notice a change to fan tables, sensors, or anything else in
# the document. bmcprog only reformats indentation between elements
# (confirmed against a real build's actual output), so build a structural
# event stream of each document — element start (tag + sorted attrs), text
# content, element end — and compare those. Text nodes that are *purely*
# whitespace (indentation between sibling elements) are dropped entirely;
# anything else is compared byte-for-byte, unstripped, so a real value like
# "A B" vs "AB" (or a change hidden only by an all-whitespace-strip) is
# still caught, unlike a naive "remove every whitespace char" comparison.
import xml.parsers.expat

def canonical_events(xml_text):
    events = []

    def start_element(name, attrs):
        events.append(('start', name, tuple(sorted(attrs.items()))))

    def end_element(name):
        events.append(('end', name))

    def char_data(data):
        if data.strip() != '':
            events.append(('text', data))

    p = xml.parsers.expat.ParserCreate()
    p.StartElementHandler = start_element
    p.EndElementHandler = end_element
    p.CharacterDataHandler = char_data
    p.Parse(xml_text, True)
    return events

if canonical_events(compiled_xml) != canonical_events(embedded_xml):
    sys.exit("ERROR: embedded XML differs structurally from compiled SKU.xml — "
             "something beyond the named identity fields changed during compilation")

def field(text, tag):
    m = re.search(f'<{tag}>([^<]*)</{tag}>', text)
    return m.group(1) if m else None

print(f"    OK: {len(data)} bytes, header valid, full XML content matches compiled SKU.xml "
      f"(ProductName={field(embedded_xml, 'ProductName')!r}, FanProfile={field(embedded_xml, 'FanProfile')!r})")
PYEOF

echo "==> Publishing output"
# Guard against two concurrent runs both seeing OUT_DIR absent and racing
# to publish: `mkdir` is atomic, so only one process can win this lock.
# Without it, a second run's `mv` onto an existing directory (GNU mv,
# without -T) moves *into* it rather than replacing it, and would still
# report success while not actually being at the path it just printed.
LOCK_DIR="$OUT_DIR.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "ERROR: $LOCK_DIR exists — another run appears to be publishing to $OUT_DIR right now (or a previous run was killed mid-publish; remove $LOCK_DIR manually if so)." >&2
  exit 1
fi
LOCK_DIR_HELD="$LOCK_DIR"

if [ -e "$OUT_DIR" ] || [ -L "$OUT_DIR" ]; then
  echo "ERROR: $OUT_DIR already exists (possibly a dangling symlink). Refusing" >&2
  echo "to remove or overwrite it automatically — it may contain files this" >&2
  echo "script doesn't know about. Inspect it, then move it aside yourself" >&2
  echo "(rather than delete it sight unseen), e.g.:" >&2
  echo "  mv $OUT_DIR $OUT_DIR.previous" >&2
  rmdir "$LOCK_DIR"
  exit 1
fi
STAGE_DIR="$(mktemp -d "./sku_build.XXXXXX")"
cp "$BUILD_DIR/SKU.BIN" "$STAGE_DIR/SKU.BIN"
cp "$WORK/SKU.xml" "$STAGE_DIR/SKU.xml"
mv -T "$STAGE_DIR" "$OUT_DIR"
STAGE_DIR=""
rmdir "$LOCK_DIR_HELD"

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
