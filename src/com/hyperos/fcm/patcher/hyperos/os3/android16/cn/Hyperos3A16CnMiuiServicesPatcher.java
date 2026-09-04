package com.hyperos.fcm.patcher.hyperos.os3.android16.cn;

import com.android.tools.smali.dexlib2.AccessFlags;
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
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction;
import com.android.tools.smali.dexlib2.iface.reference.FieldReference;
import com.android.tools.smali.dexlib2.iface.reference.Reference;
import com.android.tools.smali.dexlib2.immutable.ImmutableClassDef;
import com.android.tools.smali.dexlib2.immutable.ImmutableMethod;
import com.android.tools.smali.dexlib2.immutable.ImmutableMethodImplementation;
import com.android.tools.smali.dexlib2.immutable.instruction.*;
import com.android.tools.smali.dexlib2.immutable.reference.ImmutableMethodReference;
import com.android.tools.smali.dexlib2.immutable.reference.ImmutableStringReference;
import com.android.tools.smali.dexlib2.writer.pool.DexPool;
import com.android.tools.smali.dexlib2.DexFileFactory;
import com.hyperos.fcm.patcher.common.AlignedJarRepacker;
import com.hyperos.fcm.patcher.common.DexUtils;
import com.hyperos.fcm.patcher.common.PatchResult;

import java.io.File;
import java.util.*;

/**
 * Dedicated miui-services.jar Patcher for Xiaomi HyperOS 3.0 (Android 16 / SDK 36) China.
 * Preserves the exact, verified DomesticPolicy, GMS QuickFreeze, and ModernStub bytecode modifications.
 */
public class Hyperos3A16CnMiuiServicesPatcher {

    public static PatchResult patchMiuiServicesJar(File sourceJar, File destJar, File workDir, File patcherJar) {
        PatchResult result = new PatchResult();

        try {
            MultiDexContainer<? extends DexBackedDexFile> container =
                DexFileFactory.loadDexContainer(sourceJar, Opcodes.getDefault());

            List<String> entryNames = container.getDexEntryNames();
            System.out.println("[HyperOS 3.0 / A16 CN miui-services.jar] Scanning Multi-DEX container (" + entryNames.size() + " DEX entries)...");

            ClassDef fcmFilterClassDef = DexUtils.findClassInJarOrClasspath(patcherJar, "Lcom/android/server/am/FcmWakeFilter;");
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

                    // Vector 2 & 3: GreezeManagerService (Vector 2: Screen-OFF C2DM Thaw, Vector 3: GMS Quick-Freeze Neutralizer)
                    if (type.equals("Lcom/miui/server/greeze/GreezeManagerService;")) {
                        System.out.println("  -> Located GreezeManagerService in " + entryName);
                        List<Method> methods = new ArrayList<>();
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("triggerGMSLimitAction") && m.getReturnType().equals("V")) {
                                // The signature is not stable across HyperOS 3 CN builds:
                                //   OS2.x / early OS3 : triggerGMSLimitAction()V
                                //   OS3.0.307.0 (MIX Fold 4, 24072PX77C) : triggerGMSLimitAction(Z)V
                                // Match on name + void return only, and size the stub frame from the
                                // real signature (registers_size must be >= ins_size, or ART rejects it).
                                int stubRegs = DexUtils.paramRegCount(m);
                                System.out.println("    -> Rewriting triggerGMSLimitAction("
                                    + String.join("", m.getParameterTypes()) + ")V to return-void (GMS unfreeze, "
                                    + stubRegs + " regs)");
                                List<com.android.tools.smali.dexlib2.immutable.instruction.ImmutableInstruction> insns = Collections.singletonList(
                                    new ImmutableInstruction10x(Opcode.RETURN_VOID)
                                );
                                ImmutableMethodImplementation newImpl = new ImmutableMethodImplementation(stubRegs, insns, null, null);
                                methods.add(new ImmutableMethod(
                                    m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                    m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), newImpl));
                                result.v3_gms_quickfreeze = true;
                                result.v3_note = "GreezeManagerService.triggerGMSLimitAction -> return-void";
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
                                    result.v2_screenoff_thaw = true;
                                    result.v2_note = "GreezeManagerService.isAllowBroadcast (Screen-OFF C2DM Thaw)";
                                    dexModified = true;
                                    System.out.println("    -> [PASS] Dynamic Screen-OFF Greezer check injected into GreezeManagerService.isAllowBroadcast");
                                } else {
                                    methods.add(m);
                                }
                            } else if (m.getName().equals("isGmsApp") && m.getReturnType().equals("Z")) {
                                int stubRegs = DexUtils.paramRegCount(m);
                                System.out.println("    -> Rewriting isGmsApp("
                                    + String.join("", m.getParameterTypes()) + ")Z to return false (GMS screen-off thaw, "
                                    + stubRegs + " regs)");
                                List<com.android.tools.smali.dexlib2.immutable.instruction.ImmutableInstruction> insns = Arrays.asList(
                                    new ImmutableInstruction11n(Opcode.CONST_4, 0, 0),
                                    new ImmutableInstruction11x(Opcode.RETURN, 0)
                                );
                                ImmutableMethodImplementation newImpl = new ImmutableMethodImplementation(stubRegs, insns, null, null);
                                methods.add(new ImmutableMethod(
                                    m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                    m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), newImpl));
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
                            System.out.println("  -> [PASS] Injected FcmWakeFilter ClassDef alongside GreezeManagerService into " + entryName);
                        }

                    // Vector 8: PolicyManager (Force International policy, GMS permanently important)
                    } else if (type.equals("Lcom/miui/server/greeze/PolicyManager;")) {
                        System.out.println("  -> Located PolicyManager in " + entryName);
                        List<Method> methods = new ArrayList<>();
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("<clinit>") && m.getImplementation() != null) {
                                MutableMethodImplementation mut = new MutableMethodImplementation(m.getImplementation());
                                for (int i = 0; i < mut.getInstructions().size(); i++) {
                                    BuilderInstruction ins = mut.getInstructions().get(i);
                                    if (ins.getOpcode() == Opcode.SPUT_BOOLEAN) {
                                        Reference ref = ((ReferenceInstruction) ins).getReference();
                                        if (ref instanceof FieldReference && ((FieldReference) ref).getName().equals("CN_MODEL")) {
                                            int reg = ((OneRegisterInstruction) ins).getRegisterA();
                                            System.out.println("    -> Patching PolicyManager.CN_MODEL to false (reg " + reg + ")");
                                            if (i > 0 && mut.getInstructions().get(i - 1).getOpcode() == Opcode.MOVE_RESULT) {
                                                mut.replaceInstruction(i - 1, new BuilderInstruction11n(Opcode.CONST_4, reg, 0));
                                            } else {
                                                mut.addInstruction(i, new BuilderInstruction11n(Opcode.CONST_4, reg, 0));
                                            }
                                            result.v8_policy_intl = true;
                                            result.v8_note = "PolicyManager.CN_MODEL -> false (International Policy)";
                                            dexModified = true;
                                            break;
                                        }
                                    }
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

                    // Vector 9: AurogonFilterManager (Signal CANNOT_FREEZE for GMS)
                    } else if (type.equals("Lcom/miui/server/greeze/AurogonFilterManager;")) {
                        System.out.println("  -> Located AurogonFilterManager in " + entryName);
                        List<Method> methods = new ArrayList<>();
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("filter") && m.getReturnType().equals("Z") && m.getImplementation() != null) {
                                MutableMethodImplementation mut = new MutableMethodImplementation(m.getImplementation());
                                int totalRegs = mut.getRegisterCount();
                                // p0: this, p1: uid (I), p2: packageName (String), p3: policy (I)
                                int p2 = totalRegs - 2;
                                Label cont = mut.newLabelForIndex(0);
                                int cur = 0;
                                mut.addInstruction(cur++, new BuilderInstruction21c(Opcode.CONST_STRING, 0, new ImmutableStringReference("com.google.android.gms")));
                                mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 2, 0, p2, 0, 0, 0,
                                    new ImmutableMethodReference("Ljava/lang/String;", "equals", Collections.singletonList("Ljava/lang/Object;"), "Z")));
                                mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT, 0));
                                mut.addInstruction(cur++, new BuilderInstruction21t(Opcode.IF_EQZ, 0, cont));
                                // false = CANNOT_FREEZE in PolicyMaker
                                mut.addInstruction(cur++, new BuilderInstruction11n(Opcode.CONST_4, 0, 0));
                                mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.RETURN, 0));
                                System.out.println("    -> Injected GMS freeze shield into AurogonFilterManager.filter");
                                result.v9_aurogon_filter = true;
                                result.v9_note = "AurogonFilterManager.filter: GMS returns false (CANNOT_FREEZE)";
                                dexModified = true;
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
                                    result.v4_autostart_bypass = true;
                                    result.v4_note = "BroadcastQueueModernStubImpl.checkApplicationAutoStart (IS_INTERNATIONAL_BUILD -> const/4 1)";
                                    dexModified = true;
                                } else {
                                    System.err.println("    -> [WARNING] Build.IS_INTERNATIONAL_BUILD instruction not found in BroadcastQueueModernStubImpl#checkApplicationAutoStart");
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

                    File tempDex = new File(workDir, "patched_hyperos3_a16_cn_miui_" + entryName);
                    DexPool.writeTo(tempDex.getAbsolutePath(), outDexFile);
                    byte[] patchedBytes = java.nio.file.Files.readAllBytes(tempDex.toPath());
                    tempDex.delete();

                    replacementDexMap.put(entryName, patchedBytes);
                    System.out.println("  -> [PASS] Patched and buffered " + entryName + " (" + patchedBytes.length + " bytes)");
                }
            }

            if (!result.v2_screenoff_thaw) {
                result.details += "[FAIL] Vector 2: GreezeManagerService.isAllowBroadcast() not found. ";
            }
            if (!result.v3_gms_quickfreeze) {
                result.details += "[FAIL] Vector 3: GreezeManagerService.triggerGMSLimitAction() not found. ";
            }
            if (!result.v4_autostart_bypass) {
                result.details += "[FAIL] Vector 4: BroadcastQueueModernStubImpl.checkApplicationAutoStart() not found. ";
            }

            if (!result.isAllMiuiServicesSuccess()) {
                result.success = false;
                return result;
            }

            System.out.println("[HyperOS 3.0 / A16 CN miui-services.jar] Repacking with 4-byte DEX alignment...");
            AlignedJarRepacker.repackJar(sourceJar, replacementDexMap, destJar);

            result.success = true;
            result.details = "Vectors 2, 3, 4, 8, 9 successfully applied to HyperOS 3.0 A16 CN miui-services.jar";
            return result;

        } catch (Exception e) {
            result.success = false;
            result.details = "Exception during HyperOS 3.0 A16 CN miui-services.jar patching: " + e.getMessage();
            e.printStackTrace();
            return result;
        }
    }
}
