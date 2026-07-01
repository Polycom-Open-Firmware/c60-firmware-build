#!/usr/bin/env bash
# bootstrap.sh — fetch the build inputs for the C60 mainline pipeline.
#
# - submodules: kernel-patches (c60-kernel-patches) + rootfs (c60-rootfs),
#   initialized from .gitmodules.
# - linux-6.6:  shallow-cloned from kernel.org.
# - avbtool:    fetched from the AOSP external/avb mirror (not packaged in
#               Debian); vendored for the boot.img / vbmeta packing step.
#
# Idempotent — safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

LINUX_DIR="${REPO_ROOT}/linux-6.6"
LINUX_TAG="v6.6"
LINUX_URL="${LINUX_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"

AVBTOOL_DIR="${REPO_ROOT}/vendored/avbtool"
AVBTOOL_URL="${AVBTOOL_URL:-https://android.googlesource.com/platform/external/avb}"

echo "===> [1/3] init submodules (kernel-patches, rootfs)"
git submodule update --init --recursive

echo "===> [2/3] linux-6.6"
if [[ -d "$LINUX_DIR/.git" || -f "$LINUX_DIR/Makefile" ]]; then
    echo "[=] $LINUX_DIR already present — skipping"
else
    echo "[+] shallow-cloning ${LINUX_TAG} from ${LINUX_URL}"
    git clone --branch "$LINUX_TAG" --depth 1 "$LINUX_URL" "$LINUX_DIR"
fi

echo "===> [3/3] avbtool"
if [[ -x "$AVBTOOL_DIR/avbtool" || -f "$AVBTOOL_DIR/avbtool.py" ]]; then
    echo "[=] $AVBTOOL_DIR already vendored — skipping"
else
    mkdir -p "$(dirname "$AVBTOOL_DIR")"
    echo "[+] cloning avbtool from ${AVBTOOL_URL}"
    git clone --depth 1 "$AVBTOOL_URL" "$AVBTOOL_DIR"
fi

cat <<EOF

[OK] bootstrap complete.

Next:
    ./build.sh --profile=emmc

Artifacts land in ./out/emmc/.
EOF
