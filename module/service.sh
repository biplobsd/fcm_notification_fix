#!/system/bin/sh
MODDIR=${0%/*}

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
# Wake screen / Light up screen on notification:
settings put secure notification_animation_style screen_on 2>/dev/null
settings put system wake_up_for_notification 1 2>/dev/null
settings put secure lock_screen_wake_up_for_notification 1 2>/dev/null
settings put system wakeup_for_keyguard_notification 1 2>/dev/null
settings put secure full_screen_aod_notification 1 2>/dev/null

# Show all notifications and their full contents on lock screen (No hidden content):
settings put secure lock_screen_show_notifications 1 2>/dev/null
settings put secure lock_screen_allow_private_notifications 1 2>/dev/null
settings put system pref_key_enable_notification_body 1 2>/dev/null
settings put secure lock_screen_show_only_unseen_notifications 0 2>/dev/null

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
fi

# ==============================================================================
# 3. Auto-Grant Lockscreen Visibility to New App Notification Channels
# ==============================================================================
# In HyperOS China ROM, unconfigured 3rd-party app channels default to "Don't show"
# on keyguard due to CN whitelist fallback. We automatically grant lockscreen
# visibility to newly registered channels while strictly preserving user customizations:
# if an app/channel already has an entry (whether true or false), it is untouched.
sync_notification_channels() {
  XML="/data/user_de/0/com.android.systemui/shared_prefs/app_notification.xml"
  [ -f "$XML" ] && chcon u:object_r:system_app_data_file:s0 "$XML" 2>/dev/null

  dumpsys notification --noredact 2>/dev/null | awk -v xml="$XML" '
    BEGIN {
      if (xml != "") {
        while ((getline line < xml) > 0) {
          if (match(line, /name="([^"]+)"/)) {
            n = substr(line, RSTART+6, RLENGTH-7);
            existing[n] = 1;
          }
        }
        close(xml);
      }
    }
    /^ *AppSettings: / {
      sub(/^ *AppSettings: /, "");
      split($0, a, " ");
      pkg = a[1];
      pkg_key = pkg "_keyguard";
      if (pkg != "" && !(pkg_key in existing)) {
        print pkg, "";
        existing[pkg_key] = 1;
      }
    }
    /^ *NotificationChannel\{mId=/ {
      match($0, /mId=([^,]+)/);
      id = substr($0, RSTART+4, RLENGTH-4);
      gsub(/\047/, "", id);
      if (pkg != "" && id != "") {
        ch_key = pkg "_" id "_keyguard";
        if (!(ch_key in existing)) {
          print pkg, id;
          existing[ch_key] = 1;
        }
      }
    }
  ' | while read -r pkg ch; do
    if [ -z "$ch" ]; then
      content call --uri content://statusbar.notification --method setShowOnKeyguard --extra package:s:"$pkg" --extra canShowOnKeyguard:b:true >/dev/null 2>&1
    else
      content call --uri content://statusbar.notification --method setShowOnKeyguard --extra package:s:"$pkg" --extra channel_id:s:"$ch" --extra canShowOnKeyguard:b:true >/dev/null 2>&1
    fi
  done
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



