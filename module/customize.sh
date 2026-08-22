#!/system/bin/sh
# ====================================================================
# HyperOS FCM Surgical Fix - On-The-Fly Transactional Patcher Installer
# ====================================================================

ui_print "***********************************************"
ui_print "*   HyperOS FCM & GMS Push Notification Fix    *"
ui_print "*   On-Device Surgical Bytecode Patcher        *"
ui_print "*   (Zero-PC, Dynamic All-or-Nothing Engine)   *"
ui_print "***********************************************"

STAGE_DIR="/data/local/tmp/fcm_patch_stage_$$"
mkdir -p "$STAGE_DIR"

cleanup() {
    rm -rf "$STAGE_DIR"
}

abort_install() {
    ui_print ""
    ui_print "[!] ERROR: $1"
    ui_print "[!] Aborting installation. Stock system remains 100% untouched."
    cleanup
    abort "$1"
}

# ==========================================
# Pre-Flight Compatibility & ROM Checks
# ==========================================

# 1. Check Android SDK Version (Require Android 13+ / SDK 33+)
API_LEVEL=$(getprop ro.build.version.sdk)
[ -z "$API_LEVEL" ] && API_LEVEL=0

if [ "$API_LEVEL" -lt 33 ]; then
    ui_print ""
    ui_print "[!] INCOMPATIBLE ANDROID VERSION: SDK $API_LEVEL (Android $(getprop ro.build.version.release))"
    ui_print "[!] This surgical patch requires Android 13+ (SDK 33, 34, 35, 36+) for modern HyperOS / MIUI."
    abort_install "Unsupported Android version (SDK $API_LEVEL < 33)."
fi

# 2. Check Device Manufacturer & ROM (Xiaomi / Redmi / POCO / HyperOS)
MANUFACTURER=$(getprop ro.product.manufacturer | tr '[:upper:]' '[:lower:]')
BRAND=$(getprop ro.product.brand | tr '[:upper:]' '[:lower:]')
MIUI_VER=$(getprop ro.miui.ui.version.name)
INCREMENTAL=$(getprop ro.build.version.incremental)

IS_XIAOMI=false
case "$MANUFACTURER" in
    *xiaomi*|*redmi*|*poco*|*blackshark*) IS_XIAOMI=true ;;
esac
case "$BRAND" in
    *xiaomi*|*redmi*|*poco*|*blackshark*) IS_XIAOMI=true ;;
esac
[ -n "$MIUI_VER" ] && IS_XIAOMI=true

if [ "$IS_XIAOMI" != "true" ]; then
    ui_print ""
    ui_print "[!] NON-XIAOMI DEVICE DETECTED: $MANUFACTURER $BRAND"
    ui_print "[!] This module is strictly designed for Xiaomi / Redmi / POCO devices running HyperOS / MIUI."
    abort_install "Non-Xiaomi device detected ($MANUFACTURER)."
fi

# 3. Locate Dalvik / ART Runtime
DALVIK_BIN=""
if [ -f "/apex/com.android.art/bin/dalvikvm" ]; then
    DALVIK_BIN="/apex/com.android.art/bin/dalvikvm"
elif [ -f "/system/bin/dalvikvm" ]; then
    DALVIK_BIN="/system/bin/dalvikvm"
else
    abort_install "dalvikvm runtime not found on this device."
fi

# 4. Check source framework files from live ROM
SERVICES_STOCK="/system/framework/services.jar"
MIUI_SERVICES_STOCK="/system_ext/framework/miui-services.jar"

[ ! -f "$SERVICES_STOCK" ] && abort_install "Missing stock $SERVICES_STOCK"
[ ! -f "$MIUI_SERVICES_STOCK" ] && abort_install "Missing stock $MIUI_SERVICES_STOCK (Ensure you are on HyperOS / MIUI)"

ui_print "- Device: $(getprop ro.product.model) ($(getprop ro.product.manufacturer))"
ui_print "- OS: HyperOS / MIUI ($INCREMENTAL, Android $(getprop ro.build.version.release) / SDK $API_LEVEL)"
ui_print "- Found stock services.jar ($(ls -lh "$SERVICES_STOCK" | awk '{print $5}'))"
ui_print "- Found stock miui-services.jar ($(ls -lh "$MIUI_SERVICES_STOCK" | awk '{print $5}'))"
ui_print "- Launching on-device DEX patch engine..."
ui_print ""

# 5. Execute Transactional Patcher
PATCHER_JAR="$MODPATH/tools/patcher.jar"
[ ! -f "$PATCHER_JAR" ] && abort_install "Patcher engine not found at $PATCHER_JAR"

export ANDROID_DATA="$STAGE_DIR"
"$DALVIK_BIN" -Xmx512m \
    -cp "$PATCHER_JAR" \
    com.hyperos.fcm.patcher.Main \
    --services "$SERVICES_STOCK" \
    --miui-services "$MIUI_SERVICES_STOCK" \
    --out-dir "$STAGE_DIR"

PATCH_STATUS=$?

if [ $PATCH_STATUS -ne 0 ]; then
    abort_install "Bytecode patch verification failed (exit code $PATCH_STATUS). Check log above."
fi

# 6. Verify staged output files exist
if [ ! -f "$STAGE_DIR/services.jar" ] || [ ! -f "$STAGE_DIR/miui-services.jar" ]; then
    abort_install "Patched output JAR files are missing from staging."
fi

ui_print ""
ui_print "- [PASS] All 4 patch vectors verified successfully!"
ui_print "- Performing atomic swap into module filesystem..."

# 7. Atomic Swap into Module Overlay Structure
mkdir -p "$MODPATH/system/framework"
mkdir -p "$MODPATH/system_ext/framework"
mkdir -p "$MODPATH/system/system_ext/framework"

cp "$STAGE_DIR/services.jar" "$MODPATH/system/framework/services.jar"
cp "$STAGE_DIR/miui-services.jar" "$MODPATH/system_ext/framework/miui-services.jar"
cp "$STAGE_DIR/miui-services.jar" "$MODPATH/system/system_ext/framework/miui-services.jar"

# Remove tools directory to keep installed module lean (~30KB)
rm -rf "$MODPATH/tools"

# Signal post-fs-data to purge stale dalvik-cache once on first boot
touch "$MODPATH/wipe_cache_once"

# 8. Apply File Permissions and SELinux Attributes
set_perm "$MODPATH/system/framework/services.jar" 0 0 0644 "u:object_r:system_file:s0"
set_perm "$MODPATH/system_ext/framework/miui-services.jar" 0 0 0644 "u:object_r:system_file:s0"
set_perm "$MODPATH/system/system_ext/framework/miui-services.jar" 0 0 0644 "u:object_r:system_file:s0"
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755

# Clean up staging directory
cleanup

ui_print "- [PASS] Atomic swap completed. Module ready!"
ui_print "***********************************************"
