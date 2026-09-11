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

# Dynamically resolve Google Play Services UID with exact package anchoring
GMS_UID=$(pm list packages -U com.google.android.gms 2>/dev/null | grep -E '^package:com\.google\.android\.gms ' | grep -o 'uid:[0-9]*' | cut -d: -f2 | head -n1)
[ -z "$GMS_UID" ] && GMS_UID=$(stat -c %u /data/data/com.google.android.gms 2>/dev/null)

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

# Restore FSI AppOps for user packages if staged by uninstall.sh. This script is
# copied to /data/adb/service.d and runs with no module directory to source from,
# so the op set and the record lookup are spelled out here; they must stay in
# step with FSI_APPOPS and saved_fsi_appop_mode in common.sh.
#
#   USE_FULL_SCREEN_INTENT             AOSP full-screen notification access
#   10020 OP_SHOW_WHEN_LOCKED          MIUI, App info > Other permissions
#   10021 OP_BACKGROUND_START_ACTIVITY MIUI, the op checkFullScreenIntent reads
#
# A missing or unrecognised record falls back to "default" - the mode an
# untouched op sits at - and never to "ignore", which actively denies the op.
FSI_APPOPS="USE_FULL_SCREEN_INTENT 10020 10021"

if [ -f "$RESTORE_CONF" ]; then
    grep "^fsi_pkg:" "$RESTORE_CONF" 2>/dev/null | cut -d: -f2 | tr -d '\r' | while read -r _pkg; do
        [ -z "$_pkg" ] && continue
        for _op in $FSI_APPOPS; do
            _mode=$(awk -F= -v key="fsi_appop:${_pkg}:${_op}" '
                $1 == key { print substr($0, index($0, "=") + 1); exit }
            ' "$RESTORE_CONF" 2>/dev/null)
            case "$_mode" in
                allow|ignore|deny|foreground|default) ;;
                *) _mode="default" ;;
            esac
            cmd appops set "$_pkg" "$_op" "$_mode" 2>/dev/null || true
        done
    done
fi

# Restore PowerKeeper gms_control and both userTable rows to stock
RESTORE_FAILED=0
pk_ctrl="true"
if [ -f "$RESTORE_CONF" ]; then
    saved_pk=$(awk -F= '$1 == "powerkeeper_gms_control" { print substr($0, index($0, "=") + 1); exit }' "$RESTORE_CONF" 2>/dev/null)
    [ -n "$saved_pk" ] && pk_ctrl="$saved_pk"
fi
content call --uri content://com.miui.powerkeeper.configure/SimpleSettings/misc \
  --method PUT_misc --arg gms_control --extra value:s:"$pk_ctrl" 2>/dev/null || RESTORE_FAILED=1

if [ -f "$RESTORE_CONF" ]; then
    for pk_pkg in com.google.android.gms com.android.vending; do
        pk_existed=$(awk -F= -v key="powerkeeper_user:${pk_pkg}:exists" \
          '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$RESTORE_CONF" 2>/dev/null)
        if [ "$pk_existed" = "0" ]; then
            content delete --uri content://com.miui.powerkeeper.configure/userTable \
              --where "pkgName='${pk_pkg}' AND userId=0" 2>/dev/null || RESTORE_FAILED=1
        elif [ "$pk_existed" = "1" ]; then
            pk_bg_control=$(awk -F= -v key="powerkeeper_user:${pk_pkg}:bg_control" \
              '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$RESTORE_CONF" 2>/dev/null)
            if [ -z "$pk_bg_control" ]; then
                RESTORE_FAILED=1
                continue
            fi
            pk_row=$(content query --uri content://com.miui.powerkeeper.configure/userTable \
              --where "pkgName='${pk_pkg}' AND userId=0" 2>/dev/null)
            pk_query_status=$?
            if [ "$pk_query_status" -ne 0 ]; then
                RESTORE_FAILED=1
                continue
            fi
            if [ "$pk_bg_control" = "NULL" ] || [ "$pk_bg_control" = "null" ]; then
                pk_binding="bgControl:n:"
            else
                pk_binding="bgControl:s:${pk_bg_control}"
            fi
            if printf '%s\n' "$pk_row" | grep -q "pkgName=${pk_pkg}"; then
                content update --uri content://com.miui.powerkeeper.configure/userTable \
                  --bind "$pk_binding" --where "pkgName='${pk_pkg}' AND userId=0" 2>/dev/null || RESTORE_FAILED=1
            else
                content insert --uri content://com.miui.powerkeeper.configure/userTable \
                  --bind pkgName:s:"$pk_pkg" --bind userId:i:0 --bind "$pk_binding" 2>/dev/null || RESTORE_FAILED=1
            fi
        fi
    done
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

if [ "$RESTORE_FAILED" -ne 0 ]; then
    exit 1
fi

cleanup_restore
exit 0
