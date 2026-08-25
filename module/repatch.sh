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

MODDIR=${0%/*}
LOG="$MODDIR/repatch.log"

# shellcheck source=common.sh
. "$MODDIR/common.sh"

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
    getprop ro.build.version.incremental
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
    NOW="$(date +%s 2>/dev/null || echo 0)"
    TS="$(date -r "$FLAG_RUNNING" +%s 2>/dev/null || echo 0)"
    if [ "$NOW" -gt 0 ] && [ "$TS" -gt 0 ] && [ "$((NOW - TS))" -gt "$STALE_RUN_SECONDS" ]; then
        rm -f "$FLAG_RUNNING"
        log "cleared stale running flag (previous re-patch never finished)"
    fi
}

# Where the patched miui-services.jar has to land for this ROM layout.
miui_dests() {
    module_dest_paths "$MODDIR" "$MIUI_LIVE"
}

cmd_status() {
    clear_stale_running

    CUR="$(current_fp)"
    STORED="$(stored_fp)"
    [ -z "$STORED" ] && STORED="-"

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
    elif [ "$STORED" != "-" ] && [ "$STORED" != "$CUR" ]; then
        STATE=pending
    else
        STATE=ok
    fi

    LAST="$(tail -n 1 "$LOG" 2>/dev/null | tr -d '\r')"

    echo "state=$STATE"
    echo "current=$CUR"
    echo "stored=$STORED"
    echo "active=$ACTIVE"
    echo "last=$LAST"
}

cmd_run() {
    clear_stale_running
    if [ -f "$FLAG_RUNNING" ]; then
        echo "RESULT=BUSY"
        return 0
    fi

    CUR="$(current_fp)"
    PATCHER_JAR="$MODDIR/tools/patcher.jar"

    if [ ! -f "$PATCHER_JAR" ]; then
        log "re-patch aborted: patcher engine missing (re-flash the module zip)"
        touch "$FLAG_FAILED"
        notify "Firmware changed and the patch engine is missing. Re-flash the module zip to restore push notifications."
        echo "RESULT=FAIL"
        return 1
    fi

    if [ -z "$MIUI_LIVE" ]; then
        log "re-patch aborted: no miui-services.jar found on this ROM"
        touch "$FLAG_FAILED"
        echo "RESULT=FAIL"
        return 1
    fi

    DALVIK_BIN=""
    if [ -f "/apex/com.android.art/bin/dalvikvm" ]; then
        DALVIK_BIN="/apex/com.android.art/bin/dalvikvm"
    elif [ -f "/system/bin/dalvikvm" ]; then
        DALVIK_BIN="/system/bin/dalvikvm"
    else
        log "re-patch aborted: dalvikvm runtime not found"
        touch "$FLAG_FAILED"
        echo "RESULT=FAIL"
        return 1
    fi

    # The OTA may have moved the device onto a profile this module cannot patch
    # (new Android level, region switch). Resolve it exactly like customize.sh.
    detect_rom_profile
    if ! REASON="$(rom_profile_supported)"; then
        log "re-patch aborted: $REASON"
        touch "$FLAG_FAILED"
        notify "Firmware changed to a profile this module cannot patch: $REASON The device stays on stock framework."
        echo "RESULT=FAIL"
        return 1
    fi

    # Never patch an already patched jar: that would stack hooks on hooks.
    if ! is_stock_jar "$SERVICES_LIVE" || ! is_stock_jar "$MIUI_LIVE"; then
        log "re-patch aborted: live framework jars are not stock (module overlay still active?)"
        touch "$FLAG_FAILED"
        notify "Automatic re-patch could not run because the framework is not in its stock state. Re-flash the module zip."
        echo "RESULT=FAIL"
        return 1
    fi

    touch "$FLAG_RUNNING"
    rm -f "$FLAG_FAILED"
    STAGE_DIR="/data/local/tmp/fcm_repatch_$$"
    mkdir -p "$STAGE_DIR"
    export ANDROID_DATA="$STAGE_DIR"

    log "re-patching for firmware $CUR (was $(stored_fp)) - profile $ROM_OS/$ROM_REGION, SDK $ROM_SDK"

    "$DALVIK_BIN" -Xmx512m \
        -cp "$PATCHER_JAR" \
        com.hyperos.fcm.patcher.Main \
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
        rm -rf "$STAGE_DIR"
        rm -f "$FLAG_RUNNING"
        touch "$FLAG_FAILED"
        notify "Automatic re-patch failed on firmware $CUR. The device runs on stock framework; push notifications are unfixed until the module is re-flashed."
        echo "RESULT=FAIL"
        return 1
    fi

    mkdir -p "$MODDIR/system/framework"
    cp -f "$STAGE_DIR/services.jar" "$MODDIR/system/framework/services.jar"

    for dest in $(miui_dests); do
        mkdir -p "${dest%/*}"
        cp -f "$STAGE_DIR/miui-services.jar" "$dest"
    done

    for f in "$MODDIR/system/framework/services.jar" $(miui_dests); do
        [ -f "$f" ] || continue
        chown 0:0 "$f" 2>/dev/null
        chmod 0644 "$f" 2>/dev/null
        chcon u:object_r:system_file:s0 "$f" 2>/dev/null
    done

    # Refresh the pristine stock stash so manual upgrades keep working
    if [ -d "$MODDIR/stock" ]; then
        cp -f "$SERVICES_LIVE" "$MODDIR/stock/services.jar" 2>/dev/null
        cp -f "$MIUI_LIVE" "$MODDIR/stock/miui-services.jar" 2>/dev/null
        echo "$CUR" > "$MODDIR/stock/fingerprint"
    fi

    # Pre-compile system_server AOT cache (dex2oat)
    if compile_aot_cache "$STAGE_DIR/services.jar" "$SERVICES_LIVE" "$STAGE_DIR/miui-services.jar" "$MIUI_LIVE"; then
        log "native AOT speed compilation complete"
        rm -f "$MODDIR/wipe_cache_once"
    else
        # Fallback: signal post-fs-data to purge stale dalvik-cache on first boot
        touch "$MODDIR/wipe_cache_once"
    fi

    echo "$CUR" > "$MODDIR/rom.fingerprint"
    rm -f "$FLAG_PENDING" "$FLAG_RUNNING"
    touch "$FLAG_REBOOT"
    rm -rf "$STAGE_DIR"

    # skip_mount stays until the next boot: post-fs-data.sh removes it once the
    # recorded fingerprint matches again, so nothing is served this boot.
    log "re-patch OK for firmware $CUR - reboot required to serve the new jars"
    notify "Framework re-patched for firmware $CUR. Reboot to re-enable push notification fixes."
    echo "RESULT=OK"
    return 0
}

case "$1" in
    run)  cmd_run ;;
    *)    cmd_status ;;
esac
