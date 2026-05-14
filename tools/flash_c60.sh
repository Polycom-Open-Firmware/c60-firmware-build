#!/usr/bin/env bash
# flash_c60.sh — flash a C60 panel with the artifacts in out/<profile>/.
#
# Two paths:
#
#   --path=A   "TC8 trick" — catch stock u-boot via brainslug Ctrl-C spam
#              during a PoE-cycle. Install env, `ums 0 mmc 1`, write
#              partitions from staging host. Mirrors TC8 onboard.sh.
#              CAVEAT: per feedback_c60_uboot_no_interrupt, stock C60
#              u-boot has zero bootdelay AND Polycom's auto-saveenv may
#              not honor our env writes. Path A may not work; try it
#              first since it leaves slot B perfectly untouched.
#
#   --path=B   Bootstrap installer — flash boot-c60-installer.img +
#              vbmeta-c60-installer.img via fastboot. Installer runs
#              once on first boot and transitions the device to the
#              mmc-read+booti path. Requires --with-bootstrap-installer
#              in build.sh.
#
# DEFAULTS: --no-dry-run is required to actually do anything destructive.
# Without it the script prints what it WOULD do and exits 0.
#
# USAGE
#   tools/flash_c60.sh --path=A --brainslug http://10.99.0.95 \
#                       --staging-host aibox --poe-port N \
#                       --artifacts /path/to/out/emmc \
#                       [--no-dry-run]
#
#   tools/flash_c60.sh --path=B --artifacts /path/to/out/emmc \
#                       [--no-dry-run]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PROFILE_ENV="${PROFILE_ENV:-$REPO_ROOT/profiles/emmc.env}"
# shellcheck disable=SC1090
[[ -r "$PROFILE_ENV" ]] && source "$PROFILE_ENV"

PATH_SEL=""
BRAINSLUG="${BRAINSLUG:-http://192.168.10.95}"   # slug-2 per MEMORY.md (main LAN, NOT test VLAN)
STAGING_HOST="${STAGING_HOST:-aibox}"
POE_PORT=""
ARTIFACTS=""
SLOT="${SLOT:-main}"
NO_DRY_RUN=0
: "${C60_HOST_PASS:=root}"
: "${SW_PASS:=${POE_SW_PASS:-}}"
: "${SW_HOST:=192.168.10.243}"

usage() {
  cat <<EOF
flash_c60.sh — install our build onto a C60 panel.

USAGE
  flash_c60.sh --path=A|B --artifacts=DIR [options]

REQUIRED
  --path=A           Path A: brainslug Ctrl-C catch + UMS + dd
  --path=B           Path B: fastboot flash bootstrap installer
  --artifacts=DIR    Directory containing Image / DTB / rootfs.img.zst
                     (Path A); plus boot-c60-installer.img +
                     vbmeta-c60-installer.img (Path B).

OPTIONS
  --brainslug URL    brainslug base URL (default: \$BRAINSLUG = $BRAINSLUG)
  --staging-host H   staging host name (default: \$STAGING_HOST = $STAGING_HOST)
  --poe-port N       PoE port number for Path A (required for A)
  --slot main|bak    install slot — only 'main' is supported on C60 v2
                     (we don't replace slot B; bak is a no-op flag)
  --no-dry-run       actually do the destructive thing. WITHOUT this, we
                     print what would happen and exit 0.
  -h, --help         Show this help

env:
  C60_HOST_PASS     panel root password for post-install ssh checks (default: root)
  SW_PASS            PoE switch admin password (Path A)
  SW_HOST            PoE switch IP (Path A; default $SW_HOST)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path=*)         PATH_SEL="${1#--path=}"; shift;;
        --brainslug)      BRAINSLUG="$2"; shift 2;;
        --brainslug=*)    BRAINSLUG="${1#--brainslug=}"; shift;;
        --staging-host)   STAGING_HOST="$2"; shift 2;;
        --staging-host=*) STAGING_HOST="${1#--staging-host=}"; shift;;
        --poe-port)       POE_PORT="$2"; shift 2;;
        --poe-port=*)     POE_PORT="${1#--poe-port=}"; shift;;
        --artifacts)      ARTIFACTS="$2"; shift 2;;
        --artifacts=*)    ARTIFACTS="${1#--artifacts=}"; shift;;
        --slot)           SLOT="$2"; shift 2;;
        --slot=*)         SLOT="${1#--slot=}"; shift;;
        --no-dry-run)     NO_DRY_RUN=1; shift;;
        -h|--help)        usage; exit 0;;
        *) echo "unknown arg: $1" >&2; exit 1;;
    esac
done

[[ -n "$PATH_SEL"  ]] || { echo "ERROR: --path=A|B required" >&2; exit 1; }
[[ -n "$ARTIFACTS" ]] || { echo "ERROR: --artifacts DIR required" >&2; exit 1; }
[[ -d "$ARTIFACTS" ]] || { echo "ERROR: $ARTIFACTS not a dir" >&2; exit 1; }
[[ "$PATH_SEL" == "A" || "$PATH_SEL" == "B" ]] || { echo "ERROR: --path must be A or B" >&2; exit 1; }
[[ "$SLOT" == "main" ]] || echo "[!] --slot=$SLOT: C60 v2 only writes slot A; flag ignored"

run() {
    if (( NO_DRY_RUN )); then
        "$@"
    else
        printf 'DRY-RUN: '; printf '%q ' "$@"; printf '\n'
    fi
}

run_ssh() {
    # `ssh "$STAGING_HOST" "cmd"` with dry-run shim
    local host="$1"; shift
    if (( NO_DRY_RUN )); then
        ssh "$host" "$@"
    else
        printf 'DRY-RUN: ssh %q ' "$host"; printf '%q ' "$@"; printf '\n'
    fi
}

# -----------------------------------------------------------------------
# Path B: fastboot flash bootstrap installer.
# -----------------------------------------------------------------------
flash_path_b() {
    local boot="$ARTIFACTS/boot-c60-installer.img"
    local vbmeta="$ARTIFACTS/vbmeta-c60-installer.img"
    [[ -f "$boot"   ]] || { echo "ERROR: missing $boot — run build.sh with --with-bootstrap-installer" >&2; exit 1; }
    [[ -f "$vbmeta" ]] || { echo "ERROR: missing $vbmeta — run build.sh with --with-bootstrap-installer" >&2; exit 1; }
    command -v fastboot >/dev/null || { echo "ERROR: fastboot not in PATH" >&2; exit 1; }

    echo "[+] Path B: fastboot flash bootstrap installer"
    echo "[+]   boot:   $boot"
    echo "[+]   vbmeta: $vbmeta"
    echo
    echo "[!] Pre-flight: panel must already be in fastboot mode and unlocked."
    echo "[!]   - reboot into fastboot via Polycom recovery menu or `adb reboot bootloader`"
    echo "[!]   - confirm:  fastboot getvar unlocked  →  unlocked: yes"
    echo
    if (( ! NO_DRY_RUN )); then
        echo "[i] DRY RUN — pass --no-dry-run to actually flash."
    fi

    run fastboot flash boot_a   "$boot"
    run fastboot flash vbmeta_a "$vbmeta"
    run fastboot --set-active=a
    run fastboot reboot

    echo
    echo "[+] After reboot the installer runs ONCE: it dd's Image / DTB /"
    echo "    rootfs.img.zst into slot-A partitions and writes the u-boot"
    echo "    env block. Watch the brainslug UART for [installer] lines."
    echo "[+] On the next reboot, stock u-boot loads our env and runs"
    echo "    'slotbboot' (mmc read + booti) into Debian on system_a."
}

# -----------------------------------------------------------------------
# Path A: brainslug Ctrl-C spam + ums + dd.
# Implementation parallels tc8-firmware-build/smoke/onboard.sh, but:
#   - We don't repartition. We only write slot-A partitions.
#   - We don't preserve magic offsets — slot B Android holds them.
# -----------------------------------------------------------------------
flash_path_a() {
    [[ -n "$POE_PORT" ]] || { echo "ERROR: --poe-port required for Path A" >&2; exit 1; }
    : "${SW_PASS:?SW_PASS required for PoE cycle}"

    local kernel="$ARTIFACTS/Image"
    local dtb="$ARTIFACTS/imx8mm-kepler-proto1.dtb"
    local rootfs_zst="$ARTIFACTS/rootfs.img.zst"
    local env_bin="$ARTIFACTS/uboot-env.bin"
    for f in "$kernel" "$dtb" "$rootfs_zst" "$env_bin"; do
        [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
    done

    if (( ! NO_DRY_RUN )); then
        echo "[i] DRY RUN — pass --no-dry-run to actually do this."
    fi

    echo "[+] Path A: brainslug catch + UMS write"
    echo "[+]   brainslug:    $BRAINSLUG"
    echo "[+]   staging host: $STAGING_HOST"
    echo "[+]   PoE port:     $POE_PORT"
    echo "[+]   artifacts:    $ARTIFACTS"

    # Catch u-boot — same approach as TC8 onboard.sh's catch_uboot, but
    # we don't have a known-working Linux on the panel yet, so we skip
    # the "ssh-reboot the panel first" optimization and just hammer the
    # PoE cycle. catch_uboot.py is reused from tc8-firmware-build.
    if [[ ! -x "$REPO_ROOT/../tc8-firmware-build/smoke/catch_uboot.py" ]]; then
        echo "ERROR: catch_uboot.py not found in sibling tc8-firmware-build/smoke/" >&2
        exit 1
    fi

    echo "[+] PoE-cycling port $POE_PORT (C60 stock u-boot has bootdelay=0;"
    echo "    we spam Ctrl-C via the brainslug WS from the first byte)"
    run env SW_PASS="$SW_PASS" SW_HOST="$SW_HOST" \
        "$REPO_ROOT/../tc8-firmware-build/smoke/poe_cycle.sh" cycle "$POE_PORT"
    run python3 "$REPO_ROOT/../tc8-firmware-build/smoke/catch_uboot.py" \
        --brainslug "$BRAINSLUG"

    echo
    echo "[!] If catch_uboot.py timed out, Path A is not usable on this"
    echo "[!] panel — use Path B (boota bootstrap installer) instead."
    echo

    # Send the env via setenv / saveenv from u-boot, then `ums 0 mmc 1`.
    # We do NOT use the pre-built uboot-env.bin in Path A — instead, the
    # env vars are set via `setenv` commands so the existing u-boot env
    # block stays in a consistent state (CRC etc). uboot-env.bin is only
    # consumed by Path B's installer.
    # NB: each ub_cmd is a curl POST; assemble the slotbboot expression
    # without literal semicolons that would terminate the setenv call.
    cat <<UBOOT
[+] u-boot env to install:
    bootdelay=3
    boot_slot=main
    kepler_bootargs='${KEPLER_BOOTARGS:-<from profile>}'
    slotbboot='${SLOTBBOOT:-<from profile>}'
    BOOT_A_LBA=${BOOT_A_LBA:-?} DTBO_A_LBA=${DTBO_A_LBA:-?}
    BOOT_LEN=${BOOT_LEN:-?} DTBO_LEN=${DTBO_LEN:-?}
    bootcmd='run slotbboot'
UBOOT

    if (( ! NO_DRY_RUN )); then
        echo "[i] DRY RUN — env-install via UART would happen here."
        echo "[i] DRY RUN — ums + dd from $STAGING_HOST would happen next."
        return 0
    fi

    echo "[!] Path A env-install is not yet implemented as a one-liner."
    echo "[!] Recommended: catch u-boot manually (above), then paste the"
    echo "[!] following at the u-boot prompt, then run 'ums 0 mmc 1' and"
    echo "[!] write partitions via the staging host (sshpass / dd)."
    echo
    cat <<EOF
    setenv bootdelay 3
    setenv boot_slot main
    setenv BOOT_A_LBA ${BOOT_A_LBA:-?}
    setenv BOOT_B_LBA ${BOOT_B_LBA:-?}
    setenv DTBO_A_LBA ${DTBO_A_LBA:-?}
    setenv DTBO_B_LBA ${DTBO_B_LBA:-?}
    setenv BOOT_LEN ${BOOT_LEN:-?}
    setenv DTBO_LEN ${DTBO_LEN:-?}
    setenv kepler_bootargs '${KEPLER_BOOTARGS:-?}'
    setenv slotbboot '${SLOTBBOOT:-?}'
    setenv bootcmd 'run slotbboot'
    saveenv
    ums 0 mmc 1

    # then on $STAGING_HOST:
    dev=\$(ls /dev/disk/by-id/usb-* | grep -v -- -part | head -1)
    sudo dd if=$kernel      of=\${dev}p3 bs=1M conv=fsync   # boot_a
    sudo dd if=$dtb         of=\${dev}p1 bs=1M conv=fsync   # dtbo_a
    sudo zstd -dc $rootfs_zst | sudo dd of=\${dev}p5 bs=4M conv=fsync  # system_a
    sudo sync

    # back on the brainslug UART:
    <Ctrl-C> to leave ums
    reset
EOF
}

case "$PATH_SEL" in
    A) flash_path_a;;
    B) flash_path_b;;
esac
