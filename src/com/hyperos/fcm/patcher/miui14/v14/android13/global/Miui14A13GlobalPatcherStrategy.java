package com.hyperos.fcm.patcher.miui14.v14.android13.global;

import com.hyperos.fcm.patcher.common.PatcherStrategy;
import com.hyperos.fcm.patcher.common.PatchResult;

import java.io.File;

/**
 * Strategy implementation for Xiaomi MIUI 14 (Android 13 / SDK 33) Global / EEA ROM.
 */
public class Miui14A13GlobalPatcherStrategy implements PatcherStrategy {

    @Override
    public String getStrategyName() {
        return "MIUI 14 Global (Android 13 / SDK 33)";
    }

    @Override
    public String getTargetRomDescription() {
        return "Xiaomi MIUI 14 Global/EEA (ActivityManagerService + GreezeManagerService Screen-OFF Thaw)";
    }

    @Override
    public String getOsVersion() {
        return "MIUI 14";
    }

    @Override
    public String getAndroidVersion() {
        return "Android 13 (SDK 33)";
    }

    @Override
    public String getRegion() {
        return "Global";
    }

    @Override
    public PatchResult patchServices(File sourceJar, File destJar, File workDir, File patcherJar) {
        return Miui14A13GlobalServicesPatcher.patchServicesJar(sourceJar, destJar, workDir, patcherJar);
    }

    @Override
    public PatchResult patchMiuiServices(File sourceJar, File destJar, File workDir, File patcherJar) {
        return Miui14A13GlobalMiuiServicesPatcher.patchMiuiServicesJar(sourceJar, destJar, workDir, patcherJar);
    }
}
