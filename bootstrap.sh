#!/usr/bin/env bash
# bootstrap.sh — fetch build inputs for C60 mainline pipeline.
#
# - linux-6.6:   symlinked from tc8-firmware-build/linux-6.6 if present,
#                otherwise shallow-cloned from kernel.org.
# - kernel-patches: ditto — reuses the TC8 patch series since 0003+0004
#                (RTL switch driver + FEC fixed-link) apply cleanly to
#                C60. 0001+0002+0005 patch the LCC board files; they
#                don't conflict with our C60 DTS.
# - avbtool:     fetched from the AOSP external/avb mirror on GitHub.
#                Not packaged in Debian; the tc8 v0.1 pipeline vendored
#                it the same way.
#
# Idempotent — safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

LINUX_DIR="${REPO_ROOT}/linux-6.6"
LINUX_TAG="v6.6"
LINUX_URL="${LINUX_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"

PATCHES_DIR="${REPO_ROOT}/kernel-patches"
PATCHES_URL="${PATCHES_URL:-https://github.com/Polycom-Open-Firmware/tc8-kernel-patches.git}"

AVBTOOL_DIR="${REPO_ROOT}/vendored/avbtool"
AVBTOOL_URL="${AVBTOOL_URL:-https://android.googlesource.com/platform/external/avb}"

# Sibling TC8 checkout — if present, we can hardlink/symlink large inputs
# instead of re-fetching them.
TC8_BUILD="${REPO_ROOT}/../tc8-firmware-build"

# --- [1/3] linux-6.6 ---
echo "===> [1/3] linux-6.6"
if [[ -d "$LINUX_DIR/.git" || -f "$LINUX_DIR/Makefile" ]]; then
    echo "[=] $LINUX_DIR already present — skipping"
elif [[ -d "$TC8_BUILD/linux-6.6" && ( -d "$TC8_BUILD/linux-6.6/.git" || -f "$TC8_BUILD/linux-6.6/Makefile" ) ]]; then
    echo "[+] symlinking $TC8_BUILD/linux-6.6 → $LINUX_DIR"
    ln -snf "$TC8_BUILD/linux-6.6" "$LINUX_DIR"
else
    echo "[+] shallow-cloning ${LINUX_TAG} from ${LINUX_URL}"
    git clone --branch "$LINUX_TAG" --depth 1 "$LINUX_URL" "$LINUX_DIR"
fi

# --- [2/3] kernel-patches ---
echo "===> [2/3] kernel-patches"
if [[ -d "$PATCHES_DIR" && -d "$PATCHES_DIR/patches" ]]; then
    echo "[=] $PATCHES_DIR already present — skipping"
elif [[ -d "$TC8_BUILD/kernel-patches/patches" ]]; then
    echo "[+] symlinking $TC8_BUILD/kernel-patches → $PATCHES_DIR"
    ln -snf "$TC8_BUILD/kernel-patches" "$PATCHES_DIR"
else
    echo "[+] cloning kernel-patches from ${PATCHES_URL}"
    git clone "$PATCHES_URL" "$PATCHES_DIR"
fi

# --- [3/3] avbtool ---
echo "===> [3/3] avbtool"
if [[ -x "$AVBTOOL_DIR/avbtool" || -f "$AVBTOOL_DIR/avbtool.py" ]]; then
    echo "[=] $AVBTOOL_DIR already vendored — skipping"
else
    mkdir -p "$(dirname "$AVBTOOL_DIR")"
    # AOSP repo includes a Python avbtool; we only need that file + libavb_aftl
    # support modules. A full repo clone is the simplest reproducible path.
    echo "[+] cloning avbtool from ${AVBTOOL_URL}"
    git clone --depth 1 "$AVBTOOL_URL" "$AVBTOOL_DIR"
fi

cat <<EOF

[OK] bootstrap complete.

Next:
    ./build.sh --profile=emmc

Artifacts will land in ./out/emmc/.
EOF
