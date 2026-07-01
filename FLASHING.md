# Flashing the C60

The Poly Trio C60 is HAB-open, so the bootloader is replaced directly.
Installation runs with the board in serial-download (SDP) mode: the bootloader is
loaded into RAM with `uuu`, then the bootloader and the slot-A image set are
written to eMMC over `fastboot`.

## Prerequisites

- Host tools: `uuu` (NXP mfgtools) and `fastboot` (android-tools).
- `flash.bin` — the bootloader, built from `polycom-uboot`
  (`scripts/build.sh c60-kepler_proto1`).
- The slot-A image set from `build.sh --profile=emmc`: `boot.img`, `dtbo.img`,
  `vbmeta.img`, `rootfs.img.zst`.

## Install

1. Set the BOOT_MODE switches to **serial download (SDP)** and power on. The
   board enumerates as an i.MX SDP device (`1fc9:0134`).

2. Load the bootloader into RAM. It comes up as a fastboot gadget:

   ```
   uuu -b spl flash.bin
   ```

3. Write the bootloader to eMMC:

   ```
   fastboot flash bootloader0 flash.bin
   ```

4. Set the BOOT_MODE switches to **internal boot** and reboot. The bootloader now
   runs from eMMC and comes up as a fastboot gadget.

5. Write the slot-A image set:

   ```
   zstd -d rootfs.img.zst
   fastboot flash boot_a   boot.img
   fastboot flash dtbo_a   dtbo.img
   fastboot flash vbmeta_a vbmeta.img
   fastboot flash system_a rootfs.img
   ```

6. Reboot. The bootloader boots slot A (`mmc read boot_a` + `booti`) into Debian.

## Recovery

Set the BOOT_MODE switches to serial download and repeat from step 2 to reload
the bootloader over SDP at any time; internal boot from eMMC is never the only
way back in.
