#!/system/bin/sh
MODDIR=${0%/*}

# Wait for Android boot completion
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done

# Keep Xiaomi Greezer active globally for battery savings
cmd greezer enable true 2>/dev/null

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
[ -z "$GMS_UID" ] && GMS_UID=10133

cmd greezer thuid "$GMS_UID" 86400000 2>/dev/null
cmd greezer unmonitor "$GMS_UID" 2>/dev/null
cmd deviceidle whitelist +com.google.android.gms 2>/dev/null
cmd deviceidle sys-whitelist +com.google.android.gms 2>/dev/null
cmd appops set com.google.android.gms RUN_IN_BACKGROUND allow 2>/dev/null
cmd appops set com.google.android.gms RUN_ANY_IN_BACKGROUND allow 2>/dev/null
cmd appops set com.google.android.gms 10008 allow 2>/dev/null
cmd appops set com.google.android.gms WAKE_LOCK allow 2>/dev/null

# Unfreeze GMS cgroup freezer node
for fz in "/sys/fs/cgroup/apps/uid_${GMS_UID}/cgroup.freeze" "/sys/fs/cgroup/apps/uid_${GMS_UID}"/*/cgroup.freeze; do
  [ -f "$fz" ] && echo 0 > "$fz" 2>/dev/null
done

# ==============================================================================
# 3. Enable Lockscreen & Floating Notification Display for Installed Apps
# ==============================================================================
for pkg in $(pm list packages -3 2>/dev/null | cut -d: -f2); do
  [ -z "$pkg" ] && continue
  cmd appops set "$pkg" 10020 allow >/dev/null 2>&1  # Show on Lockscreen
  cmd appops set "$pkg" 10021 allow >/dev/null 2>&1  # Floating notification / Banner
  cmd appops set "$pkg" 10022 allow >/dev/null 2>&1  # Badge
  cmd appops set "$pkg" 10004 allow >/dev/null 2>&1  # Vibrate
  cmd appops set "$pkg" 10033 allow >/dev/null 2>&1  # Sound
  cmd appops set "$pkg" POST_NOTIFICATION allow >/dev/null 2>&1
  cmd appops set "$pkg" USE_FULL_SCREEN_INTENT allow >/dev/null 2>&1
done
