#!/system/bin/sh
# ==============================================================================
# HyperOS FCM Notification Fix - shared shell helpers
# ==============================================================================
# Sourced by customize.sh (install time) and repatch.sh (post-OTA re-patch), so
# both resolve the ROM profile and inspect jars with exactly the same rules. Any
# drift between them would mean the re-patch resolves a different patcher
# strategy than the install did.
# ==============================================================================

# Fills ROM_SDK / ROM_OS / ROM_REGION / ROM_INCREMENTAL from the running build.
detect_rom_profile() {
    ROM_SDK="$(getprop ro.build.version.sdk)"
    [ -z "$ROM_SDK" ] && ROM_SDK=0
    ROM_INCREMENTAL="$(getprop ro.build.version.incremental)"

    ROM_OS="hyperos"
    [ "$ROM_SDK" -eq 33 ] && ROM_OS="miui14"

    ROM_REGION="global"
    case "$ROM_INCREMENTAL" in
        *CNXM*|*cnxm*) ROM_REGION="cn" ;;
    esac
    REGION_PROP="$(getprop ro.miui.region | tr '[:upper:]' '[:lower:]')"
    [ "$REGION_PROP" = "cn" ] && ROM_REGION="cn"
}

# Prints a reason and returns 1 when the detected profile has no patcher.
rom_profile_supported() {
    if [ "$ROM_SDK" -lt 33 ]; then
        echo "Unsupported Android version (SDK $ROM_SDK < 33)."
        return 1
    fi
    if [ "$ROM_OS" = "hyperos" ] && [ "$ROM_REGION" = "global" ]; then
        echo "HyperOS Global patcher is not available (only HyperOS China is currently supported)."
        return 1
    fi
    return 0
}

# True while a jar does not carry our injected filter class. Framework dex
# entries are ZIP-stored uncompressed, so the class name is greppable; -m1 stops
# at the first hit instead of scanning the whole 30 MB jar.
is_stock_jar() {
    ! grep -aqm1 FcmWakeFilter "$1" 2>/dev/null
}

# Echoes the live miui-services.jar path (HyperOS keeps it in /system_ext,
# older MIUI builds in /system).
live_miui_services() {
    if [ -f /system_ext/framework/miui-services.jar ]; then
        echo /system_ext/framework/miui-services.jar
    elif [ -f /system/framework/miui-services.jar ]; then
        echo /system/framework/miui-services.jar
    fi
}
