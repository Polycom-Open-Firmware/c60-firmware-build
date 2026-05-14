#!/usr/bin/env bash
# bootimg/build.sh — pack the kernel Image into an Android boot.img and
# add an AVB hash footer.
#
# C60 u-boot rejects boot.img without a valid AVB footer (NXP quirk —
# even in unlocked/orange mode). vbmeta_a is flashed separately by
# build_vbmeta.sh and references the descriptor we add here.
#
# We use AOSP testkey RSA-2048 (smaller than RSA-4096, generated locally
# if absent). orange mode will warn on key mismatch but still boot.
#
# USAGE
#   bootimg/build.sh --kernel=PATH --profile=PATH [--key=PATH] [--out=FILE]
#
# Default profile: profiles/emmc.env
# Default key:     /tmp/testkey_rsa2048.pem (auto-generated if missing)
# Default out:     out/<profile-name>/<BOOT_IMG_NAME>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

KERNEL=""
PROFILE=""
AVB_KEY=""
OUT=""

usage() {
  cat <<EOF
bootimg/build.sh — pack + AVB-sign Android boot.img for C60

USAGE
  bootimg/build.sh --kernel=PATH --profile=PATH [options]

REQUIRED
  --kernel=PATH    Kernel Image (with initramfs embedded by kernel build)
  --profile=PATH   profiles/emmc.env (or path to a custom .env)

OPTIONS
  --key=PATH       AVB RSA-2048 key (default: /tmp/testkey_rsa2048.pem;
                   auto-generated if missing)
  --out=FILE       Output path (default: out/<profile>/<BOOT_IMG_NAME>)
  -h, --help       Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --kernel=*) KERNEL="${arg#--kernel=}";;
    --profile=*) PROFILE="${arg#--profile=}";;
    --key=*) AVB_KEY="${arg#--key=}";;
    --out=*) OUT="${arg#--out=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

[[ -n "$KERNEL"  ]] || { echo "ERROR: --kernel= required" >&2; exit 1; }
[[ -f "$KERNEL"  ]] || { echo "ERROR: kernel not found: $KERNEL" >&2; exit 1; }
[[ -n "$PROFILE" ]] || { echo "ERROR: --profile= required" >&2; exit 1; }
[[ -f "$PROFILE" ]] || { echo "ERROR: profile not found: $PROFILE" >&2; exit 1; }

# Source the profile to pull KERNEL_CMDLINE + BOOT_* + AVB_* knobs.
# shellcheck disable=SC1090
source "$PROFILE"

: "${AVB_KEY:=/tmp/testkey_rsa2048.pem}"

# Generate testkey on demand. RSA-2048 (not 4096) because:
#   - smaller signature → smaller boot.img overhead
#   - orange mode doesn't validate the key anyway; size is purely aesthetic.
if [[ ! -f "$AVB_KEY" ]]; then
    echo "[+] generating AVB test key at $AVB_KEY"
    openssl genrsa -out "$AVB_KEY" 2048
fi

profile_name="$(basename "${PROFILE%.env}")"
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/out/$profile_name/$BOOT_IMG_NAME"
mkdir -p "$(dirname "$OUT")"

# --- Resolve avbtool ---
# Prefer a vendored copy (bootstrap.sh fetches one). Fall back to PATH.
AVBTOOL=""
if [[ -x "$REPO_ROOT/vendored/avbtool/avbtool" ]]; then
    AVBTOOL="$REPO_ROOT/vendored/avbtool/avbtool"
elif [[ -x "$REPO_ROOT/vendored/avbtool/avbtool.py" ]]; then
    AVBTOOL="python3 $REPO_ROOT/vendored/avbtool/avbtool.py"
elif command -v avbtool >/dev/null 2>&1; then
    AVBTOOL="avbtool"
else
    echo "ERROR: avbtool not found. Run ./bootstrap.sh to vendor it, or" >&2
    echo "       install via pip:  pip install avbtool" >&2
    exit 1
fi

# --- mkbootimg ---
# mkbootimg ships in Debian as /usr/bin/mkbootimg. Header v0, page size 2048,
# load addresses from the profile (matching stock C60 u-boot — see
# stock-boot.log (forensic-derived, outside this repo): kernel @ 0x40480000, fdt @ 0x43400000).
#
# We do NOT pass --ramdisk: initramfs is embedded in the kernel Image via
# CONFIG_INITRAMFS_SOURCE (NXP boota external-ramdisk on mainline DT is
# broken — see feedback_nxp_boota_quirks).
#
# We do NOT pass --dtb either, for the same reason: header v0 doesn't have
# a DTB slot anyway, and u-boot's boota on this u-boot rev locates the DTB
# via its env (or the dtbo_a partition); we'll set bootcmd accordingly.

echo "[+] kernel:        $KERNEL ($(stat -c%s "$KERNEL") bytes)"
echo "[+] cmdline:       $KERNEL_CMDLINE"
echo "[+] base:          $BOOT_BASE"
echo "[+] kernel_offset: $BOOT_KERNEL_OFFSET"
echo "[+] pagesize:      $BOOT_PAGESIZE"
echo "[+] out:           $OUT"

# mkbootimg refuses to overwrite a partial output sometimes; remove first.
rm -f "$OUT"

mkbootimg \
    --kernel "$KERNEL" \
    --cmdline "$KERNEL_CMDLINE" \
    --base "$BOOT_BASE" \
    --kernel_offset "$BOOT_KERNEL_OFFSET" \
    --ramdisk_offset "$BOOT_RAMDISK_OFFSET" \
    --tags_offset "$BOOT_TAGS_OFFSET" \
    --pagesize "$BOOT_PAGESIZE" \
    --header_version "$BOOT_HEADER_VERSION" \
    -o "$OUT"

# --- Sanity: confirm magic 'ANDROID!' ---
hdr_magic="$(head -c 8 "$OUT")"
if [[ "$hdr_magic" != "ANDROID!" ]]; then
    echo "ERROR: boot.img header magic is not 'ANDROID!' — mkbootimg failed" >&2
    od -c "$OUT" | head -1 >&2
    exit 1
fi

# --- Pad to BOOT_PAD_SIZE before AVB footer ---
# avbtool add_hash_footer pads internally up to partition_size, but truncating
# to a fixed intermediate size makes the output more predictable for re-flashes.
truncate -s "$BOOT_PAD_SIZE" "$OUT"

# --- Add AVB hash footer ---
echo "[+] avbtool add_hash_footer (partition_size=$BOOT_PARTITION_SIZE)"
$AVBTOOL add_hash_footer \
    --image "$OUT" \
    --partition_name boot \
    --partition_size "$BOOT_PARTITION_SIZE" \
    --algorithm "$AVB_ALGORITHM" \
    --key "$AVB_KEY"

ls -la "$OUT"
echo "[OK] $OUT"
