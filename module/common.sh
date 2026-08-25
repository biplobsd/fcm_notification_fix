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

# Echoes the live miui-services.jar path across all known partition schemes
# (HyperOS keeps it in /system_ext, some dynamic partition layouts in /system/system_ext,
# older MIUI builds in /system, and select builds in /product).
live_miui_services() {
    for _p in /system_ext/framework/miui-services.jar \
             /system/system_ext/framework/miui-services.jar \
             /system/framework/miui-services.jar \
             /product/framework/miui-services.jar \
             /system/product/framework/miui-services.jar; do
        if [ -f "$_p" ]; then
            echo "$_p"
            return 0
        fi
    done
}

# Returns all module destination paths for a given framework jar path,
# handling both direct overlay paths (KernelSU/APatch) and Magisk /system mirrors.
module_dest_paths() {
    _base_dir="$1"
    _stock_path="$2"
    [ -z "$_stock_path" ] && return 0

    # Primary path matching stock layout (e.g. $MODDIR/system_ext/...)
    echo "$_base_dir$_stock_path"

    # Mirror for Magisk compatibility if target is outside /system
    case "$_stock_path" in
        /system/system_ext/*|/system/product/*)
            # If stock path was already nested in /system, also emit un-nested path for direct overlays
            echo "$_base_dir${_stock_path#/system}"
            ;;
        /system/*)
            ;;
        *)
            # If stock was top-level (/system_ext, /product), emit Magisk system/ mirror
            echo "$_base_dir/system$_stock_path"
            ;;
    esac
}

# Pre-compiles system_server framework jars with dex2oat using full speed AOT
# so that the runtime never suffers from interpreter or JIT lag.
# Returns 0 on success, 1 on failure / missing dex2oat.
compile_aot_cache() {
    _staged_services="$1"
    _target_services="$2"
    _staged_miui="$3"
    _target_miui="$4"

    _dex2oat=""
    if command -v dex2oat64 >/dev/null 2>&1; then
        _dex2oat="$(command -v dex2oat64)"
    elif command -v dex2oat >/dev/null 2>&1; then
        _dex2oat="$(command -v dex2oat)"
    elif [ -f "/apex/com.android.art/bin/dex2oat64" ]; then
        _dex2oat="/apex/com.android.art/bin/dex2oat64"
    elif [ -f "/system/bin/dex2oat64" ]; then
        _dex2oat="/system/bin/dex2oat64"
    elif [ -f "/apex/com.android.art/bin/dex2oat" ]; then
        _dex2oat="/apex/com.android.art/bin/dex2oat"
    elif [ -f "/apex/com.android.runtime/bin/dex2oat" ]; then
        _dex2oat="/apex/com.android.runtime/bin/dex2oat"
    elif [ -f "/system/bin/dex2oat" ]; then
        _dex2oat="/system/bin/dex2oat"
    fi

    [ -z "$_dex2oat" ] && return 1

    _arch="$(getprop ro.bionic.arch)"
    if [ -z "$_arch" ]; then
        _abi="$(getprop ro.product.cpu.abi)"
        case "$_abi" in
            arm64*|aarch64*) _arch="arm64" ;;
            armeabi*|armv7*) _arch="arm" ;;
            x86_64*)         _arch="x86_64" ;;
            x86*)            _arch="x86" ;;
            *)               _arch="arm64" ;;
        esac
    fi
    mkdir -p "/data/dalvik-cache/$_arch"

    _services_oat="$(echo "$_target_services" | sed 's|^/||; s|/|@|g')@classes.dex"
    _miui_oat="$(echo "$_target_miui" | sed 's|^/||; s|/|@|g')@classes.dex"

    _sscp="$SYSTEMSERVERCLASSPATH"
    if [ -z "$_sscp" ]; then
        _sspid="$(pidof system_server)"
        [ -n "$_sspid" ] && _sscp="$(cat /proc/$_sspid/environ 2>/dev/null | tr '\0' '\n' | grep '^SYSTEMSERVERCLASSPATH=' | cut -d= -f2-)"
        [ -z "$_sscp" ] && _sscp="$(cat /proc/1/environ 2>/dev/null | tr '\0' '\n' | grep '^SYSTEMSERVERCLASSPATH=' | cut -d= -f2-)"
    fi

    _get_clc() {
        _tgt="$1"
        _res=""
        _old_ifs="$IFS"
        IFS=:
        for _j in $_sscp; do
            if [ "$_j" = "$_tgt" ] || [ "$(basename "$_j")" = "$(basename "$_tgt")" ]; then
                break
            fi
            if [ -n "$_res" ]; then
                _res="$_res:$_j"
            else
                _res="$_j"
            fi
        done
        IFS="$_old_ifs"
        echo "PCL[$_res]"
    }

    _services_clc="$(_get_clc "$_target_services")"
    _miui_clc="$(_get_clc "$_target_miui")"

    "$_dex2oat" \
        --instruction-set="$_arch" \
        --dex-file="$_staged_services" \
        --dex-location="$_target_services" \
        --oat-file="/data/dalvik-cache/$_arch/$_services_oat" \
        --compiler-filter=speed \
        --class-loader-context="$_services_clc" \
        --generate-mini-debug-info >/dev/null 2>&1 || true

    "$_dex2oat" \
        --instruction-set="$_arch" \
        --dex-file="$_staged_miui" \
        --dex-location="$_target_miui" \
        --oat-file="/data/dalvik-cache/$_arch/$_miui_oat" \
        --compiler-filter=speed \
        --class-loader-context="$_miui_clc" \
        --generate-mini-debug-info >/dev/null 2>&1 || true

    if [ -f "/data/dalvik-cache/$_arch/$_services_oat" ] && [ -f "/data/dalvik-cache/$_arch/$_miui_oat" ]; then
        chmod 0644 /data/dalvik-cache/"$_arch"/*services* 2>/dev/null || true
        chown root:root /data/dalvik-cache/"$_arch"/*services* 2>/dev/null || true
        chcon u:object_r:dalvikcache_data_file:s0 /data/dalvik-cache/"$_arch"/*services* 2>/dev/null || true
        return 0
    fi

    return 1
}

