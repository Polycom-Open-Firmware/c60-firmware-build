#!/usr/bin/env bash
# initramfs/build.sh — minimal busybox initramfs for C60 mainline bring-up.
#
# NOTE (v2 pivot): the primary pipeline does NOT use this initramfs.
# `build.sh --profile=emmc` produces a kernel with no embedded initramfs;
# root comes up via partlabel against system_a. This script is retained
# for two purposes:
#
#   1. Bring-up debugging — drop a kernel into RAM via netboot / SDP
#      recovery / fastboot boot, pass this initramfs externally, and get
#      a serial shell on ttymxc1 to inspect the running kernel without
#      committing anything to eMMC.
#   2. As a reference for tools/bootstrap_installer/build_initramfs.sh,
#      which builds the very different "one-shot install dance" initramfs
#      used by Path B.
#
# Produces (under initramfs/out/):
#   rootfs/                    populated tree
#   initramfs.cpio.gz          standalone cpio for external-ramdisk use
#                              (NXP boota external-ramdisk path is broken
#                              on mainline DT — but the cpio works for
#                              netboot or initrd= experiments)
#
# Goal: get to a serial shell on ttymxc1 so we can prove the kernel boots.
# DHCP + DSA user-port bring-up happens here too (no userspace required) so
# the first boot can be debugged over the LAN as well as serial.
#
# Busybox: pulled from Debian's `busybox-static` package on the host (apt
# install busybox-static). We extract just the static binary; no chroot/
# debootstrap dance. Override path via BUSYBOX=/path/to/busybox-static.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${HERE}/out"
ROOTFS="${OUT}/rootfs"

# Source of the static busybox. On Debian/Ubuntu: `apt install busybox-static`
# installs /bin/busybox (a static binary). If the user has built their own,
# point BUSYBOX at it.
BUSYBOX="${BUSYBOX:-/bin/busybox}"
if [[ ! -x "$BUSYBOX" ]]; then
    # Fallback: try Debian's package alt path
    for candidate in /usr/bin/busybox /usr/local/bin/busybox; do
        [[ -x "$candidate" ]] && BUSYBOX="$candidate" && break
    done
fi
[[ -x "$BUSYBOX" ]] || {
    echo "ERROR: static busybox not found." >&2
    echo "       try: sudo apt install busybox-static" >&2
    echo "       or set: BUSYBOX=/path/to/busybox-static $0" >&2
    exit 1
}

# Confirm it's actually static — a glibc-linked busybox will fail to exec
# under the initramfs (no /lib/ld-linux-aarch64.so.1).
if file "$BUSYBOX" 2>/dev/null | grep -q "dynamically linked"; then
    echo "ERROR: $BUSYBOX is dynamically linked — needs the static build." >&2
    echo "       on Debian: apt install busybox-static (/bin/busybox)" >&2
    exit 1
fi

# We need an arm64 busybox, not the host's. Detect mismatch and bail.
HOST_ARCH="$(file "$BUSYBOX" | grep -oE 'ARM aarch64|x86-64|aarch64' | head -1 || true)"
case "$HOST_ARCH" in
    *aarch64*) ;;
    *) echo "ERROR: $BUSYBOX is not aarch64 (got: $HOST_ARCH)." >&2
       echo "       cross-host: install busybox-static from a Debian arm64 sysroot," >&2
       echo "       or BUSYBOX=/path/to/aarch64-static-busybox $0" >&2
       exit 1 ;;
esac

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/{bin,sbin,etc,proc,sys,dev,run,tmp,mnt,root,var/log}
chmod 1777 "$ROOTFS/tmp"

install -m 0755 "$BUSYBOX" "$ROOTFS/bin/busybox"

# Applets used by /init. Stay narrow — every applet symlink ends up in
# the cpio. (busybox itself is one binary; symlinks are cheap.)
for applet in \
        sh ash mount umount mkdir cat grep sed cp mv ls ln rm chmod chown \
        sleep echo cut tr printenv hostname date dmesg uname free df du \
        ps top kill killall ip ifconfig route udhcpc telnet ftpget vi \
        getty login passwd switch_root reboot poweroff halt insmod modprobe \
        find xargs head tail wc cmp od hexdump base64 nc ping ; do
    ln -sf busybox "$ROOTFS/bin/$applet"
done

# /init is the kernel's first program when no rdinit= is on the cmdline.
install -m 0755 "$HERE/init" "$ROOTFS/init"

# Minimal /etc state — enough that login + busybox tools don't complain.
cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
EOF
cat > "$ROOTFS/etc/hostname" <<'EOF'
c60-bringup
EOF
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1   localhost c60-bringup
EOF
cat > "$ROOTFS/etc/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
# Empty motd-style banner — gets printed by /init before handing to sh.
cat > "$ROOTFS/etc/banner.txt" <<'EOF'
============================================================
 C60 (Kepler proto1) mainline bring-up initramfs
   ttymxc1: serial console
   lan*:    DSA user ports (DHCP attempted by /init)
============================================================
EOF

# Also build a standalone cpio.gz for external-ramdisk experimentation.
# Not consumed by the default pipeline but cheap to produce.
mkdir -p "$OUT"
( cd "$ROOTFS" && find . | cpio -o -H newc --quiet ) | gzip -9 > "$OUT/initramfs.cpio.gz"

echo "[OK] populated tree: $ROOTFS"
echo "[OK] cpio.gz:        $OUT/initramfs.cpio.gz ($(stat -c%s "$OUT/initramfs.cpio.gz") bytes)"
