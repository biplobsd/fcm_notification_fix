#!/system/bin/sh
MODDIR=${0%/*}

# 1. Purge stale dalvik-cache artifacts ONCE on first boot after install/update
if [ -f "$MODDIR/wipe_cache_once" ]; then
    rm -rf /data/dalvik-cache/arm64/*services* 2>/dev/null
    rm -rf /data/dalvik-cache/arm64/*miui-services* 2>/dev/null
    rm -f "$MODDIR/wipe_cache_once"
fi

# 2. Firmware Change Guard (OTA safety)
# The patched jars are built against one specific firmware build. After an OTA
# the rest of the ROM has moved on and mounting them is a bootloop, so when the
# build recorded at install time no longer matches the running one we mount
# nothing at all: the device boots on 100% stock framework and service.sh
# re-patches against the new firmware after boot.
CURRENT_FP="$(getprop ro.build.version.incremental)"
STORED_FP="$(cat "$MODDIR/rom.fingerprint" 2>/dev/null)"

if [ -n "$STORED_FP" ] && [ -n "$CURRENT_FP" ] && [ "$STORED_FP" != "$CURRENT_FP" ]; then
    touch "$MODDIR/repatch_pending"
    rm -f "$MODDIR/repatch_reboot"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] firmware changed ($STORED_FP -> $CURRENT_FP): framework mounts skipped, re-patch pending" >> "$MODDIR/repatch.log"
    exit 0
fi

# Firmware matches again (fresh install, or a completed re-patch): clear state
rm -f "$MODDIR/repatch_pending" "$MODDIR/repatch_reboot" "$MODDIR/repatch_failed"

# 3. Strict Bootloop Guard & Global Root Bind Mounts
# Only mount if patched JAR exists and is a valid, non-corrupt archive (> 1MB)
# If files are missing or corrupt, skip mounting to safely fall back to 100% stock ROM.
SERVICES_JAR="$MODDIR/system/framework/services.jar"
if [ -f "$SERVICES_JAR" ]; then
    SERVICES_SZ=$(wc -c < "$SERVICES_JAR" 2>/dev/null || echo 0)
    if [ "$SERVICES_SZ" -gt 1000000 ]; then
        mount -o bind "$SERVICES_JAR" /system/framework/services.jar 2>/dev/null
    fi
fi

MIUI_SERVICES_JAR="$MODDIR/system_ext/framework/miui-services.jar"
if [ -f "$MIUI_SERVICES_JAR" ]; then
    MIUI_SZ=$(wc -c < "$MIUI_SERVICES_JAR" 2>/dev/null || echo 0)
    if [ "$MIUI_SZ" -gt 1000000 ]; then
        mount -o bind "$MIUI_SERVICES_JAR" /system_ext/framework/miui-services.jar 2>/dev/null
        [ -d /system/system_ext/framework ] && mount -o bind "$MIUI_SERVICES_JAR" /system/system_ext/framework/miui-services.jar 2>/dev/null || true
    fi
fi
