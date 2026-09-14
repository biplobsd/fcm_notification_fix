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

# ==============================================================================
# Per-app FullScreenIntent AppOps
# ==============================================================================
# The ops granted to a package on the FSI list, by name:
#   USE_FULL_SCREEN_INTENT             AOSP; Settings > Apps > Special app access
#                                      > Full screen notifications
#   10020 OP_SHOW_WHEN_LOCKED          MIUI; App info > Other permissions
#   10021 OP_BACKGROUND_START_ACTIVITY MIUI, same screen. This is the op that
#                                      NotificationManagerServiceImpl.checkFullScreenIntent
#                                      passes to noteOpNoThrow before it nulls
#                                      Notification.fullScreenIntent.
# The numeric ops are declared in com.miui.internal.os.MiuiHooks inside
# miui-framework.jar (MIUI_OP_START 10000 .. MIUI_OP_END 10036).
#
# 10008 OP_AUTO_START is deliberately absent: checkFullScreenIntent never reads
# it, so granting it bought nothing for this feature while silently switching on
# an unrelated permission that users keep off on purpose.
FSI_APPOPS="USE_FULL_SCREEN_INTENT 10020 10021"

# Resolve the current mode of one AppOps operation for one package. Prints one of
# allow|ignore|deny|foreground|default, or "unknown" when the op cannot be read -
# callers treat "unknown" as "restore to default" rather than guessing a mode.
# Classify one "<something>: <mode>" line from `cmd appops get` output. Prints
# the mode, or nothing when the line carries none - an empty result is what the
# caller uses to fall through to the next source.
appop_line_mode() {
    case "$1" in
        *": allow"*)      echo "allow" ;;
        *": ignore"*)     echo "ignore" ;;
        *": deny"*)       echo "deny" ;;
        *": foreground"*) echo "foreground" ;;
        *": default"*)    echo "default" ;;
        *)                echo "" ;;
    esac
}

read_appop_mode() {
    _ra_pkg="$1"
    _ra_op="$2"
    _ra_mode="unknown"
    if [ -z "$_ra_pkg" ] || [ -z "$_ra_op" ]; then
        echo "$_ra_mode"
        return 1
    fi

    _ra_out=$(cmd appops get "$_ra_pkg" "$_ra_op" 2>/dev/null)
    _ra_status=$?
    if [ "$_ra_status" -eq 0 ] && [ -n "$_ra_out" ]; then
        # Four sources, in falling order of precedence. Each is a line of the
        # form "<something>: <mode>", so appop_line_mode classifies all of them.
        #
        #   1. the package record  - what `cmd appops set <pkg> ...` writes, and
        #      therefore what a restore puts back;
        #   2. the uid record, printed as "Uid mode: <OP>: <mode>" - a different
        #      record, but on some packages it is the ONLY line the framework
        #      prints, and reading those as "unknown" is how a restore ends up
        #      writing "default" over a mode the user had set. Measured on
        #      OS3.0.307.0.WNVCNXM: 6 of 154 third-party packages print only this
        #      line for USE_FULL_SCREEN_INTENT - com.vkontakte.android among
        #      them. A restore then writes the uid value as the package mode,
        #      which is not the same record, but preserves the effective answer
        #      under either precedence rule and beats guessing;
        #   3. the op's stated default mode, when the framework prints one;
        #   4. "No operations." - nothing recorded at all, so it sits at default.
        #
        # The name in front of the first colon is compared exactly rather than by
        # regex: a MIUI op is printed wrapped, as "MIUIOP(10021): allow", so
        # anchoring on the bare number never matches.
        _ra_line=$(printf '%s\n' "$_ra_out" | awk -v op="$_ra_op" '
            {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                if (index(line, "Uid mode:") == 1) next
                p = index(line, ":")
                if (p == 0) next
                name = substr(line, 1, p - 1)
                sub(/[[:space:]]+$/, "", name)
                if (name == op || name == "MIUIOP(" op ")") { print line; exit }
            }
        ')
        if [ -n "$_ra_line" ]; then
            # A package record exists and is authoritative. If its mode is one
            # this reader cannot classify, the answer is "unknown" - falling
            # through to the uid record here would restore a value the package
            # never had.
            _ra_mode=$(appop_line_mode "$_ra_line")
        else
            _ra_uid=$(printf '%s\n' "$_ra_out" | awk -v op="$_ra_op" '
                {
                    line = $0
                    sub(/^[[:space:]]+/, "", line)
                    if (index(line, "Uid mode:") != 1) next
                    if (index(line, op) == 0) next
                    print line; exit
                }
            ')
            _ra_mode=$(appop_line_mode "$_ra_uid")

            if [ -z "$_ra_mode" ]; then
                _ra_default=$(printf '%s\n' "$_ra_out" | awk '
                    /^[[:space:]]*Default mode[[:space:]]*:/ { print; exit }
                ')
                _ra_mode=$(appop_line_mode "$_ra_default")
            fi

            if [ -z "$_ra_mode" ]; then
                case "$_ra_out" in
                    *"No operations."*) _ra_mode="default" ;;
                esac
            fi
        fi

        [ -z "$_ra_mode" ] && _ra_mode="unknown"
    fi
    echo "$_ra_mode"
}

# Read one recorded FSI mode back out of a backup file, normalising anything
# missing or unrecognised to "default" - never to "ignore", which is a real mode
# meaning "denied" and is not where an untouched op sits.
saved_fsi_appop_mode() {
    _sf_conf="$1"
    _sf_pkg="$2"
    _sf_op="$3"
    _sf_mode=""
    if [ -n "$_sf_conf" ] && [ -f "$_sf_conf" ]; then
        _sf_mode=$(awk -F= -v key="fsi_appop:${_sf_pkg}:${_sf_op}" '
            $1 == key { print substr($0, index($0, "=") + 1); exit }
        ' "$_sf_conf" 2>/dev/null)
    fi
    case "$_sf_mode" in
        allow|ignore|deny|foreground|default) echo "$_sf_mode" ;;
        *) echo "default" ;;
    esac
}

# Record the pre-grant mode of every FSI op for a package, once. An existing
# record is never overwritten: after the first grant the live mode is the
# module's own "allow", so re-recording would erase the user's real setting.
backup_fsi_appops() {
    _bf_conf="$1"
    _bf_pkg="$2"
    if [ -z "$_bf_conf" ] || [ -z "$_bf_pkg" ]; then
        return 1
    fi
    # Braces around the redirect: a failing `>` is reported by the shell before
    # a trailing 2>/dev/null on the command itself can suppress it.
    [ -f "$_bf_conf" ] || { : > "$_bf_conf"; } 2>/dev/null || return 1

    for _bf_op in $FSI_APPOPS; do
        # Exact key comparison, not a regex: a package name is full of dots.
        awk -F= -v key="fsi_appop:${_bf_pkg}:${_bf_op}" '
            $1 == key { found = 1; exit } END { exit found ? 0 : 1 }
        ' "$_bf_conf" 2>/dev/null && continue
        _bf_mode=$(read_appop_mode "$_bf_pkg" "$_bf_op")
        echo "fsi_appop:${_bf_pkg}:${_bf_op}=${_bf_mode}" >> "$_bf_conf" 2>/dev/null || return 1
    done
    chmod 0600 "$_bf_conf" 2>/dev/null || true
    return 0
}

# Drop a package's records once its previous state has been put back, so that a
# later re-add captures the restored state instead of the module's own grant.
forget_fsi_appops() {
    _ff_conf="$1"
    _ff_pkg="$2"
    if [ -z "$_ff_conf" ] || [ -z "$_ff_pkg" ]; then
        return 1
    fi
    [ -f "$_ff_conf" ] || return 0

    _ff_tmp="${_ff_conf}.tmp.$$"
    # Drop this package's records by exact key prefix. grep would treat the dots
    # in a package name as wildcards and could take a neighbour's records with it.
    if awk -F= -v pfx="fsi_appop:${_ff_pkg}:" '
        index($1, pfx) == 1 { next } { print }
    ' "$_ff_conf" > "$_ff_tmp" 2>/dev/null; then
        chmod 0600 "$_ff_tmp" 2>/dev/null || true
        mv -f "$_ff_tmp" "$_ff_conf" 2>/dev/null || rm -f "$_ff_tmp" 2>/dev/null
    else
        rm -f "$_ff_tmp" 2>/dev/null
    fi
    return 0
}

# Grant the FSI ops, recording what they were beforehand.
#
# The grant is refused outright when the record could not be written. Granting
# with no record means a later removal has nothing to give back and falls to
# "default", which silently loses an ignore, deny or foreground the user had
# set - the very failure this whole change exists to stop. Refusing costs
# nothing the feature needs: vector 18's bypass makes checkFullScreenIntent
# return before it ever consults 10021, so a listed package keeps its
# full-screen call screen whether or not these ops were granted.
apply_fsi_appops() {
    _af_conf="$1"
    _af_pkg="$2"
    [ -z "$_af_pkg" ] && return 1

    backup_fsi_appops "$_af_conf" "$_af_pkg" || return 1
    for _af_op in $FSI_APPOPS; do
        cmd appops set "$_af_pkg" "$_af_op" allow 2>/dev/null || true
    done
    return 0
}

# Put every FSI op back to the mode recorded before the module granted it.
# Pass "keep" as the third argument to leave the records in place: uninstall
# needs them to survive into the staged restore conf, so that the boot-time pass
# can repeat the restoration for anything that could not be set while the module
# was being removed.
restore_fsi_appops() {
    _rf_conf="$1"
    _rf_pkg="$2"
    _rf_keep="${3:-}"
    [ -z "$_rf_pkg" ] && return 1

    for _rf_op in $FSI_APPOPS; do
        _rf_mode=$(saved_fsi_appop_mode "$_rf_conf" "$_rf_pkg" "$_rf_op")
        cmd appops set "$_rf_pkg" "$_rf_op" "$_rf_mode" 2>/dev/null || true
    done
    [ "$_rf_keep" = "keep" ] || forget_fsi_appops "$_rf_conf" "$_rf_pkg"
    return 0
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
# Locates the dex2oat binary, or prints nothing when the device has none.
resolve_dex2oat() {
    if command -v dex2oat64 >/dev/null 2>&1; then
        command -v dex2oat64
    elif command -v dex2oat >/dev/null 2>&1; then
        command -v dex2oat
    elif [ -f "/apex/com.android.art/bin/dex2oat64" ]; then
        echo "/apex/com.android.art/bin/dex2oat64"
    elif [ -f "/system/bin/dex2oat64" ]; then
        echo "/system/bin/dex2oat64"
    elif [ -f "/apex/com.android.art/bin/dex2oat" ]; then
        echo "/apex/com.android.art/bin/dex2oat"
    elif [ -f "/apex/com.android.runtime/bin/dex2oat" ]; then
        echo "/apex/com.android.runtime/bin/dex2oat"
    elif [ -f "/system/bin/dex2oat" ]; then
        echo "/system/bin/dex2oat"
    fi
}

# Instruction set name dex2oat expects for this device.
resolve_isa() {
    _isa="$(getprop ro.bionic.arch)"
    if [ -z "$_isa" ]; then
        case "$(getprop ro.product.cpu.abi)" in
            arm64*|aarch64*) _isa="arm64" ;;
            armeabi*|armv7*) _isa="arm" ;;
            x86_64*)         _isa="x86_64" ;;
            x86*)            _isa="x86" ;;
            *)               _isa="arm64" ;;
        esac
    fi
    echo "$_isa"
}

# Runs ART's own verifier over the patched jars before anything can mount them.
#
# A bytecode injection that resolves a register or a type wrongly still produces a
# structurally valid DEX: the register index is in range and every reference links, so
# the patcher's own LinkageVerifier passes it. It fails only when ART verifies the class
# while starting system_server - at which point the device never finishes booting and
# there is no comfortable way to read the error off it. dex2oat reaches the same verdict
# at install time with --compiler-filter=verify --abort-on-hard-verifier-error, where the
# answer is still useful: the install can simply refuse.
#
# Unresolved references to classes outside the jar are soft failures and do not abort,
# so no class-loader context is needed here; type confusion of the kind a mis-resolved
# parameter register produces is a hard failure, which is exactly what we want to catch.
#
# Returns 0 when both jars verify, 2 when the device has no dex2oat at all - nothing can
# be asserted there, and the install proceeds as it did before this check existed - and 1
# on failure, with VERIFY_FAILED_JAR and VERIFY_FAILED_REASON set.
#
# Anything that goes wrong once dex2oat *is* available fails closed. A gate that reports a
# pass it never actually performed is worse than no gate, because the install then claims
# the jars were verified when they were not.
verify_patched_jars() {
    VERIFY_FAILED_JAR=""
    VERIFY_FAILED_REASON=""

    _vp_dex2oat="$(resolve_dex2oat)"
    [ -z "$_vp_dex2oat" ] && return 2
    _vp_isa="$(resolve_isa)"

    _vp_tmp="${TMPDIR:-/data/local/tmp}/fcm_verify.$$"
    if ! mkdir -p "$_vp_tmp" 2>/dev/null; then
        VERIFY_FAILED_JAR="$_vp_tmp"
        VERIFY_FAILED_REASON="cannot create the verifier workspace, so the jars were left unverified"
        return 1
    fi
    _vp_status=0

    for _vp_pair in "$1|$2" "$3|$4"; do
        _vp_jar="${_vp_pair%%|*}"
        _vp_dst="${_vp_pair#*|}"
        [ -f "$_vp_jar" ] || continue

        if ! "$_vp_dex2oat" \
            --instruction-set="$_vp_isa" \
            --dex-file="$_vp_jar" \
            --dex-location="$_vp_dst" \
            --oat-file="$_vp_tmp/verify.oat" \
            --compiler-filter=verify \
            --abort-on-hard-verifier-error \
            >"$_vp_tmp/log" 2>&1; then
            VERIFY_FAILED_JAR="$_vp_dst"
            VERIFY_FAILED_REASON="$(grep -m1 -iE 'verif|reject|cannot|failure' "$_vp_tmp/log" 2>/dev/null)"
            [ -z "$VERIFY_FAILED_REASON" ] && VERIFY_FAILED_REASON="$(tail -n 1 "$_vp_tmp/log" 2>/dev/null)"
            _vp_status=1
            break
        fi
    done

    rm -rf "$_vp_tmp" 2>/dev/null
    return "$_vp_status"
}

compile_aot_cache() {
    _staged_services="$1"
    _target_services="$2"
    _staged_miui="$3"
    _target_miui="$4"

    _dex2oat="$(resolve_dex2oat)"
    [ -z "$_dex2oat" ] && return 1

    _arch="$(resolve_isa)"
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

    # Locate ART boot image.
    # Note: ART dex2oat --boot-image requires an image location without ISA (e.g. /system/framework/boot.art).
    # ART's ImageSpace::ExpandLocationToFilename automatically appends /<isa>/boot.art.
    # Passing the arch path directly (/system/framework/arm64/boot.art) would break ART expansion.
    _boot_image=""
    for _base in \
        "/data/misc/apexdata/com.android.art/dalvik-cache" \
        "/system/framework" \
        "/apex/com.android.art/javalib"; do
        if [ -f "$_base/$_arch/boot.art" ]; then
            _boot_image="$_base/boot.art"
            break
        fi
    done

    _zyg_pid="$(pidof zygote64 2>/dev/null || pidof zygote 2>/dev/null || echo 1)"
    _bcp="$(cat /proc/$_zyg_pid/environ 2>/dev/null | tr '\0' '\n' | grep '^BOOTCLASSPATH=' | cut -d= -f2-)"
    [ -z "$_bcp" ] && _bcp="$BOOTCLASSPATH"

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
        ${_boot_image:+--boot-image="$_boot_image"} \
        ${_bcp:+--runtime-arg -Xbootclasspath:"$_bcp"} \
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
        ${_boot_image:+--boot-image="$_boot_image"} \
        ${_bcp:+--runtime-arg -Xbootclasspath:"$_bcp"} \
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
                ${_boot_image:+--boot-image=\"$_boot_image\"} \
                ${_bcp:+--runtime-arg -Xbootclasspath:\"$_bcp\"} \
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
                        ${_boot_image:+--boot-image="$_boot_image"} \
                        ${_bcp:+--runtime-arg -Xbootclasspath:"$_bcp"} \
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
                                              ${_boot_image:+--boot-image=\"$_boot_image\"} \
                                              ${_bcp:+--runtime-arg -Xbootclasspath:\"$_bcp\"} \
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
                        ${_boot_image:+--boot-image="$_boot_image"} \
                        ${_bcp:+--runtime-arg -Xbootclasspath:"$_bcp"} \
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
                                              ${_boot_image:+--boot-image=\"$_boot_image\"} \
                                              ${_bcp:+--runtime-arg -Xbootclasspath:\"$_bcp\"} \
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
