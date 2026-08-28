package com.android.server.am;

import android.content.ComponentName;
import android.content.Intent;
import android.os.SystemClock;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

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
    private static volatile long sLastCheckTimestamp = 0;
    private static final long CONFIG_CHECK_INTERVAL_MS = 5000;

    // ---- Notification-sound grace period ----------------------------------
    // A stopped/frozen app woken by an allowed C2DM push has its process (re)started
    // by FLAG_INCLUDE_STOPPED_PACKAGES, but MIUI's greezer re-freezes it within a
    // few hundred ms. Banner and vibration are emitted by system_server and survive,
    // but a custom notification sound (a content:// URI served by the app itself)
    // needs the app's process alive while RingtonePlayer reads it - so it is lost.
    // We hold the callee uid thawed for a short window after an allowed push,
    // mirroring the ROM's own audio-focus thaw (GreezeManagerService.checkAudioFocus).
    // Config: GRACE_MS=<ms> in fcm_wake.conf (0 disables). Default 3000, capped 30000.
    private static final long DEFAULT_GRACE_MS = 3000;
    private static final long MAX_GRACE_MS = 30000;
    private static final long GRACE_STEP_MS = 500;
    private static volatile long sGraceMs = DEFAULT_GRACE_MS;

    private static final String GREEZE_CLASS = "com.miui.server.greeze.GreezeManagerService";
    private static final int GREEZE_THAW_FLAG = 1000; // same reason flag the ROM uses
    private static volatile boolean sGraceResolved = false;
    private static volatile boolean sGraceUnavailable = false;
    private static Method sGetInstance;
    private static Method sGetUidByPkg;
    private static Method sThawUidAsync;
    private static Method sIsUidFrozen; // optional: skip thaw when the app is already alive
    private static volatile ScheduledExecutorService sGraceExec;
    private static final ConcurrentHashMap<Integer, GraceState> sGrace = new ConcurrentHashMap<Integer, GraceState>();

    // Per-uid grace state: a deadline (elapsedRealtime by which pulsing may stop)
    // that each new push extends, and a single-worker flag so concurrent pushes
    // never schedule overlapping pulse trains for the same uid.
    private static final class GraceState {
        final AtomicLong deadline = new AtomicLong(0L);
        final AtomicBoolean running = new AtomicBoolean(false);
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
            scheduleGraceThaw(getTargetPackage(intent));
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
                scheduleGraceThaw(targetPkg);
            }
        } else if (sCurrentMode == MODE_BLACKLIST) {
            // All packages get the wake flag EXCEPT those in the blacklist
            if (!inSet) {
                intent.addFlags(FLAG_INCLUDE_STOPPED_PACKAGES);
                scheduleGraceThaw(targetPkg);
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

        String targetPkg = basePackage(calleePkgName);
        if (targetPkg != null) {
            targetPkg = targetPkg.trim();
        }

        if (sCurrentMode == MODE_ALL) {
            scheduleGraceThaw(targetPkg);
            return 1; // Allow all C2DM thaws
        }

        if (targetPkg == null || targetPkg.isEmpty()) {
            return sCurrentMode == MODE_BLACKLIST ? 1 : 0;
        }

        boolean inSet = isPackageInFilterSet(targetPkg);
        boolean allow;
        if (sCurrentMode == MODE_WHITELIST) {
            allow = inSet;
        } else if (sCurrentMode == MODE_BLACKLIST) {
            allow = !inSet;
        } else {
            allow = true;
        }
        if (allow) {
            scheduleGraceThaw(targetPkg);
        }
        return allow ? 1 : 0;
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
                    sGraceMs = DEFAULT_GRACE_MS;
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
            sGraceMs = DEFAULT_GRACE_MS;

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
                    } else if (line.regionMatches(true, 0, "GRACE_MS=", 0, 9)) {
                        try {
                            long g = Long.parseLong(line.substring(9).trim());
                            if (g < 0) g = 0;
                            if (g > MAX_GRACE_MS) g = MAX_GRACE_MS;
                            sGraceMs = g;
                        } catch (NumberFormatException ignored) {
                        }
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
            sLastModified = modified;
        } catch (Throwable t) {
            // Failsafe fallback: never break push delivery on file read errors
            sLastModified = -1; // Force retry on next attempt
            sCurrentMode = MODE_ALL;
        }
    }

    /**
     * Keep the callee uid thawed for a short window after an allowed C2DM push so
     * a custom notification sound (a content:// URI served by the app) can be read
     * while its process is alive. Fully guarded: any failure disables the feature
     * silently and never affects push delivery.
     *
     * Each push extends the uid's deadline to now + graceMs, so back-to-back
     * notifications each get a full window rather than the tail of the first one.
     * A single worker per uid pulses until that (possibly extended) deadline, so
     * repeat pushes never stack overlapping pulse trains.
     */
    static void scheduleGraceThaw(String pkg) {
        try {
            final long graceMs = sGraceMs;
            if (graceMs <= 0) return;
            if (pkg == null) return;
            pkg = pkg.trim();
            if (pkg.isEmpty() || GMS_PKG.equals(pkg)) return;
            if (!ensureGraceReflection()) return;

            Object svc = sGetInstance.invoke(null);
            if (svc == null) return;

            Object uidObj = sGetUidByPkg.invoke(svc, pkg);
            if (!(uidObj instanceof Integer)) return;
            final int uid = ((Integer) uidObj).intValue();
            if (uid <= 0) return;

            Integer key = Integer.valueOf(uid);
            GraceState st = sGrace.get(key);
            if (st == null) {
                GraceState fresh = new GraceState();
                GraceState prev = sGrace.putIfAbsent(key, fresh);
                st = (prev != null) ? prev : fresh;
            }

            // Extend the deadline to the later of the current one and now+graceMs.
            long target = SystemClock.elapsedRealtime() + graceMs;
            long cur;
            do {
                cur = st.deadline.get();
                if (cur >= target) break;
            } while (!st.deadline.compareAndSet(cur, target));

            // Start a worker only if none is already pulsing this uid.
            if (st.running.compareAndSet(false, true)) {
                graceExecutor().schedule(new GraceWorker(uid, svc, st), 0, TimeUnit.MILLISECONDS);
            }
        } catch (Throwable ignored) {
            // Never let the grace path break broadcast handling.
        }
    }

    /**
     * Thaws one uid every GRACE_STEP_MS until its deadline passes, then stops -
     * re-checking once after clearing the running flag so a push that extended the
     * deadline in the same instant is not lost. Exactly one worker runs per uid.
     */
    private static final class GraceWorker implements Runnable {
        private final int uid;
        private final Object svc;
        private final GraceState st;

        GraceWorker(int uid, Object svc, GraceState st) {
            this.uid = uid;
            this.svc = svc;
            this.st = st;
        }

        public void run() {
            try {
                // Skip the thaw when the app is already alive: only a frozen uid
                // needs waking to serve its sound URI.
                boolean thaw = true;
                if (sIsUidFrozen != null) {
                    Object fz = sIsUidFrozen.invoke(svc, Integer.valueOf(uid));
                    if (fz instanceof Boolean && !((Boolean) fz).booleanValue()) {
                        thaw = false;
                    }
                }
                if (thaw) {
                    sThawUidAsync.invoke(svc, Integer.valueOf(uid), Integer.valueOf(GREEZE_THAW_FLAG), "fcm_sound_grace");
                }
            } catch (Throwable ignored) {
            }

            if (SystemClock.elapsedRealtime() < st.deadline.get()) {
                graceExecutor().schedule(this, GRACE_STEP_MS, TimeUnit.MILLISECONDS);
                return;
            }
            // Deadline reached: stop, then re-check for a concurrent extension.
            st.running.set(false);
            if (SystemClock.elapsedRealtime() < st.deadline.get()
                    && st.running.compareAndSet(false, true)) {
                graceExecutor().schedule(this, GRACE_STEP_MS, TimeUnit.MILLISECONDS);
            }
        }
    }

    private static boolean ensureGraceReflection() {
        if (sGraceResolved) return !sGraceUnavailable;
        synchronized (FcmWakeFilter.class) {
            if (sGraceResolved) return !sGraceUnavailable;
            try {
                Class<?> cls = Class.forName(GREEZE_CLASS);
                sGetInstance = cls.getMethod("getInstance");
                sGetUidByPkg = cls.getMethod("getUidByPackageName", String.class);
                sThawUidAsync = cls.getMethod("thawUidAsync", int.class, int.class, String.class);
                try {
                    sIsUidFrozen = cls.getMethod("isUidFrozen", int.class);
                } catch (Throwable ignoredFrozen) {
                    sIsUidFrozen = null; // guard is optional; without it we simply always thaw
                }
                sGraceUnavailable = false;
            } catch (Throwable t) {
                sGraceUnavailable = true;
            }
            sGraceResolved = true;
        }
        return !sGraceUnavailable;
    }

    private static ScheduledExecutorService graceExecutor() {
        ScheduledExecutorService exec = sGraceExec;
        if (exec != null) return exec;
        synchronized (FcmWakeFilter.class) {
            if (sGraceExec == null) {
                sGraceExec = Executors.newSingleThreadScheduledExecutor(new ThreadFactory() {
                    public Thread newThread(Runnable r) {
                        Thread t = new Thread(r, "fcm-sound-grace");
                        t.setDaemon(true);
                        return t;
                    }
                });
            }
            return sGraceExec;
        }
    }
}
