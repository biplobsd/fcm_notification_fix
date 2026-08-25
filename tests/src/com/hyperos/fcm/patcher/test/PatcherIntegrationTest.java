package com.hyperos.fcm.patcher.test;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * Automated Multi-ROM Integration Test Runner for FCM Bytecode Patcher.
 * Verifies patcher execution, transactional commit, and 4-byte DEX alignment.
 */
public class PatcherIntegrationTest {

    public static class TestResult {
        public String archetypeId;
        public boolean patchSuccess;
        public boolean dex4ByteAligned;
        public String details = "";

        public boolean isAllPassed() {
            return patchSuccess && dex4ByteAligned;
        }
    }

    public static void main(String[] args) {
        System.out.println("=================================================");
        System.out.println("  Universal FCM Patcher Automated Test Suite     ");
        System.out.println("=================================================");

        String fixturesPath = args.length > 0 ? args[0] : "tests/fixtures";
        String patcherJarPath = args.length > 1 ? args[1] : "module/tools/patcher.jar";
        String outDirPath = args.length > 2 ? args[2] : "/tmp/fcm_test_runs";

        File fixturesDir = new File(fixturesPath);
        File patcherJar = new File(patcherJarPath);
        File outBaseDir = new File(outDirPath);
        outBaseDir.mkdirs();

        List<File> targetFixtureDirs = new ArrayList<>();
        if (fixturesDir.exists() && fixturesDir.isDirectory()) {
            discoverFixturesRecursively(fixturesDir, targetFixtureDirs);
        }

        if (targetFixtureDirs.isEmpty()) {
            System.err.println("[!] No test fixture directories found in " + fixturesDir.getAbsolutePath());
            System.exit(1);
        }

        System.out.println("[*] Discovered " + targetFixtureDirs.size() + " versioned test fixture ROM(s) to verify.");
        List<TestResult> results = new ArrayList<>();

        for (File fixDir : targetFixtureDirs) {
            String fixtureName = fixturesDir.exists() && fixDir.getAbsolutePath().startsWith(fixturesDir.getAbsolutePath()) ?
                fixDir.getAbsolutePath().substring(fixturesDir.getAbsolutePath().length()).replaceAll("^[\\\\/]+", "") :
                fixDir.getName();

            File servicesSrc = new File(fixDir, "services.jar");
            File miuiServicesSrc = new File(fixDir, "miui-services.jar");

            if (!servicesSrc.exists() || !miuiServicesSrc.exists()) {
                continue;
            }

            System.out.println("-------------------------------------------------");
            System.out.println(">>> TESTING FIXTURE: " + fixtureName + " <<<");
            String safeOutName = fixtureName.replaceAll("[^a-zA-Z0-9_.-]", "_");
            File stageOut = new File(outBaseDir, "stage_" + safeOutName);
            stageOut.mkdirs();

            TestResult tr = runFixtureTest(fixtureName, servicesSrc, miuiServicesSrc, patcherJar, stageOut);
            results.add(tr);
        }

        // Summary Report
        System.out.println("\n=================================================");
        System.out.println("             INTEGRATION TEST REPORT             ");
        System.out.println("=================================================");
        int passed = 0;
        int failed = 0;

        for (TestResult tr : results) {
            String status = tr.isAllPassed() ? "[PASS ✓]" : "[FAIL ✗]";
            if (tr.isAllPassed()) passed++; else failed++;

            System.out.println(String.format("%-10s %-38s | Aligned: %s",
                status, tr.archetypeId,
                tr.dex4ByteAligned ? "YES" : "NO"));

            if (!tr.isAllPassed()) {
                System.err.println("   -> Failure details: " + tr.details);
            }
        }

        System.out.println("=================================================");
        System.out.println(" Total: " + results.size() + " | Passed: " + passed + " | Failed: " + failed);
        System.out.println("=================================================");

        if (failed > 0) {
            System.exit(1);
        }
        System.exit(0);
    }

    private static void discoverFixturesRecursively(File dir, List<File> accumulator) {
        if (dir == null || !dir.exists() || !dir.isDirectory()) return;
        File s = new File(dir, "services.jar");
        File m = new File(dir, "miui-services.jar");
        if (s.exists() && s.isFile() && m.exists() && m.isFile()) {
            accumulator.add(dir);
            return;
        }
        File[] subs = dir.listFiles(File::isDirectory);
        if (subs != null) {
            for (File sub : subs) {
                discoverFixturesRecursively(sub, accumulator);
            }
        }
    }

    private static TestResult runFixtureTest(String archetypeId, File servicesSrc, File miuiServicesSrc, File patcherJar, File stageOut) {
        TestResult tr = new TestResult();
        tr.archetypeId = archetypeId;

        try {
            // Determine OS & Region parameters (read version.json if present)
            String osArg = "hyperos";
            String regionArg = "cn";
            String sdkArg = "36";

            File metaFile = new File(servicesSrc.getParentFile(), "version.json");
            if (metaFile.exists()) {
                try {
                    String metaContent = new String(java.nio.file.Files.readAllBytes(metaFile.toPath()), StandardCharsets.UTF_8);
                    if (metaContent.contains("\"os\": \"miui14\"") || metaContent.contains("\"os\":\"miui14\"")) osArg = "miui14";
                    if (metaContent.contains("\"region\": \"global\"") || metaContent.contains("\"region\":\"global\"")) regionArg = "global";
                    if (metaContent.contains("\"sdk\": 33") || metaContent.contains("\"sdk\":33")) sdkArg = "33";
                    if (metaContent.contains("\"sdk\": 34") || metaContent.contains("\"sdk\":34")) sdkArg = "34";
                    if (metaContent.contains("\"sdk\": 35") || metaContent.contains("\"sdk\":35")) sdkArg = "35";
                    if (metaContent.contains("\"sdk\": 36") || metaContent.contains("\"sdk\":36")) sdkArg = "36";
                } catch (Exception ignored) {}
            }

            // Run Patcher Main via ProcessBuilder
            List<String> cmd = new ArrayList<>();
            cmd.add("java");
            cmd.add("-cp");
            cmd.add(System.getProperty("java.class.path"));
            cmd.add("com.hyperos.fcm.patcher.Main");
            cmd.add("--services"); cmd.add(servicesSrc.getAbsolutePath());
            cmd.add("--miui-services"); cmd.add(miuiServicesSrc.getAbsolutePath());
            cmd.add("--out-dir"); cmd.add(stageOut.getAbsolutePath());
            cmd.add("--patcher"); cmd.add(patcherJar.getAbsolutePath());
            cmd.add("--os"); cmd.add(osArg);
            cmd.add("--region"); cmd.add(regionArg);
            cmd.add("--sdk"); cmd.add(sdkArg);

            ProcessBuilder pb = new ProcessBuilder(cmd);
            pb.inheritIO();
            Process proc = pb.start();
            int exitCode = proc.waitFor();

            if (exitCode != 0) {
                tr.patchSuccess = false;
                tr.details += "Patcher rejected transaction (exit code " + exitCode + "). ";
                return tr;
            }
            tr.patchSuccess = true;

            File patchedServices = new File(stageOut, "services.jar");
            File patchedMiuiServices = new File(stageOut, "miui-services.jar");

            if (!patchedServices.exists() || !patchedMiuiServices.exists()) {
                tr.patchSuccess = false;
                tr.details += "Output JARs missing. ";
                return tr;
            }

            // Verify 4-Byte DEX Offset Alignment in ZIP
            tr.dex4ByteAligned = checkZipDexAlignment(patchedServices) && checkZipDexAlignment(patchedMiuiServices);
            if (!tr.dex4ByteAligned) {
                tr.details += "DEX alignment check failed (SIGBUS risk on ART). ";
            }

        } catch (Exception e) {
            tr.patchSuccess = false;
            tr.details += "Exception during test: " + e.getMessage() + " ";
        }

        return tr;
    }

    private static boolean checkZipDexAlignment(File jarFile) {
        try (RandomAccessFile raf = new RandomAccessFile(jarFile, "r")) {
            long fileLength = raf.length();
            long pos = 0;

            while (pos < fileLength - 30) {
                raf.seek(pos);
                int sig = Integer.reverseBytes(raf.readInt());
                if (sig == 0x04034b50) { // Local File Header Signature
                    raf.seek(pos + 8);
                    short compressionMethod = Short.reverseBytes(raf.readShort());
                    raf.seek(pos + 26);
                    int nameLen = Short.reverseBytes(raf.readShort()) & 0xffff;
                    int extraLen = Short.reverseBytes(raf.readShort()) & 0xffff;

                    byte[] nameBytes = new byte[nameLen];
                    raf.readFully(nameBytes);
                    String fileName = new String(nameBytes, StandardCharsets.UTF_8);

                    long dataOffset = pos + 30 + nameLen + extraLen;
                    if (fileName.endsWith(".dex")) {
                        if (compressionMethod != 0) {
                            System.err.println("[!] DEX file not STORED (uncompressed): " + fileName);
                            return false;
                        }
                        if (dataOffset % 4 != 0) {
                            System.err.println("[!] DEX file not 4-byte aligned: " + fileName + " at offset " + dataOffset);
                            return false;
                        }
                    }
                    raf.seek(pos + 18);
                    long compSize = Integer.reverseBytes(raf.readInt()) & 0xffffffffL;
                    pos = dataOffset + compSize;
                } else {
                    pos++;
                }
            }
            return true;
        } catch (Exception e) {
            System.err.println("[!] Error checking DEX alignment: " + e.getMessage());
            return false;
        }
    }
}
