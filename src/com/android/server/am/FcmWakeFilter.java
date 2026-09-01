package com.android.server.am;

import android.content.ComponentName;
import android.content.Intent;
import android.os.SystemClock;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/**
 * Dynamic FCM Wake-on-Push Filter for HyperOS / Android 16.
 * Injected into services.jar to provide zero-reboot runtime control over
 * which apps are permitted to wake from stopped=true state on incoming C2DM pushes.
 *
 * Supported Modes (/data/system/fcm_wake.conf):
 * - MODE=ALL (Default): Injects 0x20 into all C2DM broadcasts.
 * - MODE=WHITELIST: Injects 0x20 ONLY for packages explicitly listed in conf.
 * - MODE=BLACKLIST: Injects 0x20 for all packages EXCEPT those listed in conf.
 */
public class FcmWakeFilter {

    public static final String CONF_PATH = "/data/system/fcm_wake.conf";
    public static final int FLAG_INCLUDE_STOPPED_PACKAGES = 0x00000020; // Intent.FLAG_INCLUDE_STOPPED_PACKAGES

    public static final int MODE_ALL = 0;
    public static final int MODE_WHITELIST = 1;
    public static final int MODE_BLACKLIST = 2;

    private static final String GMS_PKG = "com.google.android.gms";
    private static final ThreadLocal<String> sPendingCallee = new ThreadLocal<String>();

    private static volatile long sLastModified = -1;
    private static volatile int sCurrentMode = MODE_ALL;
    private static volatile Set<String> sPackageFilterSet = Collections.emptySet();
    private static volatile boolean sGroupAlertFixEnabled = true;
    private static volatile boolean sUnthrottleVibEnabled = true;
    private static volatile long sLastCheckTimestamp = 0;
    private static final long CONFIG_CHECK_INTERVAL_MS = 5000;

    /**
     * Hooked in NotificationAttentionHelper.shouldMuteNotificationLocked(...)
     * Resolves the result of Notification.suppressAlertingDueToGrouping().
     * If sGroupAlertFixEnabled is true, bypasses group muting (returns false).
     * If sGroupAlertFixEnabled is false, preserves stock Android suppression logic.
     */
    public static boolean shouldSuppressGrouping(boolean stockSuppress) {
        checkConfig();
        if (sGroupAlertFixEnabled) {
            return false; // Do not mute grouped notifications
        }
        return stockSuppress;
    }

    /**
     * Hooked at the head of VibRateLimiter.shouldRateLimitVib(...) on MIUI / HyperOS.
     * Returns true if the 15-second vibration throttle should be bypassed (always allowed to vibrate).
     */
    public static boolean isVibThrottleBypassEnabled() {
        checkConfig();
        return sUnthrottleVibEnabled;
    }

    /**
     * Hooked at the head of GreezeManagerService.isRestrictBackgroundAction(...) on MIUI 14.
     * Records the target callee process name in a thread-local for subsequent isNeedAllowRequest check.
     */
    public static void noteGreezeCallee(String calleeName) {
        sPendingCallee.set(calleeName);
    }

    /**
     * Hooked at the head of GreezeManagerService.isNeedAllowRequest(...) on MIUI 14.
     * Returns:
     *   1  -> Allow thaw (stock logic then invokes thawUid)
     *   0  -> Deny thaw (remains frozen)
     *  -1  -> Not an FCM wake attempt from GMS, fall through to stock policy
     */
    public static int checkGreezeAllowRequest(String callerPkgName) {
        String callee = sPendingCallee.get();
        sPendingCallee.remove();

        if (!GMS_PKG.equals(callerPkgName)) {
            return -1;
        }
        checkConfig();
        if (sCurrentMode == MODE_ALL) {
            return 1;
        }
        if (callee == null || callee.isEmpty()) {
            return sCurrentMode == MODE_BLACKLIST ? 1 : 0;
        }
        boolean inSet = isPackageInFilterSet(basePackage(callee));
        if (sCurrentMode == MODE_WHITELIST) {
            return inSet ? 1 : 0;
        }
        return inSet ? 0 : 1; // MODE_BLACKLIST
    }

    /**
     * Extracts base package name from a potential process name (e.g. "com.foo.bar:remote" -> "com.foo.bar").
     */
    public static String basePackage(String processName) {
        if (processName == null) return null;
        int i = processName.indexOf(':');
        return i > 0 ? processName.substring(0, i) : processName;
    }

    /**
     * Called from BroadcastController.broadcastIntentLockedTraced(...)
     * on every broadcast delivery attempt.
     */
    public static void applyFlags(Intent intent) {
        if (intent == null) {
            return;
        }

        String action = intent.getAction();
        if (action == null || !action.equals("com.google.android.c2dm.intent.RECEIVE")) {
            return;
        }

        // Fast sync configuration from /data/system/fcm_wake.conf
        checkConfig();

        if (sCurrentMode == MODE_ALL) {
            intent.addFlags(FLAG_INCLUDE_STOPPED_PACKAGES);
            return;
        }

        String targetPkg = getTargetPackage(intent);

        if (targetPkg == null || targetPkg.isEmpty()) {
            // No explicit package targeted, allow delivery if in blacklist mode
            if (sCurrentMode == MODE_BLACKLIST) {
                intent.addFlags(FLAG_INCLUDE_STOPPED_PACKAGES);
            }
            return;
        }

        boolean inSet = isPackageInFilterSet(targetPkg);

        if (sCurrentMode == MODE_WHITELIST) {
            // Only packages in the whitelist get the wake flag
            if (inSet) {
                intent.addFlags(FLAG_INCLUDE_STOPPED_PACKAGES);
            }
        } else if (sCurrentMode == MODE_BLACKLIST) {
            // All packages get the wake flag EXCEPT those in the blacklist
            if (!inSet) {
                intent.addFlags(FLAG_INCLUDE_STOPPED_PACKAGES);
            }
        }
    }

    /**
     * Called from DomesticPolicyManager / GreezeManagerService
     * during Screen-OFF broadcast evaluation.
     *
     * Returns:
     *   1  -> C2DM broadcast ALLOWED to thaw process in Screen-OFF
     *   0  -> C2DM broadcast DENIED thaw in Screen-OFF (stays frozen)
     *  -1  -> Non-C2DM broadcast (defer to original Greeze domestic policy)
     */
    public static int checkGreezeBroadcastAllow(String action, String calleePkgName) {
        if (action == null || !action.equals("com.google.android.c2dm.intent.RECEIVE")) {
            return -1; // Not C2DM, pass through to stock Greeze policy
        }

        // Fast sync configuration from /data/system/fcm_wake.conf
        checkConfig();

        if (sCurrentMode == MODE_ALL) {
            return 1; // Allow all C2DM thaws
        }

        String targetPkg = basePackage(calleePkgName);
        if (targetPkg != null) {
            targetPkg = targetPkg.trim();
        }

        if (targetPkg == null || targetPkg.isEmpty()) {
            return sCurrentMode == MODE_BLACKLIST ? 1 : 0;
        }

        boolean inSet = isPackageInFilterSet(targetPkg);

        if (sCurrentMode == MODE_WHITELIST) {
            return inSet ? 1 : 0;
        } else if (sCurrentMode == MODE_BLACKLIST) {
            return !inSet ? 1 : 0;
        }

        return 1;
    }

    public static boolean isAllowBroadcast(String action, String calleePkgName) {
        int res = checkGreezeBroadcastAllow(action, calleePkgName);
        return res > 0;
    }

    public static boolean isAllowBroadcast(Intent intent, String calleePkgName) {
        if (intent == null) {
            return false;
        }
        String pkg = calleePkgName;
        if (pkg == null || pkg.isEmpty()) {
            pkg = getTargetPackage(intent);
        }
        return isAllowBroadcast(intent.getAction(), pkg);
    }

    public static boolean isAllowBroadcast(Intent intent) {
        return isAllowBroadcast(intent, null);
    }

    public static boolean isAllowBroadcast() {
        checkConfig();
        return sCurrentMode == MODE_ALL;
    }

    public static String getTargetPackage(Intent intent) {
        if (intent == null) return null;
        String targetPkg = intent.getPackage();
        if (targetPkg == null) {
            ComponentName cmp = intent.getComponent();
            if (cmp != null) {
                targetPkg = cmp.getPackageName();
            }
        }
        if (targetPkg == null && intent.getSelector() != null) {
            targetPkg = intent.getSelector().getPackage();
            if (targetPkg == null && intent.getSelector().getComponent() != null) {
                targetPkg = intent.getSelector().getComponent().getPackageName();
            }
        }
        if (targetPkg != null) {
            targetPkg = targetPkg.trim();
        }
        return targetPkg;
    }

    public static boolean isPackageInFilterSet(String pkg) {
        if (pkg == null) return false;
        Set<String> set = sPackageFilterSet;
        return set.contains(pkg) || set.contains(pkg.toLowerCase());
    }

    private static void checkConfig() {
        long now = SystemClock.elapsedRealtime();
        if (now - sLastCheckTimestamp < CONFIG_CHECK_INTERVAL_MS && sLastModified >= 0) {
            return;
        }
        sLastCheckTimestamp = now;
        syncConfigInternal();
    }

    private static synchronized void syncConfigInternal() {
        try {
            File confFile = new File(CONF_PATH);
            if (!confFile.exists()) {
                if (sLastModified != 0) {
                    sCurrentMode = MODE_ALL;
                    sPackageFilterSet = Collections.emptySet();
                    sLastModified = 0;
                }
                return;
            }

            long modified = confFile.lastModified();
            if (modified == sLastModified && sLastModified > 0) {
                return; // In-memory cache is valid, 0 disk I/O
            }

            Set<String> newFilterSet = new HashSet<String>();
            int mode = MODE_ALL;
            boolean groupAlertFix = true;
            boolean unthrottleVib = true;

            BufferedReader reader = null;
            try {
                reader = new BufferedReader(new FileReader(confFile));
                String line;
                while ((line = reader.readLine()) != null) {
                    line = line.trim();
                    if (line.isEmpty() || line.startsWith("#")) {
                        continue;
                    }
                    if (line.equalsIgnoreCase("MODE=WHITELIST") || line.equalsIgnoreCase("MODE=SELECTED")) {
                        mode = MODE_WHITELIST;
                    } else if (line.equalsIgnoreCase("MODE=BLACKLIST") || line.equalsIgnoreCase("MODE=BLOCK")) {
                        mode = MODE_BLACKLIST;
                    } else if (line.equalsIgnoreCase("MODE=ALL")) {
                        mode = MODE_ALL;
                    } else if (line.equalsIgnoreCase("GROUP_ALERT_FIX=0") || line.equalsIgnoreCase("GROUP_ALERT_FIX=FALSE")) {
                        groupAlertFix = false;
                    } else if (line.equalsIgnoreCase("GROUP_ALERT_FIX=1") || line.equalsIgnoreCase("GROUP_ALERT_FIX=TRUE")) {
                        groupAlertFix = true;
                    } else if (line.equalsIgnoreCase("UNTHROTTLE_VIB=0") || line.equalsIgnoreCase("UNTHROTTLE_VIB=FALSE") || line.equalsIgnoreCase("UNTHROTTLE_VIBRATION=0")) {
                        unthrottleVib = false;
                    } else if (line.equalsIgnoreCase("UNTHROTTLE_VIB=1") || line.equalsIgnoreCase("UNTHROTTLE_VIB=TRUE") || line.equalsIgnoreCase("UNTHROTTLE_VIBRATION=1")) {
                        unthrottleVib = true;
                    } else if (!line.contains("=")) {
                        newFilterSet.add(line);
                        newFilterSet.add(line.toLowerCase());
                    }
                }
            } finally {
                if (reader != null) {
                    try {
                        reader.close();
                    } catch (Throwable ignored) {
                    }
                }
            }

            sPackageFilterSet = Collections.unmodifiableSet(newFilterSet);
            sCurrentMode = mode;
            sGroupAlertFixEnabled = groupAlertFix;
            sUnthrottleVibEnabled = unthrottleVib;
            sLastModified = modified;
        } catch (Throwable t) {
            // Failsafe fallback: never break push delivery on file read errors
            sLastModified = -1; // Force retry on next attempt
            sCurrentMode = MODE_ALL;
            sGroupAlertFixEnabled = true;
            sUnthrottleVibEnabled = true;
        }
    }
}
