#!/system/bin/sh
MODDIR=${0%/*}

# 1. Purge stale dalvik-cache artifacts ONCE on first boot after install/update
if [ -f "$MODDIR/wipe_cache_once" ]; then
    rm -rf /data/dalvik-cache/arm64/*services* 2>/dev/null
    rm -rf /data/dalvik-cache/arm64/*miui-services* 2>/dev/null
    rm -f "$MODDIR/wipe_cache_once"
fi

# A re-patch cannot survive a reboot, so a running flag found this early was
# left behind by one that was killed. Drop it, or the module would report
# "re-patching" forever and refuse to start a new attempt.
if [ -f "$MODDIR/repatch_running" ]; then
    rm -f "$MODDIR/repatch_running"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] previous re-patch was interrupted by a reboot" >> "$MODDIR/repatch.log"
fi

# 2. Firmware Change Guard (OTA safety)
# The patched jars are built against one specific firmware build. After an OTA
# the rest of the ROM has moved on and serving them is a bootloop, so when the
# build recorded at install time no longer matches the running one the module
# serves nothing at all: the device boots on 100% stock framework and
# service.sh re-patches against the new firmware after boot.
#
# skip_mount is the documented signal for that - Magisk, KernelSU and APatch all
# honour it, and all of them read it after running post-fs-data.sh. Without it
# the root manager would still mount $MODDIR/system over /system on its own, no
# matter what this script does with its own bind mounts.
CURRENT_FP="$(getprop ro.build.version.incremental)"
STORED_FP="$(cat "$MODDIR/rom.fingerprint" 2>/dev/null)"

if [ -n "$STORED_FP" ] && [ -n "$CURRENT_FP" ] && [ "$STORED_FP" != "$CURRENT_FP" ]; then
    touch "$MODDIR/skip_mount"
    touch "$MODDIR/repatch_pending"
    rm -f "$MODDIR/repatch_reboot"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] firmware changed ($STORED_FP -> $CURRENT_FP): module not mounted, re-patch pending" >> "$MODDIR/repatch.log"
    exit 0
fi

# Firmware matches again (fresh install, or a completed re-patch): let the root
# manager mount the module again and clear the transient state.
rm -f "$MODDIR/skip_mount" "$MODDIR/repatch_pending" "$MODDIR/repatch_reboot" "$MODDIR/repatch_failed"

# 3. Strict Bootloop Guard & Global Root Bind Mounts
# Only mount if the patched JAR exists and is a valid, non-corrupt archive (> 1MB).
# If files are missing or corrupt, skip mounting to safely fall back to 100% stock ROM.
mount_if_valid() {
    _src="$1"
    _dst="$2"
    [ -f "$_src" ] || return 0
    [ -e "$_dst" ] || return 0
    _sz=$(wc -c < "$_src" 2>/dev/null || echo 0)
    [ "$_sz" -gt 1000000 ] || return 0
    mount -o bind "$_src" "$_dst" 2>/dev/null
}

mount_if_valid "$MODDIR/system/framework/services.jar" /system/framework/services.jar

# HyperOS keeps miui-services.jar in /system_ext, older MIUI builds in /system;
# mount whichever copies this install produced, each to the path it came from.
mount_if_valid "$MODDIR/system_ext/framework/miui-services.jar" /system_ext/framework/miui-services.jar
mount_if_valid "$MODDIR/system/system_ext/framework/miui-services.jar" /system/system_ext/framework/miui-services.jar
mount_if_valid "$MODDIR/system/framework/miui-services.jar" /system/framework/miui-services.jar
