#!/system/bin/sh
# ==============================================================================
# HyperOS FCM Notification Fix - Complete Stock Restoration & Uninstall Script
# ==============================================================================
# Executed automatically by KernelSU / APatch / Magisk when the module is removed.
# Restores all framework caches, configuration files, GMS power policies,
# SystemUI SELinux contexts, and lockscreen/AOD settings to pristine stock state.
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

STOCK_CONF="$MODDIR/stock_settings.conf"

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

# ==============================================================================
# 4. Restore SystemUI SharedPreferences SELinux Context
# ==============================================================================
XML="/data/user_de/0/com.android.systemui/shared_prefs/app_notification.xml"
if [ -f "$XML" ]; then
    restorecon -F "$XML" 2>/dev/null || true
fi
if [ -d "/data/user_de/0/com.android.systemui/shared_prefs" ]; then
    restorecon -R "/data/user_de/0/com.android.systemui/shared_prefs" 2>/dev/null || true
fi

# ==============================================================================
# 5. Restore Google Play Services (GMS) Power Management & Freezer State
# ==============================================================================
GMS_UID=$(pm list packages -U com.google.android.gms 2>/dev/null | grep -o 'uid:[0-9]*' | cut -d: -f2 | head -n1)

# Check if GMS was already user-whitelisted before the module was installed
GMS_WAS_WHITELISTED=0
if [ -f "$STOCK_CONF" ]; then
    if grep -q "^gms_user_whitelisted=1" "$STOCK_CONF" 2>/dev/null; then
        GMS_WAS_WHITELISTED=1
    fi
fi

# Remove GMS from Doze user whitelist only if it was NOT originally whitelisted
if [ "$GMS_WAS_WHITELISTED" -eq 0 ]; then
    cmd deviceidle whitelist -com.google.android.gms 2>/dev/null || true
fi

# Restore saved GMS AppOps permissions surgically without resetting entire package ops
if [ -f "$STOCK_CONF" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            gms_appop:*)
                op_mode_entry="${line#gms_appop:}"
                op="${op_mode_entry%%=*}"
                mode="${op_mode_entry#*=}"
                if [ -n "$op" ] && [ -n "$mode" ] && [ "$mode" != "unknown" ]; then
                    case "$mode" in
                        allow|ignore|deny|foreground|default)
                            cmd appops set com.google.android.gms "$op" "$mode" 2>/dev/null || true
                            ;;
                    esac
                fi
                ;;
        esac
    done < "$STOCK_CONF"
else
    # Fallback if stock_settings.conf was missing: revert only the 4 touched AppOps to default
    cmd appops set com.google.android.gms RUN_IN_BACKGROUND default 2>/dev/null || true
    cmd appops set com.google.android.gms RUN_ANY_IN_BACKGROUND default 2>/dev/null || true
    cmd appops set com.google.android.gms 10008 default 2>/dev/null || true
    cmd appops set com.google.android.gms WAKE_LOCK default 2>/dev/null || true
fi

# Expire active thaw TTL in greezer and re-enable freezer monitoring
if [ -n "$GMS_UID" ]; then
    cmd greezer thuid "$GMS_UID" 0 2>/dev/null || true
    cmd greezer monitor "$GMS_UID" 2>/dev/null || true
fi

# ==============================================================================
# 6. Restore System & Secure Settings to Stock State
# ==============================================================================
if [ -f "$STOCK_CONF" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            secure:*|system:*|global:*)
                ns_k="${line%%=*}"
                val="${line#*=}"
                ns="${ns_k%%:*}"
                k="${ns_k#*:}"
                if [ "$val" = "null" ] || [ -z "$val" ]; then
                    settings delete "$ns" "$k" 2>/dev/null || true
                else
                    settings put "$ns" "$k" "$val" 2>/dev/null || true
                fi
                ;;
        esac
    done < "$STOCK_CONF"
else
    # Fallback if stock_settings.conf was missing: delete overrides to revert to framework defaults
    settings delete secure notification_animation_style 2>/dev/null || true
    settings delete system wake_up_for_notification 2>/dev/null || true
    settings delete secure lock_screen_wake_up_for_notification 2>/dev/null || true
    settings delete system wakeup_for_keyguard_notification 2>/dev/null || true
    settings delete secure full_screen_aod_notification 2>/dev/null || true
    settings delete secure lock_screen_show_notifications 2>/dev/null || true
    settings delete secure lock_screen_allow_private_notifications 2>/dev/null || true
    settings delete system pref_key_enable_notification_body 2>/dev/null || true
    settings delete secure lock_screen_show_only_unseen_notifications 2>/dev/null || true
fi

# ==============================================================================
# 7. Cancel Any Persistent Module Notifications
# ==============================================================================
cmd notification cancel fcm_repatch 2>/dev/null || true
cmd notification cancel fcm_repatch 0 2>/dev/null || true

# ==============================================================================
# 8. Clean Up Module Runtime Flags and Transient Files
# ==============================================================================
rm -f "$MODDIR/repatch_pending" "$MODDIR/repatch_running" "$MODDIR/repatch_failed" "$MODDIR/repatch_reboot" "$MODDIR/wipe_cache_once" "$MODDIR/.defaults_applied" "$MODDIR/skip_mount" "$MODDIR/stock_settings.conf" "$MODDIR"/stock_settings.conf.tmp.* 2>/dev/null || true

exit 0
