#!/usr/bin/env bash
# install_uboot_env.sh — produce a u-boot env binary blob suitable for
# `dd` to /dev/mmcblk2 at offset UBOOT_ENV_OFFSET (default 0x400000).
#
# The blob layout matches u-boot's CONFIG_ENV_IS_IN_MMC (single, non-
# redundant) form:
#
#   [0x0000..0x0004)  little-endian CRC32 of bytes [0x0004..end-of-block)
#   [0x0004..end)     NUL-separated key=value entries, padded with 0x00
#
# We use `mkenvimage` (from u-boot-tools) so it stays in lockstep with
# whatever CRC variant the running u-boot uses. mkenvimage handles the
# CRC; we just supply the env text in key=value lines.
#
# Why this matters: the steady-state C60 boot path is set by env vars
# (bootcmd, kepler_bootargs, slotbboot, BOOT_A_LBA, ...). Whatever
# happens during the install dance, this env must already be on the
# eMMC BEFORE u-boot loads next time, otherwise it falls back to stock
# (which auto-boots into Android via `boota`).
#
# USAGE
#   install_uboot_env.sh --profile=profiles/emmc.env [--out=uboot-env.bin]
#                        [--size=0x1000]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PROFILE=""
OUT=""
ENV_SIZE=""

usage() {
  cat <<EOF
install_uboot_env.sh — make a CRC-stamped u-boot env blob for C60

USAGE
  install_uboot_env.sh --profile=PATH [options]

REQUIRED
  --profile=PATH    profile (e.g. profiles/emmc.env) — supplies env values.

OPTIONS
  --out=FILE        output (default: out/<profile>/uboot-env.bin)
  --size=BYTES      env block size (default: profile UBOOT_ENV_SIZE,
                    fallback 0x1000 / 4 KiB). Polycom u-boot uses 4 KiB
                    for TC8; C60 ASSUMED to match — change if your
                    target u-boot's CONFIG_ENV_SIZE differs.
  -h, --help        Show this help

The output is a raw blob you `dd` to the eMMC at byte offset
UBOOT_ENV_OFFSET (default 0x400000). Path A (tools/flash_c60.sh) does
this via UMS; Path B (bootstrap installer) does it from running Linux.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --profile=*) PROFILE="${arg#--profile=}";;
    --out=*) OUT="${arg#--out=}";;
    --size=*) ENV_SIZE="${arg#--size=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

[[ -n "$PROFILE" ]] || { echo "ERROR: --profile= required" >&2; exit 1; }
[[ -f "$PROFILE" ]] || { echo "ERROR: profile not found: $PROFILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$PROFILE"

profile_name="$(basename "${PROFILE%.env}")"
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/out/$profile_name/uboot-env.bin"
[[ -n "$ENV_SIZE" ]] || ENV_SIZE="${UBOOT_ENV_SIZE:-0x1000}"

mkdir -p "$(dirname "$OUT")"

# mkenvimage is the cleanest path — it stamps the standard u-boot env
# CRC32 (zlib variant) and pads the output to --size. Refusing to bring
# our own implementation since Polycom u-boot's CRC quirks (redundant vs
# single env, byte-swap, etc) are easier to track via the official tool.
command -v mkenvimage >/dev/null || {
    echo "ERROR: mkenvimage not in PATH (apt install u-boot-tools)" >&2
    exit 1
}

# Build the env text. Order doesn't matter, but we keep it stable for
# diffing. Values that contain literal `$` need to remain raw — u-boot
# evaluates them at boot, not now.
TXT="$(mktemp)"
trap 'rm -f "$TXT"' EXIT

cat > "$TXT" <<EOF
bootdelay=3
bootcmd=run slotbboot
boot_slot=main
kepler_bootargs=${KEPLER_BOOTARGS}
slotbboot=${SLOTBBOOT}
BOOT_A_LBA=${BOOT_A_LBA}
BOOT_B_LBA=${BOOT_B_LBA}
DTBO_A_LBA=${DTBO_A_LBA}
DTBO_B_LBA=${DTBO_B_LBA}
BOOT_LEN=${BOOT_LEN}
DTBO_LEN=${DTBO_LEN}
EOF

echo "[+] env text: $TXT"
echo "[+] env size: $ENV_SIZE bytes"
echo "[+] target offset (per profile): ${UBOOT_ENV_OFFSET:-0x400000}"
echo "[+] target device (per profile): ${UBOOT_ENV_DEVICE:-/dev/mmcblk2}"

# -s expects decimal or 0x hex; mkenvimage accepts both.
mkenvimage -s "$ENV_SIZE" -o "$OUT" "$TXT"

ls -la "$OUT"
echo "[OK] $OUT"
echo
echo "To install (Path A, UMS attached to staging host as /dev/sdX):"
echo "  dd if=$OUT of=/dev/sdX bs=4096 seek=\$((${UBOOT_ENV_OFFSET:-0x400000}/4096)) conv=fsync"
echo
echo "To install (Path B, from running Linux on the C60):"
echo "  dd if=$OUT of=${UBOOT_ENV_DEVICE:-/dev/mmcblk2} bs=4096 \\"
echo "     seek=\$((${UBOOT_ENV_OFFSET:-0x400000}/4096)) conv=fsync"
