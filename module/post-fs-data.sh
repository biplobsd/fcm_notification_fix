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
    if ! mount -t tmpfs -o mode=0755,size=100M tmpfs "$TMP_DIR" 2>/dev/null; then
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
    chcon u:object_r:system_file:s0 "$_staged" 2>/dev/null || true

    # Staging succeeded: safely replace the target mount
    umount "$_dst" 2>/dev/null || true
    if ! mount -o bind "$_staged" "$_dst" 2>/dev/null; then
        umount -l "$TMP_DIR" 2>/dev/null || true
        rm -rf "$TMP_DIR" 2>/dev/null
        return 1
    fi

    mount -o remount,ro,bind "$_dst" 2>/dev/null || true

    # Clean up staging mount; pinned VFS inode at $_dst persists
    umount -l "$TMP_DIR" 2>/dev/null || true
    rm -rf "$TMP_DIR" 2>/dev/null
    return 0
}

# Resolve patched services.jar
SERVICES_SRC=""
if [ -f "$MODDIR/framework/services.jar" ]; then
    SERVICES_SRC="$MODDIR/framework/services.jar"
elif [ -f "$MODDIR/system/framework/services.jar" ]; then
    SERVICES_SRC="$MODDIR/system/framework/services.jar"
fi

if [ -n "$SERVICES_SRC" ]; then
    if ! mount_stealth_jar "$SERVICES_SRC" /system/framework/services.jar "services.jar"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: failed to stealth-mount services.jar" >> "$MODDIR/repatch.log"
    fi
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

if [ -n "$MIUI_SRC" ] && [ -n "$MIUI_DST" ]; then
    if ! mount_stealth_jar "$MIUI_SRC" "$MIUI_DST" "miui-services.jar"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: failed to stealth-mount miui-services.jar to $MIUI_DST" >> "$MODDIR/repatch.log"
    fi
fi
