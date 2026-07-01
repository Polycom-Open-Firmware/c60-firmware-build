# Building the C60 firmware

Builds the mainline Linux 6.6 kernel and a Debian bookworm arm64 rootfs for the
Poly Trio C60 (Kepler proto1, i.MX 8M Mini Quad), packaged as an Android
boot.img slot-A image set that the board's u-boot boots.

## Prerequisites

Host packages (Debian/Ubuntu):

```
sudo apt install -y \
    git build-essential bc bison flex libssl-dev libelf-dev \
    crossbuild-essential-arm64 \
    cpio gzip rsync zstd busybox-static \
    debootstrap qemu-user-static binfmt-support \
    u-boot-tools mkbootimg openssl python3
```

`avbtool` is fetched into `vendored/avbtool/` by `bootstrap.sh` (it is not
packaged in Debian).

## Build

```
./bootstrap.sh              # linux-6.6, kernel-patches, the rootfs submodule, avbtool
./build.sh --profile=emmc
```

`build.sh` runs four steps: rootfs tarball (debootstrap, under sudo) → kernel
(Image + DTB) → `rootfs.img` (ext4, zstd-compressed) → slot-A image set
(`bootimg/pack_boota_set.sh`).

Outputs in `out/emmc/`:

| File | Target partition | Purpose |
|---|---|---|
| `boot.img` | `boot_a` | Android boot.img v0 — kernel + DTB in `second` |
| `dtbo.img` | `dtbo_a` | DTB in an Android DTBO container |
| `vbmeta.img` | `vbmeta_a` | AVB metadata (hash descriptors for boot + dtbo) |
| `rootfs.img.zst` | `system_a` | zstd-compressed ext4 Debian rootfs |
| `Image` | — | raw kernel (intermediate) |
| `imx8mm-kepler-proto1.dtb` | — | device tree (intermediate) |
| `SHA256SUMS`, `version.env` | — | checksums + build stamp |

## Iterating

- `--skip-kernel` — reuse `out/<profile>/kernel/Image`
- `--skip-rootfs` — reuse `rootfs/out/rootfs.tar.gz`
- `--skip-rootfs-img` — reuse `out/<profile>/rootfs.img.zst`
- `--jobs=N` — kernel build parallelism (default: `nproc`)
- `--dry-run` — print the pipeline without running it

## Profiles

`profiles/<name>.env` defines the kernel command line, artifact names, and the
Android boot.img / AVB packing parameters. Select with `--profile=NAME`; outputs
land in `out/<name>/`. `emmc` is the default and the only shipped profile.

## Boot model

The C60 is HAB-open. The bootloader (built from `polycom-uboot`, target
`c60-kepler_proto1`) is loaded into RAM over i.MX SDP with `uuu`, comes up as a
fastboot gadget, and boots slot A by reading `boot_a` with `mmc read` and
calling `booti`. The slot image set is written with `fastboot`. See
[FLASHING.md](FLASHING.md) for the install procedure.
