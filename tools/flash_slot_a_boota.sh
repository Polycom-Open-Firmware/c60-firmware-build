#!/usr/bin/env bash
# flash_slot_a_boota.sh — flash C60 slot A with the boota+AVB path.
#
# Pushes our mainline boot.img + ext4 rootfs + vbmeta to slot A. Stock
# Polycom Android stays untouched on slot B as recovery.
#
# Prereqs:
#   - USB cable from the fastboot-capable host to the C60.
#   - C60 in fastboot mode (run `reboot bootloader` from a uid=2000
#     Android shell on the panel; SELinux is permissive on stock so this
#     works without root). Verify with `fastboot devices`.
#
# DEFAULTS: --no-dry-run is required to actually flash. Without it the
# script prints what it would do and exits.
#
# After flash + reboot: stock u-boot does boota boot_a → AVB orange warns
# about testkey → proceeds → our kernel boots → mounts
# /dev/disk/by-partlabel/system_a → systemd → ssh on the LAN (root/root
# unless --root-password was passed at rootfs build time).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS="${ARTIFACTS:-$REPO_ROOT/out/emmc}"
NO_DRY_RUN=0

for arg in "$@"; do
    case "$arg" in
        --artifacts=*) ARTIFACTS="${arg#--artifacts=}";;
        --no-dry-run)  NO_DRY_RUN=1;;
        -h|--help) sed -n '2,20p' "$0"; exit 0;;
        *) echo "unknown arg: $arg" >&2; exit 1;;
    esac
done

boot_img="$ARTIFACTS/boot-c60.img"
vbmeta_img="$ARTIFACTS/vbmeta-c60.img"
rootfs_img="$ARTIFACTS/rootfs.img"

for f in "$boot_img" "$vbmeta_img" "$rootfs_img"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done

command -v fastboot >/dev/null || { echo "ERROR: fastboot not in PATH" >&2; exit 1; }

run() {
    if (( NO_DRY_RUN )); then
        "$@"
    else
        printf 'DRY-RUN: '; printf '%q ' "$@"; printf '\n'
    fi
}

echo "[+] artifacts:"
echo "    boot.img:    $boot_img    ($(stat -c%s "$boot_img") bytes)"
echo "    vbmeta.img:  $vbmeta_img  ($(stat -c%s "$vbmeta_img") bytes)"
echo "    rootfs.img:  $rootfs_img  ($(stat -c%s "$rootfs_img") bytes)"
echo

if (( ! NO_DRY_RUN )); then
    echo "[i] DRY RUN — pass --no-dry-run to actually flash."
    echo "[i] First verify the device is in fastboot:  fastboot devices"
fi

run fastboot getvar unlocked
run fastboot flash   boot_a    "$boot_img"
run fastboot flash   vbmeta_a  "$vbmeta_img"
run fastboot flash   system_a  "$rootfs_img"
run fastboot --set-active=a
run fastboot reboot

echo
echo "[+] After reboot, watch the brainslug UART for:"
echo "    - stock u-boot 'verify OK, boot boot_a' (AVB orange may warn about testkey)"
echo "    - our kernel banner: 'Linux version 6.6.x' / 'Polycom Trio C60 (Kepler proto1)'"
echo "    - 'Starting kernel ...' → systemd journal → 'Reached target Login Prompts'"
echo "    - ssh root@<panel-ip> should work on the LAN (DHCP)"
