#!/system/bin/sh
MODDIR=${0%/*}

# Strict Bootloop Guard & Global Root Bind Mounts
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
