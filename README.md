# c60-firmware-build

Mainline Linux 6.6 build pipeline for the **Poly Trio C60** (codename
`kepler_proto1`, i.MX 8M Mini Quad). Sister to `tc8-firmware-build`.

Builds a mainline kernel and a Debian bookworm arm64 Wayland/Cage kiosk rootfs,
packaged as an Android boot.img slot-A image set. The C60 is HAB-open: the
bootloader (`polycom-uboot`) is loaded into RAM over i.MX SDP with `uuu` and
boots slot A by reading `boot_a` with `mmc read` and calling `booti`.

## Layout

| Path | Contents |
|---|---|
| `kernel-patches/` | kernel patch series incl. board DTS (submodule → `c60-kernel-patches`) |
| `kernel/` | kernel build + config fragment |
| `images/` | ext4 `rootfs.img` packing |
| `bootimg/` | Android boot.img / dtbo / vbmeta packing |
| `initramfs/` | busybox initramfs for bring-up debugging |
| `profiles/` | build profiles (`emmc`) |
| `rootfs/` | Debian rootfs builder (submodule → `c60-rootfs`) |

## Build

```
./bootstrap.sh
./build.sh --profile=emmc
```

Outputs in `out/emmc/`: `boot.img`, `dtbo.img`, `vbmeta.img`, `rootfs.img.zst`,
`Image`, `imx8mm-kepler-proto1.dtb`, `SHA256SUMS`. See [BUILDING.md](BUILDING.md).

## Flashing

The board is placed in SDP mode, the bootloader is loaded with `uuu`, and the
bootloader plus the slot-A image set are written over `fastboot`. See
[FLASHING.md](FLASHING.md).
