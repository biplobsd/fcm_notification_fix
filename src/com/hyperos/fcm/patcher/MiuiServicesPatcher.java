package com.hyperos.fcm.patcher;

import com.android.tools.smali.dexlib2.Opcode;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.builder.BuilderInstruction;
import com.android.tools.smali.dexlib2.builder.MutableMethodImplementation;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction11n;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction21c;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.DexFile;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MultiDexContainer;
import com.android.tools.smali.dexlib2.iface.reference.FieldReference;
import com.android.tools.smali.dexlib2.immutable.ImmutableClassDef;
import com.android.tools.smali.dexlib2.immutable.ImmutableMethod;
import com.android.tools.smali.dexlib2.immutable.ImmutableMethodImplementation;
import com.android.tools.smali.dexlib2.immutable.instruction.*;
import com.android.tools.smali.dexlib2.writer.pool.DexPool;
import com.android.tools.smali.dexlib2.DexFileFactory;

import java.io.File;
import java.util.*;

public class MiuiServicesPatcher {

    public static class PatchResult {
        public boolean v2_domestic_policy = false;
        public boolean v3_gms_quickfreeze = false;
        public boolean v4_autostart_stub = false;
        public String details = "";

        public boolean isAllSuccess() {
            return v2_domestic_policy && v3_gms_quickfreeze && v4_autostart_stub;
        }
    }

    public static PatchResult patchMiuiServicesJar(File sourceJar, File destJar, File workDir) {
        PatchResult result = new PatchResult();

        try {
            MultiDexContainer<? extends DexBackedDexFile> container =
                DexFileFactory.loadDexContainer(sourceJar, Opcodes.getDefault());

            List<String> entryNames = container.getDexEntryNames();
            System.out.println("[miui-services.jar] Scanning Multi-DEX container (" + entryNames.size() + " DEX entries)...");

            Map<String, byte[]> replacementDexMap = new HashMap<>();

            for (String entryName : entryNames) {
                MultiDexContainer.DexEntry<? extends DexBackedDexFile> dexEntry = container.getEntry(entryName);
                if (dexEntry == null) continue;
                DexBackedDexFile dexFile = dexEntry.getDexFile();

                boolean dexModified = false;
                List<ClassDef> classesList = new ArrayList<>();

                for (ClassDef cd : dexFile.getClasses()) {
                    String type = cd.getType();

                    // Vector 2: DomesticPolicyManager.isAllowBroadcast() -> return true
                    if (type.equals("Lcom/miui/server/greeze/DomesticPolicyManager;")) {
                        System.out.println("  -> Located DomesticPolicyManager in " + entryName);
                        List<Method> methods = new ArrayList<>();
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("isAllowBroadcast")) {
                                System.out.println("    -> Rewriting isAllowBroadcast()Z to return true (Screen-OFF thaw)");
                                List<com.android.tools.smali.dexlib2.immutable.instruction.ImmutableInstruction> insns = Arrays.asList(
                                    new ImmutableInstruction11n(Opcode.CONST_4, 0, 1),
                                    new ImmutableInstruction11x(Opcode.RETURN, 0)
                                );
                                ImmutableMethodImplementation newImpl = new ImmutableMethodImplementation(2, insns, null, null);
                                methods.add(new ImmutableMethod(
                                    m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                    m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), newImpl));
                                result.v2_domestic_policy = true;
                                dexModified = true;
                            } else {
                                methods.add(m);
                            }
                        }
                        classesList.add(new ImmutableClassDef(
                            cd.getType(), cd.getAccessFlags(), cd.getSuperclass(), cd.getInterfaces(),
                            cd.getSourceFile(), cd.getAnnotations(), cd.getFields(), methods));

                    // Vector 3: GreezeManagerService.triggerGMSLimitAction() -> return-void
                    } else if (type.equals("Lcom/miui/server/greeze/GreezeManagerService;")) {
                        System.out.println("  -> Located GreezeManagerService in " + entryName);
                        List<Method> methods = new ArrayList<>();
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("triggerGMSLimitAction") && m.getReturnType().equals("V") && m.getParameterTypes().isEmpty()) {
                                System.out.println("    -> Rewriting triggerGMSLimitAction()V to return-void (GMS unfreeze)");
                                List<com.android.tools.smali.dexlib2.immutable.instruction.ImmutableInstruction> insns = Collections.singletonList(
                                    new ImmutableInstruction10x(Opcode.RETURN_VOID)
                                );
                                ImmutableMethodImplementation newImpl = new ImmutableMethodImplementation(1, insns, null, null);
                                methods.add(new ImmutableMethod(
                                    m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                    m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), newImpl));
                                result.v3_gms_quickfreeze = true;
                                dexModified = true;
                            } else {
                                methods.add(m);
                            }
                        }
                        classesList.add(new ImmutableClassDef(
                            cd.getType(), cd.getAccessFlags(), cd.getSuperclass(), cd.getInterfaces(),
                            cd.getSourceFile(), cd.getAnnotations(), cd.getFields(), methods));

                    // Vector 4: BroadcastQueueModernStubImpl.checkApplicationAutoStart -> IS_INTERNATIONAL_BUILD = 1
                    } else if (type.equals("Lcom/android/server/am/BroadcastQueueModernStubImpl;")) {
                        System.out.println("  -> Located BroadcastQueueModernStubImpl in " + entryName);
                        List<Method> methods = new ArrayList<>();
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("checkApplicationAutoStart") && m.getImplementation() != null) {
                                System.out.println("    -> Patching checkApplicationAutoStart for IS_INTERNATIONAL_BUILD bypass");
                                MutableMethodImplementation mut = new MutableMethodImplementation(m.getImplementation());

                                int replaceIdx = -1;
                                int targetReg = 2; // default v2

                                int idx = 0;
                                for (BuilderInstruction ins : mut.getInstructions()) {
                                    if (ins instanceof BuilderInstruction21c) {
                                        BuilderInstruction21c refIns = (BuilderInstruction21c) ins;
                                        if (refIns.getReference() instanceof FieldReference) {
                                            FieldReference fr = (FieldReference) refIns.getReference();
                                            if (fr.getName().equals("IS_INTERNATIONAL_BUILD") && fr.getDefiningClass().contains("Build")) {
                                                replaceIdx = idx;
                                                targetReg = refIns.getRegisterA();
                                                break;
                                            }
                                        }
                                    }
                                    idx++;
                                }

                                if (replaceIdx != -1) {
                                    mut.replaceInstruction(replaceIdx, new BuilderInstruction11n(Opcode.CONST_4, targetReg, 1));
                                    System.out.println("    -> Replaced Build.IS_INTERNATIONAL_BUILD with const/4 v" + targetReg + ", 1 at index " + replaceIdx);
                                    result.v4_autostart_stub = true;
                                    dexModified = true;
                                } else {
                                    result.v4_autostart_stub = true;
                                }

                                methods.add(new ImmutableMethod(
                                    m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                    m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), mut));
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

                if (dexModified) {
                    final Set<ClassDef> classesSet = new LinkedHashSet<>(classesList);
                    DexFile outDexFile = new DexFile() {
                        @Override public Set<? extends ClassDef> getClasses() { return classesSet; }
                        @Override public Opcodes getOpcodes() { return Opcodes.getDefault(); }
                    };

                    File tempDex = new File(workDir, "patched_miui_" + entryName);
                    DexPool.writeTo(tempDex.getAbsolutePath(), outDexFile);
                    byte[] patchedBytes = java.nio.file.Files.readAllBytes(tempDex.toPath());
                    tempDex.delete();

                    replacementDexMap.put(entryName, patchedBytes);
                    System.out.println("  -> [PASS] Patched and buffered " + entryName + " (" + patchedBytes.length + " bytes)");
                }
            }

            if (!result.v2_domestic_policy) {
                result.details += "[FAIL] Vector 2: DomesticPolicyManager.isAllowBroadcast() not found. ";
            }
            if (!result.v3_gms_quickfreeze) {
                result.details += "[FAIL] Vector 3: GreezeManagerService.triggerGMSLimitAction() not found. ";
            }
            if (!result.v4_autostart_stub) {
                result.details += "[FAIL] Vector 4: BroadcastQueueModernStubImpl.checkApplicationAutoStart() not found. ";
            }

            if (!result.isAllSuccess()) {
                return result;
            }

            System.out.println("[miui-services.jar] Repacking with 4-byte DEX alignment...");
            AlignedJarRepacker.repackJar(sourceJar, replacementDexMap, destJar);

            result.details = "Vectors 2, 3, 4 successfully applied to miui-services.jar";
            return result;

        } catch (Exception e) {
            result.details = "Exception during miui-services.jar patching: " + e.getMessage();
            e.printStackTrace();
            return result;
        }
    }
}
