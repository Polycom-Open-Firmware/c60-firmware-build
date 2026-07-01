#!/usr/bin/env bash
# build.sh — C60 (Kepler proto1) top-level firmware pipeline.
#
# Boot flow: our u-boot (RAM-loaded over SDP with uuu) reads boot_a with
# `mmc read` and boots it with `booti`. boot_a is an Android boot.img v0
# holding the kernel plus the DTB in its `second` area; dtbo_a and vbmeta_a
# carry the DTBO overlay table and its AVB metadata. The slot images are
# written with `fastboot flash`.
#
# Outputs (into out/<profile>):
#   Image                       raw kernel
#   imx8mm-kepler-proto1.dtb    raw DTB
#   boot.img                    Android boot.img (kernel + DTB), AVB-signed
#   dtbo.img                    Android DTBO image, AVB-signed
#   vbmeta.img                  chained vbmeta for boot.img + dtbo.img
#   rootfs.img.zst              zstd-compressed ext4 rootfs for system_a
#   version.env
#   SHA256SUMS
#
# Usage:
#   ./build.sh --profile=emmc

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"

DEFAULT_LINUX="${REPO_ROOT}/linux-6.6"
DEFAULT_PATCHES="${REPO_ROOT}/kernel-patches/patches"
DEFAULT_KEY="/tmp/testkey_rsa2048.pem"
DEFAULT_ROOTFS_DIR="${REPO_ROOT}/rootfs"
DEFAULT_ROOTFS_TGZ="${DEFAULT_ROOTFS_DIR}/out/rootfs.tar.gz"

LINUX=""; PATCHES=""; PROFILE=""; AVB_KEY=""; OUT=""
ROOTFS=""
ROOTFS_IMG_SIZE=""
SKIP_KERNEL=0
SKIP_ROOTFS=0
SKIP_ROOTFS_IMG=0
DRY_RUN=0
JOBS="$(nproc)"

usage() {
  cat <<EOF
build.sh — C60 (Kepler proto1) firmware build (kernel + DTB + rootfs + slot-A image set).

USAGE
  ./build.sh --profile=emmc [options]

REQUIRED
  --profile=NAME              emmc | path/to/custom.env

OPTIONS
  --linux=DIR                 Vanilla linux-6.6 source tree    (default: ./linux-6.6)
  --patches=DIR               kernel patch series              (default: ./kernel-patches/patches)
  --rootfs=PATH               rootfs tarball or directory      (default: ./rootfs/out/rootfs.tar.gz; auto-built if missing)
  --rootfs-size=N             rootfs.img size in bytes         (default: 1.6 GiB; sized for system_a)
  --key=PATH                  AVB RSA-2048 key                 (default: /tmp/testkey_rsa2048.pem)
  --out=DIR                   output dir                       (default: ./out/<profile>)
  --skip-kernel               reuse existing out/<profile>/kernel/Image
  --skip-rootfs               reuse existing rootfs/out/rootfs.tar.gz
  --skip-rootfs-img           reuse existing out/<profile>/rootfs.img.zst
  --jobs=N                    parallelism for kernel build     (default: nproc)
  --dry-run                   print every command without running it
  -h, --help                  Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --linux=*) LINUX="${arg#--linux=}";;
    --patches=*) PATCHES="${arg#--patches=}";;
    --rootfs=*) ROOTFS="${arg#--rootfs=}";;
    --rootfs-size=*) ROOTFS_IMG_SIZE="${arg#--rootfs-size=}";;
    --profile=*) PROFILE="${arg#--profile=}";;
    --key=*) AVB_KEY="${arg#--key=}";;
    --out=*) OUT="${arg#--out=}";;
    --skip-kernel) SKIP_KERNEL=1;;
    --skip-rootfs) SKIP_ROOTFS=1;;
    --skip-rootfs-img) SKIP_ROOTFS_IMG=1;;
    --dry-run) DRY_RUN=1;;
    --jobs=*) JOBS="${arg#--jobs=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

: "${LINUX:=$DEFAULT_LINUX}"
: "${PATCHES:=$DEFAULT_PATCHES}"
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
BOOT_IMG="$OUT/$BOOT_IMG_NAME"
DTBO_IMG="$OUT/$DTBO_IMG_NAME"
VBMETA_IMG="$OUT/$VBMETA_IMG_NAME"

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
mkdir -p "$OUT"

# Export version stamps so rootfs/build.sh can stamp /etc/c60-version.
export C60_FW_VERSION C60_BUILD_DATE C60_BUILD_HOST

# --- [1/4] rootfs tarball (lazy — only if missing) ---
# Building the rootfs needs root for chroot, so re-invoke under sudo when not
# already privileged. Skipped entirely if --skip-rootfs.
if (( SKIP_ROOTFS )); then
    echo "===> [1/4] rootfs tarball SKIPPED (--skip-rootfs)"
elif [[ ! -e "$ROOTFS" ]]; then
    if [[ ! -f "$DEFAULT_ROOTFS_DIR/build.sh" ]]; then
        echo "ERROR: rootfs/build.sh missing — a rootfs is required to build rootfs.img." >&2
        echo "       check $DEFAULT_ROOTFS_DIR" >&2
        exit 1
    fi
    echo "===> [1/4] rootfs tarball (no $ROOTFS yet)"
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
    echo "===> [1/4] rootfs tarball present at $ROOTFS"
fi

# --- [2/4] kernel: Image + DTB ---
# No embedded initramfs — root is on system_a, so kernel/build.sh runs
# without --initramfs-dir.
if (( SKIP_KERNEL )); then
    echo "===> [2/4] kernel SKIPPED (--skip-kernel)"
    if (( ! DRY_RUN )); then
        [[ -f "$KIMG" ]] || { echo "ERROR: $KIMG missing; cannot --skip-kernel" >&2; exit 1; }
    fi
else
    echo "===> [2/4] kernel (Image + DTB)"
    run "$REPO_ROOT/kernel/build.sh" \
        --linux="$LINUX" \
        --patches="$PATCHES" \
        --jobs="$JOBS" \
        --out="$KERNEL_OUT"
fi

# --- [3/4] rootfs.img + rootfs.img.zst ---
# system_a is 1.75 GiB — the default 1.6 GiB leaves ext4 superblock + journal
# headroom.
if (( SKIP_ROOTFS_IMG )); then
    echo "===> [3/4] rootfs.img SKIPPED (--skip-rootfs-img)"
    # Don't insist on the .zst existing — the caller may be iterating on just
    # the kernel or the boot images; a missing rootfs is caught at flash time.
elif (( SKIP_ROOTFS )) && [[ ! -e "$ROOTFS" ]]; then
    echo "===> [3/4] rootfs.img SKIPPED (no source rootfs tarball and --skip-rootfs)"
else
    echo "===> [3/4] rootfs.img + zstd"
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

# --- [4/4] slot-A image set: boot.img + dtbo.img + vbmeta.img ---
# pack_boota_set.sh builds the Android boot.img (kernel + DTB in --second),
# the DTBO image, and a vbmeta chaining both, all AVB-signed. It writes
# boot-c60.img / dtbo-c60.img / vbmeta-c60.img; republish them under the slot
# names the flasher expects.
echo "===> [4/4] slot-A image set (boot.img + dtbo.img + vbmeta.img)"
run "$REPO_ROOT/bootimg/pack_boota_set.sh" \
    --kernel="$KIMG" \
    --dtb="$DTB" \
    --profile="$PROFILE" \
    --key="$AVB_KEY" \
    --out="$OUT"
run mv -f "$OUT/boot-c60.img"   "$BOOT_IMG"
run mv -f "$OUT/dtbo-c60.img"   "$DTBO_IMG"
run mv -f "$OUT/vbmeta-c60.img" "$VBMETA_IMG"

# --- summary ---
if (( ! DRY_RUN )); then
    cp "$KIMG" "$OUT/Image" 2>/dev/null || true
    cp "$DTB"  "$OUT/$DTB_NAME" 2>/dev/null || true

    cat > "$OUT/version.env" <<EOF
C60_FW_VERSION=$C60_FW_VERSION
C60_BUILD_DATE=$C60_BUILD_DATE
C60_BUILD_HOST=$C60_BUILD_HOST
C60_PROFILE=$profile_name
EOF

    sumset=( Image "$DTB_NAME" )
    [[ -f "$OUT/$BOOT_IMG_NAME"       ]] && sumset+=( "$BOOT_IMG_NAME" )
    [[ -f "$OUT/$DTBO_IMG_NAME"       ]] && sumset+=( "$DTBO_IMG_NAME" )
    [[ -f "$OUT/$VBMETA_IMG_NAME"     ]] && sumset+=( "$VBMETA_IMG_NAME" )
    [[ -f "$OUT/$ROOTFS_IMG_ZST_NAME" ]] && sumset+=( "$ROOTFS_IMG_ZST_NAME" )
    sumset+=( version.env )
    ( cd "$OUT" && sha256sum "${sumset[@]}" 2>/dev/null > SHA256SUMS && cat SHA256SUMS )
fi

echo "[OK] artifacts in $OUT"
