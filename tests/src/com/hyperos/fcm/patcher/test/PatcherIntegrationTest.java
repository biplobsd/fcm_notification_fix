package com.hyperos.fcm.patcher.test;

import com.android.tools.smali.dexlib2.DexFileFactory;
import com.android.tools.smali.dexlib2.Opcode;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MultiDexContainer;
import com.android.tools.smali.dexlib2.iface.instruction.Instruction;
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction;
import com.android.tools.smali.dexlib2.iface.reference.MethodReference;
import com.android.tools.smali.dexlib2.iface.reference.Reference;
import com.hyperos.fcm.patcher.common.LinkageVerifier;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * Automated Multi-ROM Integration Test Runner for FCM Bytecode Patcher.
 * Verifies patcher execution, transactional commit, 4-byte DEX alignment,
 * bytecode linkage & register safety, and semantic hook invariants.
 */
public class PatcherIntegrationTest {

    public static class TestResult {
        public String archetypeId;
        public boolean patchSuccess;
        public boolean dex4ByteAligned;
        public boolean linkageVerified;
        public boolean semanticVerified;
        public String details = "";

        public boolean isAllPassed() {
            return patchSuccess && dex4ByteAligned && linkageVerified && semanticVerified;
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

            System.out.println(String.format("%-10s %-32s | Aligned: %s | Linkage: %s | Semantics: %s",
                status, tr.archetypeId,
                tr.dex4ByteAligned ? "YES" : "NO",
                tr.linkageVerified ? "PASS" : "FAIL",
                tr.semanticVerified ? "PASS" : "FAIL"));

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
        if (s.exists() && m.exists()) {
            accumulator.add(dir);
            return;
        }
        File[] children = dir.listFiles();
        if (children != null) {
            for (File c : children) {
                if (c.isDirectory()) {
                    discoverFixturesRecursively(c, accumulator);
                }
            }
        }
    }

    private static TestResult runFixtureTest(String archetypeId, File servicesSrc, File miuiServicesSrc, File patcherJar, File stageOut) {
        TestResult tr = new TestResult();
        tr.archetypeId = archetypeId;

        try {
            // Infer OS profile arguments from directory path
            String osArg = "hyperos3";
            String regionArg = "cn";
            String sdkArg = "36";

            if (archetypeId.contains("V14") || archetypeId.contains("TKUMIXM")) {
                osArg = "miui14";
                regionArg = "global";
                sdkArg = "33";
            }

            // Execute patcher via Java sub-process
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

            // Verify 4-Byte DEX Offset Alignment & Uncompressed Storage in ZIP
            tr.dex4ByteAligned = checkZipDexAlignment(patchedServices) && checkZipDexAlignment(patchedMiuiServices);
            if (!tr.dex4ByteAligned) {
                tr.details += "DEX alignment/storage check failed (SIGBUS risk on ART). ";
            }

            // Verify Bytecode Linkage, Register Bounds, Duplicate Classes, and 64K Tables
            tr.linkageVerified = LinkageVerifier.verifyJarLinkage(patchedServices, "Lcom/android/server/am/FcmWakeFilter") &&
                                 LinkageVerifier.verifyJarLinkage(patchedMiuiServices, "Lcom/android/server/am/FcmWakeFilter");
            if (!tr.linkageVerified) {
                tr.details += "Bytecode linkage/structural integrity check failed. ";
            }

            // Verify Semantic Vector Hook Invariants
            tr.semanticVerified = verifySemanticInvariants(patchedServices, patchedMiuiServices, archetypeId, tr);
            if (!tr.semanticVerified) {
                tr.details += "Semantic vector verification failed. ";
            }

        } catch (Exception e) {
            tr.patchSuccess = false;
            tr.details += "Exception during test: " + e.getMessage() + " ";
        }

        return tr;
    }

    private static boolean verifySemanticInvariants(File servicesJar, File miuiServicesJar, String archetypeId, TestResult tr) {
        try {
            MultiDexContainer<? extends DexBackedDexFile> servicesContainer =
                DexFileFactory.loadDexContainer(servicesJar, Opcodes.getDefault());
            MultiDexContainer<? extends DexBackedDexFile> miuiContainer =
                DexFileFactory.loadDexContainer(miuiServicesJar, Opcodes.getDefault());

            boolean isHyperos = archetypeId.contains("OS") || archetypeId.contains("WNVCNXM") ||
                                archetypeId.contains("WOKCNXM") || archetypeId.contains("WOLCNXM");

            boolean foundVector1 = false;
            boolean foundVector2 = false;
            boolean foundVector3 = false;
            boolean foundVector4 = false;
            boolean foundVector17 = false;
            boolean foundVector18 = false;
            boolean foundVector19 = false;

            // Check services.jar
            for (String entry : servicesContainer.getDexEntryNames()) {
                DexBackedDexFile df = servicesContainer.getEntry(entry).getDexFile();
                for (ClassDef cd : df.getClasses()) {
                    String type = cd.getType();
                    if (type.equals("Lcom/android/server/am/BroadcastController;") || type.equals("Lcom/android/server/am/ActivityManagerService;")) {
                        for (Method m : cd.getMethods()) {
                            if (m.getName().startsWith("broadcastIntentLocked") && m.getImplementation() != null) {
                                for (Instruction ins : m.getImplementation().getInstructions()) {
                                    if (ins instanceof ReferenceInstruction) {
                                        Reference ref = ((ReferenceInstruction) ins).getReference();
                                        if (ref instanceof MethodReference) {
                                            MethodReference mr = (MethodReference) ref;
                                            if (mr.getDefiningClass().equals("Lcom/android/server/am/FcmWakeFilter;") &&
                                                (mr.getName().equals("applyFlags") || mr.getName().equals("shouldAllowFcmBroadcast"))) {
                                                foundVector1 = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Check miui-services.jar
            for (String entry : miuiContainer.getDexEntryNames()) {
                DexBackedDexFile df = miuiContainer.getEntry(entry).getDexFile();
                for (ClassDef cd : df.getClasses()) {
                    String type = cd.getType();

                    // Vector 2 & 3: GreezeManagerService
                    if (type.equals("Lcom/miui/server/greeze/GreezeManagerService;")) {
                        for (Method m : cd.getMethods()) {
                            if ((m.getName().equals("isAllowBroadcast") || m.getName().equals("isNeedAllowRequest")) && m.getImplementation() != null) {
                                for (Instruction ins : m.getImplementation().getInstructions()) {
                                    if (ins instanceof ReferenceInstruction) {
                                        Reference ref = ((ReferenceInstruction) ins).getReference();
                                        if (ref instanceof MethodReference && ((MethodReference) ref).getDefiningClass().equals("Lcom/android/server/am/FcmWakeFilter;")) {
                                            foundVector2 = true;
                                            break;
                                        }
                                    }
                                }
                            }
                            if (m.getName().equals("triggerGMSLimitAction") && m.getImplementation() != null) {
                                Iterator<? extends Instruction> it = m.getImplementation().getInstructions().iterator();
                                if (it.hasNext() && it.next().getOpcode() == Opcode.RETURN_VOID) {
                                    foundVector3 = true;
                                }
                            }
                        }
                    }

                    // Vector 4: AutoStart C2DM Permission Bypass
                    if (type.equals("Lcom/android/server/am/BroadcastQueueModernStubImpl;") || type.equals("Lcom/android/server/am/BroadcastQueueImpl;")) {
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("checkApplicationAutoStart") && m.getImplementation() != null) {
                                for (Instruction ins : m.getImplementation().getInstructions()) {
                                    if (ins.getOpcode() == Opcode.CONST_4 && ins instanceof OneRegisterInstruction) {
                                        foundVector4 = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }

                    // Vector 17: ActivityManagerServiceImpl.checkRunningCompatibility
                    if (type.equals("Lcom/android/server/am/ActivityManagerServiceImpl;")) {
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("checkRunningCompatibility") && m.getImplementation() != null) {
                                for (Instruction ins : m.getImplementation().getInstructions()) {
                                    if (ins instanceof ReferenceInstruction) {
                                        Reference ref = ((ReferenceInstruction) ins).getReference();
                                        if (ref instanceof MethodReference) {
                                            MethodReference mr = (MethodReference) ref;
                                            if (mr.getDefiningClass().equals("Lcom/android/server/am/FcmWakeFilter;") && mr.getName().equals("shouldAllowRunningCompatibility")) {
                                                foundVector17 = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Vector 18: NotificationManagerServiceImpl.checkFullScreenIntent
                    if (type.equals("Lcom/android/server/notification/NotificationManagerServiceImpl;")) {
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("checkFullScreenIntent") && m.getImplementation() != null) {
                                for (Instruction ins : m.getImplementation().getInstructions()) {
                                    if (ins instanceof ReferenceInstruction) {
                                        Reference ref = ((ReferenceInstruction) ins).getReference();
                                        if (ref instanceof MethodReference) {
                                            MethodReference mr = (MethodReference) ref;
                                            if (mr.getDefiningClass().equals("Lcom/android/server/am/FcmWakeFilter;") && mr.getName().equals("shouldBypassFullScreenIntent")) {
                                                foundVector18 = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Vector 19: AlarmManagerServiceStubImpl.init
                    if (type.equals("Lcom/android/server/alarm/AlarmManagerServiceStubImpl;")) {
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("init") && m.getImplementation() != null) {
                                for (Instruction ins : m.getImplementation().getInstructions()) {
                                    if (ins.getOpcode() == Opcode.CONST_4 && ins instanceof OneRegisterInstruction) {
                                        foundVector19 = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            boolean ok = foundVector1 && foundVector2 && foundVector4;
            if (isHyperos) {
                ok = ok && foundVector3 && foundVector17 && foundVector18 && foundVector19;
            }

            if (!ok) {
                tr.details += "Semantic invariants missing: [V1=" + foundVector1 + ", V2=" + foundVector2 +
                              ", V3=" + foundVector3 + ", V4=" + foundVector4 + ", V17=" + foundVector17 +
                              ", V18=" + foundVector18 + ", V19=" + foundVector19 + "]. ";
            }
            return ok;

        } catch (Exception e) {
            tr.details += "Semantic verification exception: " + e.getMessage() + ". ";
            return false;
        }
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
