#!/usr/bin/env bash
# kernel/build.sh — C60 (Kepler proto1) mainline kernel build.
#
# Differs from TC8's kernel/build.sh in three ways:
#   1. Drops in the C60 DTS from dts/ and registers it in
#      the Makefile (TC8's DTS comes from the patch series; C60's DTS
#      lives standalone for now — a kernel patch series will come later).
#   2. Output DTB name is imx8mm-kepler-proto1.dtb.
#   3. --initramfs-dir is OPTIONAL. Primary build path (TC8 trick: raw
#      mmc read + booti, root on system_a) leaves CONFIG_INITRAMFS_SOURCE
#      empty. Only the bootstrap installer build (Path B) sets
#      --initramfs-dir → CONFIG_INITRAMFS_SOURCE → embedded ramdisk.
#
# USAGE
#   kernel/build.sh --linux=DIR --patches=DIR [--dts=PATH] [--config=FILE] \
#                   [--initramfs-dir=DIR] [--jobs=N] [--out=DIR]
#
# OUTPUTS (in --out dir, default ./out/kernel)
#   Image
#   imx8mm-kepler-proto1.dtb

set -euo pipefail

LINUX=""
PATCHES=""
CONFIG=""
DTS=""
INITRAMFS_DIR=""
JOBS="$(nproc)"
OUT=""
ARCH="arm64"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
DTB_NAME="imx8mm-kepler-proto1.dtb"
DTS_NAME="imx8mm-kepler-proto1.dts"
DTB_SUBPATH="arch/arm64/boot/dts/freescale/$DTB_NAME"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Default DTS lives at dts/imx8mm-kepler-proto1.dts in this repo. The build
# copies it into the kernel tree on each run so edits to the canonical copy
# are picked up without manual sync.
DEFAULT_DTS="${REPO_ROOT}/dts/imx8mm-kepler-proto1.dts"

usage() {
  cat <<EOF
kernel/build.sh — C60 mainline kernel + DTB build

USAGE
  kernel/build.sh --linux=DIR --patches=DIR [options]

REQUIRED
  --linux=DIR        Path to vanilla linux-6.6 source tree
  --patches=DIR      Path to tc8-kernel-patches/patches (the C60 needs 0003+0004
                     for the RTL switch; 0001+0002+0005 are TC8-board-specific
                     but harmless to apply since they touch separate files).

OPTIONS
  --dts=PATH         C60 DTS source (default: dts/imx8mm-kepler-proto1.dts)
  --config=FILE      Kernel config fragment (default: kernel/c60.config)
  --initramfs-dir=DIR  Populated initramfs tree to embed (default:
                       \$REPO_ROOT/initramfs/out/rootfs). Must exist before this
                       script runs — initramfs/build.sh populates it.
  --jobs=N           make -j (default: nproc)
  --out=DIR          Output dir for Image + DTB (default: ./out/kernel)
  --arch=ARCH        default arm64
  --cross=PREFIX     default aarch64-linux-gnu-

ENVIRONMENT
  CROSS_COMPILE      Same as --cross
EOF
}

for arg in "$@"; do
  case "$arg" in
    --linux=*) LINUX="${arg#--linux=}";;
    --patches=*) PATCHES="${arg#--patches=}";;
    --dts=*) DTS="${arg#--dts=}";;
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
[[ -n "$DTS" ]] || DTS="$DEFAULT_DTS"
[[ -f "$DTS" ]] || { echo "ERROR: C60 DTS not found: $DTS" >&2; exit 1; }
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/out/kernel"

# INITRAMFS_DIR is optional. Primary C60 build (TC8 trick) has no embedded
# initramfs: root is on system_a. The bootstrap installer build (Path B)
# passes --initramfs-dir → kernel embeds the installer initramfs.
if [[ -n "$INITRAMFS_DIR" ]]; then
    [[ -d "$INITRAMFS_DIR" ]] || {
        echo "ERROR: --initramfs-dir set but $INITRAMFS_DIR doesn't exist" >&2
        exit 1
    }
fi

mkdir -p "$OUT"
echo "[+] linux tree:       $LINUX"
echo "[+] patches:          $PATCHES"
echo "[+] config:           $CONFIG"
echo "[+] DTS:              $DTS"
if [[ -n "$INITRAMFS_DIR" ]]; then
    echo "[+] initramfs source: $INITRAMFS_DIR"
else
    echo "[+] initramfs source: (none — primary mmc-read+booti build)"
fi
echo "[+] out:              $OUT"
echo "[+] ARCH=$ARCH CROSS_COMPILE=$CROSS jobs=$JOBS"

cd "$LINUX"

# --- Apply patches idempotently ---
# Same logic as TC8: forward apply if not yet applied, skip if reverse-applies,
# fail otherwise. The TC8 patch set is mostly orthogonal to C60 except for
# 0001 (which adds the LCC DTS in arch/arm64/boot/dts/freescale/Makefile —
# safe to apply, it doesn't touch our DTS).
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

# --- Drop the C60 DTS into the kernel tree ---
# Always overwrite — keeps the in-tree copy in lockstep with the canonical
# dts/imx8mm-kepler-proto1.dts. Edits to the canonical version
# show up on the next build with no manual sync.
DTS_DEST="arch/arm64/boot/dts/freescale/$DTS_NAME"
cp "$DTS" "$DTS_DEST"
echo "[+] installed DTS:    $DTS_DEST"

# --- Register the DTB in the Makefile ---
# Append a `dtb-${CONFIG_ARCH_MXC} += imx8mm-kepler-proto1.dtb` line if not
# already present. The Makefile already has many `dtb-${CONFIG_ARCH_MXC} +=`
# lines for sibling i.MX 8M Mini boards (e.g. imx8mm-evk.dtb).
MAKEFILE="arch/arm64/boot/dts/freescale/Makefile"
if ! grep -q "$DTB_NAME" "$MAKEFILE"; then
    echo "dtb-\${CONFIG_ARCH_MXC} += $DTB_NAME" >> "$MAKEFILE"
    echo "[+] registered $DTB_NAME in $MAKEFILE"
else
    echo "[=] $DTB_NAME already in $MAKEFILE"
fi

# --- Install config: start from arm64 defconfig, merge our overlay, then
# (only if --initramfs-dir was passed) resolve INITRAMFS_SOURCE to an
# absolute path so the kernel doesn't try to read it relative to its own
# source dir. ---
# Stage WiFi firmware blobs into the kernel tree's firmware/ dir so
# CONFIG_EXTRA_FIRMWARE picks them up at vmlinux link time. Embeds them
# in the Image so brcmfmac PCIe probe at t≈3s can load firmware without
# waiting for /lib/firmware/ to be mounted from system_a. See
# memory/feedback-c60-pcie-refclk-pad-mode.md for the timing rationale.
FW_SRC="$REPO_ROOT/firmware-blobs"
if [[ -d "$FW_SRC" ]]; then
    mkdir -p firmware/brcm
    for blob in brcmfmac4356-pcie.bin brcmfmac4356-pcie.clm_blob brcmfmac4356-pcie.txt; do
        [[ -f "$FW_SRC/$blob" ]] && cp -f "$FW_SRC/$blob" "firmware/brcm/$blob"
    done
    echo "[+] staged brcm firmware blobs into firmware/brcm/ for CONFIG_EXTRA_FIRMWARE"
fi

make ARCH="$ARCH" CROSS_COMPILE="$CROSS" defconfig
scripts/kconfig/merge_config.sh -m .config "$CONFIG"

if [[ -n "$INITRAMFS_DIR" ]]; then
    # Replace the literal initramfs path with the actual absolute path.
    # Config files ship a relative placeholder ("initramfs/out/rootfs") so
    # they stay portable; we rewrite in-place into the working .config
    # after merge_config but before olddefconfig.
    INITRAMFS_ABS="$(cd "$INITRAMFS_DIR" && pwd)"
    sed -i "s|^CONFIG_INITRAMFS_SOURCE=.*$|CONFIG_INITRAMFS_SOURCE=\"$INITRAMFS_ABS\"|" .config
else
    # Primary build: no embedded initramfs. Strip any stale path so the
    # kernel doesn't try to gen_init_cpio against a missing dir.
    sed -i 's|^CONFIG_INITRAMFS_SOURCE=.*$|CONFIG_INITRAMFS_SOURCE=""|' .config
fi

make ARCH="$ARCH" CROSS_COMPILE="$CROSS" olddefconfig

# --- Build ---
make -j"$JOBS" ARCH="$ARCH" CROSS_COMPILE="$CROSS" Image dtbs

IMAGE_SRC="arch/$ARCH/boot/Image"
DTB_SRC="$DTB_SUBPATH"
[[ -f "$IMAGE_SRC" ]] || { echo "ERROR: $IMAGE_SRC not produced" >&2; exit 1; }
[[ -f "$DTB_SRC" ]]   || { echo "ERROR: $DTB_SRC not produced" >&2; exit 1; }

cp "$IMAGE_SRC" "$OUT/Image"
cp "$DTB_SRC"   "$OUT/$DTB_NAME"

# Sanity: warn if Image exceeds u-boot BOOTM_LEN (~32 MiB).
SIZE_BYTES="$(stat -c%s "$OUT/Image")"
if (( SIZE_BYTES > 33554432 )); then
    echo "[!!] WARNING: Image is $SIZE_BYTES bytes (> 32 MiB BOOTM_LEN cap)" >&2
    echo "[!!] u-boot 2018.03 will likely reject this. Trim more drivers from c60.config." >&2
fi

echo "[OK] kernel build complete:"
ls -la "$OUT/"
