#!/usr/bin/env bash
# build.sh — C60 (Kepler proto1) top-level pipeline.
#
# Pivot v2: PRIMARY boot path is u-boot env `slotbboot` doing `mmc read` +
# `booti` against raw kernel/DTB in slot-A partitions (the TC8 trick;
# see FLASHING.md in tc8-firmware-build/). NO Android boot.img, NO AVB on
# the steady-state boot path. The output set mirrors TC8:
#
#   out/<profile>/Image                       (raw kernel, read by slotbboot)
#   out/<profile>/imx8mm-kepler-proto1.dtb    (raw DTB)
#   out/<profile>/rootfs.img.zst              (zstd-compressed ext4 rootfs)
#   out/<profile>/uboot-env.bin               (u-boot env blob; written to
#                                              /dev/mmcblk2 at 0x400000 by
#                                              the install step)
#   out/<profile>/SHA256SUMS
#
# With `--with-bootstrap-installer`, ALSO produces a one-shot Android-
# format boot.img+vbmeta installer for Path B (the case where we can't
# catch u-boot via brainslug Ctrl-C spam). The installer's initramfs runs
# the install dance from inside Linux, then reboots into the mmc-read
# path forever. Outputs:
#
#   out/<profile>/boot-c60-installer.img     (fastboot flash boot_a)
#   out/<profile>/vbmeta-c60-installer.img   (fastboot flash vbmeta_a)
#
# Default (run after ./bootstrap.sh):
#   ./build.sh --profile=emmc
#
# With installer:
#   ./build.sh --profile=emmc --with-bootstrap-installer

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

DEFAULT_LINUX="${REPO_ROOT}/linux-6.6"
DEFAULT_PATCHES="${REPO_ROOT}/kernel-patches/patches"
DEFAULT_DTS="${REPO_ROOT}/dts/imx8mm-kepler-proto1.dts"
DEFAULT_KEY="/tmp/testkey_rsa2048.pem"
DEFAULT_ROOTFS_DIR="${REPO_ROOT}/rootfs"
DEFAULT_ROOTFS_TGZ="${DEFAULT_ROOTFS_DIR}/out/rootfs.tar.gz"

LINUX=""; PATCHES=""; DTS=""; PROFILE=""; AVB_KEY=""; OUT=""
ROOTFS=""
ROOTFS_IMG_SIZE=""
SKIP_KERNEL=0
SKIP_ROOTFS=0
SKIP_ROOTFS_IMG=0
WITH_INSTALLER=0
DRY_RUN=0
JOBS="$(nproc)"

usage() {
  cat <<EOF
build.sh — C60 (Kepler proto1) firmware build (kernel + DTB + rootfs).

Primary boot path: u-boot env 'slotbboot' macro does raw mmc read + booti
into slot-A partitions. No Android boot.img on the steady-state path.

USAGE
  ./build.sh --profile=emmc [options]

REQUIRED
  --profile=NAME              emmc | path/to/custom.env

OPTIONS
  --linux=DIR                 Vanilla linux-6.6 source tree    (default: ./linux-6.6)
  --patches=DIR               tc8-kernel-patches/patches       (default: ./kernel-patches/patches)
  --dts=PATH                  C60 DTS                         (default: dts/imx8mm-kepler-proto1.dts)
  --rootfs=PATH               rootfs tarball or directory      (default: ./rootfs/out/rootfs.tar.gz; auto-built if missing)
  --rootfs-size=N             rootfs.img size in bytes         (default: 1.6 GiB; sized for system_a)
  --key=PATH                  AVB RSA-2048 key (installer only) (default: /tmp/testkey_rsa2048.pem)
  --out=DIR                   output dir                       (default: ./out/<profile>)
  --skip-kernel               reuse existing out/<profile>/kernel/Image
  --skip-rootfs               reuse existing rootfs/out/rootfs.tar.gz
  --skip-rootfs-img           reuse existing out/<profile>/rootfs.img.zst
  --with-bootstrap-installer  ALSO build Path B one-shot installer (boot.img + vbmeta)
  --jobs=N                    parallelism for kernel build     (default: nproc)
  --dry-run                   print every command without running it
  -h, --help                  Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --linux=*) LINUX="${arg#--linux=}";;
    --patches=*) PATCHES="${arg#--patches=}";;
    --dts=*) DTS="${arg#--dts=}";;
    --rootfs=*) ROOTFS="${arg#--rootfs=}";;
    --rootfs-size=*) ROOTFS_IMG_SIZE="${arg#--rootfs-size=}";;
    --profile=*) PROFILE="${arg#--profile=}";;
    --key=*) AVB_KEY="${arg#--key=}";;
    --out=*) OUT="${arg#--out=}";;
    --skip-kernel) SKIP_KERNEL=1;;
    --skip-rootfs) SKIP_ROOTFS=1;;
    --skip-rootfs-img) SKIP_ROOTFS_IMG=1;;
    --with-bootstrap-installer) WITH_INSTALLER=1;;
    --dry-run) DRY_RUN=1;;
    --jobs=*) JOBS="${arg#--jobs=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

: "${LINUX:=$DEFAULT_LINUX}"
: "${PATCHES:=$DEFAULT_PATCHES}"
: "${DTS:=$DEFAULT_DTS}"
: "${AVB_KEY:=$DEFAULT_KEY}"
: "${ROOTFS:=$DEFAULT_ROOTFS_TGZ}"

[[ -n "$PROFILE" ]] || { echo "ERROR: --profile= required" >&2; exit 1; }
# Resolve profile to a real path: "emmc" → "$REPO_ROOT/profiles/emmc.env".
if [[ "$PROFILE" != */* && "$PROFILE" != *.env ]]; then
    PROFILE="$REPO_ROOT/profiles/${PROFILE}.env"
fi
[[ -f "$PROFILE" ]] || { echo "ERROR: profile not found: $PROFILE" >&2; exit 1; }

# shellcheck disable=SC1090
source "$PROFILE"

profile_name="$(basename "${PROFILE%.env}")"
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/out/$profile_name"
KERNEL_OUT="$OUT/kernel"
KIMG="$KERNEL_OUT/Image"
DTB="$KERNEL_OUT/$DTB_NAME"
ROOTFS_IMG="$OUT/$ROOTFS_IMG_NAME"
ROOTFS_IMG_ZST="$OUT/$ROOTFS_IMG_ZST_NAME"
UBOOT_ENV_BIN="$OUT/uboot-env.bin"

# run/echo a command depending on --dry-run.
run() {
    if (( DRY_RUN )); then
        printf 'DRY-RUN: '; printf '%q ' "$@"; printf '\n'
    else
        "$@"
    fi
}

# Pre-flight: bootstrap state.
if (( ! DRY_RUN )); then
    if [[ $SKIP_KERNEL -ne 1 && ! -f "${LINUX}/Makefile" ]]; then
        echo "ERROR: linux source not found at ${LINUX}. Run: ./bootstrap.sh" >&2
        exit 1
    fi
    if [[ $SKIP_KERNEL -ne 1 && ! -d "${PATCHES}" ]]; then
        echo "ERROR: patches dir not found at ${PATCHES}. Run: ./bootstrap.sh" >&2
        exit 1
    fi
fi

# Version stamp.
C60_FW_VERSION="$(cd "$REPO_ROOT" && git describe --tags --always --dirty 2>/dev/null || echo unknown)"
C60_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
C60_BUILD_HOST="$(hostname)"
echo "[+] version: $C60_FW_VERSION  built $C60_BUILD_DATE on $C60_BUILD_HOST"
echo "[+] profile: $PROFILE"
echo "[+] out:     $OUT"
[[ "$WITH_INSTALLER" -eq 1 ]] && echo "[+] installer: ON (Path B boot.img + vbmeta will be built)"
mkdir -p "$OUT"

# Export version stamps so rootfs/build.sh can stamp /etc/c60-version.
export C60_FW_VERSION C60_BUILD_DATE C60_BUILD_HOST

# --- [1/5] rootfs tarball (lazy — only if missing) ---
# Mirrors TC8 build.sh: needs root for chroot, so re-invoke under sudo when
# not already privileged. Skipped entirely if --skip-rootfs.
if (( SKIP_ROOTFS )); then
    echo "===> [1/5] rootfs tarball SKIPPED (--skip-rootfs)"
elif [[ ! -e "$ROOTFS" ]]; then
    if [[ ! -f "$DEFAULT_ROOTFS_DIR/build.sh" ]]; then
        echo "ERROR: rootfs/build.sh missing — Path A primary boot needs a real rootfs." >&2
        echo "       check $DEFAULT_ROOTFS_DIR" >&2
        exit 1
    fi
    echo "===> [1/5] rootfs tarball (no $ROOTFS yet)"
    if (( DRY_RUN )); then
        echo "DRY-RUN: would run $DEFAULT_ROOTFS_DIR/build.sh as root"
    elif [[ $EUID -eq 0 ]]; then
        ( cd "$DEFAULT_ROOTFS_DIR" && ./build.sh )
    else
        ( cd "$DEFAULT_ROOTFS_DIR" && \
          sudo --preserve-env=C60_FW_VERSION,C60_BUILD_DATE,C60_BUILD_HOST,C60_SSH_PUBKEY,C60_ROOT_PASSWORD \
              ./build.sh )
    fi
else
    echo "===> [1/5] rootfs tarball present at $ROOTFS"
fi

# --- [2/5] kernel ---
# Primary build: Image + DTB. No embedded initramfs — root is on system_a.
# c60.config's CONFIG_INITRAMFS_SOURCE is empty, so kernel/build.sh's
# --initramfs-dir is also unused on this path.
if (( SKIP_KERNEL )); then
    echo "===> [2/5] kernel SKIPPED (--skip-kernel)"
    if (( ! DRY_RUN )); then
        [[ -f "$KIMG" ]] || { echo "ERROR: $KIMG missing; cannot --skip-kernel" >&2; exit 1; }
    fi
else
    echo "===> [2/5] kernel (primary — no embedded initramfs)"
    run "$REPO_ROOT/kernel/build.sh" \
        --linux="$LINUX" \
        --patches="$PATCHES" \
        --dts="$DTS" \
        --jobs="$JOBS" \
        --out="$KERNEL_OUT"
fi

# --- [3/5] rootfs.img + rootfs.img.zst ---
# system_a is 1.75 GiB on stock C60 — anything bigger gets refused. We
# default to 1.6 GiB to leave ext4 superblock + journal headroom.
if (( SKIP_ROOTFS_IMG )); then
    echo "===> [3/5] rootfs.img SKIPPED (--skip-rootfs-img)"
    # Don't insist on the .zst existing — the caller may be iterating on
    # just the env blob or the kernel; only error out at install time.
elif (( SKIP_ROOTFS )) && [[ ! -e "$ROOTFS" ]]; then
    echo "===> [3/5] rootfs.img SKIPPED (no source rootfs tarball and --skip-rootfs)"
else
    echo "===> [3/5] rootfs.img + zstd"
    img_args=( --rootfs="$ROOTFS" --out="$ROOTFS_IMG" )
    [[ -n "$ROOTFS_IMG_SIZE" ]] && img_args+=( --image-size="$ROOTFS_IMG_SIZE" )
    run "$REPO_ROOT/images/rootfs.sh" "${img_args[@]}"
    # Compress to .zst for fast transfer to the panel. -19 is the sweet spot
    # for an ext4 image — ratio approaches xz with 5x faster decompress.
    if (( ! DRY_RUN )); then
        echo "[+] compressing rootfs.img -> rootfs.img.zst"
        zstd -19 -f -T0 -q "$ROOTFS_IMG" -o "$ROOTFS_IMG_ZST"
        rm -f "$ROOTFS_IMG"   # keep only the .zst; saves ~1.5 GiB on disk
    else
        echo "DRY-RUN: would zstd $ROOTFS_IMG -> $ROOTFS_IMG_ZST"
    fi
fi

# --- [4/5] u-boot env blob ---
# Built from profile values; written to /dev/mmcblk2 at offset
# 0x400000 by the install step (Path A: tools/flash_c60.sh writes via
# UMS dd; Path B: the bootstrap installer initramfs writes from inside
# Linux on first boot).
echo "===> [4/5] u-boot env blob"
run "$REPO_ROOT/tools/install_uboot_env.sh" \
    --profile="$PROFILE" \
    --out="$UBOOT_ENV_BIN"

# --- [5/5] OPTIONAL: bootstrap installer boot.img + vbmeta ---
# Builds a SECOND kernel with a special install-only initramfs embedded.
# Output lands at $OUT/$BOOT_IMG_NAME + $OUT/$VBMETA_IMG_NAME.
if (( WITH_INSTALLER )); then
    INSTALLER_DIR="$REPO_ROOT/tools/bootstrap_installer"
    if [[ ! -d "$INSTALLER_DIR" ]]; then
        echo "ERROR: --with-bootstrap-installer set but $INSTALLER_DIR missing" >&2
        exit 1
    fi
    echo "===> [5/5] bootstrap installer (Path B)"

    # 5a. Build the installer initramfs (separate tree from the regular
    # bring-up initramfs in initramfs/).
    run "$INSTALLER_DIR/build_initramfs.sh"

    # 5b. Build a kernel with the installer initramfs embedded.
    # kernel/build.sh's --initramfs-dir overrides the default
    # initramfs/out/rootfs path; the kernel config's CONFIG_INITRAMFS_SOURCE
    # is rewritten in-place by kernel/build.sh after merge_config.
    INSTALLER_KERNEL_OUT="$OUT/installer-kernel"
    run "$REPO_ROOT/kernel/build.sh" \
        --linux="$LINUX" \
        --patches="$PATCHES" \
        --dts="$DTS" \
        --initramfs-dir="$INSTALLER_DIR/out/rootfs" \
        --config="$REPO_ROOT/kernel/c60-installer.config" \
        --jobs="$JOBS" \
        --out="$INSTALLER_KERNEL_OUT"

    # 5c. Pack into Android boot.img + add AVB hash footer.
    BOOT_IMG="$OUT/$BOOT_IMG_NAME"
    VBMETA_IMG="$OUT/$VBMETA_IMG_NAME"
    run "$REPO_ROOT/bootimg/build.sh" \
        --kernel="$INSTALLER_KERNEL_OUT/Image" \
        --profile="$PROFILE" \
        --key="$AVB_KEY" \
        --out="$BOOT_IMG"
    run "$REPO_ROOT/bootimg/build_vbmeta.sh" \
        --boot="$BOOT_IMG" \
        --profile="$PROFILE" \
        --key="$AVB_KEY" \
        --out="$VBMETA_IMG"
fi

# --- summary ---
if (( ! DRY_RUN )); then
    cp "$KIMG" "$OUT/Image" 2>/dev/null || true
    cp "$DTB"  "$OUT/$DTB_NAME" 2>/dev/null || true

    cat > "$OUT/version.env" <<EOF
C60_FW_VERSION=$C60_FW_VERSION
C60_BUILD_DATE=$C60_BUILD_DATE
C60_BUILD_HOST=$C60_BUILD_HOST
C60_PROFILE=$profile_name
C60_WITH_INSTALLER=$WITH_INSTALLER
EOF

    sumset=( Image "$DTB_NAME" version.env )
    [[ -f "$OUT/$ROOTFS_IMG_ZST_NAME" ]] && sumset+=( "$ROOTFS_IMG_ZST_NAME" )
    [[ -f "$OUT/uboot-env.bin"        ]] && sumset+=( uboot-env.bin )
    if (( WITH_INSTALLER )); then
        [[ -f "$OUT/$BOOT_IMG_NAME"   ]] && sumset+=( "$BOOT_IMG_NAME" )
        [[ -f "$OUT/$VBMETA_IMG_NAME" ]] && sumset+=( "$VBMETA_IMG_NAME" )
    fi
    ( cd "$OUT" && sha256sum "${sumset[@]}" 2>/dev/null > SHA256SUMS && cat SHA256SUMS )
fi

echo "[OK] artifacts in $OUT"
