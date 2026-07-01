#!/usr/bin/env bash
# bootimg/build_vbmeta.sh — generate vbmeta-c60-a.img that chains to the
# boot.img produced by bootimg/build.sh.
#
# NXP u-boot 2018.03 on C60 verifies the boot.img against the descriptor
# inside this vbmeta image. The vbmeta partition is 1 MiB on stock.
#
# IMPORTANT: do NOT pass `--flag 2` (DISABLE_VERIFICATION) — NXP u-boot
# rejects vbmeta images that have verification disabled. Orange mode is
# permitted via key mismatch (warning only); disabling verification is not.
#
# USAGE
#   bootimg/build_vbmeta.sh --boot=PATH --profile=PATH [--key=PATH] [--out=FILE]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BOOT=""
PROFILE=""
AVB_KEY=""
OUT=""

usage() {
  cat <<EOF
bootimg/build_vbmeta.sh — generate vbmeta image chained to boot.img

USAGE
  bootimg/build_vbmeta.sh --boot=PATH --profile=PATH [options]

REQUIRED
  --boot=PATH      Signed boot.img (output of bootimg/build.sh)
  --profile=PATH   profiles/emmc.env

OPTIONS
  --key=PATH       AVB RSA-2048 key (default: /tmp/testkey_rsa2048.pem)
  --out=FILE       Output path (default: out/<profile>/<VBMETA_IMG_NAME>)
  -h, --help       Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --boot=*) BOOT="${arg#--boot=}";;
    --profile=*) PROFILE="${arg#--profile=}";;
    --key=*) AVB_KEY="${arg#--key=}";;
    --out=*) OUT="${arg#--out=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

[[ -n "$BOOT"    ]] || { echo "ERROR: --boot= required" >&2; exit 1; }
[[ -f "$BOOT"    ]] || { echo "ERROR: boot.img not found: $BOOT" >&2; exit 1; }
[[ -n "$PROFILE" ]] || { echo "ERROR: --profile= required" >&2; exit 1; }
[[ -f "$PROFILE" ]] || { echo "ERROR: profile not found: $PROFILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$PROFILE"
: "${AVB_KEY:=/tmp/testkey_rsa2048.pem}"
[[ -f "$AVB_KEY" ]] || { echo "ERROR: AVB key not found: $AVB_KEY (run bootimg/build.sh first)" >&2; exit 1; }

profile_name="$(basename "${PROFILE%.env}")"
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/out/$profile_name/$VBMETA_IMG_NAME"
mkdir -p "$(dirname "$OUT")"

# --- Resolve avbtool (same precedence as build.sh) ---
AVBTOOL=""
if [[ -x "$REPO_ROOT/vendored/avbtool/avbtool" ]]; then
    AVBTOOL="$REPO_ROOT/vendored/avbtool/avbtool"
elif [[ -x "$REPO_ROOT/vendored/avbtool/avbtool.py" ]]; then
    AVBTOOL="python3 $REPO_ROOT/vendored/avbtool/avbtool.py"
elif command -v avbtool >/dev/null 2>&1; then
    AVBTOOL="avbtool"
else
    echo "ERROR: avbtool not found. Run ./bootstrap.sh to vendor it." >&2
    exit 1
fi

echo "[+] boot.img:        $BOOT"
echo "[+] vbmeta key:      $AVB_KEY"
echo "[+] vbmeta out:      $OUT"
echo "[+] algorithm:       $AVB_ALGORITHM"
echo "[+] partition_size:  $VBMETA_PARTITION_SIZE"

rm -f "$OUT"

# Pull the hash descriptor out of the boot.img and pack it into vbmeta.
# `--padding_size` pads to a multiple; the partition itself is sized by GPT,
# so we pad to 1 MiB to fill the on-device partition cleanly.
$AVBTOOL make_vbmeta_image \
    --output "$OUT" \
    --algorithm "$AVB_ALGORITHM" \
    --key "$AVB_KEY" \
    --include_descriptors_from_image "$BOOT" \
    --padding_size "$VBMETA_PARTITION_SIZE"

ls -la "$OUT"
echo "[OK] $OUT"
