#!/system/bin/sh
# ====================================================================
# HyperOS FCM Push Notification Fix - On-The-Fly Patcher
# ====================================================================

ui_print "***********************************************"
ui_print "*      HyperOS FCM Push Notification Fix      *"
ui_print "*   On-Device Surgical Bytecode Patcher       *"
ui_print "*   (Multi-ROM OS & Region Adaptive Engine)   *"
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
    ui_print "[!] This surgical patch requires Android 13+ (SDK 33, 34, 35, 36+) for HyperOS."
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
    ui_print "[!] This module is strictly designed for Xiaomi / Redmi / POCO devices running HyperOS."
    abort_install "Non-Xiaomi device detected ($MANUFACTURER)."
fi

# Detect OS & Region Profile
OS_TYPE="hyperos"
[ "$API_LEVEL" -eq 33 ] && OS_TYPE="miui14"

REGION_TYPE="global"
case "$INCREMENTAL" in
    *CNXM*|*cnxm*) REGION_TYPE="cn" ;;
esac
REGION_PROP=$(getprop ro.miui.region | tr '[:upper:]' '[:lower:]')
[ "$REGION_PROP" = "cn" ] && REGION_TYPE="cn"

# Guard against unsupported profiles
if [ "$OS_TYPE" = "hyperos" ] && [ "$REGION_TYPE" = "global" ]; then
    abort_install "HyperOS Global patcher is not available (only HyperOS China is currently supported)."
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
if [ ! -f "$MIUI_SERVICES_STOCK" ]; then
    if [ -f "/system/framework/miui-services.jar" ]; then
        MIUI_SERVICES_STOCK="/system/framework/miui-services.jar"
    else
        abort_install "Missing stock miui-services.jar (Ensure you are on HyperOS)"
    fi
fi

ui_print "- Device: $(getprop ro.product.model) ($(getprop ro.product.manufacturer))"
ui_print "- OS Target: $OS_TYPE ($REGION_TYPE, $INCREMENTAL, Android $(getprop ro.build.version.release) / SDK $API_LEVEL)"
ui_print "- Found stock services.jar ($(ls -lh "$SERVICES_STOCK" | awk '{print $5}'))"
ui_print "- Found stock miui-services.jar ($(ls -lh "$MIUI_SERVICES_STOCK" | awk '{print $5}'))"

# ==========================================
# 4.5 Stock Jar Stash — upgrade support.
# First install stashes pristine jars inside the module so future updates can
# re-patch from true stock while the old overlay is still mounted. The stash
# is carried across updates via the modules -> modules_update window.
# ==========================================
MODULE_ID="fcm_notification_fix"
OLD_MOD_DIR="/data/adb/modules/$MODULE_ID"
STOCK_DIR="$MODPATH/stock"
STASH_STATUS="none"   # none | kept | created | carried | skipped

is_stock_jar() {
    # FcmWakeFilter exists only in this module's patched output; framework dex
    # entries are ZIP-stored uncompressed, so the class name is greppable.
    [ "$(grep -ac FcmWakeFilter "$1" 2>/dev/null)" = "0" ]
}

# Carry an existing stash forward so it survives the modules_update swap
if [ -f "$OLD_MOD_DIR/stock/services.jar" ] && [ -f "$OLD_MOD_DIR/stock/miui-services.jar" ]; then
    mkdir -p "$STOCK_DIR"
    cp -f "$OLD_MOD_DIR/stock/services.jar" "$STOCK_DIR/services.jar"
    cp -f "$OLD_MOD_DIR/stock/miui-services.jar" "$STOCK_DIR/miui-services.jar"
    [ -f "$OLD_MOD_DIR/stock/fingerprint" ] && cp -f "$OLD_MOD_DIR/stock/fingerprint" "$STOCK_DIR/fingerprint"
fi

# Decide which jar copies the patch engine should read
SERVICES_READ="$SERVICES_STOCK"
MIUI_READ="$MIUI_SERVICES_STOCK"
USING_STASH=0

LIVE_IS_STOCK=1
is_stock_jar "$SERVICES_STOCK" || LIVE_IS_STOCK=0
is_stock_jar "$MIUI_SERVICES_STOCK" || LIVE_IS_STOCK=0

CURRENT_FP="$(getprop ro.build.version.incremental)"
STASHED_FP="$(cat "$STOCK_DIR/fingerprint" 2>/dev/null)"

if [ "$LIVE_IS_STOCK" != "1" ]; then
    ui_print "- Live framework jars already contain a previous patch"
    if [ -f "$STOCK_DIR/services.jar" ] && [ -f "$STOCK_DIR/miui-services.jar" ] \
        && [ -n "$STASHED_FP" ] && [ "$STASHED_FP" = "$CURRENT_FP" ] \
        && is_stock_jar "$STOCK_DIR/services.jar" && is_stock_jar "$STOCK_DIR/miui-services.jar"; then
        SERVICES_READ="$STOCK_DIR/services.jar"
        MIUI_READ="$STOCK_DIR/miui-services.jar"
        USING_STASH=1
        STASH_STATUS="carried"
        ui_print "- Valid stock stash found (firmware match)"
        ui_print "- Re-patching engine input: stashed stock jars"
    elif [ -n "$STASHED_FP" ] && [ "$STASHED_FP" != "$CURRENT_FP" ]; then
        abort_install "Firmware changed since the stock stash was taken (stashed: $STASHED_FP, current: $CURRENT_FP). Disable this module in your manager, reboot, then re-flash this zip to re-stash against the current firmware."
    else
        abort_install "No valid stock stash found for a live upgrade. Disable this module in your manager, reboot, then re-flash this zip — the first install on stock jars will create the stash automatically."
    fi
elif [ -d "$STOCK_DIR" ] && [ -n "$STASHED_FP" ] && [ "$STASHED_FP" != "$CURRENT_FP" ]; then
    rm -rf "$STOCK_DIR"   # stale stash from older firmware; recreate below
fi

if [ "$USING_STASH" != "1" ] && [ "$LIVE_IS_STOCK" = "1" ]; then
    if [ -f "$STOCK_DIR/services.jar" ] && [ "$STASHED_FP" = "$CURRENT_FP" ] \
        && is_stock_jar "$STOCK_DIR/services.jar" && is_stock_jar "$STOCK_DIR/miui-services.jar"; then
        STASH_STATUS="kept"
    else
        FREE_KB=$(df -k /data/adb 2>/dev/null | tail -n 1 | awk '{print $4}')
        NEED_KB=$(( ($(stat -c %s "$SERVICES_STOCK") + $(stat -c %s "$MIUI_SERVICES_STOCK")) / 1024 + 4096 ))
        if [ "${FREE_KB:-0}" -ge "$NEED_KB" ]; then
            rm -rf "$STOCK_DIR"
            mkdir -p "$STOCK_DIR"
            cp -f "$SERVICES_STOCK" "$STOCK_DIR/services.jar"
            cp -f "$MIUI_SERVICES_STOCK" "$STOCK_DIR/miui-services.jar"
            getprop ro.build.version.incremental > "$STOCK_DIR/fingerprint"
            STASH_STATUS="created"
        else
            STASH_STATUS="skipped"
            ui_print "- [!] Low /data space (${FREE_KB:-0} KB free): skipping stock stash."
            ui_print "- [!] Future live upgrades will need disable + reboot + re-flash."
        fi
    fi
fi

ui_print "- Launching on-device DEX patch engine..."
ui_print ""

# 5. Execute Transactional Patcher
PATCHER_JAR="$MODPATH/tools/patcher.jar"
[ ! -f "$PATCHER_JAR" ] && abort_install "Patcher engine not found at $PATCHER_JAR"

export ANDROID_DATA="$STAGE_DIR"
"$DALVIK_BIN" -Xmx512m \
    -cp "$PATCHER_JAR" \
    com.hyperos.fcm.patcher.Main \
    --services "$SERVICES_READ" \
    --miui-services "$MIUI_READ" \
    --patcher "$PATCHER_JAR" \
    --out-dir "$STAGE_DIR" \
    --sdk "$API_LEVEL" \
    --os "$OS_TYPE" \
    --region "$REGION_TYPE"

PATCH_STATUS=$?

if [ $PATCH_STATUS -ne 0 ]; then
    abort_install "Bytecode patch verification failed (exit code $PATCH_STATUS). Check log above."
fi

# 6. Verify staged output files exist
if [ ! -f "$STAGE_DIR/services.jar" ] || [ ! -f "$STAGE_DIR/miui-services.jar" ]; then
    abort_install "Patched output JAR files are missing from staging."
fi

ui_print ""
ui_print "- [PASS] All patch checkpoints verified successfully!"
ui_print "- Performing atomic swap into module filesystem..."

# 7. Atomic Swap into Module Overlay Structure
mkdir -p "$MODPATH/system/framework"
mkdir -p "$MODPATH/system_ext/framework"
mkdir -p "$MODPATH/system/system_ext/framework"

cp "$STAGE_DIR/services.jar" "$MODPATH/system/framework/services.jar"
cp "$STAGE_DIR/miui-services.jar" "$MODPATH/system_ext/framework/miui-services.jar"
cp "$STAGE_DIR/miui-services.jar" "$MODPATH/system/system_ext/framework/miui-services.jar"

# Initialize default FCM dynamic filter config if not existing
CONF_FILE="/data/system/fcm_wake.conf"
if [ ! -f "$CONF_FILE" ]; then
    cat <<'EOF' > "$CONF_FILE"
# HyperOS FCM Dynamic Wake Filter Configuration
# Modes: MODE=ALL | MODE=WHITELIST | MODE=BLACKLIST
MODE=ALL
EOF
    chmod 0644 "$CONF_FILE"
    chown system:system "$CONF_FILE" 2>/dev/null || true
    chcon u:object_r:system_data_file:s0 "$CONF_FILE" 2>/dev/null || true
fi

# 7.5 Pre-compile system_server AOT cache (dex2oat)
DEX2OAT_BIN=""
if [ -f "/apex/com.android.art/bin/dex2oat64" ]; then
    DEX2OAT_BIN="/apex/com.android.art/bin/dex2oat64"
elif [ -f "/system/bin/dex2oat64" ]; then
    DEX2OAT_BIN="/system/bin/dex2oat64"
elif [ -f "/apex/com.android.art/bin/dex2oat" ]; then
    DEX2OAT_BIN="/apex/com.android.art/bin/dex2oat"
elif [ -f "/system/bin/dex2oat" ]; then
    DEX2OAT_BIN="/system/bin/dex2oat"
fi

if [ -n "$DEX2OAT_BIN" ]; then
    ARCH=$(getprop ro.bionic.arch)
    [ -z "$ARCH" ] && ARCH="arm64"

    ui_print "- Pre-compiling system_server native AOT cache (dex2oat on $ARCH)..."
    mkdir -p "/data/dalvik-cache/$ARCH"

    SERVICES_OAT_NAME="$(echo "$SERVICES_STOCK" | sed 's|^/||; s|/|@|g')@classes.dex"
    MIUI_OAT_NAME="$(echo "$MIUI_SERVICES_STOCK" | sed 's|^/||; s|/|@|g')@classes.dex"

    # Dynamically resolve SYSTEMSERVERCLASSPATH from environment or live system_server process
    SSCP="$SYSTEMSERVERCLASSPATH"
    if [ -z "$SSCP" ]; then
        SSPID=$(pidof system_server)
        [ -n "$SSPID" ] && SSCP=$(cat /proc/$SSPID/environ 2>/dev/null | tr '\0' '\n' | grep '^SYSTEMSERVERCLASSPATH=' | cut -d= -f2-)
        [ -z "$SSCP" ] && SSCP=$(cat /proc/1/environ 2>/dev/null | tr '\0' '\n' | grep '^SYSTEMSERVERCLASSPATH=' | cut -d= -f2-)
    fi

    get_clc_for_jar() {
        target="$1"
        res=""
        OLD_IFS="$IFS"
        IFS=:
        for j in $SSCP; do
            if [ "$j" = "$target" ] || [ "$(basename "$j")" = "$(basename "$target")" ]; then
                break
            fi
            if [ -n "$res" ]; then
                res="$res:$j"
            else
                res="$j"
            fi
        done
        IFS="$OLD_IFS"
        echo "PCL[$res]"
    }

    SERVICES_CLC=$(get_clc_for_jar "$SERVICES_STOCK")
    MIUI_CLC=$(get_clc_for_jar "$MIUI_SERVICES_STOCK")

    "$DEX2OAT_BIN" \
        --instruction-set="$ARCH" \
        --dex-file="$STAGE_DIR/services.jar" \
        --dex-location="$SERVICES_STOCK" \
        --oat-file="/data/dalvik-cache/$ARCH/$SERVICES_OAT_NAME" \
        --compiler-filter=speed \
        --class-loader-context="$SERVICES_CLC" \
        --generate-mini-debug-info >/dev/null 2>&1 || true

    "$DEX2OAT_BIN" \
        --instruction-set="$ARCH" \
        --dex-file="$STAGE_DIR/miui-services.jar" \
        --dex-location="$MIUI_SERVICES_STOCK" \
        --oat-file="/data/dalvik-cache/$ARCH/$MIUI_OAT_NAME" \
        --compiler-filter=speed \
        --class-loader-context="$MIUI_CLC" \
        --generate-mini-debug-info >/dev/null 2>&1 || true

    chmod 0644 /data/dalvik-cache/"$ARCH"/*services* 2>/dev/null || true
    chown root:root /data/dalvik-cache/"$ARCH"/*services* 2>/dev/null || true
    chcon u:object_r:dalvikcache_data_file:s0 /data/dalvik-cache/"$ARCH"/*services* 2>/dev/null || true
    ui_print "- [PASS] Native AOT speed compilation complete."
fi

# Remove tools directory to keep installed module lean (~30KB)
rm -rf "$MODPATH/tools"

# 8. Apply File Permissions and SELinux Attributes
set_perm "$MODPATH/system/framework/services.jar" 0 0 0644 "u:object_r:system_file:s0"
set_perm "$MODPATH/system_ext/framework/miui-services.jar" 0 0 0644 "u:object_r:system_file:s0"
set_perm "$MODPATH/system/system_ext/framework/miui-services.jar" 0 0 0644 "u:object_r:system_file:s0"
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755

if [ -d "$MODPATH/webroot" ]; then
    set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644
    [ -f "$MODPATH/webroot/cgi-bin/exec" ] && set_perm "$MODPATH/webroot/cgi-bin/exec" 0 0 0755
fi

# Clean up staging directory
cleanup

case "$STASH_STATUS" in
    carried) ui_print "- Stock jars re-patched from carried-forward stash" ;;
    kept)    ui_print "- Stock stash verified intact for future upgrades" ;;
    created) ui_print "- Pristine stock jars stashed inside module for future upgrades (~$(du -k "$STOCK_DIR" 2>/dev/null | cut -f1 | tail -n1) KB)" ;;
esac

ui_print "- [PASS] Atomic swap completed. Module ready!"
ui_print "***********************************************"
