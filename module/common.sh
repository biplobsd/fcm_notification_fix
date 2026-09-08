#!/system/bin/sh
# ==============================================================================
# HyperOS FCM Notification Fix - shared shell helpers
# ==============================================================================
# Sourced by customize.sh (install time) and repatch.sh (post-OTA re-patch), so
# both resolve the ROM profile and inspect jars with exactly the same rules. Any
# drift between them would mean the re-patch resolves a different patcher
# strategy than the install did.
# ==============================================================================

# PowerKeeper state touched by the module is stored in stock_settings.conf.
# Each userTable backup records both row existence and the bgControl value so
# restoration can remove rows that the module had to create.
backup_powerkeeper_state() {
    _pk_conf="$1"
    [ -n "$_pk_conf" ] || return 1

    if ! grep -q '^powerkeeper_gms_control=' "$_pk_conf" 2>/dev/null; then
        _pk_gms_ctrl=$(content query --uri content://com.miui.powerkeeper.configure/SimpleSettings/misc \
          --where "name='gms_control'" 2>/dev/null)
        _pk_query_status=$?
        [ "$_pk_query_status" -eq 0 ] || return 1
        _pk_gms_ctrl=$(printf '%s\n' "$_pk_gms_ctrl" | grep -o 'value=[a-z]*' | cut -d= -f2 | head -n1)
        [ -z "$_pk_gms_ctrl" ] && _pk_gms_ctrl="true"
        echo "powerkeeper_gms_control=${_pk_gms_ctrl}" >> "$_pk_conf"
    fi

    for _pk_pkg in com.google.android.gms com.android.vending; do
        _pk_exists_key="powerkeeper_user:${_pk_pkg}:exists"
        if grep -Fq "${_pk_exists_key}=" "$_pk_conf" 2>/dev/null; then
            continue
        fi

        _pk_row=$(content query --uri content://com.miui.powerkeeper.configure/userTable \
          --where "pkgName='${_pk_pkg}' AND userId=0" 2>/dev/null)
        _pk_query_status=$?
        [ "$_pk_query_status" -eq 0 ] || return 1

        if printf '%s\n' "$_pk_row" | grep -q "pkgName=${_pk_pkg}"; then
            _pk_bg_control=$(printf '%s\n' "$_pk_row" | grep -o 'bgControl=[^,]*' | cut -d= -f2- | head -n1 | tr -d '\r')
            _pk_bg_control=$(printf '%s' "$_pk_bg_control" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$_pk_bg_control" ] && _pk_bg_control="NULL"
            echo "${_pk_exists_key}=1" >> "$_pk_conf"
            echo "powerkeeper_user:${_pk_pkg}:bg_control=${_pk_bg_control}" >> "$_pk_conf"
        else
            echo "${_pk_exists_key}=0" >> "$_pk_conf"
        fi
    done
}

ensure_powerkeeper_backup() {
    _pk_target_conf="$1"
    [ -n "$_pk_target_conf" ] || return 1
    _pk_tmp="${_pk_target_conf}.tmp.$$"
    rm -f "$_pk_tmp" 2>/dev/null
    if [ -f "$_pk_target_conf" ]; then
        cp -f "$_pk_target_conf" "$_pk_tmp" 2>/dev/null || return 1
    else
        : > "$_pk_tmp" || return 1
    fi

    if ! backup_powerkeeper_state "$_pk_tmp"; then
        rm -f "$_pk_tmp" 2>/dev/null
        return 1
    fi

    chmod 0600 "$_pk_tmp" 2>/dev/null
    mv -f "$_pk_tmp" "$_pk_target_conf" 2>/dev/null
}

restore_powerkeeper_state() {
    _pk_conf="$1"
    [ -f "$_pk_conf" ] || return 1
    _pk_restore_status=0

    _pk_gms_ctrl=$(awk -F= '$1 == "powerkeeper_gms_control" { print substr($0, index($0, "=") + 1); exit }' "$_pk_conf" 2>/dev/null)
    [ -z "$_pk_gms_ctrl" ] && _pk_gms_ctrl="true"
    content call --uri content://com.miui.powerkeeper.configure/SimpleSettings/misc \
      --method PUT_misc --arg gms_control --extra value:s:"$_pk_gms_ctrl" 2>/dev/null || _pk_restore_status=1

    for _pk_pkg in com.google.android.gms com.android.vending; do
        _pk_existed=$(awk -F= -v key="powerkeeper_user:${_pk_pkg}:exists" \
          '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$_pk_conf" 2>/dev/null)
        if [ "$_pk_existed" = "0" ]; then
            content delete --uri content://com.miui.powerkeeper.configure/userTable \
              --where "pkgName='${_pk_pkg}' AND userId=0" 2>/dev/null || _pk_restore_status=1
        elif [ "$_pk_existed" = "1" ]; then
            _pk_bg_control=$(awk -F= -v key="powerkeeper_user:${_pk_pkg}:bg_control" \
              '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$_pk_conf" 2>/dev/null)
            if [ -z "$_pk_bg_control" ]; then
                _pk_restore_status=1
                continue
            fi

            _pk_row=$(content query --uri content://com.miui.powerkeeper.configure/userTable \
              --where "pkgName='${_pk_pkg}' AND userId=0" 2>/dev/null)
            _pk_query_status=$?
            if [ "$_pk_query_status" -ne 0 ]; then
                _pk_restore_status=1
                continue
            fi
            if [ "$_pk_bg_control" = "NULL" ] || [ "$_pk_bg_control" = "null" ]; then
                _pk_binding="bgControl:n:"
            else
                _pk_binding="bgControl:s:${_pk_bg_control}"
            fi
            if printf '%s\n' "$_pk_row" | grep -q "pkgName=${_pk_pkg}"; then
                content update --uri content://com.miui.powerkeeper.configure/userTable \
                  --bind "$_pk_binding" --where "pkgName='${_pk_pkg}' AND userId=0" 2>/dev/null || _pk_restore_status=1
            else
                content insert --uri content://com.miui.powerkeeper.configure/userTable \
                  --bind pkgName:s:"$_pk_pkg" --bind userId:i:0 --bind "$_pk_binding" 2>/dev/null || _pk_restore_status=1
            fi
        fi
    done

    return "$_pk_restore_status"
}

# Returns a composite signature that uniquely identifies the OS, partition-level framework jars,
# and carrier/XMS hotfix sub-versions (e.g. 3.0.307.0.WOKCNXM.C11).
# Any change to system, system_ext, or OS build triggers a mismatch.
get_rom_fingerprint() {
    _fp="$(getprop ro.build.fingerprint)"
    _sys_fp="$(getprop ro.system.build.fingerprint)"
    _ext_fp="$(getprop ro.system_ext.build.fingerprint)"
    _inc="$(getprop ro.build.version.incremental)"
    _xms="$(getprop persist.sys.xms.version)"
    [ -z "$_xms" ] && _xms="$(getprop ro.mi.xms.version.incremental)"
    [ -z "$_fp" ] && _fp="$(getprop ro.bootimage.build.fingerprint)"
    [ -z "$_fp" ] && _fp="$_inc"

    echo "${_fp}|${_sys_fp}|${_ext_fp}|${_inc}|${_xms}"
}

# Returns a user-friendly version string for UI display and terminal logging.
# Formats: "OS3.0.307.0.WOKCNXM.C11" or "OS1.0.30.0.UNACNXM" or fallback to incremental.
get_rom_display_version() {
    _inc="$(getprop ro.build.version.incremental)"
    _xms="$(getprop persist.sys.xms.version)"
    [ -z "$_xms" ] && _xms="$(getprop ro.mi.xms.version.incremental)"

    if [ -n "$_inc" ] && [ -n "$_xms" ]; then
        case "$_inc" in
            *"."*"$_xms"*) echo "$_inc" ;;
            *) echo "${_inc}.${_xms}" ;;
        esac
    elif [ -n "$_inc" ]; then
        echo "$_inc"
    else
        echo "$(getprop ro.build.display.id)"
    fi
}

# Compares stored fingerprint against current running fingerprint with full backward
# compatibility. Matches if signatures are identical or if stored is in legacy single-string
# format matching base incremental version (from v1.0 - v1.2 releases).
is_fingerprint_match() {
    _stored="$(printf '%s' "$1" | tr -d '\r\n')"
    _current="$(printf '%s' "$2" | tr -d '\r\n')"
    [ -z "$_stored" ] || [ -z "$_current" ] && return 1
    [ "$_stored" = "$_current" ] && return 0

    # Legacy format fallback (stored has no "|" delimiter from module versions v1.0 - v1.2)
    case "$_stored" in
        *"|"*) ;;
        *)
            _inc="$(getprop ro.build.version.incremental | tr -d '\r\n')"
            [ -n "$_inc" ] && [ "$_stored" = "$_inc" ] && return 0
            case "$_current" in
                *"|"*)
                    _cur_inc="$(echo "$_current" | cut -d'|' -f4 | tr -d '\r\n')"
                    [ -n "$_cur_inc" ] && [ "$_stored" = "$_cur_inc" ] && return 0
                    ;;
            esac
            ;;
    esac

    # Backward fallback when current is single-string and stored is composite
    case "$_current" in
        *"|"*) ;;
        *)
            case "$_stored" in
                *"|"*)
                    _stored_inc="$(echo "$_stored" | cut -d'|' -f4 | tr -d '\r\n')"
                    [ -n "$_stored_inc" ] && [ "$_stored_inc" = "$_current" ] && return 0
                    ;;
            esac
            ;;
    esac

    return 1
}

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
    [ -z "$REGION_PROP" ] && REGION_PROP="$(getprop ro.miui.build.region | tr '[:upper:]' '[:lower:]')"
    [ -z "$REGION_PROP" ] && REGION_PROP="$(getprop ro.vendor.miui.region | tr '[:upper:]' '[:lower:]')"
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


# True when a skip_mount-respecting metamodule (mountify) is active and will
# overlay-mount our system/ layout. When so, post-fs-data.sh hands the framework
# mount to it instead of doing the in-memory stealth self-mount: mountify's
# OverlayFS mounts carry a clean /mnt/vendor source and are read-only, so
# integrity checkers (banking / payment apps) no longer flag a module bind mount
# sitting over /system. Only mountify is keyed on here because it is the one
# metamodule verified to honour skip_mount in metamodule mode (its OTA guard).
metamodule_will_mount() {
    _mmp=""
    [ -L /data/adb/metamodule ] && _mmp="$(readlink -f /data/adb/metamodule 2>/dev/null)"
    [ -z "$_mmp" ] && [ -f /data/adb/modules/mountify/metamount.sh ] && _mmp="/data/adb/modules/mountify"
    [ -n "$_mmp" ] || return 1
    [ "$(basename "$_mmp")" = "mountify" ] || return 1
    [ -f "$_mmp/metamount.sh" ] || return 1
    [ -f "$_mmp/disable" ] && return 1
    [ -f "$_mmp/remove" ] && return 1

    # mountify modes: 2 auto (mounts every module with system/), 1 manual (needs
    # us in modules.txt), 0/other disabled. Only delegate when it will mount us.
    _cfg="/data/adb/mountify/config.sh"
    _mode="$(sed -n 's/^[[:space:]]*mountify_mounts=\([0-9]\).*/\1/p' "$_cfg" 2>/dev/null | tail -n1)"
    [ -z "$_mode" ] && _mode=2
    case "$_mode" in
        2) return 0 ;;
        1) grep -Eq '^[[:space:]]*fcm_notification_fix([[:space:]]|$)' /data/adb/mountify/modules.txt 2>/dev/null && return 0
           return 1 ;;
        *) return 1 ;;
    esac
}

# True only when the live framework targets map 1:1 onto mountify's OverlayFS
# target scheme: module/system/<dir> -> /system/<dir> (single depth) or /<top>
# for top-level partition names (system_ext, product, ...). Paths nested under
# /system/<partition>/ (e.g. /system/system_ext/...) would land at the wrong
# mountpoint, so those layouts self-mount instead of delegating.
mountify_maps_cleanly() {
    [ "$1" = "/system/framework/services.jar" ] || return 1
    case "$2" in
        /system_ext/framework/miui-services.jar) return 0 ;;
        /product/framework/miui-services.jar) return 0 ;;
        /system/framework/miui-services.jar) return 0 ;;
        *) return 1 ;;
    esac
}

# Maps an absolute framework target to its path INSIDE the module's system/ tree,
# matching how mountify re-mounts it: module/system/<dir> is overlaid at
# /system/<dir>, while a top-level partition dir (system_ext, product, ...) is
# overlaid at /<dir>. So /system/framework/x -> framework/x, but
# /system_ext/framework/x -> system_ext/framework/x.
target_to_module_rel() {
    case "$1" in
        /system/*) printf '%s\n' "${1#/system/}" ;;
        /*) printf '%s\n' "${1#/}" ;;
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

    _services_oat="/data/dalvik-cache/$_arch/$(echo "$_target_services" | sed 's|^/||; s|/|@|g')@classes.dex"
    _miui_oat="/data/dalvik-cache/$_arch/$(echo "$_target_miui" | sed 's|^/||; s|/|@|g')@classes.dex"

    _services_tmp="/data/dalvik-cache/$_arch/$(echo "$_target_services" | sed 's|^/||; s|/|@|g')@classes.tmp.$$.dex"
    _miui_tmp="/data/dalvik-cache/$_arch/$(echo "$_target_miui" | sed 's|^/||; s|/|@|g')@classes.tmp.$$.dex"

    _sscp="$SYSTEMSERVERCLASSPATH"
    if [ -z "$_sscp" ]; then
        _sspid="$(pidof system_server)"
        [ -n "$_sspid" ] && _sscp="$(cat /proc/$_sspid/environ 2>/dev/null | tr '\0' '\n' | grep '^SYSTEMSERVERCLASSPATH=' | cut -d= -f2-)"
        [ -z "$_sscp" ] && _sscp="$(cat /proc/1/environ 2>/dev/null | tr '\0' '\n' | grep '^SYSTEMSERVERCLASSPATH=' | cut -d= -f2-)"
        if [ -z "$_sscp" ] && [ -f "/data/system/environ/classpath" ]; then
            _sscp="$(grep -m1 '^export SYSTEMSERVERCLASSPATH ' /data/system/environ/classpath 2>/dev/null | awk '{print $3}')"
        fi
    fi

    # Generates ClassLoaderContext, optionally substituting a target jar with its staged counterpart
    _get_clc() {
        _tgt="$1"
        _sub_tgt="$2"
        _sub_rep="$3"
        _res=""
        _old_ifs="$IFS"
        IFS=:
        for _j in $_sscp; do
            if [ "$_j" = "$_tgt" ] || [ "$(basename "$_j")" = "$(basename "$_tgt")" ]; then
                break
            fi
            _val="$_j"
            if [ -n "$_sub_tgt" ] && [ -n "$_sub_rep" ]; then
                if [ "$_j" = "$_sub_tgt" ] || [ "$(basename "$_j")" = "$(basename "$_sub_tgt")" ]; then
                    _val="$_sub_rep"
                fi
            fi
            if [ -n "$_res" ]; then
                _res="$_res:$_val"
            else
                _res="$_val"
            fi
        done
        IFS="$_old_ifs"
        echo "PCL[$_res]"
    }

    _threads="$(nproc 2>/dev/null || echo 4)"

    _services_clc="$(_get_clc "$_target_services")"
    _miui_compile_clc="$(_get_clc "$_target_miui" "$_target_services" "$_staged_services")"
    _miui_stored_clc="$(_get_clc "$_target_miui")"

    _cleanup_tmp() {
        rm -f "$_services_tmp" "${_services_tmp%.dex}.vdex" \
              "$_miui_tmp" "${_miui_tmp%.dex}.vdex" 2>/dev/null
    }

    _services_status=0
    "$_dex2oat" \
        --instruction-set="$_arch" \
        --dex-file="$_staged_services" \
        --dex-location="$_target_services" \
        --oat-file="$_services_tmp" \
        --compiler-filter=speed \
        --class-loader-context="$_services_clc" \
        -j"$_threads" \
        --runtime-arg -Xmx512m \
        --generate-mini-debug-info >/dev/null 2>&1 || _services_status=$?

    _miui_status=0
    if ! "$_dex2oat" \
        --instruction-set="$_arch" \
        --dex-file="$_staged_miui" \
        --dex-location="$_target_miui" \
        --oat-file="$_miui_tmp" \
        --compiler-filter=speed \
        --class-loader-context="$_miui_compile_clc" \
        --stored-class-loader-context="$_miui_stored_clc" \
        -j"$_threads" \
        --runtime-arg -Xmx512m \
        --generate-mini-debug-info >/dev/null 2>&1; then
        # Fallback: if --stored-class-loader-context fails on legacy ART, execute inside isolated mount namespace
        if command -v unshare >/dev/null 2>&1; then
            unshare -m sh -c "(command -v busybox >/dev/null 2>&1 && busybox mount --make-rprivate / 2>/dev/null) && \
                              mount -o bind '$_staged_services' '$_target_services' 2>/dev/null && '$_dex2oat' \
                --instruction-set='$_arch' \
                --dex-file='$_staged_miui' \
                --dex-location='$_target_miui' \
                --oat-file='$_miui_tmp' \
                --compiler-filter=speed \
                --class-loader-context='$_miui_stored_clc' \
                -j'$_threads' \
                --runtime-arg -Xmx512m \
                --generate-mini-debug-info >/dev/null 2>&1" || _miui_status=$?
        else
            _miui_status=1
        fi
    fi

    if [ "$_services_status" -ne 0 ] || [ "$_miui_status" -ne 0 ]; then
        _cleanup_tmp
        return 1
    fi

    # Verify all 4 staged artifacts exist and are non-empty
    if [ ! -s "$_services_tmp" ] || [ ! -s "${_services_tmp%.dex}.vdex" ] || \
       [ ! -s "$_miui_tmp" ] || [ ! -s "${_miui_tmp%.dex}.vdex" ]; then
        _cleanup_tmp
        return 1
    fi

    # Atomically commit: purge stale companion and destination files in the
    # dalvik-cache tree we own. Only /data/dalvik-cache is ours - every artifact
    # written above lands there. The ART-managed tree under
    # /data/misc/apexdata/com.android.art/dalvik-cache belongs to odrefresh and is
    # deliberately left alone: clearing its system-server artifacts without
    # replacing them forces odrefresh to rebuild the boot classpath and the whole
    # system-server classpath on the next boot, stalling it for minutes.
    _clean_dir="/data/dalvik-cache/$_arch"
    if [ -d "$_clean_dir" ]; then
        for _f in "$_clean_dir"/*services*; do
            [ -e "$_f" ] || continue
            case "$_f" in
                *.tmp.*) ;;
                *) rm -f "$_f" 2>/dev/null ;;
            esac
        done
    fi

    # Move staged artifacts to definitive names
    mv -f "$_services_tmp" "$_services_oat" 2>/dev/null
    mv -f "${_services_tmp%.dex}.vdex" "${_services_oat%.dex}.vdex" 2>/dev/null
    mv -f "$_miui_tmp" "$_miui_oat" 2>/dev/null
    mv -f "${_miui_tmp%.dex}.vdex" "${_miui_oat%.dex}.vdex" 2>/dev/null

    chmod 0644 /data/dalvik-cache/"$_arch"/*services* 2>/dev/null || true
    chown root:root /data/dalvik-cache/"$_arch"/*services* 2>/dev/null || true
    chcon u:object_r:dalvikcache_data_file:s0 /data/dalvik-cache/"$_arch"/*services* 2>/dev/null || true
    restorecon -F /data/dalvik-cache/"$_arch"/*services* 2>/dev/null || true

    # ── Downstream SYSTEMSERVERCLASSPATH AOT Compilation ──
    # All jars subsequent to miui-services.jar suffer from rejected factory .odex
    # due to ClassLoaderContext dependency checksum mismatches. We sequentially
    # pre-compile them so 100% of system_server runs in native speed AOT mode.
    if [ -n "$_sscp" ]; then
        _clc_compile=""
        _clc_stored=""
        _downstream_active=0
        _downstream_compiled=0
        _old_ifs="$IFS"
        IFS=:
        for _j in $_sscp; do
            if [ "$_downstream_active" -eq 1 ]; then
                if [ -f "$_j" ]; then
                    _oat_name="$(echo "$_j" | sed 's|^/||; s|/|@|g')@classes.dex"
                    _oat_target="/data/dalvik-cache/$_arch/$_oat_name"
                    _oat_tmp="/data/dalvik-cache/$_arch/$_oat_name.tmp.$$.dex"

                    _down_status=0
                    "$_dex2oat" \
                        --instruction-set="$_arch" \
                        --dex-file="$_j" \
                        --dex-location="$_j" \
                        --oat-file="$_oat_tmp" \
                        --compiler-filter=speed \
                        --class-loader-context="PCL[$_clc_compile]" \
                        --stored-class-loader-context="PCL[$_clc_stored]" \
                        -j"$_threads" \
                        --runtime-arg -Xmx512m \
                        --generate-mini-debug-info >/dev/null 2>&1 || _down_status=$?

                    if [ "$_down_status" -ne 0 ] && command -v unshare >/dev/null 2>&1; then
                        unshare -m sh -c "(command -v busybox >/dev/null 2>&1 && busybox mount --make-rprivate / 2>/dev/null) && \
                                          mount -o bind '$_staged_services' '$_target_services' 2>/dev/null && \
                                          mount -o bind '$_staged_miui' '$_target_miui' 2>/dev/null && \
                                          '$_dex2oat' \
                                              --instruction-set='$_arch' \
                                              --dex-file='$_j' \
                                              --dex-location='$_j' \
                                              --oat-file='$_oat_tmp' \
                                              --compiler-filter=speed \
                                              --class-loader-context='PCL[$_clc_stored]' \
                                              -j'$_threads' \
                                              --runtime-arg -Xmx512m \
                                              --generate-mini-debug-info >/dev/null 2>&1" || true
                    fi

                    if [ -s "$_oat_tmp" ] && [ -s "${_oat_tmp%.dex}.vdex" ]; then
                        mv -f "$_oat_tmp" "$_oat_target" 2>/dev/null
                        mv -f "${_oat_tmp%.dex}.vdex" "${_oat_target%.dex}.vdex" 2>/dev/null
                        chmod 0644 "$_oat_target" "${_oat_target%.dex}.vdex" 2>/dev/null || true
                        chown root:root "$_oat_target" "${_oat_target%.dex}.vdex" 2>/dev/null || true
                        chcon u:object_r:dalvikcache_data_file:s0 "$_oat_target" "${_oat_target%.dex}.vdex" 2>/dev/null || true
                        restorecon -F "$_oat_target" "${_oat_target%.dex}.vdex" 2>/dev/null || true
                        _downstream_compiled=$((_downstream_compiled + 1))
                    else
                        rm -f "$_oat_tmp" "${_oat_tmp%.dex}.vdex" 2>/dev/null
                    fi
                fi
            fi

            # Accumulate CLC chains
            _compile_val="$_j"
            if [ "$_j" = "$_target_services" ] || [ "$(basename "$_j")" = "$(basename "$_target_services")" ]; then
                _compile_val="$_staged_services"
            elif [ "$_j" = "$_target_miui" ] || [ "$(basename "$_j")" = "$(basename "$_target_miui")" ]; then
                _compile_val="$_staged_miui"
            fi

            if [ -z "$_clc_compile" ]; then
                _clc_compile="$_compile_val"
                _clc_stored="$_j"
            else
                _clc_compile="${_clc_compile}:${_compile_val}"
                _clc_stored="${_clc_stored}:${_j}"
            fi

            if [ "$_j" = "$_target_miui" ] || [ "$(basename "$_j")" = "$(basename "$_target_miui")" ]; then
                _downstream_active=1
            fi
        done
        IFS="$_old_ifs"
        # ── Standalone System Server Jars AOT Compilation ──
        # Services loaded dynamically as children of system_server (e.g. wifi, connectivity, bluetooth)
        # require ClassLoaderContext format PCL[];PCL[SYSTEMSERVERCLASSPATH].
        _standalone="$STANDALONE_SYSTEMSERVER_JARS"
        if [ -z "$_standalone" ]; then
            _sspid="$(pidof system_server)"
            [ -n "$_sspid" ] && _standalone="$(cat /proc/$_sspid/environ 2>/dev/null | tr '\0' '\n' | grep '^STANDALONE_SYSTEMSERVER_JARS=' | cut -d= -f2-)"
            [ -z "$_standalone" ] && _standalone="$(cat /proc/1/environ 2>/dev/null | tr '\0' '\n' | grep '^STANDALONE_SYSTEMSERVER_JARS=' | cut -d= -f2-)"
            if [ -z "$_standalone" ] && [ -f "/data/system/environ/classpath" ]; then
                _standalone="$(grep -m1 '^export STANDALONE_SYSTEMSERVER_JARS ' /data/system/environ/classpath 2>/dev/null | awk '{print $3}')"
            fi
        fi

        if [ -n "$_standalone" ]; then
            IFS=:
            for _sjar in $_standalone; do
                if [ -f "$_sjar" ]; then
                    _soat_name="$(echo "$_sjar" | sed 's|^/||; s|/|@|g')@classes.dex"
                    _soat_target="/data/dalvik-cache/$_arch/$_soat_name"
                    _soat_tmp="/data/dalvik-cache/$_arch/$_soat_name.tmp.$$.dex"

                    _s_status=0
                    "$_dex2oat" \
                        --instruction-set="$_arch" \
                        --dex-file="$_sjar" \
                        --dex-location="$_sjar" \
                        --oat-file="$_soat_tmp" \
                        --compiler-filter=speed \
                        --class-loader-context="PCL[];PCL[$_clc_compile]" \
                        --stored-class-loader-context="PCL[];PCL[$_clc_stored]" \
                        -j"$_threads" \
                        --runtime-arg -Xmx512m \
                        --generate-mini-debug-info >/dev/null 2>&1 || _s_status=$?

                    if [ "$_s_status" -ne 0 ] && command -v unshare >/dev/null 2>&1; then
                        unshare -m sh -c "(command -v busybox >/dev/null 2>&1 && busybox mount --make-rprivate / 2>/dev/null) && \
                                          mount -o bind '$_staged_services' '$_target_services' 2>/dev/null && \
                                          mount -o bind '$_staged_miui' '$_target_miui' 2>/dev/null && \
                                          '$_dex2oat' \
                                              --instruction-set='$_arch' \
                                              --dex-file='$_sjar' \
                                              --dex-location='$_sjar' \
                                              --oat-file='$_soat_tmp' \
                                              --compiler-filter=speed \
                                              --class-loader-context='PCL[];PCL[$_clc_stored]' \
                                              -j'$_threads' \
                                              --runtime-arg -Xmx512m \
                                              --generate-mini-debug-info >/dev/null 2>&1" || true
                    fi

                    if [ -s "$_soat_tmp" ] && [ -s "${_soat_tmp%.dex}.vdex" ]; then
                        mv -f "$_soat_tmp" "$_soat_target" 2>/dev/null
                        mv -f "${_soat_tmp%.dex}.vdex" "${_soat_target%.dex}.vdex" 2>/dev/null
                        chmod 0644 "$_soat_target" "${_soat_target%.dex}.vdex" 2>/dev/null || true
                        chown root:root "$_soat_target" "${_soat_target%.dex}.vdex" 2>/dev/null || true
                        chcon u:object_r:dalvikcache_data_file:s0 "$_soat_target" "${_soat_target%.dex}.vdex" 2>/dev/null || true
                        restorecon -F "$_soat_target" "${_soat_target%.dex}.vdex" 2>/dev/null || true
                        _downstream_compiled=$((_downstream_compiled + 1))
                    else
                        rm -f "$_soat_tmp" "${_soat_tmp%.dex}.vdex" 2>/dev/null
                    fi
                fi
            done
            IFS="$_old_ifs"
        fi
        IFS="$_old_ifs"

        [ "$_downstream_compiled" -gt 0 ] && export COMPILED_DOWNSTREAM_COUNT="$_downstream_compiled"
    fi

    return 0
}

# Executes the patcher engine using dalvikvm or app_process fallback with safe CLASSPATH.
# Usage: execute_patcher_engine <patcher_jar> <stage_dir> [patcher_args...]
execute_patcher_engine() {
    _patcher_jar="$1"
    _stage_dir="$2"
    shift 2

    [ -f "$_patcher_jar" ] || return 1
    export ANDROID_DATA="$_stage_dir"

    # 1. Prefer dalvikvm
    if [ -x "/apex/com.android.art/bin/dalvikvm" ]; then
        /apex/com.android.art/bin/dalvikvm -Xmx512m -cp "$_patcher_jar" com.hyperos.fcm.patcher.Main "$@"
        return $?
    elif [ -x "/system/bin/dalvikvm" ]; then
        /system/bin/dalvikvm -Xmx512m -cp "$_patcher_jar" com.hyperos.fcm.patcher.Main "$@"
        return $?
    fi

    # 2. Fallback to app_process with guaranteed CLASSPATH export
    # Note: app_process MUST have CLASSPATH exported in environment to prevent ClassNotFoundException -> SIGABRT
    export CLASSPATH="$_patcher_jar"
    if [ -x "/system/bin/app_process64" ]; then
        /system/bin/app_process64 /system/bin com.hyperos.fcm.patcher.Main "$@"
        return $?
    elif [ -x "/system/bin/app_process" ]; then
        /system/bin/app_process /system/bin com.hyperos.fcm.patcher.Main "$@"
        return $?
    fi

    echo "ERROR: Neither dalvikvm nor app_process runtime found." >&2
    return 1
}
