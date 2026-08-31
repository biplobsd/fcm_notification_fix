#!/system/bin/sh
# One-shot stock-state restoration staged by uninstall.sh.

RESTORE_CONF="/data/adb/fcm_notification_fix_restore.conf"
RESTORE_SCRIPT="/data/adb/service.d/fcm_notification_fix_restore.sh"
MODULE_DIR="/data/adb/modules/fcm_notification_fix"

cleanup_restore() {
    rm -f "$RESTORE_CONF" "$RESTORE_SCRIPT" 2>/dev/null || true
}

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

# A reinstall before reboot supersedes the pending uninstall restoration.
if [ -d "$MODULE_DIR" ] && [ ! -f "$MODULE_DIR/remove" ]; then
    cleanup_restore
    exit 0
fi

XML="/data/user_de/0/com.android.systemui/shared_prefs/app_notification.xml"
if [ -f "$XML" ]; then
    restorecon -F "$XML" 2>/dev/null || true
fi
if [ -d "/data/user_de/0/com.android.systemui/shared_prefs" ]; then
    restorecon -R "/data/user_de/0/com.android.systemui/shared_prefs" 2>/dev/null || true
fi

GMS_APPOPS="
RUN_IN_BACKGROUND
RUN_ANY_IN_BACKGROUND
10008
WAKE_LOCK
"

GMS_UID=$(pm list packages -U com.google.android.gms 2>/dev/null | grep -o 'uid:[0-9]*' | cut -d: -f2 | head -n1)

# Restore the Doze whitelist only when the package was not user-whitelisted
# before installation. A missing backup retains the previous default fallback.
GMS_WAS_WHITELISTED=0
if [ -f "$RESTORE_CONF" ] && grep -q "^gms_user_whitelisted=1" "$RESTORE_CONF" 2>/dev/null; then
    GMS_WAS_WHITELISTED=1
fi
if [ "$GMS_WAS_WHITELISTED" -eq 0 ]; then
    cmd deviceidle whitelist -com.google.android.gms 2>/dev/null || true
fi

# Restore all AppOps touched by the module. Unknown, invalid, or unavailable
# records are normalized to the operation's default rather than left allowed.
for op in $GMS_APPOPS; do
    [ -z "$op" ] && continue
    mode="default"
    if [ -f "$RESTORE_CONF" ]; then
        saved_mode=$(awk -F= -v key="gms_appop:$op" '
            $1 == key { print substr($0, index($0, "=") + 1); exit }
        ' "$RESTORE_CONF" 2>/dev/null)
        case "$saved_mode" in
            allow|ignore|deny|foreground|default) mode="$saved_mode" ;;
            unknown|"") mode="default" ;;
        esac
    fi
    cmd appops set com.google.android.gms "$op" "$mode" 2>/dev/null || true
done

# Expire the module's thaw lease and return GMS to freezer monitoring.
if [ -n "$GMS_UID" ]; then
    cmd greezer thuid "$GMS_UID" 0 2>/dev/null || true
    cmd greezer monitor "$GMS_UID" 2>/dev/null || true
fi

if [ -f "$RESTORE_CONF" ]; then
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
    done < "$RESTORE_CONF"
else
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

cmd notification cancel fcm_repatch 2>/dev/null || true
cmd notification cancel fcm_repatch 0 2>/dev/null || true

cleanup_restore
exit 0
