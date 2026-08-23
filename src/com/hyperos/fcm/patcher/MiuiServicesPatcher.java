package com.hyperos.fcm.patcher;

import com.android.tools.smali.dexlib2.Opcode;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.builder.BuilderInstruction;
import com.android.tools.smali.dexlib2.builder.Label;
import com.android.tools.smali.dexlib2.builder.MutableMethodImplementation;
import com.android.tools.smali.dexlib2.builder.instruction.*;
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
import com.android.tools.smali.dexlib2.immutable.reference.ImmutableMethodReference;
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
        return patchMiuiServicesJar(sourceJar, destJar, workDir, null);
    }

    public static PatchResult patchMiuiServicesJar(File sourceJar, File destJar, File workDir, File patcherJar) {
        PatchResult result = new PatchResult();

        try {
            MultiDexContainer<? extends DexBackedDexFile> container =
                DexFileFactory.loadDexContainer(sourceJar, Opcodes.getDefault());

            List<String> entryNames = container.getDexEntryNames();
            System.out.println("[miui-services.jar] Scanning Multi-DEX container (" + entryNames.size() + " DEX entries)...");

            ClassDef fcmFilterClassDef = ServicesPatcher.findClassInJarOrClasspath(patcherJar, "Lcom/android/server/am/FcmWakeFilter;");
            if (fcmFilterClassDef != null) {
                System.out.println("  -> [FOUND] Located FcmWakeFilter ClassDef for miui-services.jar injection");
            }

            Map<String, byte[]> replacementDexMap = new HashMap<>();

            for (String entryName : entryNames) {
                MultiDexContainer.DexEntry<? extends DexBackedDexFile> dexEntry = container.getEntry(entryName);
                if (dexEntry == null) continue;
                DexBackedDexFile dexFile = dexEntry.getDexFile();

                boolean dexModified = false;
                List<ClassDef> classesList = new ArrayList<>();

                for (ClassDef cd : dexFile.getClasses()) {
                    String type = cd.getType();

                    // Vector 2: DomesticPolicyManager.isAllowBroadcast() -> dynamic FcmWakeFilter Screen-OFF filter
                    if (type.equals("Lcom/miui/server/greeze/DomesticPolicyManager;")) {
                        System.out.println("  -> Located DomesticPolicyManager in " + entryName);
                        List<Method> methods = new ArrayList<>();
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("isAllowBroadcast")) {
                                int paramCount = 0;
                                for (CharSequence pt : m.getParameterTypes()) {
                                    paramCount++;
                                }
                                System.out.println("    -> Rewriting isAllowBroadcast()Z to invoke FcmWakeFilter.isAllowBroadcast (" + paramCount + " params)");

                                List<com.android.tools.smali.dexlib2.immutable.instruction.ImmutableInstruction> insns;
                                if (paramCount >= 2) {
                                    ImmutableMethodReference isAllowBroadcastRef = new ImmutableMethodReference(
                                        "Lcom/android/server/am/FcmWakeFilter;", "isAllowBroadcast",
                                        Arrays.asList("Landroid/content/Intent;", "Ljava/lang/String;"), "Z");
                                    insns = Arrays.asList(
                                        new ImmutableInstruction35c(Opcode.INVOKE_STATIC, 2, 0, 1, 0, 0, 0, isAllowBroadcastRef),
                                        new ImmutableInstruction11x(Opcode.MOVE_RESULT, 0),
                                        new ImmutableInstruction11x(Opcode.RETURN, 0)
                                    );
                                } else if (paramCount == 1) {
                                    ImmutableMethodReference isAllowBroadcastRef = new ImmutableMethodReference(
                                        "Lcom/android/server/am/FcmWakeFilter;", "isAllowBroadcast",
                                        Collections.singletonList("Landroid/content/Intent;"), "Z");
                                    insns = Arrays.asList(
                                        new ImmutableInstruction35c(Opcode.INVOKE_STATIC, 1, 0, 0, 0, 0, 0, isAllowBroadcastRef),
                                        new ImmutableInstruction11x(Opcode.MOVE_RESULT, 0),
                                        new ImmutableInstruction11x(Opcode.RETURN, 0)
                                    );
                                } else {
                                    ImmutableMethodReference isAllowBroadcastRef = new ImmutableMethodReference(
                                        "Lcom/android/server/am/FcmWakeFilter;", "isAllowBroadcast",
                                        Collections.emptyList(), "Z");
                                    insns = Arrays.asList(
                                        new ImmutableInstruction35c(Opcode.INVOKE_STATIC, 0, 0, 0, 0, 0, 0, isAllowBroadcastRef),
                                        new ImmutableInstruction11x(Opcode.MOVE_RESULT, 0),
                                        new ImmutableInstruction11x(Opcode.RETURN, 0)
                                    );
                                }

                                ImmutableMethodImplementation newImpl = new ImmutableMethodImplementation(Math.max(2, paramCount + 1), insns, null, null);
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

                        if (fcmFilterClassDef != null) {
                            classesList.add(fcmFilterClassDef);
                            System.out.println("  -> [PASS] Injected FcmWakeFilter ClassDef alongside DomesticPolicyManager into " + entryName);
                        }

                    // Vector 3: GreezeManagerService.triggerGMSLimitAction() -> return-void + isAllowBroadcast hook
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
                            } else if (m.getName().equals("isAllowBroadcast") && m.getImplementation() != null) {
                                int paramCount = 0;
                                for (CharSequence pt : m.getParameterTypes()) paramCount++;
                                if (paramCount == 5) {
                                    System.out.println("    -> Injecting FcmWakeFilter hook into GreezeManagerService.isAllowBroadcast (5 params)");
                                    MutableMethodImplementation mut = new MutableMethodImplementation(m.getImplementation());
                                    int totalRegs = mut.getRegisterCount();
                                    // p0 is this, p1: callingUid, p2: callerPackage, p3: calleeUid, p4: calleePkgName, p5: action
                                    int p4 = totalRegs - 2;
                                    int p5 = totalRegs - 1;

                                    Label continueLabel = mut.newLabelForIndex(0);

                                    ImmutableMethodReference checkGreezeRef = new ImmutableMethodReference(
                                        "Lcom/android/server/am/FcmWakeFilter;", "checkGreezeBroadcastAllow",
                                        Arrays.asList("Ljava/lang/String;", "Ljava/lang/String;"), "I");

                                    int cur = 0;
                                    mut.addInstruction(cur++, new BuilderInstruction22x(Opcode.MOVE_OBJECT_FROM16, 0, p5));
                                    mut.addInstruction(cur++, new BuilderInstruction22x(Opcode.MOVE_OBJECT_FROM16, 1, p4));
                                    mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 2, 0, 1, 0, 0, 0, checkGreezeRef));
                                    mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT, 0));
                                    mut.addInstruction(cur++, new BuilderInstruction21t(Opcode.IF_LTZ, 0, continueLabel));
                                    mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.RETURN, 0));

                                    methods.add(new ImmutableMethod(
                                        m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                        m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), mut));
                                    dexModified = true;
                                    System.out.println("    -> [PASS] Dynamic Screen-OFF Greezer check injected into GreezeManagerService.isAllowBroadcast");
                                } else {
                                    methods.add(m);
                                }
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
