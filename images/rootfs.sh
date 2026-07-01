#!/usr/bin/env bash
# images/rootfs.sh — build a plain ext4 rootfs.img from a rootfs tarball or
# directory. No AVB footer — C60 mmc-read+booti path doesn't verify it.
#
# Default image size is 1.6 GiB, sized to fit inside the stock C60 system_a
# partition (1.75 GiB) with ~150 MiB headroom for ext4 metadata. Anything
# bigger is refused when dd'd into /dev/disk/by-partlabel/system_a.
#
# USAGE
#   images/rootfs.sh --rootfs=PATH [--out=FILE] [--image-size=BYTES]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ROOTFS=""
OUT=""
# 1.6 GiB. stock system_a = 1.75 GiB = 1879048192 B. IMAGE_SIZE is
# 1717986918 B (1.6 GiB): headroom-safe under system_a but large enough
# for a Debian rootfs with the default package set.
IMAGE_SIZE="1717986918"
LABEL="c60-rootfs"

usage() {
  cat <<EOF
images/rootfs.sh — build plain ext4 rootfs.img (no AVB)

USAGE
  images/rootfs.sh --rootfs=PATH [options]

REQUIRED
  --rootfs=PATH        Tarball (.tar[.gz|.xz|.zst]) or directory containing rootfs

OPTIONS
  --out=FILE           Output (default: ./out/rootfs.img)
  --image-size=N       ext4 image size in bytes (default $IMAGE_SIZE)
  --label=NAME         ext4 volume label (default $LABEL)
  -h, --help           Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --rootfs=*) ROOTFS="${arg#--rootfs=}";;
    --out=*) OUT="${arg#--out=}";;
    --image-size=*) IMAGE_SIZE="${arg#--image-size=}";;
    --label=*) LABEL="${arg#--label=}";;
    -h|--help) usage; exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 1;;
  esac
done

[[ -n "$ROOTFS"  ]] || { echo "ERROR: --rootfs= required" >&2; exit 1; }
[[ -e "$ROOTFS"  ]] || { echo "ERROR: rootfs not found: $ROOTFS" >&2; exit 1; }
[[ -n "$OUT" ]] || OUT="$REPO_ROOT/out/rootfs.img"

command -v mkfs.ext4 >/dev/null || { echo "ERROR: mkfs.ext4 not in PATH" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

WORK=""
ROOTFS_DIR=""
cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"; }
trap cleanup EXIT

if [[ -d "$ROOTFS" ]]; then
  ROOTFS_DIR="$ROOTFS"
else
  WORK="$(mktemp -d -t c60-rootfs.XXXXXX)"
  ROOTFS_DIR="$WORK/rootfs"
  mkdir -p "$ROOTFS_DIR"
  echo "[+] extracting $ROOTFS -> $ROOTFS_DIR"
  case "$ROOTFS" in
    *.tar.gz|*.tgz)   tar -xzf "$ROOTFS" -C "$ROOTFS_DIR";;
    *.tar.xz)         tar -xJf "$ROOTFS" -C "$ROOTFS_DIR";;
    *.tar.zst)        tar --zstd -xf "$ROOTFS" -C "$ROOTFS_DIR";;
    *.tar.bz2)        tar -xjf "$ROOTFS" -C "$ROOTFS_DIR";;
    *.tar)            tar -xf  "$ROOTFS" -C "$ROOTFS_DIR";;
    *) echo "ERROR: unrecognized rootfs format: $ROOTFS" >&2; exit 1;;
  esac
fi

echo "[+] truncating image to $IMAGE_SIZE bytes -> $OUT"
truncate -s "$IMAGE_SIZE" "$OUT"

echo "[+] mkfs.ext4 -d $ROOTFS_DIR -L $LABEL"
mkfs.ext4 -F -L "$LABEL" -d "$ROOTFS_DIR" -T default "$OUT"

ls -la "$OUT"
echo "[OK] $OUT"
