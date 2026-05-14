# Building C60 (Kepler proto1) mainline firmware

Sister to `tc8-firmware-build`. Pivoted (v2) to the **TC8 "flat-layout"
boot trick**: u-boot env runs a `slotbboot` macro that does raw
`mmc read` + `booti` into slot-A partitions, bypassing the Android
`boot.img` / `boota` / AVB stack entirely. Slot B (Android) is left
untouched as a fallback — `fastboot set_active b && fastboot reboot`
brings the device back to stock.

## Boot path

After install, stock u-boot's boot path is:

```
bootcmd = run slotbboot
slotbboot = mmc dev 1;
            if test "${boot_slot}" = "bak"; then
              mmc read 0x40000000 ${BOOT_B_LBA} ${BOOT_LEN}; # raw Image
              mmc read 0x43400000 ${DTBO_B_LBA} ${DTBO_LEN}; # raw DTB
            else
              mmc read 0x40000000 ${BOOT_A_LBA} ${BOOT_LEN};
              mmc read 0x43400000 ${DTBO_A_LBA} ${DTBO_LEN};
            fi;
            setenv bootargs "${kepler_bootargs}";
            booti 0x40000000 - 0x43400000
kepler_bootargs = console=tty0 console=ttymxc1,115200 ...
                  root=/dev/disk/by-partlabel/system_a rw rootwait
boot_slot = main
```

`BOOT_A_LBA` / `DTBO_A_LBA` etc. are stored in the env block as
explicit hex sectors, populated by `tools/install_uboot_env.sh` from
`profiles/emmc.env`. They map to the stock C60 GPT (per
`c60-forensics/PROBE_NOTES.md` (in the polycom_re parent tree)) — see "LBAs" below.

The `bak` branch references `BOOT_B_LBA` / `DTBO_B_LBA` (stock kernel
locations). We never overwrite slot B, so `boot_slot=bak` would
currently `booti` into stock Android's vendor-format kernel header
(panic on entry — Android header is not a Linux booti header). Keep
`boot_slot=main` for now; the "bak" path is reserved for a future
mainline-on-slot-B mirror.

## Outputs

`./build.sh --profile=emmc` produces in `out/emmc/`:

| File | Purpose |
|---|---|
| `Image` | raw kernel — read by `slotbboot` into RAM |
| `imx8mm-kepler-proto1.dtb` | raw DTB |
| `rootfs.img.zst` | zstd-compressed ext4 rootfs for `system_a` (1.6 GiB inflated) |
| `uboot-env.bin` | u-boot env blob to `dd` to `/dev/mmcblk2` at offset `0x400000` |
| `SHA256SUMS` | for verification |
| `version.env` | git rev + build host stamp |

Add `--with-bootstrap-installer` to ALSO build the Path B installer:

| File | Purpose |
|---|---|
| `boot-c60-installer.img` | Android boot.img with embedded one-shot install initramfs |
| `vbmeta-c60-installer.img` | matching vbmeta for boot_a |

## Prerequisites

Host packages (Debian/Ubuntu):

```
sudo apt install -y \
    git build-essential bc bison flex libssl-dev libelf-dev \
    crossbuild-essential-arm64 \
    cpio gzip rsync zstd \
    busybox-static \
    debootstrap qemu-user-static binfmt-support \
    u-boot-tools \
    openssl \
    python3
```

For the installer (`--with-bootstrap-installer`):

```
sudo apt install -y mkbootimg
```

`avbtool` is fetched into `vendored/avbtool/` by `bootstrap.sh` (not
packaged in Debian) — only needed for the installer.

## Build

```
./bootstrap.sh             # fetch linux-6.6, kernel-patches, avbtool
./build.sh --profile=emmc
```

For Path B installer:

```
./build.sh --profile=emmc --with-bootstrap-installer
```

## Two install paths

### Path A — brainslug Ctrl-C catch (preferred, leaves device cleanest)

Spam Ctrl-C at stock u-boot via the brainslug WebSocket during a PoE
cycle. Then set the env from inside u-boot (`setenv kepler_bootargs ...;
setenv slotbboot ...; saveenv`), invoke `ums 0 mmc 1` to expose the
eMMC user area, and `dd` Image / DTB / rootfs.img into slot-A
partitions from the staging host. Mirrors `tc8-firmware-build/smoke/onboard.sh`
exactly except we DON'T repartition.

```
tools/flash_c60.sh --path=A \
    --brainslug http://10.99.0.95 \
    --staging-host aibox \
    --poe-port 4 \
    --artifacts out/emmc \
    --no-dry-run
```

Caveats:
- C60 stock u-boot has `bootdelay=0` (per
  `feedback_c60_uboot_no_interrupt`). Past attempts to interrupt failed.
  The TC8 brainslug catch_uboot.py spams via WebSocket from the first
  byte and reliably catches TC8 — try this approach harder before
  giving up.
- We don't know whether Polycom u-boot will accept env writes that
  survive reboot. TC8 confirms it does; C60 has a "bad CRC, using
  defaults" boot message which suggests env writes may not persist.
  If `saveenv` reports success but the next boot ignores it, Path A
  is dead and you need Path B.

### Path B — bootstrap installer via fastboot

Flash a one-shot installer that runs the install dance from inside Linux:

```
fastboot flash boot_a   out/emmc/boot-c60-installer.img
fastboot flash vbmeta_a out/emmc/vbmeta-c60-installer.img
fastboot --set-active=a
fastboot reboot
```

Or with the wrapper:

```
tools/flash_c60.sh --path=B --artifacts out/emmc --no-dry-run
```

The installer's `/init` waits for `/dev/mmcblk2pN` to appear, sanity-
checks the GPT (refuses if partition sizes don't match stock C60),
`dd`s Image / DTB / rootfs.img into slot-A partitions, writes the
u-boot env blob to `/dev/mmcblk2` at offset `0x400000`, and reboots.

After the install reboot, stock u-boot loads our env, runs `slotbboot`,
and the device is on the mmc-read+booti path forever. The installer
boot.img isn't run again unless we re-flash it.

Slot B remains the stock kernel + system: `fastboot set_active b &&
fastboot reboot` rolls back.

## LBAs

Stock C60 GPT (per `PROBE_NOTES.md` + `/proc/partitions`). LBA sizes
in 512-byte sectors:

| # | Name | LBA size | Use |
|---|------|---------:|-----|
| 1 | `dtbo_a` | 0x2000 (4 MiB) | raw DTB target |
| 2 | `dtbo_b` | 0x2000 (4 MiB) | UNTOUCHED (stock dtbo) |
| 3 | `boot_a` | 0x18000 (48 MiB) | raw Image target |
| 4 | `boot_b` | 0x18000 (48 MiB) | UNTOUCHED (stock boot.img) |
| 5 | `system_a` | 0x380000 (1.75 GiB) | rootfs.img target |
| 6 | `system_b` | 0x380000 (1.75 GiB) | UNTOUCHED (stock system) |

The start LBAs of those partitions are GUESSED in `profiles/emmc.env`
(conventional i.MX 8M layout: first user partition at LBA 0x2000).
The actual GPT start LBAs are needed for `slotbboot` to find the
partitions — verify them by running `sgdisk -p /dev/sdX` on the
UMS-attached eMMC during Path A, or `sgdisk -p /dev/mmcblk2` from
inside the installer initramfs during Path B. If they differ from
our assumptions, edit `profiles/emmc.env` and rebuild.

The slotbboot env in `profiles/emmc.env` uses raw LBA values rather
than u-boot's `part start` command for portability across u-boot
revisions — C60's u-boot rev may or may not have CONFIG_CMD_PART.

## u-boot env offset assumption

**UNVERIFIED for C60.** We assume `/dev/mmcblk2 @ 0x400000`, size
4 KiB — same as TC8 (verified there by binary-scanning the env block).
Polycom u-boot rev appears similar enough that the offset is likely
the same, but if it isn't:

- `fw_setenv` from Linux will silently fail (CRC mismatch → "default
  environment");
- `dd` of `uboot-env.bin` to the wrong offset will scribble random
  data on whatever's there;
- u-boot will fall back to compile-time defaults → boot stock Android.

To verify on a stock C60 (root shell needed):

```
dd if=/dev/mmcblk2 bs=4096 skip=1024 count=1 | xxd | head
```

Expect a 4-byte little-endian CRC32 followed by NUL-separated
`key=value` entries (`bootcmd=...`, `bootdelay=...`, etc). If the
first 4 bytes are 0xff or 0x00 padding, the env isn't there — search
for the `bootcmd=` ASCII signature elsewhere on the disk.

`/etc/fw_env.config` in the rootfs is set per these assumptions; edit
it if you find a different offset.

## Verifying scripts without running them

```
bash -n bootstrap.sh build.sh kernel/build.sh images/rootfs.sh \
    bootimg/build.sh bootimg/build_vbmeta.sh \
    tools/install_uboot_env.sh tools/flash_c60.sh \
    tools/bootstrap_installer/build_initramfs.sh
shellcheck bootstrap.sh build.sh kernel/build.sh images/rootfs.sh \
    bootimg/build.sh bootimg/build_vbmeta.sh \
    tools/install_uboot_env.sh tools/flash_c60.sh \
    tools/bootstrap_installer/build_initramfs.sh
./build.sh --profile=emmc --dry-run
```

## Open questions

- **C60 u-boot env offset.** Assumed 0x400000 / 4 KiB. Verify by
  inspecting a stock /dev/mmcblk2 dump (see "u-boot env offset
  assumption" above) before flashing.
- **Will Polycom u-boot persist env writes?** C60 boot log says
  "bad CRC, using defaults" — the existing env block may be intentionally
  garbled by Polycom firmware on every cold boot. If so, neither
  `saveenv` from u-boot nor `dd uboot-env.bin` will survive a reboot,
  and we have no path forward without an SDP recovery to a non-Polycom
  u-boot. Test by running `setenv foo bar; saveenv; reset` from a
  caught u-boot session, then `printenv foo` after reboot.
- **slot-A partition start LBAs.** Guessed from convention; verify
  before flashing. If our `BOOT_A_LBA` is wrong, `slotbboot` reads
  garbage and `booti` rejects it. The installer's `expect_size` check
  catches a wildly-different GPT; modest offset differences pass that
  check but still produce a bad boot.
- **Can the bootstrap installer's boota actually run?** We need stock
  u-boot to accept a custom (testkey-signed) `boot_a` + `vbmeta_a`
  in unlocked mode. C60 forensics confirms the bootloader is unlocked,
  but `UMS_PROGRESS.md` notes `fastboot boot <unsigned>` was silently
  rejected even unlocked. The signed `add_hash_footer` path SHOULD
  work (orange-mode warning), but it's not tested yet — Path B is
  effectively a single-shot experiment.
- **Path A persistence on `boota` re-run.** Even if env writes persist,
  the next stock-style boot would still try `boota boot_${slot}`
  (compile-time default). Our env override changes `bootcmd` to
  `run slotbboot`, but if the env is wiped on the FIRST boot before
  saveenv settles, we're stuck.
