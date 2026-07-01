# c60-firmware-build — build card

Builds the mainline Linux 6.6 kernel and a Debian rootfs for the Poly Trio C60
(Kepler proto1, i.MX 8M Mini Quad), packaged as an Android boot.img slot-A image
set. The board is HAB-open; `polycom-uboot` is loaded into RAM over SDP and
boots slot A with `mmc read` + `booti`.

## Build

```
sudo apt install -y git build-essential bc bison flex libssl-dev libelf-dev \
    crossbuild-essential-arm64 cpio gzip rsync zstd busybox-static \
    debootstrap qemu-user-static binfmt-support u-boot-tools mkbootimg openssl python3
./bootstrap.sh
./build.sh --profile=emmc
```

Outputs in `out/emmc/`: `boot.img` `dtbo.img` `vbmeta.img` `rootfs.img.zst`
`Image` `imx8mm-kepler-proto1.dtb` `SHA256SUMS` `version.env`.

## Rules

- Never hand-edit `linux-6.6/`; never disable a `.patch` to dodge an apply
  conflict — regenerate from a clean tree.
- Comments and docs stay neutral and present-tense: no development narrative,
  no dates, no lab-specific values, no links to files outside the repo.

## Related

- `BUILDING.md` — full build doc
- `FLASHING.md` — install procedure
- `polycom-uboot` — the bootloader (target `c60-kepler_proto1`)
- `c60-kernel-patches` — board DTS + audio-codec patches
