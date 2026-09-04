package com.hyperos.fcm.patcher.hyperos.os3.android16.cn;

import com.android.tools.smali.dexlib2.Opcode;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.builder.Label;
import com.android.tools.smali.dexlib2.builder.MutableMethodImplementation;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction21t;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction22x;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction35c;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.DexFile;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MultiDexContainer;
import com.android.tools.smali.dexlib2.immutable.ImmutableClassDef;
import com.android.tools.smali.dexlib2.immutable.ImmutableMethod;
import com.android.tools.smali.dexlib2.immutable.reference.ImmutableMethodReference;
import com.android.tools.smali.dexlib2.writer.pool.DexPool;
import com.android.tools.smali.dexlib2.DexFileFactory;
import com.hyperos.fcm.patcher.common.AlignedJarRepacker;
import com.hyperos.fcm.patcher.common.DexUtils;
import com.hyperos.fcm.patcher.common.PatchResult;

import java.io.File;
import java.util.*;

/**
 * Dedicated services.jar Patcher for Xiaomi HyperOS 3.0 (Android 16 / SDK 36) China.
 * Preserves the exact, verified BroadcastController bytecode modification.
 */
public class Hyperos3A16CnServicesPatcher {

    public static PatchResult patchServicesJar(File sourceJar, File destJar, File workDir, File patcherJar) {
        PatchResult result = new PatchResult();

        try {
            MultiDexContainer<? extends DexBackedDexFile> container =
                DexFileFactory.loadDexContainer(sourceJar, Opcodes.getDefault());

            List<String> entryNames = container.getDexEntryNames();
            System.out.println("[HyperOS 3.0 / A16 CN services.jar] Scanning Multi-DEX container (" + entryNames.size() + " DEX entries)...");

            ClassDef fcmFilterClassDef = DexUtils.findClassInJarOrClasspath(patcherJar, "Lcom/android/server/am/FcmWakeFilter;");
            if (fcmFilterClassDef != null) {
                System.out.println("  -> [FOUND] Located FcmWakeFilter ClassDef in patcher engine");
            } else {
                System.out.println("  -> [WARNING] FcmWakeFilter ClassDef not found in patcher engine");
            }

            String carrierEntryName = DexUtils.selectCarrierDexEntry(container);
            System.out.println("  -> [DEX-GUARD] Designated carrier entry for FcmWakeFilter: " + carrierEntryName);

            Map<String, byte[]> replacementDexMap = new HashMap<>();
            boolean targetFound = false;

            for (String entryName : entryNames) {
                MultiDexContainer.DexEntry<? extends DexBackedDexFile> dexEntry = container.getEntry(entryName);
                if (dexEntry == null) continue;
                DexBackedDexFile dexFile = dexEntry.getDexFile();

                boolean dexModified = false;
                List<ClassDef> classesList = new ArrayList<>();

                for (ClassDef cd : dexFile.getClasses()) {
                    String type = cd.getType();

                    if (type.equals("Lcom/android/server/am/BroadcastController;")) {
                        targetFound = true;
                        System.out.println("  -> Located BroadcastController in " + entryName);

                        List<Method> methods = new ArrayList<>();
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("broadcastIntentLockedTraced")) {
                                int intentParamIdx = -1;
                                int pIdx = 0;
                                for (CharSequence pt : m.getParameterTypes()) {
                                    if (pt.toString().equals("Landroid/content/Intent;")) {
                                        intentParamIdx = pIdx;
                                        break;
                                    }
                                    pIdx++;
                                }

                                if (intentParamIdx == -1 || m.getImplementation() == null) {
                                    methods.add(m);
                                    continue;
                                }

                                MutableMethodImplementation mut = new MutableMethodImplementation(m.getImplementation());
                                int totalRegs = mut.getRegisterCount();
                                int paramRegCount = 1; // p0 is this
                                for (CharSequence pt : m.getParameterTypes()) {
                                    String pType = pt.toString();
                                    paramRegCount += (pType.equals("J") || pType.equals("D")) ? 2 : 1;
                                }
                                int p0 = totalRegs - paramRegCount;

                                // Calculate exact parameter register for Intent
                                int intentReg = p0 + 1; // Start with first param
                                int curP = 0;
                                for (CharSequence pt : m.getParameterTypes()) {
                                    if (curP == intentParamIdx) break;
                                    String pType = pt.toString();
                                    intentReg += (pType.equals("J") || pType.equals("D")) ? 2 : 1;
                                    curP++;
                                }

                                System.out.println("  -> Injecting FcmWakeFilter hook into " + m.getName() + " (Intent reg: v" + intentReg + ")");

                                Label endLabel = mut.newLabelForIndex(0);

                                ImmutableMethodReference applyFlagsRef = new ImmutableMethodReference(
                                    "Lcom/android/server/am/FcmWakeFilter;", "applyFlags",
                                    Collections.singletonList("Landroid/content/Intent;"), "V");

                                int cur = 0;
                                // 1. move-object/from16 v0, intentReg
                                mut.addInstruction(cur++, new BuilderInstruction22x(Opcode.MOVE_OBJECT_FROM16, 0, intentReg));
                                // 2. if-eqz v0, :endLabel
                                mut.addInstruction(cur++, new BuilderInstruction21t(Opcode.IF_EQZ, 0, endLabel));
                                // 3. invoke-static {v0}, FcmWakeFilter->applyFlags(Intent)V
                                mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 1, 0, 0, 0, 0, 0, applyFlagsRef));

                                methods.add(new ImmutableMethod(
                                    m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                    m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), mut));
                                dexModified = true;
                            } else {
                                methods.add(m);
                            }
                        }

                        classesList.add(new ImmutableClassDef(
                            cd.getType(), cd.getAccessFlags(), cd.getSuperclass(), cd.getInterfaces(),
                            cd.getSourceFile(), cd.getAnnotations(), cd.getFields(), methods));
                    } else {
                        classesList.add(cd);
                    }
                }

                // Inject FcmWakeFilter into designated carrier entry to prevent 64K method table overflow
                if (entryName.equals(carrierEntryName) && fcmFilterClassDef != null) {
                    classesList.add(fcmFilterClassDef);
                    dexModified = true;
                    System.out.println("  -> [PASS] Injected FcmWakeFilter ClassDef into carrier entry " + entryName);
                }

                if (dexModified) {
                    final Set<ClassDef> classesSet = new LinkedHashSet<>(classesList);
                    DexFile outDexFile = new DexFile() {
                        @Override public Set<? extends ClassDef> getClasses() { return classesSet; }
                        @Override public Opcodes getOpcodes() { return Opcodes.getDefault(); }
                    };

                    File tempDex = new File(workDir, "patched_hyperos3_a16_cn_" + entryName);
                    DexPool.writeTo(tempDex.getAbsolutePath(), outDexFile);
                    byte[] patchedBytes = java.nio.file.Files.readAllBytes(tempDex.toPath());
                    tempDex.delete();

                    replacementDexMap.put(entryName, patchedBytes);
                    System.out.println("  -> [PASS] Patched and buffered " + entryName + " (" + patchedBytes.length + " bytes)");
                }
            }

            // If carrierEntryName was a newly allocated DEX entry (not present in original JAR), synthesize it
            if (fcmFilterClassDef != null && !replacementDexMap.containsKey(carrierEntryName)) {
                final Set<ClassDef> classesSet = Collections.singleton(fcmFilterClassDef);
                DexFile outDexFile = new DexFile() {
                    @Override public Set<? extends ClassDef> getClasses() { return classesSet; }
                    @Override public Opcodes getOpcodes() { return Opcodes.getDefault(); }
                };

                File tempDex = new File(workDir, "patched_hyperos3_a16_cn_" + carrierEntryName);
                DexPool.writeTo(tempDex.getAbsolutePath(), outDexFile);
                byte[] patchedBytes = java.nio.file.Files.readAllBytes(tempDex.toPath());
                tempDex.delete();

                replacementDexMap.put(carrierEntryName, patchedBytes);
                System.out.println("  -> [PASS] Injected FcmWakeFilter ClassDef into newly allocated carrier entry " + carrierEntryName);
            }

            if (!targetFound || replacementDexMap.isEmpty()) {
                result.details = "Target class Lcom/android/server/am/BroadcastController; not found in services.jar";
                return result;
            }

            System.out.println("[HyperOS 3.0 / A16 CN services.jar] Repacking with 4-byte DEX alignment...");
            AlignedJarRepacker.repackJar(sourceJar, replacementDexMap, destJar);

            result.success = true;
            result.v1_wake_flag = true;
            result.v1_note = "BroadcastController.broadcastIntentLockedTraced";
            result.details = "Vector 1 (Dynamic FCM Wake Filter Hook) successfully applied to HyperOS 3.0 A16 CN services.jar";
            return result;

        } catch (Exception e) {
            result.success = false;
            result.details = "Exception during HyperOS 3.0 A16 CN services.jar patching: " + e.getMessage();
            e.printStackTrace();
            return result;
        }
    }
}
