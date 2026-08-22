#!/system/bin/sh
MODDIR=${0%/*}

# 1. Purge stale dalvik-cache artifacts ONCE on first boot after install/update
if [ -f "$MODDIR/wipe_cache_once" ]; then
    rm -rf /data/dalvik-cache/arm64/*services* 2>/dev/null
    rm -rf /data/dalvik-cache/arm64/*miui-services* 2>/dev/null
    rm -f "$MODDIR/wipe_cache_once"
fi

# 2. Guarantee that patched framework JARs are bind-mounted in the global root mount namespace
# This bypasses any Xiaomi HyperOS custom pangu overlays or KernelSU OverlayFS edge cases.
if [ -f "$MODDIR/system/framework/services.jar" ]; then
    mount -o bind "$MODDIR/system/framework/services.jar" /system/framework/services.jar 2>/dev/null
fi

if [ -f "$MODDIR/system_ext/framework/miui-services.jar" ]; then
    mount -o bind "$MODDIR/system_ext/framework/miui-services.jar" /system_ext/framework/miui-services.jar 2>/dev/null
fi
