package com.hyperos.fcm.patcher;

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
        System.out.println("  HyperOS FCM & GMS Multi-DEX Bytecode Patcher   ");
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

        if (servicesPath == null || miuiServicesPath == null || outDirPath == null) {
            System.err.println("Usage: dalvikvm -cp patcher.jar com.hyperos.fcm.patcher.Main " +
                "--services <services.jar> --miui-services <miui-services.jar> --out-dir <staging_dir> [--patcher <patcher.jar>]");
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
        System.out.println("-------------------------------------------------");

        // 1. Execute Vector 1 Patch (services.jar) with Dynamic FcmWakeFilter
        System.out.println("[*] Phase 1/2: Processing services.jar...");
        ServicesPatcher.PatchResult v1Result = ServicesPatcher.patchServicesJar(servicesSrc, stagedServicesDest, outDir, patcherJar);

        // 2. Execute Vectors 2, 3, 4 Patch (miui-services.jar)
        System.out.println("-------------------------------------------------");
        System.out.println("[*] Phase 2/2: Processing miui-services.jar...");
        MiuiServicesPatcher.PatchResult miuiResult = MiuiServicesPatcher.patchMiuiServicesJar(miuiServicesSrc, stagedMiuiDest, outDir, patcherJar);

        // 3. Multi-Vector Verification Checklist
        System.out.println("=================================================");
        System.out.println("      TRANSACTION VERIFICATION CHECKLIST         ");
        System.out.println("=================================================");
        System.out.println("  [Vector 1] Dynamic FCM Wake Filter Hook:            " + (v1Result.success ? "PASS ✓" : "FAIL ✗"));
        System.out.println("  [Vector 2] DomesticPolicy Screen-OFF Thaw (Greeze): " + (miuiResult.v2_domestic_policy ? "PASS ✓" : "FAIL ✗"));
        System.out.println("  [Vector 3] GMS Quick-Freeze Deadlock Neutralizer:   " + (miuiResult.v3_gms_quickfreeze ? "PASS ✓" : "FAIL ✗"));
        System.out.println("  [Vector 4] AutoStart Modern Stub Bypass for C2DM:   " + (miuiResult.v4_autostart_stub ? "PASS ✓" : "FAIL ✗"));
        System.out.println("-------------------------------------------------");

        boolean allPassed = v1Result.success && miuiResult.isAllSuccess();

        if (!allPassed) {
            System.err.println("[!] TRANSACTION REJECTED: Not all patch checkpoints passed.");
            if (!v1Result.success) System.err.println("    " + v1Result.details);
            if (!miuiResult.isAllSuccess()) System.err.println("    " + miuiResult.details);
            System.err.println("[!] Cleaning up staged files. Stock system remains 100% untouched.");

            if (stagedServicesDest.exists()) stagedServicesDest.delete();
            if (stagedMiuiDest.exists()) stagedMiuiDest.delete();

            System.exit(1);
        }

        // 4. Validate output files exist and are non-empty
        if (!stagedServicesDest.exists() || stagedServicesDest.length() < 1000000 ||
            !stagedMiuiDest.exists() || stagedMiuiDest.length() < 1000000) {
            System.err.println("[!] ERROR: Output JAR files are missing or incomplete.");
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
}
