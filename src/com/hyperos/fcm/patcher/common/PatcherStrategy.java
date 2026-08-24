package com.hyperos.fcm.patcher.common;

import java.io.File;

/**
 * Common Strategy interface for multi-ROM FCM surgical patching.
 */
public interface PatcherStrategy {
    String getStrategyName();
    String getTargetRomDescription();
    String getOsVersion();
    String getAndroidVersion();
    String getRegion();

    PatchResult patchServices(File sourceJar, File destJar, File workDir, File patcherJar);
    PatchResult patchMiuiServices(File sourceJar, File destJar, File workDir, File patcherJar);
}
