#!/usr/bin/env bash
# bootimg/pack_boota_set.sh — pack the slot-A boota+AVB set for the C60:
# boot.img + dtbo + vbmeta.
#
# Inputs: Image + DTB (from kernel/build.sh out dir)
# Outputs (into --out, default out/<profile>):
#   boot-c60.img    mkbootimg --header_version 0 --kernel Image
#                                --second <DTB>; truncate 32 MiB;
#                                avbtool add_hash_footer partition_size=48 MiB
#   dtbo-c60.img    Android DTBO image (magic d7b7ab1e) wrapping the single
#                    FDT; padded to 1 MiB content; avbtool add_hash_footer
#                    partition_size=4 MiB
#   vbmeta-c60.img  avbtool make_vbmeta_image chaining hash descriptors
#                    from BOTH boot-c60.img AND dtbo-c60.img (mandatory
#                    on C60 stock u-boot; missing dtbo descriptor
#                    drops to fastboot)
#
# USAGE
#   bootimg/pack_boota_set.sh --kernel=PATH --dtb=PATH --profile=PATH \
#                             [--key=PATH] [--out=DIR]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

KERNEL=""
DTB=""
PROFILE=""
AVB_KEY=""
OUT=""

usage() {
  cat <<EOF
bootimg/pack_boota_set.sh — pack boot-c60.img + dtbo-c60.img + vbmeta-c60.img

REQUIRED
  --kernel=PATH    Kernel Image (no embedded initramfs)
  --dtb=PATH       imx8mm-kepler-proto1.dtb (goes into boot.img --second slot
                   AND into the dtbo wrapper)
  --profile=PATH   profiles/emmc.env

OPTIONS
  --key=PATH       AVB RSA-2048 key (default /tmp/testkey_rsa2048.pem)
  --out=DIR        Output dir (default: out/<profile>)
EOF
}

for arg in "$@"; do
  case "$arg" in
    --kernel=*) KERNEL="${arg#--kernel=}";;
    --dtb=*)    DTB="${arg#--dtb=}";;
    --profile=*) PROFILE="${arg#--profile=}";;
    --key=*)    AVB_KEY="${arg#--key=}";;
    --out=*)    OUT="${arg#--out=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

[[ -n "$KERNEL" && -f "$KERNEL"  ]] || { echo "ERROR: --kernel= path required" >&2; exit 1; }
[[ -n "$DTB"    && -f "$DTB"     ]] || { echo "ERROR: --dtb= path required" >&2; exit 1; }
[[ -n "$PROFILE" && -f "$PROFILE" ]] || { echo "ERROR: --profile= required" >&2; exit 1; }

# shellcheck disable=SC1090
source "$PROFILE"
: "${AVB_KEY:=/tmp/testkey_rsa2048.pem}"

profile_name="$(basename "${PROFILE%.env}")"
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/out/$profile_name"
mkdir -p "$OUT"

# --- avbtool: prefer the vendored copy (it's avbtool.py here, not avbtool) ---
AVBTOOL=""
if [[ -x "$REPO_ROOT/vendored/avbtool/avbtool" ]]; then
    AVBTOOL="$REPO_ROOT/vendored/avbtool/avbtool"
elif [[ -f "$REPO_ROOT/vendored/avbtool/avbtool.py" ]]; then
    # Use /usr/bin/python3 explicitly — local shell hooks may force `uv run`
    # otherwise (which would block the build).
    AVBTOOL="/usr/bin/python3 $REPO_ROOT/vendored/avbtool/avbtool.py"
elif command -v avbtool >/dev/null 2>&1; then
    AVBTOOL="avbtool"
else
    echo "ERROR: avbtool not found." >&2
    exit 1
fi

if [[ ! -f "$AVB_KEY" ]]; then
    echo "[+] generating AVB test key at $AVB_KEY"
    openssl genrsa -out "$AVB_KEY" 2048
fi

BOOT_IMG="$OUT/boot-c60.img"
DTBO_IMG="$OUT/dtbo-c60.img"
VBMETA_IMG="$OUT/vbmeta-c60.img"

# Constant sizes per stock C60 GPT (see profiles/emmc.env):
BOOT_PART_SIZE="${BOOT_PARTITION_SIZE:-50331648}"   # 48 MiB
DTBO_PART_SIZE="${DTBO_PARTITION_SIZE:-4194304}"    # 4 MiB
VBMETA_PART_SIZE="${VBMETA_PARTITION_SIZE:-1048576}" # 1 MiB
BOOT_PAD="${BOOT_PAD_SIZE:-33554432}"                # 32 MiB content cap

echo "[+] kernel:   $KERNEL ($(stat -c%s "$KERNEL") bytes)"
echo "[+] dtb:      $DTB ($(stat -c%s "$DTB") bytes)"
echo "[+] cmdline:  $KERNEL_CMDLINE"
echo "[+] avb key:  $AVB_KEY"
echo

# === 1. boot-c60.img ===========================================
echo "===> [1/3] boot-c60.img (mkbootimg --second <dtb>, AVB)"
rm -f "$BOOT_IMG"

# Note: header v0 + --second is the combo this u-boot requires,
# NOT --dtb / header v2.
mkbootimg \
    --kernel "$KERNEL" \
    --second "$DTB" \
    --cmdline "$KERNEL_CMDLINE" \
    --base "$BOOT_BASE" \
    --kernel_offset "$BOOT_KERNEL_OFFSET" \
    --ramdisk_offset "$BOOT_RAMDISK_OFFSET" \
    --second_offset "$BOOT_TAGS_OFFSET" \
    --tags_offset "$BOOT_TAGS_OFFSET" \
    --pagesize "$BOOT_PAGESIZE" \
    --header_version 0 \
    -o "$BOOT_IMG"

magic="$(head -c 8 "$BOOT_IMG")"
[[ "$magic" == "ANDROID!" ]] || { echo "ERROR: boot.img magic != ANDROID!" >&2; exit 1; }

# Pad to 32 MiB content before AVB footer (avbtool pads to partition_size,
# but truncating intermediate gives a predictable, reproducible boot.img
# layout).
truncate -s "$BOOT_PAD" "$BOOT_IMG"

$AVBTOOL add_hash_footer \
    --image "$BOOT_IMG" \
    --partition_name boot \
    --partition_size "$BOOT_PART_SIZE" \
    --algorithm "$AVB_ALGORITHM" \
    --key "$AVB_KEY"

echo "[+] boot-c60.img: $(stat -c%s "$BOOT_IMG") bytes"

# === 2. dtbo-c60.img ===========================================
# Android DTBO image format (magic d7b7ab1e). Wraps our single FDT as the
# sole entry. u-boot's boota on this rev parses the dtbo header before
# applying overlays — a raw 0xd00dfeed FDT gets `boota: bad dt table magic`.
echo "===> [2/3] dtbo-c60.img (Android DTBO format + AVB)"
rm -f "$DTBO_IMG"

# Build the dtbo file inline with Python — keeps it self-contained.
# Layout (per AOSP dt_table.h):
#   uint32_be magic       = 0xd7b7ab1e
#   uint32_be total_size  = (header_size + dt_entry_size + fdt_size)
#   uint32_be header_size = 32
#   uint32_be dt_entry_size = 32
#   uint32_be dt_entry_count = 1
#   uint32_be dt_entries_offset = 32
#   uint32_be page_size = 2048
#   uint32_be version   = 0
#   /* dt_table_entry */
#   uint32_be dt_size   = <FDT size>
#   uint32_be dt_offset = <header_size + dt_entry_size>
#   uint32_be id, rev, custom[4]  (all zero — we don't use the dtbo idx)
/usr/bin/python3 - <<PY_EOF
import struct, sys, pathlib
dtb = pathlib.Path("$DTB").read_bytes()
fdt_size = len(dtb)
header_size = 32
entry_size  = 32
dt_offset   = header_size + entry_size
total_size  = dt_offset + fdt_size
hdr = struct.pack(">IIIIIIII",
    0xd7b7ab1e, total_size, header_size, entry_size,
    1, header_size, 2048, 0)
entry = struct.pack(">IIIIIIII",
    fdt_size, dt_offset, 0, 0, 0, 0, 0, 0)
out = hdr + entry + dtb
pathlib.Path("$DTBO_IMG").write_bytes(out)
print(f"[+] dtbo raw size: {len(out)} bytes (dtb={fdt_size})")
PY_EOF

# AVB hash footer: dtbo_a is 4 MiB on stock; image must fit comfortably
# inside that with room for the 64 KiB footer + descriptor metadata.
$AVBTOOL add_hash_footer \
    --image "$DTBO_IMG" \
    --partition_name dtbo \
    --partition_size "$DTBO_PART_SIZE" \
    --algorithm "$AVB_ALGORITHM" \
    --key "$AVB_KEY"

echo "[+] dtbo-c60.img: $(stat -c%s "$DTBO_IMG") bytes"

# === 3. vbmeta-c60.img =========================================
# CRITICAL: include descriptors from BOTH boot AND dtbo images. Without
# the dtbo descriptor, u-boot's boota emits 'Can't find dtbo partition
# from avb partition data!' and drops to fastboot.
echo "===> [3/3] vbmeta-c60.img (chain boot + dtbo)"
rm -f "$VBMETA_IMG"

# No --padding_size: vbmeta is tiny (~1.5 KiB) and the partition is sized
# by GPT. avbtool make_vbmeta_image doesn't pad by default.
$AVBTOOL make_vbmeta_image \
    --output "$VBMETA_IMG" \
    --algorithm "$AVB_ALGORITHM" \
    --key "$AVB_KEY" \
    --include_descriptors_from_image "$BOOT_IMG" \
    --include_descriptors_from_image "$DTBO_IMG"

echo "[+] vbmeta-c60.img: $(stat -c%s "$VBMETA_IMG") bytes"

echo
echo "[OK] boota+AVB set in $OUT:"
ls -la "$BOOT_IMG" "$DTBO_IMG" "$VBMETA_IMG"
