#!/system/bin/sh
# ==============================================================================
# HyperOS FCM Notification Fix - Post-OTA Re-Patch Engine
# ==============================================================================
# The module bind-mounts framework jars that were patched against one specific
# firmware build. After an OTA those jars no longer match the rest of the ROM,
# and mounting them is a bootloop. post-fs-data.sh therefore compares the build
# recorded at install time (rom.fingerprint) with the running build and skips
# every mount when they differ, leaving the device on 100% stock framework.
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

FLAG_PENDING="$MODDIR/repatch_pending"
FLAG_RUNNING="$MODDIR/repatch_running"
FLAG_FAILED="$MODDIR/repatch_failed"
FLAG_REBOOT="$MODDIR/repatch_reboot"

SERVICES_LIVE="/system/framework/services.jar"
MIUI_LIVE="/system_ext/framework/miui-services.jar"
[ -f "$MIUI_LIVE" ] || MIUI_LIVE="/system/framework/miui-services.jar"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

current_fp() {
    getprop ro.build.version.incremental
}

stored_fp() {
    cat "$MODDIR/rom.fingerprint" 2>/dev/null
}

# A jar is stock while it does not carry our injected filter class. Framework
# dex entries are stored uncompressed, so the class name is greppable.
is_stock_jar() {
    [ "$(grep -ac FcmWakeFilter "$1" 2>/dev/null)" = "0" ]
}

notify() {
    cmd notification post -S bigtext -t "FCM Notification Fix" fcm_repatch "$1" >/dev/null 2>&1 || true
}

cmd_status() {
    CUR="$(current_fp)"
    STORED="$(stored_fp)"
    [ -z "$STORED" ] && STORED="-"

    MOUNTED=no
    grep -q "framework/miui-services.jar" /proc/mounts 2>/dev/null && MOUNTED=yes

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
    echo "mounted=$MOUNTED"
    echo "last=$LAST"
}

cmd_run() {
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

    # Never patch an already patched jar: that would stack hooks on hooks.
    if ! is_stock_jar "$SERVICES_LIVE" || ! is_stock_jar "$MIUI_LIVE"; then
        log "re-patch aborted: live framework jars are not stock (module overlay still mounted?)"
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

    log "re-patching for firmware $CUR (was $(stored_fp))"

    "$DALVIK_BIN" -Xmx512m \
        -cp "$PATCHER_JAR" \
        com.hyperos.fcm.patcher.Main \
        --services "$SERVICES_LIVE" \
        --miui-services "$MIUI_LIVE" \
        --patcher "$PATCHER_JAR" \
        --out-dir "$STAGE_DIR" >> "$LOG" 2>&1
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

    mkdir -p "$MODDIR/system/framework" "$MODDIR/system_ext/framework" "$MODDIR/system/system_ext/framework"
    cp -f "$STAGE_DIR/services.jar" "$MODDIR/system/framework/services.jar"
    cp -f "$STAGE_DIR/miui-services.jar" "$MODDIR/system_ext/framework/miui-services.jar"
    cp -f "$STAGE_DIR/miui-services.jar" "$MODDIR/system/system_ext/framework/miui-services.jar"

    for f in "$MODDIR/system/framework/services.jar" \
             "$MODDIR/system_ext/framework/miui-services.jar" \
             "$MODDIR/system/system_ext/framework/miui-services.jar"; do
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

    echo "$CUR" > "$MODDIR/rom.fingerprint"
    touch "$MODDIR/wipe_cache_once"
    rm -f "$FLAG_PENDING" "$FLAG_RUNNING"
    touch "$FLAG_REBOOT"
    rm -rf "$STAGE_DIR"

    log "re-patch OK for firmware $CUR - reboot required to mount the new jars"
    notify "Framework re-patched for firmware $CUR. Reboot to re-enable push notification fixes."
    echo "RESULT=OK"
    return 0
}

case "$1" in
    run)  cmd_run ;;
    *)    cmd_status ;;
esac
