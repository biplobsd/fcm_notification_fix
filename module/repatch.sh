#!/system/bin/sh
# ==============================================================================
# HyperOS FCM Notification Fix - Post-OTA Re-Patch Engine
# ==============================================================================
# The module serves framework jars that were patched against one specific
# firmware build. After an OTA those jars no longer match the rest of the ROM,
# and serving them is a bootloop. post-fs-data.sh therefore compares the build
# recorded at install time (rom.fingerprint) with the running build and, when
# they differ, creates skip_mount, skips its own bind mounts and leaves the
# device on 100% stock framework.
#
# This script is what repairs that state: it re-runs the transactional patch
# engine against the (now stock, unmounted) framework jars of the new firmware,
# swaps the result into the module and asks for a reboot. It is invoked
# automatically by service.sh when a re-patch is pending, and manually from the
# WebUI button.
#
# Usage: repatch.sh status | run
# ==============================================================================

MODDIR="${0%/*}"
[ "$MODDIR" = "$0" ] && MODDIR="."
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules/fcm_notification_fix"
[ -d "$MODDIR" ] || MODDIR="/data/adb/modules_update/fcm_notification_fix"
LOG="$MODDIR/repatch.log"

# shellcheck source=common.sh
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

FLAG_PENDING="$MODDIR/repatch_pending"
FLAG_RUNNING="$MODDIR/repatch_running"
FLAG_FAILED="$MODDIR/repatch_failed"
FLAG_REBOOT="$MODDIR/repatch_reboot"
SKIP_MOUNT="$MODDIR/skip_mount"

# A run that outlives this many seconds without finishing was killed (reboot,
# low-memory kill); its flag must not wedge the module in "running" forever.
STALE_RUN_SECONDS=1800

SERVICES_LIVE="/system/framework/services.jar"
MIUI_LIVE="$(live_miui_services)"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

current_fp() {
    if command -v get_rom_fingerprint >/dev/null 2>&1; then
        get_rom_fingerprint
    else
        echo "$(getprop ro.build.fingerprint)|$(getprop ro.system.build.fingerprint)|$(getprop ro.system_ext.build.fingerprint)|$(getprop ro.build.version.incremental)|$(getprop persist.sys.xms.version)"
    fi
}

stored_fp() {
    cat "$MODDIR/rom.fingerprint" 2>/dev/null
}

notify() {
    cmd notification post -S bigtext -t "FCM Notification Fix" fcm_repatch "$1" >/dev/null 2>&1 || true
}

# Drops a running flag left behind by a killed run.
clear_stale_running() {
    [ -f "$FLAG_RUNNING" ] || return 0

    # 1. Check if the recorded PID is dead
    LOCK_PID="$(cat "$FLAG_RUNNING" 2>/dev/null | tr -cd '0-9')"
    if [ -n "$LOCK_PID" ]; then
        if ! kill -0 "$LOCK_PID" 2>/dev/null; then
            rm -f "$FLAG_RUNNING"
            log "cleared stale running flag (process $LOCK_PID no longer alive)"
            return 0
        fi
        return 0
    fi

    # 2. Fallback to timestamp check when the lock has no verifiable PID
    NOW="$(date +%s 2>/dev/null || echo 0)"
    TS="$(date -r "$FLAG_RUNNING" +%s 2>/dev/null || stat -c %Y "$FLAG_RUNNING" 2>/dev/null || echo 0)"
    if [ "$NOW" -gt 0 ] && [ "$TS" -gt 0 ] && [ "$((NOW - TS))" -gt "$STALE_RUN_SECONDS" ]; then
        rm -f "$FLAG_RUNNING"
        log "cleared stale running flag (previous re-patch never finished)"
        return 0
    fi
}


cmd_status() {
    clear_stale_running

    CUR="$(current_fp)"
    STORED="$(stored_fp)"
    [ -z "$STORED" ] && STORED="-"

    # User-friendly display versions for UI
    if command -v get_rom_display_version >/dev/null 2>&1; then
        CUR_DISPLAY="$(get_rom_display_version)"
    else
        CUR_DISPLAY="$(getprop ro.build.version.incremental)"
    fi

    STORED_DISPLAY="$STORED"
    if [ "$STORED" = "$CUR" ]; then
        STORED_DISPLAY="$CUR_DISPLAY"
    elif [ "$STORED" != "-" ]; then
        case "$STORED" in
            *"|"*)
                _stored_inc=$(echo "$STORED" | cut -d'|' -f4 2>/dev/null)
                _stored_xms=$(echo "$STORED" | cut -d'|' -f5 2>/dev/null)
                if [ -n "$_stored_inc" ] && [ -n "$_stored_xms" ]; then
                    case "$_stored_inc" in
                        *"."*"$_stored_xms"*) STORED_DISPLAY="$_stored_inc" ;;
                        *) STORED_DISPLAY="${_stored_inc}.${_stored_xms}" ;;
                    esac
                elif [ -n "$_stored_inc" ]; then
                    STORED_DISPLAY="$_stored_inc"
                fi
                ;;
            *)
                STORED_DISPLAY="$STORED"
                ;;
        esac
    fi

    # Whether the patch is actually live is a property of the jar the system
    # reads, not of /proc/mounts: KernelSU and APatch serve modules through
    # OverlayFS, where individual file mounts are not listed there at all.
    ACTIVE=no
    if [ -n "$MIUI_LIVE" ] && ! is_stock_jar "$MIUI_LIVE"; then
        ACTIVE=yes
    fi

    if [ -f "$FLAG_RUNNING" ]; then
        STATE=running
    elif [ -f "$FLAG_REBOOT" ]; then
        STATE=reboot
    elif [ -f "$FLAG_FAILED" ]; then
        STATE=failed
    elif [ -f "$FLAG_PENDING" ]; then
        STATE=pending
    elif [ "$STORED" != "-" ] && ! is_fingerprint_match "$STORED" "$CUR"; then
        STATE=pending
    else
        STATE=ok
    fi

    LAST="$(tail -n 1 "$LOG" 2>/dev/null | tr -d '\r')"

    echo "state=$STATE"
    echo "current=$CUR_DISPLAY"
    echo "stored=$STORED_DISPLAY"
    echo "active=$ACTIVE"
    echo "last=$LAST"
}

cmd_run() {
    clear_stale_running
    # Atomically acquire lock using noclobber (O_CREAT | O_EXCL)
    if ! ( set -C; echo "$$" > "$FLAG_RUNNING" ) 2>/dev/null; then
        clear_stale_running
        if ! ( set -C; echo "$$" > "$FLAG_RUNNING" ) 2>/dev/null; then
            echo "RESULT=BUSY"
            return 0
        fi
    fi

    rm -f "$FLAG_FAILED"

    STAGE_DIR="/data/local/tmp/fcm_repatch_$$"
    [ -d "/data/local/tmp" ] || STAGE_DIR="${TMPDIR:-/tmp}/fcm_repatch_$$"
    PUB_DIR="$MODDIR/framework_staging_$$"

    cleanup_on_exit() {
        rm -rf "$STAGE_DIR" "$PUB_DIR" 2>/dev/null
        if [ -f "$FLAG_RUNNING" ]; then
            RUN_PID="$(cat "$FLAG_RUNNING" 2>/dev/null | tr -cd '0-9')"
            [ "$RUN_PID" = "$$" ] && rm -f "$FLAG_RUNNING"
        fi
    }
    trap 'cleanup_on_exit; exit 1' INT TERM HUP

    CUR="$(current_fp)"
    PATCHER_JAR="$MODDIR/tools/patcher.jar"

    if [ ! -f "$PATCHER_JAR" ]; then
        log "re-patch aborted: patcher engine missing (re-flash the module zip)"
        cleanup_on_exit
        trap - INT TERM HUP
        touch "$FLAG_FAILED"
        notify "Firmware changed and the patch engine is missing. Re-flash the module zip to restore push notifications."
        echo "RESULT=FAIL"
        return 1
    fi

    if [ -z "$MIUI_LIVE" ]; then
        log "re-patch aborted: no miui-services.jar found on this ROM"
        cleanup_on_exit
        trap - INT TERM HUP
        touch "$FLAG_FAILED"
        echo "RESULT=FAIL"
        return 1
    fi

    # The OTA may have moved the device onto a profile this module cannot patch
    # (new Android level, region switch). Resolve it exactly like customize.sh.
    detect_rom_profile
    if ! REASON="$(rom_profile_supported)"; then
        log "re-patch aborted: $REASON"
        cleanup_on_exit
        trap - INT TERM HUP
        touch "$FLAG_FAILED"
        notify "Firmware changed to a profile this module cannot patch: $REASON The device stays on stock framework."
        echo "RESULT=FAIL"
        return 1
    fi

    # Never patch an already patched jar: that would stack hooks on hooks.
    if ! is_stock_jar "$SERVICES_LIVE" || ! is_stock_jar "$MIUI_LIVE"; then
        log "re-patch aborted: live framework jars are not stock (module overlay still active?)"
        cleanup_on_exit
        trap - INT TERM HUP
        touch "$FLAG_FAILED"
        notify "Automatic re-patch could not run because the framework is not in its stock state. Re-flash the module zip."
        echo "RESULT=FAIL"
        return 1
    fi

    mkdir -p "$STAGE_DIR"

    CUR_DISPLAY="$(get_rom_display_version 2>/dev/null || echo "$CUR")"
    STORED_DISPLAY="$(cmd_status | grep '^stored=' | cut -d= -f2-)"

    log "re-patching for firmware $CUR_DISPLAY (was $STORED_DISPLAY) - profile $ROM_OS/$ROM_REGION, SDK $ROM_SDK"

    execute_patcher_engine "$PATCHER_JAR" "$STAGE_DIR" \
        --services "$SERVICES_LIVE" \
        --miui-services "$MIUI_LIVE" \
        --patcher "$PATCHER_JAR" \
        --out-dir "$STAGE_DIR" \
        --sdk "$ROM_SDK" \
        --os "$ROM_OS" \
        --region "$ROM_REGION" >> "$LOG" 2>&1
    STATUS=$?

    if [ "$STATUS" -ne 0 ] || [ ! -f "$STAGE_DIR/services.jar" ] || [ ! -f "$STAGE_DIR/miui-services.jar" ]; then
        log "re-patch FAILED (exit $STATUS) - device stays on stock framework"
        cleanup_on_exit
        trap - INT TERM HUP
        touch "$FLAG_FAILED"
        notify "Automatic re-patch failed on firmware $CUR_DISPLAY. The device runs on stock framework; push notifications are unfixed until the module is re-flashed."
        echo "RESULT=FAIL"
        return 1
    fi

    rm -rf "$PUB_DIR"
    mkdir -p "$PUB_DIR"

    PUB_OK=1
    cp -f "$STAGE_DIR/services.jar" "$PUB_DIR/services.jar" || PUB_OK=0
    cp -f "$STAGE_DIR/miui-services.jar" "$PUB_DIR/miui-services.jar" || PUB_OK=0

    _sz_srv_src=$(wc -c < "$STAGE_DIR/services.jar" 2>/dev/null || echo 0)
    _sz_srv_pub=$(wc -c < "$PUB_DIR/services.jar" 2>/dev/null || echo 0)
    _sz_miui_src=$(wc -c < "$STAGE_DIR/miui-services.jar" 2>/dev/null || echo 0)
    _sz_miui_pub=$(wc -c < "$PUB_DIR/miui-services.jar" 2>/dev/null || echo 0)

    if [ "$PUB_OK" -ne 1 ] || \
       [ "$_sz_srv_pub" -lt 1000000 ] || [ "$_sz_srv_pub" -ne "$_sz_srv_src" ] || \
       [ "$_sz_miui_pub" -lt 1000000 ] || [ "$_sz_miui_pub" -ne "$_sz_miui_src" ]; then
        log "re-patch FAILED: staged framework JARs validation failed"
        cleanup_on_exit
        trap - INT TERM HUP
        touch "$FLAG_FAILED"
        notify "Automatic re-patch failed on firmware $CUR_DISPLAY: framework publication staging failed."
        echo "RESULT=FAIL"
        return 1
    fi

    for f in "$PUB_DIR/services.jar" "$PUB_DIR/miui-services.jar"; do
        chown 0:0 "$f" 2>/dev/null || true
        chmod 0644 "$f" 2>/dev/null || true
        chcon u:object_r:system_file:s0 "$f" 2>/dev/null || true
    done

    rm -rf "$MODDIR/framework" "$MODDIR/system" "$MODDIR/system_ext"
    if ! mv "$PUB_DIR" "$MODDIR/framework"; then
        log "re-patch FAILED: failed to move staged framework directory"
        cleanup_on_exit
        trap - INT TERM HUP
        touch "$FLAG_FAILED"
        echo "RESULT=FAIL"
        return 1
    fi

    # Refresh the pristine stock stash so manual upgrades keep working
    if [ -d "$MODDIR/stock" ]; then
        cp -f "$SERVICES_LIVE" "$MODDIR/stock/services.jar" 2>/dev/null
        cp -f "$MIUI_LIVE" "$MODDIR/stock/miui-services.jar" 2>/dev/null
        echo "$CUR" > "$MODDIR/stock/fingerprint"
    fi

    # Pre-compile system_server AOT cache (dex2oat)
    if compile_aot_cache "$MODDIR/framework/services.jar" "$SERVICES_LIVE" "$MODDIR/framework/miui-services.jar" "$MIUI_LIVE"; then
        log "native AOT speed compilation complete"
        rm -f "$MODDIR/wipe_cache_once"
    else
        # Fallback: signal post-fs-data to purge stale dalvik-cache on first boot
        touch "$MODDIR/wipe_cache_once"
    fi

    echo "$CUR" > "$MODDIR/rom.fingerprint"
    rm -f "$FLAG_PENDING"
    cleanup_on_exit
    trap - INT TERM HUP

    touch "$FLAG_REBOOT"
    touch "$SKIP_MOUNT"

    # Stealth in-memory tmpfs mount will be activated by post-fs-data.sh on next boot
    log "re-patch OK for firmware $CUR_DISPLAY - reboot required to serve the new jars"
    notify "Framework re-patched for firmware $CUR_DISPLAY. Reboot to re-enable push notification fixes."
    echo "RESULT=OK"
    return 0
}

case "$1" in
    run)  cmd_run ;;
    *)    cmd_status ;;
esac
