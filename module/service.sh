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

    # Backup initial GMS AppOps state for surgical restoration on uninstall
    for op in $GMS_APPOPS; do
        [ -z "$op" ] && continue
        op_out=$(cmd appops get com.google.android.gms "$op" 2>/dev/null)
        op_status=$?
        op_mode="unknown"
        if [ "$op_status" -eq 0 ] && [ -n "$op_out" ]; then
            op_line=$(printf '%s\n' "$op_out" | awk -v op="$op" '
                $0 ~ "^[[:space:]]*" op "[[:space:]]*:" { print; exit }
            ')
            if [ -n "$op_line" ]; then
                case "$op_line" in
                    *": allow"*) op_mode="allow" ;;
                    *": ignore"*) op_mode="ignore" ;;
                    *": deny"*) op_mode="deny" ;;
                    *": foreground"*) op_mode="foreground" ;;
                    *": default"*) op_mode="default" ;;
                esac
            else
                default_line=$(printf '%s\n' "$op_out" | awk '
                    /^[[:space:]]*Default mode[[:space:]]*:/ { print; exit }
                ')
                case "$default_line" in
                    *": allow"*) op_mode="allow" ;;
                    *": ignore"*) op_mode="ignore" ;;
                    *": deny"*) op_mode="deny" ;;
                    *": foreground"*) op_mode="foreground" ;;
                    *": default"*) op_mode="default" ;;
                    *)
                        case "$op_out" in
                            *"No operations."*) op_mode="default" ;;
                        esac
                        ;;
                esac
            fi
        fi
        echo "gms_appop:${op}=${op_mode}" >> "$STOCK_TMP"
    done

    chmod 0600 "$STOCK_TMP" 2>/dev/null
    mv -f "$STOCK_TMP" "$STOCK_CONF" 2>/dev/null
fi

# Capture both PowerKeeper userTable rows before any service or WebUI path can
# change them. If the provider is unavailable, leave PowerKeeper untouched.
POWERKEEPER_BACKUP_OK=0
if command -v ensure_powerkeeper_backup >/dev/null 2>&1 && ensure_powerkeeper_backup "$STOCK_CONF"; then
    POWERKEEPER_BACKUP_OK=1
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
# Dynamically resolve Google Play Services UID
GMS_UID=$(pm list packages -U com.google.android.gms 2>/dev/null | grep -o 'uid:[0-9]*' | cut -d: -f2 | head -n1)

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

  # ── Gap 1: Disarm PowerKeeper GmsObserver Netd Firewall & DNS Blocker ──────
  # PowerKeeper's GmsObserver creates iptables CHAIN_GMS_WALL to block all GMS
  # TCP/DNS when Google servers are unreachable. On CN ROM, defaultState=true
  # (IS_INTERNATIONAL_BUILD=false). Setting gms_control=false completely disarms
  # the firewall chain, DNS blocker, wakelock revocation, and alarm suppression.
  if [ "$POWERKEEPER_BACKUP_OK" -eq 1 ]; then
    content call --uri content://com.miui.powerkeeper.configure/SimpleSettings/misc \
      --method PUT_misc --arg gms_control --extra value:s:false 2>/dev/null

    # PowerKeeper GmsObserver.isGmsControlEnabled() explicitly inspects com.android.vending
    # in userTable: if bgControl == "noRestrict", isGmsControlEnabled() returns false.
    # We enforce "noRestrict" across both Play Store and Google Play Services.
    for _p in com.google.android.gms com.android.vending; do
      content update --uri content://com.miui.powerkeeper.configure/userTable \
        --bind bgControl:s:noRestrict --where "pkgName='${_p}' AND userId=0" 2>/dev/null
      _has_entry=$(content query --uri content://com.miui.powerkeeper.configure/userTable --where "pkgName='${_p}' AND userId=0" 2>/dev/null | grep -o 'pkgName=' | head -n1)
      if [ -z "$_has_entry" ]; then
        content insert --uri content://com.miui.powerkeeper.configure/userTable \
          --bind pkgName:s:"${_p}" --bind userId:i:0 --bind bgControl:s:noRestrict 2>/dev/null
      fi
    done

    # Flush any existing gms_wall iptables chains
    iptables -F gms_wall 2>/dev/null
    ip6tables -F gms_wall 2>/dev/null
  fi

  # ── Gap 2: GMS Socket Recovery ─────────────────────────────────────────────
  # Trigger GCM_RECONNECT broadcast to force immediate MCS socket establishment
  am broadcast -a com.google.android.intent.action.GCM_RECONNECT \
    -p com.google.android.gms >/dev/null 2>&1
fi

# ==============================================================================
# 3. Notification Channel Permission Synchronization
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
# 4. FCM Wake Filter Configuration & WebUI Permissions
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

# Run sync asynchronously on boot completion
sync_notification_channels &


