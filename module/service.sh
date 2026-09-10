#!/system/bin/sh
MODDIR=${0%/*}
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

# Wait for Android boot completion
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done

# ==============================================================================
# 0. Post-OTA Re-Patch
# ==============================================================================
# When the firmware build changed under the module, post-fs-data.sh skipped every
# framework mount and left a pending flag: the device is running stock. Re-patch
# against the new stock jars in the background and notify the user to reboot. On
# failure the device simply stays stock and the state remains visible in the WebUI.
if [ -f "$MODDIR/repatch_pending" ] && [ -f "$MODDIR/repatch.sh" ]; then
    ( sleep 20; sh "$MODDIR/repatch.sh" run ) >/dev/null 2>&1 &
fi

# ==============================================================================
# 1. Global Lockscreen & Always-On Display (AOD) Notification Lighting & Wakeup
# ==============================================================================
STOCK_CONF="$MODDIR/stock_settings.conf"

SETTINGS_LIST="
secure:notification_animation_style
system:wake_up_for_notification
secure:lock_screen_wake_up_for_notification
system:wakeup_for_keyguard_notification
secure:full_screen_aod_notification
secure:lock_screen_show_notifications
secure:lock_screen_allow_private_notifications
system:pref_key_enable_notification_body
secure:lock_screen_show_only_unseen_notifications
"

GMS_APPOPS="
RUN_IN_BACKGROUND
RUN_ANY_IN_BACKGROUND
10008
WAKE_LOCK
"

# First boot: backup stock settings and GMS state if not already recorded. The
# key check also lets service.sh complete a PowerKeeper-only backup created by
# an early WebUI request without overwriting it.
if [ ! -f "$STOCK_CONF" ] || ! grep -q '^secure:notification_animation_style=' "$STOCK_CONF" 2>/dev/null; then
    STOCK_TMP="$MODDIR/stock_settings.conf.tmp.$$"
    rm -f "$STOCK_TMP" 2>/dev/null
    if [ -f "$STOCK_CONF" ]; then
        cp -f "$STOCK_CONF" "$STOCK_TMP" 2>/dev/null || : > "$STOCK_TMP"
    else
        : > "$STOCK_TMP"
    fi

    for entry in $SETTINGS_LIST; do
        [ -z "$entry" ] && continue
        ns="${entry%%:*}"
        k="${entry#*:}"
        val=$(settings get "$ns" "$k" 2>/dev/null | tr -d '\r')
        [ -z "$val" ] && val="null"
        echo "${ns}:${k}=${val}" >> "$STOCK_TMP"
    done

    # Backup initial GMS Doze user-whitelist state
    if cmd deviceidle whitelist 2>/dev/null | grep -q "com.google.android.gms"; then
        echo "gms_user_whitelisted=1" >> "$STOCK_TMP"
    else
        echo "gms_user_whitelisted=0" >> "$STOCK_TMP"
    fi

    # Backup initial GMS AppOps state for surgical restoration on uninstall.
    # read_appop_mode is the same reader the per-app FSI backup uses, so both
    # sides record modes by identical rules.
    for op in $GMS_APPOPS; do
        [ -z "$op" ] && continue
        op_mode=$(read_appop_mode com.google.android.gms "$op")
        echo "gms_appop:${op}=${op_mode}" >> "$STOCK_TMP"
    done

    chmod 0600 "$STOCK_TMP" 2>/dev/null
    mv -f "$STOCK_TMP" "$STOCK_CONF" 2>/dev/null
fi

# Capture both PowerKeeper userTable rows before any service or WebUI path can
# change them. If the provider is unavailable, leave PowerKeeper untouched.
POWERKEEPER_BACKUP_OK=0
if command -v ensure_powerkeeper_backup >/dev/null 2>&1; then
    _pk_retries=0
    while [ "$_pk_retries" -lt 5 ]; do
        if ensure_powerkeeper_backup "$STOCK_CONF"; then
            POWERKEEPER_BACKUP_OK=1
            break
        fi
        sleep 2
        _pk_retries=$((_pk_retries + 1))
    done
fi

# Wake screen / Light up screen on notification and notification privacy settings
# Applied only once on initial module setup to preserve subsequent user modifications
if [ ! -f "$MODDIR/.defaults_applied" ]; then
    DEFAULTS_OK=1
    settings put secure notification_animation_style screen_on 2>/dev/null || DEFAULTS_OK=0
    settings put system wake_up_for_notification 1 2>/dev/null || DEFAULTS_OK=0
    settings put secure lock_screen_wake_up_for_notification 1 2>/dev/null || DEFAULTS_OK=0
    settings put system wakeup_for_keyguard_notification 1 2>/dev/null || DEFAULTS_OK=0
    settings put secure full_screen_aod_notification 1 2>/dev/null || DEFAULTS_OK=0

    # Show all notifications and their full contents on lock screen (No hidden content):
    settings put secure lock_screen_show_notifications 1 2>/dev/null || DEFAULTS_OK=0
    settings put secure lock_screen_allow_private_notifications 1 2>/dev/null || DEFAULTS_OK=0
    settings put system pref_key_enable_notification_body 1 2>/dev/null || DEFAULTS_OK=0
    settings put secure lock_screen_show_only_unseen_notifications 0 2>/dev/null || DEFAULTS_OK=0

    [ "$DEFAULTS_OK" -eq 1 ] && touch "$MODDIR/.defaults_applied" 2>/dev/null
fi

# ==============================================================================
# 2. Google Play Services (GMS) Surgical Exemption
# ==============================================================================
# Dynamically resolve Google Play Services UID with exact package anchoring
GMS_UID=$(pm list packages -U com.google.android.gms 2>/dev/null | grep -E '^package:com\.google\.android\.gms ' | grep -o 'uid:[0-9]*' | cut -d: -f2 | head -n1)
[ -z "$GMS_UID" ] && GMS_UID=$(stat -c %u /data/data/com.google.android.gms 2>/dev/null)

if [ -n "$GMS_UID" ]; then
  cmd greezer thuid "$GMS_UID" 86400000 2>/dev/null
  cmd greezer unmonitor "$GMS_UID" 2>/dev/null
  cmd deviceidle whitelist +com.google.android.gms 2>/dev/null
  cmd deviceidle sys-whitelist +com.google.android.gms 2>/dev/null
  cmd appops set com.google.android.gms RUN_IN_BACKGROUND allow 2>/dev/null
  cmd appops set com.google.android.gms RUN_ANY_IN_BACKGROUND allow 2>/dev/null
  cmd appops set com.google.android.gms 10008 allow 2>/dev/null
  cmd appops set com.google.android.gms WAKE_LOCK allow 2>/dev/null

  # Unfreeze GMS cgroup freezer nodes across cgroup v1 and v2 hierarchies
  for fz in "/sys/fs/cgroup/apps/uid_${GMS_UID}/cgroup.freeze" \
            "/sys/fs/cgroup/uid_${GMS_UID}/cgroup.freeze" \
            "/sys/fs/cgroup/apps/uid_${GMS_UID}"/*/cgroup.freeze \
            "/sys/fs/cgroup/uid_${GMS_UID}"/*/cgroup.freeze \
            "/dev/freezer/apps/uid_${GMS_UID}/freezer.state"; do
    if [ -f "$fz" ]; then
      case "$fz" in
        *freezer.state) echo "THAWED" > "$fz" 2>/dev/null ;;
        *)              echo 0 > "$fz" 2>/dev/null ;;
      esac
    fi
  done

  # ── Gap 1: GMS Socket Recovery ─────────────────────────────────────────────
  # Trigger GCM_RECONNECT broadcast to force immediate MCS socket establishment
  am broadcast -a com.google.android.intent.action.GCM_RECONNECT \
    -p com.google.android.gms >/dev/null 2>&1
fi

# ==============================================================================
# 3. Disarm PowerKeeper GMS Firewall & DNS Blocker (China ROM Boot Apply)
# ==============================================================================
# PowerKeeper's GmsObserver creates iptables CHAIN_GMS_WALL to block all GMS
# TCP/DNS when Google servers are unreachable. On CN ROM, defaultState=true
# (IS_INTERNATIONAL_BUILD=false). Setting gms_control=false completely disarms
# the firewall chain, DNS blocker, wakelock revocation, and alarm suppression.
apply_pk_boot_disarm() {
    _pk_boot="true"
    if [ -f "/data/system/fcm_pk_boot.conf" ]; then
        _v=$(cat "/data/system/fcm_pk_boot.conf" 2>/dev/null | tr -d ' \r\n')
        [ "$_v" = "false" ] || [ "$_v" = "0" ] && _pk_boot="false"
    fi
    [ "$_pk_boot" = "true" ] || return 0

    if [ -z "$ROM_REGION" ] && command -v detect_rom_profile >/dev/null 2>&1; then
        detect_rom_profile
    fi

    # Retries at boot completion, +5s, and +15s to prevent PowerKeeper's delayed
    # startup on China ROM from silently overriding the disarmed state.
    for _delay in 0 5 15; do
        [ "$_delay" -gt 0 ] && sleep "$_delay"
        if command -v content >/dev/null 2>&1; then
            _has_pk_gms=$(content query --uri content://com.miui.powerkeeper.configure/SimpleSettings/misc --where "name='gms_control'" 2>/dev/null | grep -o 'value=' | head -n1)
            if [ "$ROM_REGION" = "cn" ] || [ -n "$_has_pk_gms" ]; then
                command -v ensure_powerkeeper_backup >/dev/null 2>&1 && ensure_powerkeeper_backup "$STOCK_CONF"
                content call --uri content://com.miui.powerkeeper.configure/SimpleSettings/misc \
                  --method PUT_misc --arg gms_control --extra value:s:false 2>/dev/null || true
                for _p in com.google.android.gms com.android.vending; do
                  content update --uri content://com.miui.powerkeeper.configure/userTable \
                    --bind bgControl:s:noRestrict --where "pkgName='${_p}' AND userId=0" 2>/dev/null || true
                  _has_entry=$(content query --uri content://com.miui.powerkeeper.configure/userTable --where "pkgName='${_p}' AND userId=0" 2>/dev/null | grep -o 'pkgName=' | head -n1)
                  if [ -z "$_has_entry" ]; then
                    content insert --uri content://com.miui.powerkeeper.configure/userTable \
                      --bind pkgName:s:"${_p}" --bind userId:i:0 --bind bgControl:s:noRestrict 2>/dev/null || true
                  fi
                done
                iptables -F gms_wall 2>/dev/null || true
                ip6tables -F gms_wall 2>/dev/null || true
            fi
        fi
    done
}

# ==============================================================================
# 4. Notification Channel Permission Synchronization
# ==============================================================================
# In HyperOS China ROM, unconfigured 3rd-party app channels default to "Don't show"
# on keyguard and have sound/vibration silenced due to CN whitelist fallback.
# We delegate startup synchronization directly to the backend exec handler.
sync_notification_channels() {
    sleep 5
    if [ -f "$MODDIR/webroot/cgi-bin/exec" ]; then
        sh "$MODDIR/webroot/cgi-bin/exec" boot_sync >/dev/null 2>&1
    fi
}

# ==============================================================================
# 5. FCM Wake Filter Configuration & WebUI Permissions
# ==============================================================================
CONF_FILE="/data/system/fcm_wake.conf"
if [ ! -f "$CONF_FILE" ]; then
    cat <<'EOF' > "$CONF_FILE"
# HyperOS FCM Dynamic Wake Filter Configuration
# Modes: MODE=ALL | MODE=WHITELIST | MODE=BLACKLIST
MODE=ALL
EOF
fi
chmod 0644 "$CONF_FILE" 2>/dev/null
chown system:system "$CONF_FILE" 2>/dev/null
chcon u:object_r:system_data_file:s0 "$CONF_FILE" 2>/dev/null

[ -f "$MODDIR/webroot/cgi-bin/exec" ] && chmod 0755 "$MODDIR/webroot/cgi-bin/exec" 2>/dev/null

# ==============================================================================
# 6. Per-App VoIP FullScreen Intent AppOps (Boot Re-Apply)
# ==============================================================================
# Re-apply the FSI ops for apps configured with FSI_PKG= in fcm_wake.conf, for
# the case where a platform drops them across a reboot. reapply_fsi_appops only
# re-grants an op that still reads exactly as it did before the module first
# touched it, so a mode the user changed in Settings survives the next boot
# instead of being silently overwritten.
apply_fsi_boot() {
    [ -f "$CONF_FILE" ] || return 0
    _fsi_pkgs=$(grep "^FSI_PKG=" "$CONF_FILE" 2>/dev/null | cut -d= -f2 | tr -d '\r' | grep -E '^[a-zA-Z0-9._-]+$')
    [ -z "$_fsi_pkgs" ] && return 0

    echo "$_fsi_pkgs" | while read -r _fpkg; do
        [ -z "$_fpkg" ] && continue
        reapply_fsi_appops "$STOCK_CONF" "$_fpkg"
    done
}

# Run PowerKeeper boot disarm, FSI boot re-apply, and channel sync asynchronously on boot completion
apply_pk_boot_disarm &
apply_fsi_boot &
sync_notification_channels &

