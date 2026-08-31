#!/system/bin/sh
MODDIR=${0%/*}

# 1. Purge stale dalvik-cache artifacts ONCE on first boot after install/update
if [ -f "$MODDIR/wipe_cache_once" ]; then
    rm -rf /data/dalvik-cache/*/*services* 2>/dev/null
    rm -rf /data/dalvik-cache/*/*miui-services* 2>/dev/null
    rm -f "$MODDIR/wipe_cache_once"
fi

# A re-patch cannot survive a reboot, so a running flag found this early was
# left behind by one that was killed. Drop it, or the module would report
# "re-patching" forever and refuse to start a new attempt.
if [ -f "$MODDIR/repatch_running" ]; then
    rm -f "$MODDIR/repatch_running"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] previous re-patch was interrupted by a reboot" >> "$MODDIR/repatch.log"
fi

# Ensure skip_mount is always enforced so root managers (KernelSU/APatch/Magisk)
# never auto-mount disk directories into the global namespace.
touch "$MODDIR/skip_mount"

# 2. Firmware Change Guard (OTA safety)
# The patched jars are built against one specific firmware build. After an OTA
# the rest of the ROM has moved on and serving them is a bootloop, so when the
# build recorded at install time no longer matches the running one the module
# serves nothing at all: the device boots on 100% stock framework and
# service.sh re-patches against the new firmware after boot.
CURRENT_FP="$(getprop ro.build.version.incremental)"
STORED_FP="$(cat "$MODDIR/rom.fingerprint" 2>/dev/null)"

if [ -n "$STORED_FP" ] && [ -n "$CURRENT_FP" ] && [ "$STORED_FP" != "$CURRENT_FP" ]; then
    touch "$MODDIR/repatch_pending"
    rm -f "$MODDIR/repatch_reboot"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] firmware changed ($STORED_FP -> $CURRENT_FP): module not mounted, re-patch pending" >> "$MODDIR/repatch.log"
    exit 0
fi

# Clear transient state flags
rm -f "$MODDIR/repatch_pending" "$MODDIR/repatch_reboot" "$MODDIR/repatch_failed"

# Sourced helpers (e.g. live_miui_services)
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

# 3. Anonymous In-Memory tmpfs Stealth Mounts
# Files are staged in a transient private tmpfs in RAM, verified, bind-mounted
# to system targets with read-only enforcement, and the staging dir is destroyed.
# Inodes remain pinned in kernel VFS with clean 0:xxx device and zero root tokens.
mount_stealth_jar() {
    _src="$1"
    _dst="$2"
    _name="$3"
    [ -f "$_src" ] || return 1
    [ -e "$_dst" ] || return 1
    _sz=$(wc -c < "$_src" 2>/dev/null || echo 0)
    [ "$_sz" -gt 1000000 ] || return 1

    TMP_DIR="/dev/.fcm_stage_${$}_$(date +%s%N 2>/dev/null || echo $$)"
    mkdir -p "$TMP_DIR" || return 1
    if ! mount -t tmpfs -o mode=0755,size=100M fcm_stage "$TMP_DIR" 2>/dev/null; then
        rm -rf "$TMP_DIR" 2>/dev/null
        return 1
    fi

    _staged="$TMP_DIR/$_name"
    if ! cp -f "$_src" "$_staged" 2>/dev/null; then
        umount -l "$TMP_DIR" 2>/dev/null || true
        rm -rf "$TMP_DIR" 2>/dev/null
        return 1
    fi

    _staged_sz=$(wc -c < "$_staged" 2>/dev/null || echo 0)
    if [ "$_staged_sz" -ne "$_sz" ]; then
        umount -l "$TMP_DIR" 2>/dev/null || true
        rm -rf "$TMP_DIR" 2>/dev/null
        return 1
    fi

    chmod 644 "$_staged" 2>/dev/null || true
    if ! chcon u:object_r:system_file:s0 "$_staged" 2>/dev/null; then
        umount -l "$TMP_DIR" 2>/dev/null || true
        rm -rf "$TMP_DIR" 2>/dev/null
        return 1
    fi

    # Staging succeeded: validate any existing mount before replacing
    _existing_src=$(awk -v tgt="$_dst" '
        $5 == tgt {
            for (i = 6; i <= NF; i++) {
                if ($i == "-") {
                    src = $(i+2);
                    break;
                }
            }
        }
        END { if (src != "") print src; }
    ' /proc/self/mountinfo 2>/dev/null)
    if [ -n "$_existing_src" ]; then
        case "$_existing_src" in
            fcm_stage|"$MODDIR"/*|/data/adb/modules/fcm_notification_fix/*)
                umount "$_dst" 2>/dev/null || umount -l "$_dst" 2>/dev/null || true
                ;;
            *)
                # Foreign module mount detected on target: abort to avoid detaching or clobbering other modules
                umount -l "$TMP_DIR" 2>/dev/null || true
                rm -rf "$TMP_DIR" 2>/dev/null
                return 1
                ;;
        esac
    fi

    if ! mount -o bind "$_staged" "$_dst" 2>/dev/null; then
        umount -l "$TMP_DIR" 2>/dev/null || true
        rm -rf "$TMP_DIR" 2>/dev/null
        return 1
    fi

    if ! mount -o remount,ro,bind "$_dst" 2>/dev/null; then
        umount -l "$_dst" 2>/dev/null || true
        umount -l "$TMP_DIR" 2>/dev/null || true
        rm -rf "$TMP_DIR" 2>/dev/null
        return 1
    fi

    # Clean up staging mount; pinned VFS inode at $_dst persists
    umount -l "$TMP_DIR" 2>/dev/null || true
    rm -rf "$TMP_DIR" 2>/dev/null
    return 0
}

SERVICES_DST="/system/framework/services.jar"

# Resolve patched services.jar
SERVICES_SRC=""
if [ -f "$MODDIR/framework/services.jar" ]; then
    SERVICES_SRC="$MODDIR/framework/services.jar"
elif [ -f "$MODDIR/system/framework/services.jar" ]; then
    SERVICES_SRC="$MODDIR/system/framework/services.jar"
fi

# Resolve patched miui-services.jar
MIUI_SRC=""
if [ -f "$MODDIR/framework/miui-services.jar" ]; then
    MIUI_SRC="$MODDIR/framework/miui-services.jar"
elif [ -f "$MODDIR/system_ext/framework/miui-services.jar" ]; then
    MIUI_SRC="$MODDIR/system_ext/framework/miui-services.jar"
elif [ -f "$MODDIR/system/system_ext/framework/miui-services.jar" ]; then
    MIUI_SRC="$MODDIR/system/system_ext/framework/miui-services.jar"
else
    MIUI_SRC="$(find "$MODDIR" -path "*/framework/miui-services.jar" -type f 2>/dev/null | head -n1)"
fi

# Resolve live system destination for miui-services.jar
if command -v live_miui_services >/dev/null 2>&1; then
    MIUI_DST="$(live_miui_services)"
else
    MIUI_DST=""
    for _p in /system_ext/framework/miui-services.jar \
             /system/system_ext/framework/miui-services.jar \
             /system/framework/miui-services.jar \
             /product/framework/miui-services.jar \
             /system/product/framework/miui-services.jar; do
        if [ -f "$_p" ]; then
            MIUI_DST="$_p"
            break
        fi
    done
fi
[ -z "$MIUI_DST" ] && MIUI_DST="/system_ext/framework/miui-services.jar"

# Both source JARs and target destinations must be present and valid
if [ -z "$SERVICES_SRC" ] || [ ! -f "$SERVICES_SRC" ] || [ ! -e "$SERVICES_DST" ] || \
   [ -z "$MIUI_SRC" ] || [ ! -f "$MIUI_SRC" ] || [ -z "$MIUI_DST" ] || [ ! -e "$MIUI_DST" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: framework source or destination missing (services: $SERVICES_SRC -> $SERVICES_DST, miui: $MIUI_SRC -> $MIUI_DST)" >> "$MODDIR/repatch.log"
    exit 0
fi

# Mount transactionally with automatic rollback on any failure
MOUNTED_TARGETS=""

rollback_mounts() {
    for _tgt in $MOUNTED_TARGETS; do
        umount -l "$_tgt" 2>/dev/null || umount "$_tgt" 2>/dev/null || true
    done
}

if mount_stealth_jar "$SERVICES_SRC" "$SERVICES_DST" "services.jar"; then
    MOUNTED_TARGETS="$MOUNTED_TARGETS $SERVICES_DST"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: failed to stealth-mount services.jar" >> "$MODDIR/repatch.log"
    rollback_mounts
    exit 0
fi

if mount_stealth_jar "$MIUI_SRC" "$MIUI_DST" "miui-services.jar"; then
    MOUNTED_TARGETS="$MOUNTED_TARGETS $MIUI_DST"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: failed to stealth-mount miui-services.jar to $MIUI_DST, rolling back" >> "$MODDIR/repatch.log"
    rollback_mounts
    exit 0
fi
