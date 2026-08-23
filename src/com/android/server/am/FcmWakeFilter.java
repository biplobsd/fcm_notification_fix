package com.android.server.am;

import android.content.ComponentName;
import android.content.Intent;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
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

    private static long sLastModified = -1;
    private static int sCurrentMode = MODE_ALL;
    private static final Set<String> sPackageFilterSet = new HashSet<String>();

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

    private static synchronized boolean isPackageInFilterSet(String pkg) {
        if (pkg == null) return false;
        return sPackageFilterSet.contains(pkg) || sPackageFilterSet.contains(pkg.toLowerCase());
    }

    private static synchronized void checkConfig() {
        try {
            File confFile = new File(CONF_PATH);
            if (!confFile.exists()) {
                if (sLastModified != 0) {
                    sCurrentMode = MODE_ALL;
                    sPackageFilterSet.clear();
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

            sPackageFilterSet.clear();
            sPackageFilterSet.addAll(newFilterSet);
            sCurrentMode = mode;
            sLastModified = modified;
        } catch (Throwable t) {
            // Failsafe fallback: never break push delivery on file read errors
            sLastModified = -1; // Force retry on next attempt
            sCurrentMode = MODE_ALL;
        }
    }
}
