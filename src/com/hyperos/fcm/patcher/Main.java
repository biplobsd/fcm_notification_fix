package com.hyperos.fcm.patcher;

import com.hyperos.fcm.patcher.common.DexUtils;
import com.hyperos.fcm.patcher.common.PatchResult;
import com.hyperos.fcm.patcher.common.PatcherStrategy;
import com.hyperos.fcm.patcher.hyperos.os3.android16.cn.Hyperos3A16CnPatcherStrategy;
import com.hyperos.fcm.patcher.miui14.v14.android13.global.Miui14A13GlobalPatcherStrategy;

import java.io.File;
import java.util.HashMap;
import java.util.Map;

public class Main {

    public static void main(String[] args) {
        if (System.getProperty("os.name") == null) {
            System.setProperty("os.name", "Linux");
        }
        if (System.getProperty("os.arch") == null) {
            System.setProperty("os.arch", "aarch64");
        }

        System.out.println("=================================================");
        System.out.println("  Universal HyperOS FCM Multi-DEX Patcher        ");
        System.out.println("  Auto-Aligning On-Device Transactional Engine   ");
        System.out.println("=================================================");

        Map<String, String> params = new HashMap<>();
        for (int i = 0; i < args.length; i++) {
            if (args[i].startsWith("--") && i + 1 < args.length) {
                params.put(args[i].substring(2), args[i + 1]);
                i++;
            }
        }

        String servicesPath = params.get("services");
        String miuiServicesPath = params.get("miui-services");
        String outDirPath = params.get("out-dir");
        String patcherJarPath = params.get("patcher");
        String sdkArg = params.get("sdk");
        String osArg = params.get("os");
        String regionArg = params.get("region");

        if (servicesPath == null || miuiServicesPath == null || outDirPath == null) {
            System.err.println("Usage: dalvikvm -cp patcher.jar com.hyperos.fcm.patcher.Main " +
                "--services <services.jar> --miui-services <miui-services.jar> --out-dir <staging_dir> " +
                "[--patcher <patcher.jar>] [--sdk <api_level>] [--os <hyperos|miui14>] [--region <cn|global>]");
            System.exit(2);
        }

        File servicesSrc = new File(servicesPath);
        File miuiServicesSrc = new File(miuiServicesPath);
        File outDir = new File(outDirPath);
        File patcherJar = patcherJarPath != null ? new File(patcherJarPath) : null;

        if (!servicesSrc.exists() || !servicesSrc.isFile()) {
            System.err.println("[!] ERROR: Source services.jar does not exist: " + servicesPath);
            System.exit(2);
        }

        if (!miuiServicesSrc.exists() || !miuiServicesSrc.isFile()) {
            System.err.println("[!] ERROR: Source miui-services.jar does not exist: " + miuiServicesPath);
            System.exit(2);
        }

        if (!outDir.exists()) {
            outDir.mkdirs();
        }

        File stagedServicesDest = new File(outDir, "services.jar");
        File stagedMiuiDest = new File(outDir, "miui-services.jar");

        System.out.println("[*] Staging Directory: " + outDir.getAbsolutePath());
        System.out.println("[*] Target 1 (AOSP Framework): " + servicesSrc.getAbsolutePath() + " (" + (servicesSrc.length() / 1024 / 1024) + " MB)");
        System.out.println("[*] Target 2 (MIUI Framework): " + miuiServicesSrc.getAbsolutePath() + " (" + (miuiServicesSrc.length() / 1024 / 1024) + " MB)");

        // 1. Resolve Patcher Strategy
        PatcherStrategy strategy = resolveStrategy(servicesSrc, miuiServicesSrc, sdkArg, osArg, regionArg);
        System.out.println("[*] Detected OS:      " + strategy.getOsVersion() + " (" + strategy.getAndroidVersion() + ")");
        System.out.println("[*] Detected Region:  " + strategy.getRegion());
        System.out.println("[*] Active Strategy:  " + strategy.getStrategyName());
        System.out.println("[*] Profile Target:   " + strategy.getTargetRomDescription());
        System.out.println("-------------------------------------------------");

        // 2. Execute Phase 1: services.jar
        System.out.println("[*] Phase 1/2: Processing services.jar...");
        PatchResult v1Result = strategy.patchServices(servicesSrc, stagedServicesDest, outDir, patcherJar);

        // 3. Execute Phase 2: miui-services.jar
        System.out.println("-------------------------------------------------");
        System.out.println("[*] Phase 2/2: Processing miui-services.jar...");
        PatchResult miuiResult = strategy.patchMiuiServices(miuiServicesSrc, stagedMiuiDest, outDir, patcherJar);

        // 4. Multi-Vector Verification Checklist
        System.out.println("=================================================");
        System.out.println("      TRANSACTION VERIFICATION CHECKLIST         ");
        System.out.println("=================================================");
        System.out.println("  [Vector 1] Dynamic FCM Wake Filter (0x20):    " + (v1Result.v1_wake_flag ? "PASS ✓" : "FAIL ✗") +
            (v1Result.v1_note.isEmpty() ? "" : "  (" + v1Result.v1_note + ")"));
        System.out.println("  [Vector 2] Screen-OFF Greeze Thaw Engine:     " + (miuiResult.v2_screenoff_thaw ? "PASS ✓" : "FAIL ✗") +
            (miuiResult.v2_note.isEmpty() ? "" : "  (" + miuiResult.v2_note + ")"));
        System.out.println("  [Vector 3] GMS Quick-Freeze Neutralizer:       " + (miuiResult.v3_gms_quickfreeze ? "PASS ✓" : "FAIL ✗") +
            (miuiResult.v3_note.isEmpty() ? "" : "  (" + miuiResult.v3_note + ")"));
        System.out.println("  [Vector 4] AutoStart C2DM Permission Bypass:   " + (miuiResult.v4_autostart_bypass ? "PASS ✓" : "FAIL ✗") +
            (miuiResult.v4_note.isEmpty() ? "" : "  (" + miuiResult.v4_note + ")"));
        System.out.println("-------------------------------------------------");

        boolean allPassed = v1Result.v1_wake_flag && miuiResult.v2_screenoff_thaw && 
                            miuiResult.v3_gms_quickfreeze && miuiResult.v4_autostart_bypass;

        if (!allPassed) {
            System.err.println("[!] TRANSACTION REJECTED: Not all patch checkpoints passed.");
            if (!v1Result.v1_wake_flag) System.err.println("    [V1] " + v1Result.details);
            if (!miuiResult.isAllMiuiServicesSuccess()) System.err.println("    [V2-4] " + miuiResult.details);
            System.err.println("[!] Cleaning up staged files. Stock system remains 100% untouched.");

            if (stagedServicesDest.exists()) stagedServicesDest.delete();
            if (stagedMiuiDest.exists()) stagedMiuiDest.delete();

            System.exit(1);
        }

        // 5. Validate output files exist and are non-empty (>1MB)
        if (!stagedServicesDest.exists() || stagedServicesDest.length() < 1000000 ||
            !stagedMiuiDest.exists() || stagedMiuiDest.length() < 1000000) {
            System.err.println("[!] ERROR: Output JAR files are missing or incomplete (< 1MB).");
            if (stagedServicesDest.exists()) stagedServicesDest.delete();
            if (stagedMiuiDest.exists()) stagedMiuiDest.delete();
            System.exit(1);
        }

        System.out.println("[✓] TRANSACTION COMMITTED: 100% Patches Verified & Ready for Atomic Swap.");
        System.out.println("    - Staged services.jar: " + stagedServicesDest.length() + " bytes");
        System.out.println("    - Staged miui-services.jar: " + stagedMiuiDest.length() + " bytes");
        System.out.println("=================================================");
        System.exit(0);
    }

    private static PatcherStrategy resolveStrategy(File servicesJar, File miuiServicesJar, String sdkArg, String osArg, String regionArg) {
        int sdk = 0;
        if (sdkArg != null) {
            try {
                sdk = Integer.parseInt(sdkArg);
            } catch (NumberFormatException ignored) {
            }
        }

        boolean isExplicitHyperOS = "hyperos".equalsIgnoreCase(osArg) || (sdk >= 34);
        boolean isExplicitMIUI14 = "miui14".equalsIgnoreCase(osArg) || (sdk == 33);
        boolean isChina = "cn".equalsIgnoreCase(regionArg) || "china".equalsIgnoreCase(regionArg);
        boolean isGlobal = "global".equalsIgnoreCase(regionArg) || "eea".equalsIgnoreCase(regionArg);

        // Bytecode signature inspection
        boolean hasBroadcastController = DexUtils.containerHasClass(servicesJar, "Lcom/android/server/am/BroadcastController;");
        boolean hasDomesticPolicy = DexUtils.containerHasClass(miuiServicesJar, "Lcom/miui/server/greeze/DomesticPolicyManager;");
        boolean hasAms = DexUtils.containerHasClass(servicesJar, "Lcom/android/server/am/ActivityManagerService;");

        // 1. HyperOS Evaluation (Only HyperOS China is implemented)
        if (isExplicitHyperOS || hasBroadcastController || hasDomesticPolicy) {
            if (isGlobal && !isChina && !hasDomesticPolicy) {
                System.err.println("[!] ERROR: HyperOS Global patcher is not available (only HyperOS China is currently supported).");
                System.exit(1);
            }
            return new Hyperos3A16CnPatcherStrategy();
        }

        // 2. Fallback Evaluation (Android 13 / Legacy Frameworks)
        if (isExplicitMIUI14 || hasAms) {
            return new Miui14A13GlobalPatcherStrategy();
        }

        System.err.println("[!] ERROR: Unrecognized framework structure. Supported target: HyperOS China.");
        System.exit(1);
        return null;
    }
}
