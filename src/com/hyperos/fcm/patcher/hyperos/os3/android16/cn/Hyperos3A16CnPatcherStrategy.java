package com.hyperos.fcm.patcher.hyperos.os3.android16.cn;

import com.hyperos.fcm.patcher.common.PatcherStrategy;
import com.hyperos.fcm.patcher.common.PatchResult;

import java.io.File;

/**
 * Strategy implementation for Xiaomi HyperOS 3.0 (Android 16 / SDK 36) China ROM.
 */
public class Hyperos3A16CnPatcherStrategy implements PatcherStrategy {

    @Override
    public String getStrategyName() {
        return "HyperOS 3.0 China (Android 16 / SDK 36)";
    }

    @Override
    public String getTargetRomDescription() {
        return "Xiaomi HyperOS 3.0 China (BroadcastController + DomesticPolicyManager + ModernStub)";
    }

    @Override
    public String getOsVersion() {
        return "HyperOS 3.0";
    }

    @Override
    public String getAndroidVersion() {
        return "Android 16 (SDK 36)";
    }

    @Override
    public String getRegion() {
        return "China";
    }

    @Override
    public PatchResult patchServices(File sourceJar, File destJar, File workDir, File patcherJar) {
        return Hyperos3A16CnServicesPatcher.patchServicesJar(sourceJar, destJar, workDir, patcherJar);
    }

    @Override
    public PatchResult patchMiuiServices(File sourceJar, File destJar, File workDir, File patcherJar) {
        return Hyperos3A16CnMiuiServicesPatcher.patchMiuiServicesJar(sourceJar, destJar, workDir, patcherJar);
    }
}
