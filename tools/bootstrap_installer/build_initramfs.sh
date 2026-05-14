#!/usr/bin/env bash
# bootstrap_installer/build_initramfs.sh — populate the installer
# initramfs tree under tools/bootstrap_installer/out/rootfs.
#
# This is DIFFERENT from initramfs/build.sh — that one drops to a debug
# shell. The installer's /init runs the one-shot install dance, then
# reboots. After first boot the device is on the mmc-read+booti path
# forever and this initramfs never runs again.
#
# Payload required at build time:
#   ../../out/<profile>/Image
#   ../../out/<profile>/imx8mm-kepler-proto1.dtb
#   ../../out/<profile>/rootfs.img.zst
#   ../../out/<profile>/uboot-env.bin
#
# These are baked into the cpio so the installer can run with the panel
# disconnected from the staging host. (The boot.img is the only thing
# fastboot needs to push.)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${HERE}/out"
ROOTFS="${OUT}/rootfs"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# Profile defaults to emmc; PROFILE env can override.
PROFILE_NAME="${PROFILE_NAME:-emmc}"
PAYLOAD_DIR="${PAYLOAD_DIR:-$REPO_ROOT/out/$PROFILE_NAME}"

BUSYBOX="${BUSYBOX:-/bin/busybox}"
[[ -x "$BUSYBOX" ]] || {
    for c in /usr/bin/busybox /usr/local/bin/busybox; do
        [[ -x "$c" ]] && BUSYBOX="$c" && break
    done
}
[[ -x "$BUSYBOX" ]] || {
    echo "ERROR: static busybox not found." >&2
    echo "       try: sudo apt install busybox-static" >&2
    exit 1
}
if file "$BUSYBOX" 2>/dev/null | grep -q "dynamically linked"; then
    echo "ERROR: $BUSYBOX is dynamically linked — need busybox-static" >&2
    exit 1
fi
HOST_ARCH="$(file "$BUSYBOX" | grep -oE 'ARM aarch64|x86-64|aarch64' | head -1 || true)"
case "$HOST_ARCH" in
    *aarch64*) ;;
    *) echo "ERROR: $BUSYBOX is not aarch64" >&2; exit 1 ;;
esac

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/{bin,sbin,etc,proc,sys,dev,run,tmp,mnt,payload,root}
chmod 1777 "$ROOTFS/tmp"

install -m 0755 "$BUSYBOX" "$ROOTFS/bin/busybox"

# Applets used by /init.
for applet in \
        sh ash mount umount mkdir cat grep sed cp mv ls ln rm chmod chown \
        sleep echo cut tr printenv hostname date dmesg uname free df du \
        ps top kill killall ip ifconfig route udhcpc switch_root reboot \
        poweroff halt insmod modprobe find xargs head tail wc cmp od hexdump \
        base64 dd zcat sync stat readlink ; do
    ln -sf busybox "$ROOTFS/bin/$applet"
done

# zstd applet — only present in some busybox builds. Fall back to a
# vendored static zstd if our busybox lacks it. The installer needs to
# decompress rootfs.img.zst, so this is non-optional.
if "$BUSYBOX" --list-full | grep -q '^bin/zstd$'; then
    ln -sf busybox "$ROOTFS/bin/zstd"
elif command -v zstd >/dev/null 2>&1 && file "$(command -v zstd)" 2>/dev/null | grep -q "ELF.*statically linked.*aarch64"; then
    install -m 0755 "$(command -v zstd)" "$ROOTFS/bin/zstd"
else
    echo "[!] WARNING: no aarch64-static zstd available." >&2
    echo "[!] The installer initramfs will fail to decompress rootfs.img.zst." >&2
    echo "[!] Either rebuild busybox with zstd, or vendor an aarch64 zstd binary at" >&2
    echo "[!]   $ROOTFS/bin/zstd before flashing the installer boot.img." >&2
fi

# Stage payload artifacts. If they don't exist, the installer will fail
# at runtime — but we WARN here so the user notices at build time.
mkdir -p "$ROOTFS/payload"
for f in Image imx8mm-kepler-proto1.dtb rootfs.img.zst uboot-env.bin; do
    if [[ -f "$PAYLOAD_DIR/$f" ]]; then
        install -m 0644 "$PAYLOAD_DIR/$f" "$ROOTFS/payload/$f"
        echo "[+] staged $f ($(stat -c%s "$PAYLOAD_DIR/$f") bytes)"
    else
        echo "[!] missing payload: $PAYLOAD_DIR/$f — installer will fail at runtime" >&2
    fi
done

# /init
install -m 0755 "$HERE/init" "$ROOTFS/init"

# Minimal /etc state.
cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF

# Build the cpio.gz alongside (kernel/build.sh embeds the DIR tree, but
# the cpio is handy for inspection / external-ramdisk experiments).
mkdir -p "$OUT"
( cd "$ROOTFS" && find . | cpio -o -H newc --quiet ) | gzip -9 > "$OUT/initramfs.cpio.gz"

echo "[OK] installer tree: $ROOTFS"
echo "[OK] cpio.gz:        $OUT/initramfs.cpio.gz ($(stat -c%s "$OUT/initramfs.cpio.gz") bytes)"
