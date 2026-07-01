#!/usr/bin/env bash
# kernel/build.sh — build the C60 (Kepler proto1) mainline kernel.
#
# Applies the C60 patch series (from the kernel-patches submodule) to a
# vanilla linux-6.6 tree, merges the config overlay, and builds Image + dtbs.
# The board DTS and its freescale/Makefile entry come from patch 0001; the
# drivers the DT needs (RTL8363NB-VB DSA, FEC fixed-phy conduit, TAS5751M,
# tlv320adc3xxx) come from the rest of the series.
#
# USAGE
#   kernel/build.sh --linux=DIR --patches=DIR [--config=FILE] \
#                   [--initramfs-dir=DIR] [--jobs=N] [--out=DIR]
#
# OUTPUTS (in --out, default ./out/kernel)
#   Image
#   imx8mm-kepler-proto1.dtb

set -euo pipefail

LINUX=""
PATCHES=""
CONFIG=""
INITRAMFS_DIR=""
JOBS="$(nproc)"
OUT=""
ARCH="arm64"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
DTB_NAME="imx8mm-kepler-proto1.dtb"
DTB_SUBPATH="arch/arm64/boot/dts/freescale/$DTB_NAME"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<EOF
kernel/build.sh — C60 mainline kernel + DTB build

USAGE
  kernel/build.sh --linux=DIR --patches=DIR [options]

REQUIRED
  --linux=DIR        Path to a vanilla linux-6.6 source tree
  --patches=DIR      Path to the C60 patch series (the patches/ dir)

OPTIONS
  --config=FILE        Kernel config fragment (default: kernel/c60.config)
  --initramfs-dir=DIR  Populated initramfs tree to embed (optional; for
                       bring-up debugging). Must exist before this runs.
  --jobs=N             make -j (default: nproc)
  --out=DIR            Output dir for Image + DTB (default: ./out/kernel)
  --arch=ARCH          default arm64
  --cross=PREFIX       default aarch64-linux-gnu-

ENVIRONMENT
  CROSS_COMPILE        Same as --cross
EOF
}

for arg in "$@"; do
  case "$arg" in
    --linux=*) LINUX="${arg#--linux=}";;
    --patches=*) PATCHES="${arg#--patches=}";;
    --config=*) CONFIG="${arg#--config=}";;
    --initramfs-dir=*) INITRAMFS_DIR="${arg#--initramfs-dir=}";;
    --jobs=*) JOBS="${arg#--jobs=}";;
    --out=*) OUT="${arg#--out=}";;
    --arch=*) ARCH="${arg#--arch=}";;
    --cross=*) CROSS="${arg#--cross=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

[[ -n "$LINUX"   ]] || { echo "ERROR: --linux=DIR required" >&2; exit 1; }
[[ -n "$PATCHES" ]] || { echo "ERROR: --patches=DIR required" >&2; exit 1; }
[[ -d "$LINUX/arch/arm64" ]] || { echo "ERROR: $LINUX does not look like a kernel tree" >&2; exit 1; }
[[ -d "$PATCHES" ]] || { echo "ERROR: patches dir not found: $PATCHES" >&2; exit 1; }
[[ -n "$CONFIG" ]] || CONFIG="$REPO_ROOT/kernel/c60.config"
[[ -f "$CONFIG" ]] || { echo "ERROR: kernel config not found: $CONFIG" >&2; exit 1; }
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/out/kernel"

if [[ -n "$INITRAMFS_DIR" ]]; then
    [[ -d "$INITRAMFS_DIR" ]] || { echo "ERROR: --initramfs-dir set but $INITRAMFS_DIR doesn't exist" >&2; exit 1; }
fi

mkdir -p "$OUT"
echo "[+] linux tree:       $LINUX"
echo "[+] patches:          $PATCHES"
echo "[+] config:           $CONFIG"
if [[ -n "$INITRAMFS_DIR" ]]; then
    echo "[+] initramfs source: $INITRAMFS_DIR"
else
    echo "[+] initramfs source: (none)"
fi
echo "[+] out:              $OUT"
echo "[+] ARCH=$ARCH CROSS_COMPILE=$CROSS jobs=$JOBS"

cd "$LINUX"

# --- Apply the patch series idempotently ---
# Forward-apply if not yet applied, skip if it reverse-applies, fail otherwise.
shopt -s nullglob
patch_files=("$PATCHES"/*.patch)
shopt -u nullglob
if (( ${#patch_files[@]} == 0 )); then
  echo "[!!] no .patch files in $PATCHES — proceeding without"
else
  for p in "${patch_files[@]}"; do
    if git -C "$LINUX" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if git apply --check "$p" >/dev/null 2>&1; then
        echo "[+] applying $(basename "$p")"
        git apply "$p"
      elif git apply --reverse --check "$p" >/dev/null 2>&1; then
        echo "[=] $(basename "$p") already applied — skipping"
      else
        echo "[XX] cannot cleanly apply $(basename "$p") (forward or reverse)" >&2
        exit 1
      fi
    else
      if patch -p1 --dry-run -R --silent < "$p" >/dev/null 2>&1; then
        echo "[=] $(basename "$p") already applied — skipping"
      else
        echo "[+] applying $(basename "$p")"
        patch -p1 < "$p"
      fi
    fi
  done
fi

# --- Stage WiFi + BT firmware blobs for CONFIG_EXTRA_FIRMWARE ---
# Embedded in the Image so brcmfmac (WiFi) and hci_bcm (BT) can load their
# firmware at probe time (~t+3s), before /lib/firmware is available from
# system_a. BCM4356A2.hcd is the BT patchram (hci_bcm requests it by the
# chip's LMP-derived name).
FW_SRC="$REPO_ROOT/firmware-blobs"
if [[ -d "$FW_SRC" ]]; then
    mkdir -p firmware/brcm
    for blob in brcmfmac4356-pcie.bin brcmfmac4356-pcie.clm_blob brcmfmac4356-pcie.txt BCM4356A2.hcd; do
        [[ -f "$FW_SRC/brcm/$blob" ]] && cp -f "$FW_SRC/brcm/$blob" "firmware/brcm/$blob"
    done
    echo "[+] staged brcm firmware blobs into firmware/brcm/"
fi

# --- Config: arm64 defconfig + the overlay fragment ---
make ARCH="$ARCH" CROSS_COMPILE="$CROSS" defconfig
scripts/kconfig/merge_config.sh -m .config "$CONFIG"

if [[ -n "$INITRAMFS_DIR" ]]; then
    INITRAMFS_ABS="$(cd "$INITRAMFS_DIR" && pwd)"
    sed -i "s|^CONFIG_INITRAMFS_SOURCE=.*$|CONFIG_INITRAMFS_SOURCE=\"$INITRAMFS_ABS\"|" .config
else
    sed -i 's|^CONFIG_INITRAMFS_SOURCE=.*$|CONFIG_INITRAMFS_SOURCE=""|' .config
fi

make ARCH="$ARCH" CROSS_COMPILE="$CROSS" olddefconfig

# --- Build ---
make -j"$JOBS" ARCH="$ARCH" CROSS_COMPILE="$CROSS" Image dtbs

IMAGE_SRC="arch/$ARCH/boot/Image"
DTB_SRC="$DTB_SUBPATH"
[[ -f "$IMAGE_SRC" ]] || { echo "ERROR: $IMAGE_SRC not produced" >&2; exit 1; }
[[ -f "$DTB_SRC" ]]   || { echo "ERROR: $DTB_SRC not produced (is it registered in the freescale Makefile by patch 0001?)" >&2; exit 1; }

cp "$IMAGE_SRC" "$OUT/Image"
cp "$DTB_SRC"   "$OUT/$DTB_NAME"

# Sanity: warn if Image exceeds the u-boot BOOTM_LEN cap (~32 MiB).
SIZE_BYTES="$(stat -c%s "$OUT/Image")"
if (( SIZE_BYTES > 33554432 )); then
    echo "[!!] WARNING: Image is $SIZE_BYTES bytes (> 32 MiB BOOTM_LEN cap); trim drivers from c60.config" >&2
fi

echo "[OK] kernel build complete:"
ls -la "$OUT/"
