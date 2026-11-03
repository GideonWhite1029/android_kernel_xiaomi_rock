#!/usr/bin/env bash
# Build UndergroundKernel for rock (POCO M5) with KernelSU-Next and NetHunter support.
# Produces a flashable kernel zip and a KernelSU module with USB adapter drivers
# (Wi-Fi, Bluetooth, serial, SDR) and their firmware.
#
# Env: CLANG_DIR  AOSP clang r416183b (default ~/toolchains/clang-r416183b)
#      ROM_DIR    ROM modules to verify against (kernel_xiaomi_rock@lineage-23.2)
#      LTO        thin (default) or full (gets OOM-killed with 15 GB RAM + 15 GB swap)
#      JOBS       make parallelism
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
OUT=$ROOT/out
CLANG_DIR=${CLANG_DIR:-$HOME/toolchains/clang-r416183b}
ROM_DIR=${ROM_DIR:-$OUT/rom-modules}
LTO=${LTO:-thin}
JOBS=${JOBS:-$(nproc)}
KSU_TAG=v3.4.2
ANYKERNEL_REPO=https://github.com/Asmodeus7999/AnyKernel3
ROM_REPO=https://github.com/Asmodeus7999/kernel_xiaomi_rock
ROM_BRANCH=lineage-23.2
FIRMWARE_REPO=https://gitlab.com/kernel-firmware/linux-firmware.git
FIRMWARE_TAG=20261019
# Out-of-tree Realtek drivers with monitor mode and injection: name, repo, commit and
# the obj-$(...) switch their Makefile only exports when run standalone, not under kbuild
OOT_DRIVERS=(
    "rtl8812au https://github.com/aircrack-ng/rtl8812au 734485506a30d6237c2deaad666a19f8ca5379f2 CONFIG_88XXAU=m"
    "rtl8188eus https://github.com/aircrack-ng/rtl8188eus af3bf004458f76b7aec33e9ba552cd382ed1f5c3 CONFIG_RTL8188EU=m"
    "88x2bu https://github.com/morrownr/88x2bu-20210702 418d71cc00cd18b4a671f8c49ecce9b19cbfd3c9 CONFIG_RTL8822BU=m"
    "8821cu https://github.com/morrownr/8821cu-20210916 bda65aac150d2cde0df9603206eec23a6f3b77c4"
)
# linux-firmware files requested by the adapter drivers in nethunter.fragment
FIRMWARE_PATHS=(
    /ath9k_htc/ /carl9170-1.fw /ar5523.bin /ath6k/AR6004/ /ath3k-1.fw /ar3k/ /qca/
    "/rt2561*.bin" /rt73.bin /rt2860.bin /rt2870.bin /rt3070.bin /rt3071.bin
    /mediatek/mt7601u.bin "/mediatek/mt7610u*" "/mediatek/mt7662u*" "/mediatek/mt7663*"
    /mediatek/mt7668pr2h.bin /mediatek/mt7622pr2h.bin
    /rtlwifi/ /rtl_bt/ /zd1211/ /isl3886usb /isl3887usb "/atmel_at76c50*"
    "/libertas/usb8*" /libertas/lbtf_usb.bin /lbtf_usb.bin "/mrvl/usb*"
    /brcm/brcmfmac43143.bin /brcm/brcmfmac43236b.bin /brcm/brcmfmac43242a.bin
    /brcm/brcmfmac43569.bin /WHENCE
)

export PATH=$CLANG_DIR/bin:$PATH
export KBUILD_BUILD_USER=build-user KBUILD_BUILD_HOST=build-host
# Same as build.config.rock; the Xiaomi Makefiles select rock sources from these
export BUILD_TARGET_PRODUCT=rock TARGET_BUILD_VARIANT=user MTK_PLATFORM=mt6789
MAKE=(make -C "$ROOT" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
      CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi-)

[ -x "$CLANG_DIR/bin/clang" ] || { echo "clang not found in $CLANG_DIR" >&2; exit 1; }
mkdir -p "$OUT"

# KernelSU-Next: drivers/Makefile and drivers/Kconfig already reference drivers/kernelsu
[ -d "$ROOT/KernelSU-Next/.git" ] ||
    git clone https://github.com/KernelSU-Next/KernelSU-Next "$ROOT/KernelSU-Next"
git -C "$ROOT/KernelSU-Next" fetch -q --tags
git -C "$ROOT/KernelSU-Next" checkout -q "$KSU_TAG"
ln -sfn ../KernelSU-Next/kernel "$ROOT/drivers/kernelsu"

if [ ! -d "$ROM_DIR" ]; then
    git clone -q --depth=1 --filter=blob:none --sparse -b "$ROM_BRANCH" "$ROM_REPO" "$ROM_DIR"
    git -C "$ROM_DIR" sparse-checkout set modulesdlkm modulesvndr
fi

CONFIGS=$ROOT/arch/arm64/configs
KCONFIG_CONFIG=$OUT/.config "$ROOT/scripts/kconfig/merge_config.sh" -m -r \
    "$CONFIGS/gki_defconfig" "$CONFIGS/rock.fragment" "$CONFIGS/nethunter.fragment"
if [ "$LTO" = thin ]; then
    "$ROOT/scripts/config" --file "$OUT/.config" -d LTO_CLANG_FULL -e LTO_CLANG_THIN
fi
"${MAKE[@]}" olddefconfig

for opt in $(grep -oE '^CONFIG_[A-Za-z0-9_]+=[ym]' "$CONFIGS/nethunter.fragment"); do
    grep -qx "$opt" "$OUT/.config" || { echo "$opt was dropped by Kconfig" >&2; exit 1; }
done
[ "${CONFIG_ONLY:-0}" = 1 ] && exit 0

"${MAKE[@]}" -j"$JOBS" Image modules

# Out-of-tree drivers are built inside $OUT/oot, where rock_modules.py order finds them.
# Kernel CFI is enforcing, so an indirect call through a mismatched function pointer
# type panics at runtime: refuse any driver that warns about one.
for entry in "${OOT_DRIVERS[@]}"; do
    read -r name repo commit objvar <<< "$entry"
    src=$OUT/oot/$name
    if [ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" != "$commit" ]; then
        rm -rf "$src"
        git init -q "$src"
        git -C "$src" fetch -q --depth=1 "$repo" "$commit"
        git -C "$src" checkout -q FETCH_HEAD
    fi
    # ndo_start_xmit returns netdev_tx_t; Realtek declares int, which CFI treats as
    # a different type and panics on the first transmitted frame
    find "$src" -name '*.[ch]' -exec sed -i -E \
        's/\b(extern |static )?int (rtw_xmit_entry|mgnt_xmit_entry|rtw_cfg80211_monitor_if_xmit_entry)\(/\1netdev_tx_t \2(/' {} +
    # GKI exports filp_open/kernel_read in a namespace drivers must import explicitly
    intfs=$src/os_dep/linux/os_intfs.c
    grep -q 'MODULE_IMPORT_NS(VFS_internal' "$intfs" ||
        sed -i 's/^MODULE_LICENSE("GPL");$/&\nMODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);/' "$intfs"
    # GCC-only warning switches that clang 12 rejects. The Android tree builds with a
    # global -Werror these GCC-oriented drivers never aimed for, so they get -Wno-error;
    # specific -Werror=... from the kernel Makefile still apply.
    sed -i -E '/-Wno-(enum-int-mismatch|stringop-overread|cast-function-type)/d' "$src/Makefile"
    if grep -rnE '\bint (rtw_xmit_entry|mgnt_xmit_entry|rtw_cfg80211_monitor_if_xmit_entry)\(' "$src"; then
        echo "$name: xmit entry still returns int" >&2
        exit 1
    fi
    "${MAKE[@]}" -j"$JOBS" M="$src" CONFIG_RTW_DEBUG=n ${objvar:-} KCFLAGS=-Wno-error modules 2>&1 | tee "$OUT/oot/$name.log"
    if [ -z "$(find "$src" -maxdepth 1 -name '*.ko')" ]; then
        echo "$name: no module built" >&2
        exit 1
    fi
    if grep -E 'incompatible-function-pointer-types|cast-function-type' "$OUT/oot/$name.log"; then
        echo "$name: function pointer type mismatch, would trip CFI" >&2
        exit 1
    fi
done

for group in adapters sdr; do
    python3 -I "$ROOT/scripts/rock_modules.py" order "$OUT" "$ROM_DIR" "$group" > "$OUT/$group-modules.txt"
done
mapfile -t ADAPTER_KO < "$OUT/adapters-modules.txt"
mapfile -t SDR_KO < "$OUT/sdr-modules.txt"
python3 -I "$ROOT/scripts/rock_modules.py" check "$OUT/Module.symvers" "$ROM_DIR" \
    "${ADAPTER_KO[@]}" "${SDR_KO[@]}"

RELEASE=$(cat "$OUT/include/config/kernel.release")
STAMP=$(date +%Y%m%d)
DIST=$OUT/dist
rm -rf "$DIST" "$OUT/AnyKernel3"
mkdir -p "$DIST"

# Flashable kernel: same flow as the UndergroundKernel release, plus a device check
git clone -q --depth=1 "$ANYKERNEL_REPO" "$OUT/AnyKernel3"
rm -rf "$OUT/AnyKernel3/.git" "$OUT/AnyKernel3/.github"
cp "$OUT/arch/arm64/boot/Image" "$OUT/AnyKernel3/"
cat > "$OUT/AnyKernel3/anykernel.sh" <<'EOF'
### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

properties() { '
kernel.string=UndergroundKernel NetHunter
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=1
device.name1=rock
device.name2=stone
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

BLOCK=boot
IS_SLOT_DEVICE=1
RAMDISK_COMPRESSION=auto
PATCH_VBMETA_FLAG=auto

. tools/ak3-core.sh;

split_boot
flash_boot
EOF
(cd "$OUT/AnyKernel3" && python3 -I -m zipfile -c "$DIST/UndergroundKernel-NetHunter-KSUN-$RELEASE-$STAMP.zip" ./*)

# USB adapter drivers as a KernelSU module, since the kernel zip leaves ROM modules alone
KSU_MOD=$OUT/ksu-module
rm -rf "$KSU_MOD"
mkdir -p "$KSU_MOD/modules" "$KSU_MOD/system/etc/firmware"
cat > "$KSU_MOD/module.prop" <<EOF
id=nethunter_usb_adapters
name=NetHunter USB adapters
version=$RELEASE
versionCode=$STAMP
author=UndergroundKernel
description=USB Wi-Fi, Bluetooth, serial and SDR adapter drivers with firmware for $RELEASE; frees /dev/hidg0 for NetHunter HID. Action toggles the V4L2 SDR drivers.
EOF
cat > "$KSU_MOD/customize.sh" <<'EOF'
# Replaces the earlier Wi-Fi-only module, which would load the same drivers twice
[ -d /data/adb/modules/nethunter_usb_wifi ] && touch /data/adb/modules/nethunter_usb_wifi/remove
EOF
cat > "$KSU_MOD/service.sh" <<'EOF'
#!/system/bin/sh
MODDIR=${0%/*}
# Vendor init creates hid.gs0 (only used for KPOC), which takes /dev/hidg0;
# NetHunter expects its keyboard and mouse at /dev/hidg0 and /dev/hidg1.
HID_GS0=/config/usb_gadget/g1/functions/hid.gs0
if [ -d "$HID_GS0" ] && ! ls -l /config/usb_gadget/g1/configs/*/ | grep -q 'hid\.gs0$'; then
    rmdir "$HID_GS0" 2>>"$MODDIR/load.log"
fi
[ "$(uname -r)" = "$(cat "$MODDIR/kernel.release")" ] || exit 0
while read -r ko; do
    insmod "$MODDIR/modules/$ko" 2>>"$MODDIR/load.log"
done < "$MODDIR/load.order"
# The V4L2 SDR drivers grab HackRF/Airspy, which libusb tools then cannot open
if [ -f "$MODDIR/sdr_v4l2" ]; then
    while read -r ko; do
        insmod "$MODDIR/modules/$ko" 2>>"$MODDIR/load.log"
    done < "$MODDIR/sdr.order"
fi
EOF
cat > "$KSU_MOD/action.sh" <<'EOF'
#!/system/bin/sh
MODDIR=${0%/*}
if [ -f "$MODDIR/sdr_v4l2" ]; then
    rm "$MODDIR/sdr_v4l2"
    sed '1!G;h;$!d' "$MODDIR/sdr.order" | while read -r ko; do rmmod "${ko%.ko}" 2>/dev/null; done
    echo "V4L2 SDR drivers off: HackRF/Airspy are free for libusb tools"
else
    touch "$MODDIR/sdr_v4l2"
    while read -r ko; do insmod "$MODDIR/modules/$ko" 2>/dev/null; done < "$MODDIR/sdr.order"
    echo "V4L2 SDR drivers on: HackRF/Airspy show up as /dev/swradio*"
fi
EOF
echo "$RELEASE" > "$KSU_MOD/kernel.release"
: > "$KSU_MOD/load.order"
: > "$KSU_MOD/sdr.order"
for ko in "${ADAPTER_KO[@]}"; do
    "$CLANG_DIR/bin/llvm-strip" --strip-debug -o "$KSU_MOD/modules/$(basename "$ko")" "$ko"
    basename "$ko" >> "$KSU_MOD/load.order"
done
for ko in "${SDR_KO[@]}"; do
    "$CLANG_DIR/bin/llvm-strip" --strip-debug -o "$KSU_MOD/modules/$(basename "$ko")" "$ko"
    basename "$ko" >> "$KSU_MOD/sdr.order"
done

# Firmware: Android's ueventd also searches /system/etc/firmware, which the module overlays
FW_SRC=$OUT/linux-firmware
if [ "$(git -C "$FW_SRC" describe --tags 2>/dev/null)" != "$FIRMWARE_TAG" ]; then
    rm -rf "$FW_SRC"
    git clone -q --depth=1 --filter=blob:none --no-checkout -b "$FIRMWARE_TAG" "$FIRMWARE_REPO" "$FW_SRC"
fi
git -C "$FW_SRC" sparse-checkout set --no-cone "${FIRMWARE_PATHS[@]}"
git -C "$FW_SRC" checkout -q
(cd "$FW_SRC" && find . -path ./.git -prune -o ! -type d ! -name WHENCE -print0 |
    xargs -0 cp -L --parents -t "$KSU_MOD/system/etc/firmware")
# Newer linux-firmware lists aliases as "Link:" entries in WHENCE instead of symlinks
python3 -I - "$FW_SRC/WHENCE" "$KSU_MOD/system/etc/firmware" <<'EOF'
import pathlib, shutil, sys
dest = pathlib.Path(sys.argv[2])
for line in pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines():
    if line.startswith("Link:") and "->" in line:
        link, target = (p.strip() for p in line[5:].split("->"))
        src = (dest / link).parent / target
        if src.is_file() and not (dest / link).exists():
            (dest / link).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest / link)
EOF
(cd "$KSU_MOD" && python3 -I -m zipfile -c "$DIST/NetHunter-USB-adapters-KSU-module-$RELEASE-$STAMP.zip" ./*)

ls -la "$DIST"
