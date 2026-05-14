# c60-firmware-build

Mainline Linux 6.6 build pipeline for the **Poly Trio C60**
(codename `kepler_proto1`). Sister to `tc8-firmware-build/`.

Boot path: u-boot env `slotbboot` macro does raw `mmc read` + `booti`
into slot-A partitions, bypassing Android `boota` + AVB entirely.
Slot B Android remains untouched as the recovery fallback.

## Background

- DT bring-up plan: [`../re/c60_mainline_prep.md`](../re/c60_mainline_prep.md)
- Starter DTS: [`dts/imx8mm-kepler-proto1.dts`](dts/imx8mm-kepler-proto1.dts)

## Build

See [`BUILDING.md`](./BUILDING.md). Short version:

```
./bootstrap.sh
./build.sh --profile=emmc
```

Outputs land in `out/emmc/`: `Image` + `imx8mm-kepler-proto1.dtb` +
`rootfs.img.zst` + `uboot-env.bin`.

For the Path B bootstrap installer (one-shot fastboot install):

```
./build.sh --profile=emmc --with-bootstrap-installer
```

## Flashing

```
tools/flash_c60.sh --path=A|B --artifacts out/emmc --no-dry-run [...]
```

- `--path=A` — catch u-boot via brainslug Ctrl-C, install env, UMS, dd.
  Mirrors TC8 `onboard.sh`. Preferred IF u-boot can be caught (C60
  `bootdelay=0` makes this uncertain).
- `--path=B` — fastboot flash a one-shot installer that does the
  install dance from inside Linux on first boot.

Slot B Android stays bootable in both cases:
`fastboot set_active b && fastboot reboot` rolls back to stock.
