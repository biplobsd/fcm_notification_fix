#!/system/bin/sh
# ==============================================================================
# HyperOS FCM Notification Fix - Complete Stock Restoration & Uninstall Script
# ==============================================================================
# Executed automatically by KernelSU / APatch / Magisk when the module is removed.
# Removes module files and mounts, then stages framework-service restoration for
# the first completed boot after removal.
# ==============================================================================

MODDIR="${0%/*}"
if [ -z "$MODDIR" ] || [ "$MODDIR" = "." ] || [ "$MODDIR" = "$0" ] || [ ! -d "$MODDIR" ]; then
    if [ -n "$MODPATH" ] && [ -d "$MODPATH" ]; then
        MODDIR="$MODPATH"
    elif [ -d "/data/adb/modules/fcm_notification_fix" ]; then
        MODDIR="/data/adb/modules/fcm_notification_fix"
    elif [ -d "/data/adb/modules_update/fcm_notification_fix" ]; then
        MODDIR="/data/adb/modules_update/fcm_notification_fix"
    fi
fi

# ==============================================================================
# 1. Unmount Active In-Memory Stealth Framework Mounts (If Live & Owned)
# ==============================================================================
# Verify against /proc/self/mountinfo and bytecode signature so we only detach
# mounts created by this module (e.g. source fcm_stage or containing FcmWakeFilter),
# strictly preserving any mounts owned by other modules.
is_module_mount() {
    _tgt="$1"
    [ -f /proc/self/mountinfo ] || return 1

    # Extract exact fstype, mount source, and root for the top mount on target
    _mount_info=$(awk -v tgt="$_tgt" '
        $5 == tgt {
            r = $4;
            for (i = 6; i <= NF; i++) {
                if ($i == "-") {
                    fs = $(i+1);
                    src = $(i+2);
                    break;
                }
            }
        }
        END {
            if (fs != "") print fs, src, r;
        }
    ' /proc/self/mountinfo 2>/dev/null)

    [ -z "$_mount_info" ] && return 1

    _fs="${_mount_info%% *}"
    _rest="${_mount_info#* }"
    _src="${_rest%% *}"
    _root="${_rest#* }"

    # Check 1: Exact mount source created by our stealth staging (fcm_stage)
    if [ "$_src" = "fcm_stage" ]; then
        return 0
    fi

    # Check 2: Direct bind mount originating from this module directory
    case "$_src" in
        "$MODDIR"/*|/data/adb/modules/fcm_notification_fix/*|/data/adb/modules_update/fcm_notification_fix/*)
            return 0
            ;;
    esac
    case "$_root" in
        /adb/modules/fcm_notification_fix/*|/adb/modules_update/fcm_notification_fix/*)
            return 0
            ;;
    esac

    # Check 3: If source is generic tmpfs from an older session, verify exact root jar
    # AND verify that the live file contains our unique FcmWakeFilter bytecode signature
    if [ "$_fs" = "tmpfs" ] && { [ "$_root" = "/services.jar" ] || [ "$_root" = "/miui-services.jar" ]; }; then
        if [ -f "$_tgt" ] && grep -aqm1 FcmWakeFilter "$_tgt" 2>/dev/null; then
            return 0
        fi
    fi

    # Ownership cannot be proven; leave mount intact
    return 1
}

for _target in \
    /system/framework/services.jar \
    /system_ext/framework/miui-services.jar \
    /system/system_ext/framework/miui-services.jar \
    /system/framework/miui-services.jar \
    /product/framework/miui-services.jar \
    /system/product/framework/miui-services.jar; do
    if is_module_mount "$_target"; then
        umount -l "$_target" 2>/dev/null || umount "$_target" 2>/dev/null || true
    fi
done

# Clean up any transient staging mounts in /dev
for _stg in /dev/.fcm_stage_*; do
    if [ -d "$_stg" ]; then
        umount -l "$_stg" 2>/dev/null || true
        rm -rf "$_stg" 2>/dev/null || true
    fi
done

# ==============================================================================
# 2. Purge Compiled dex2oat / AOT Dalvik-Cache Artifacts
# ==============================================================================
# Dropping the pre-compiled AOT cache ensures that system_server on the next boot
# compiles fresh stock framework bytecode without mismatched method offsets or hooks.
rm -rf /data/dalvik-cache/*/*services* 2>/dev/null
rm -rf /data/dalvik-cache/*/*miui-services* 2>/dev/null
rm -rf /data/dalvik-cache/*/*services.jar@classes.* 2>/dev/null
rm -rf /data/dalvik-cache/*/*miui-services.jar@classes.* 2>/dev/null
find /data/dalvik-cache -name "*services*" -exec rm -rf {} + 2>/dev/null || true

# ==============================================================================
# 3. Remove FCM Wake Filter Configuration and Staging Artifacts
# ==============================================================================
rm -f /data/system/fcm_wake.conf 2>/dev/null
rm -f /data/system/fcm_wake.conf.tmp.* 2>/dev/null
rm -rf /data/local/tmp/fcm_* 2>/dev/null
rm -rf /data/local/tmp/fcm_patch_stage_* 2>/dev/null
rm -rf /data/local/tmp/fcm_repatch_* 2>/dev/null

# ── Restore PowerKeeper GmsObserver to stock behavior ──
pk_ctrl="true"
if [ -f "$MODDIR/stock_settings.conf" ]; then
    saved_pk=$(awk -F= '$1 == "powerkeeper_gms_control" { print $2; exit }' "$MODDIR/stock_settings.conf" 2>/dev/null)
    [ -n "$saved_pk" ] && pk_ctrl="$saved_pk"
fi
content call --uri content://com.miui.powerkeeper.configure/SimpleSettings/misc \
  --method PUT_misc --arg gms_control --extra value:s:"$pk_ctrl" 2>/dev/null || true

# ==============================================================================
# 4. Stage Framework-State Restoration for the Next Completed Boot
# ==============================================================================
RESTORE_DIR="/data/adb/service.d"
RESTORE_SCRIPT="$RESTORE_DIR/fcm_notification_fix_restore.sh"
RESTORE_CONF="/data/adb/fcm_notification_fix_restore.conf"

mkdir -p "$RESTORE_DIR" 2>/dev/null || true
if [ -f "$MODDIR/stock_settings.conf" ]; then
    cp -f "$MODDIR/stock_settings.conf" "$RESTORE_CONF" 2>/dev/null || true
    chmod 0600 "$RESTORE_CONF" 2>/dev/null || true
else
    rm -f "$RESTORE_CONF" 2>/dev/null || true
fi
if [ -f "$MODDIR/restore-on-boot.sh" ]; then
    cp -f "$MODDIR/restore-on-boot.sh" "$RESTORE_SCRIPT.tmp.$$" 2>/dev/null && \
        chmod 0755 "$RESTORE_SCRIPT.tmp.$$" 2>/dev/null && \
        mv -f "$RESTORE_SCRIPT.tmp.$$" "$RESTORE_SCRIPT" 2>/dev/null
    rm -f "$RESTORE_SCRIPT.tmp.$$" 2>/dev/null || true
fi

# ==============================================================================
# 5. Clean Up Module Runtime Flags and Transient Files
# ==============================================================================
rm -f "$MODDIR/repatch_pending" "$MODDIR/repatch_running" "$MODDIR/repatch_failed" "$MODDIR/repatch_reboot" "$MODDIR/wipe_cache_once" "$MODDIR/.defaults_applied" "$MODDIR/skip_mount" "$MODDIR/stock_settings.conf" "$MODDIR"/stock_settings.conf.tmp.* 2>/dev/null || true

exit 0
