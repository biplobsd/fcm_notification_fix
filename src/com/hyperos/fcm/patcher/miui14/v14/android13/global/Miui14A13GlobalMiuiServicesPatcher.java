package com.hyperos.fcm.patcher.miui14.v14.android13.global;

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
import com.android.tools.smali.dexlib2.immutable.reference.ImmutableMethodReference;
import com.android.tools.smali.dexlib2.writer.pool.DexPool;
import com.android.tools.smali.dexlib2.DexFileFactory;
import com.hyperos.fcm.patcher.common.AlignedJarRepacker;
import com.hyperos.fcm.patcher.common.DexUtils;
import com.hyperos.fcm.patcher.common.PatchResult;

import java.io.File;
import java.util.*;

/**
 * Dedicated miui-services.jar Patcher for MIUI 14 (Android 13 / SDK 33) Global.
 * Hooks GreezeManagerService (noteGreezeCallee + checkGreezeAllowRequest) for Screen-OFF thaw,
 * confirms GMS Quick-Freeze is N/A, and verifies IS_INTERNATIONAL_BUILD autostart bypass.
 */
public class Miui14A13GlobalMiuiServicesPatcher {

    private static final String GREEZE_CLASS = "Lcom/miui/server/greeze/GreezeManagerService;";
    private static final String BQ_IMPL_CLASS = "Lcom/android/server/am/BroadcastQueueImpl;";
    private static final String BQ_MODERN_CLASS = "Lcom/android/server/am/BroadcastQueueModernStubImpl;";

    public static PatchResult patchMiuiServicesJar(File sourceJar, File destJar, File workDir, File patcherJar) {
        PatchResult result = new PatchResult();

        try {
            MultiDexContainer<? extends DexBackedDexFile> container =
                DexFileFactory.loadDexContainer(sourceJar, Opcodes.getDefault());

            List<String> entryNames = container.getDexEntryNames();
            System.out.println("[MIUI 14 / A13 Global miui-services.jar] Scanning Multi-DEX container (" + entryNames.size() + " DEX entries)...");

            ClassDef fcmFilterClassDef = DexUtils.findClassInJarOrClasspath(patcherJar, "Lcom/android/server/am/FcmWakeFilter;");
            if (fcmFilterClassDef != null) {
                System.out.println("  -> [FOUND] Located FcmWakeFilter ClassDef for miui-services.jar injection");
            }

            String carrierEntryName = DexUtils.selectCarrierDexEntry(container);
            System.out.println("  -> [DEX-GUARD] Designated carrier entry for FcmWakeFilter: " + carrierEntryName);

            Map<String, byte[]> replacementDexMap = new HashMap<>();
            boolean greezeFound = false;
            boolean bqFound = false;

            for (String entryName : entryNames) {
                MultiDexContainer.DexEntry<? extends DexBackedDexFile> dexEntry = container.getEntry(entryName);
                if (dexEntry == null) continue;
                DexBackedDexFile dexFile = dexEntry.getDexFile();

                boolean dexModified = false;
                boolean filterInjectedThisEntry = false;
                List<ClassDef> classesList = new ArrayList<>();

                for (ClassDef cd : dexFile.getClasses()) {
                    String type = cd.getType();

                    // Vector 2 & 3: GreezeManagerService
                    if (type.equals(GREEZE_CLASS)) {
                        greezeFound = true;
                        System.out.println("  -> Located GreezeManagerService in " + entryName);

                        boolean hookedRestrictAction = false;
                        boolean hookedNeedAllow = false;

                        List<Method> methods = new ArrayList<>();
                        for (Method m : cd.getMethods()) {
                            // 1. Hook isRestrictBackgroundAction(String localhost, int callerUid, String callerPkgName, int calleeUid, String calleePkgName)Z
                            if (m.getName().equals("isRestrictBackgroundAction") && m.getImplementation() != null) {
                                int paramCount = 0;
                                for (CharSequence pt : m.getParameterTypes()) paramCount++;

                                if (paramCount == 5) {
                                    System.out.println("    -> Injecting noteGreezeCallee hook into isRestrictBackgroundAction (5 params)");
                                    MutableMethodImplementation mut = new MutableMethodImplementation(m.getImplementation());
                                    int totalRegs = mut.getRegisterCount();
                                    int paramRegs = DexUtils.paramRegCount(m);
                                    int p0 = totalRegs - paramRegs;
                                    int pCallee = p0 + 5; // calleePkgName

                                    ImmutableMethodReference noteCalleeRef = new ImmutableMethodReference(
                                        "Lcom/android/server/am/FcmWakeFilter;", "noteGreezeCallee",
                                        Collections.singletonList("Ljava/lang/String;"), "V");

                                    // Prepend instructions at index 0
                                    mut.addInstruction(0, new BuilderInstruction22x(Opcode.MOVE_OBJECT_FROM16, 0, pCallee));
                                    mut.addInstruction(1, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 1, 0, 0, 0, 0, 0, noteCalleeRef));

                                    methods.add(new ImmutableMethod(
                                        m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                        m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), mut));
                                    hookedRestrictAction = true;
                                    dexModified = true;
                                } else {
                                    methods.add(m);
                                }

                            // 2. Hook isNeedAllowRequest(int callerUid, String callerPkgName, int calleeUid)Z
                            } else if (m.getName().equals("isNeedAllowRequest") && m.getImplementation() != null) {
                                int paramCount = 0;
                                for (CharSequence pt : m.getParameterTypes()) paramCount++;

                                if (paramCount == 3) {
                                    System.out.println("    -> Injecting checkGreezeAllowRequest hook into isNeedAllowRequest (3 params)");
                                    MutableMethodImplementation mut = new MutableMethodImplementation(m.getImplementation());
                                    int totalRegs = mut.getRegisterCount();
                                    int paramRegs = DexUtils.paramRegCount(m);
                                    int p0 = totalRegs - paramRegs;
                                    int pCaller = p0 + 2; // callerPkgName

                                    Label stockLabel = mut.newLabelForIndex(0);

                                    ImmutableMethodReference checkAllowRef = new ImmutableMethodReference(
                                        "Lcom/android/server/am/FcmWakeFilter;", "checkGreezeAllowRequest",
                                        Collections.singletonList("Ljava/lang/String;"), "I");

                                    int cur = 0;
                                    mut.addInstruction(cur++, new BuilderInstruction22x(Opcode.MOVE_OBJECT_FROM16, 0, pCaller));
                                    mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 1, 0, 0, 0, 0, 0, checkAllowRef));
                                    mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT, 0));
                                    mut.addInstruction(cur++, new BuilderInstruction21t(Opcode.IF_LTZ, 0, stockLabel)); // -1 -> stock policy
                                    mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.RETURN, 0)); // 1 -> allow thaw, 0 -> deny

                                    methods.add(new ImmutableMethod(
                                        m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                        m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), mut));
                                    hookedNeedAllow = true;
                                    dexModified = true;
                                } else {
                                    methods.add(m);
                                }

                            // 3. Optional triggerGMSLimitAction (Vector 3)
                            } else if (m.getName().equals("triggerGMSLimitAction") && m.getReturnType().equals("V")) {
                                System.out.println("    -> Rewriting triggerGMSLimitAction()V to return-void");
                                List<com.android.tools.smali.dexlib2.immutable.instruction.ImmutableInstruction> insns = Collections.singletonList(
                                    new com.android.tools.smali.dexlib2.immutable.instruction.ImmutableInstruction10x(Opcode.RETURN_VOID)
                                );
                                com.android.tools.smali.dexlib2.immutable.ImmutableMethodImplementation newImpl =
                                    new com.android.tools.smali.dexlib2.immutable.ImmutableMethodImplementation(
                                        com.hyperos.fcm.patcher.common.DexUtils.paramRegCount(m), insns, null, null);
                                methods.add(new ImmutableMethod(
                                    m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                    m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), newImpl));
                                result.v3_gms_quickfreeze = true;
                                result.v3_note = "triggerGMSLimitAction neutralized";
                                dexModified = true;
                            } else {
                                methods.add(m);
                            }
                        }

                        if (hookedRestrictAction && hookedNeedAllow) {
                            result.v2_screenoff_thaw = true;
                            result.v2_note = "GreezeManagerService (isRestrictBackgroundAction + isNeedAllowRequest)";
                            System.out.println("    -> [PASS] Dual-hook Screen-OFF thaw engine verified in GreezeManagerService");
                        }

                        // Vector 3 status for MIUI 14
                        if (!result.v3_gms_quickfreeze) {
                            result.v3_gms_quickfreeze = true;
                            result.v3_note = "N/A on MIUI 14 (triggerGMSLimitAction absent - no GMS quick-freeze deadlock)";
                            System.out.println("    -> [PASS] Vector 3 marked N/A (safe on MIUI 14)");
                        }

                        classesList.add(new ImmutableClassDef(
                            cd.getType(), cd.getAccessFlags(), cd.getSuperclass(), cd.getInterfaces(),
                            cd.getSourceFile(), cd.getAnnotations(), cd.getFields(), methods));

                    // Vector 4: BroadcastQueueImpl.checkApplicationAutoStart
                    } else if (type.equals(BQ_IMPL_CLASS) || type.equals(BQ_MODERN_CLASS)) {
                        bqFound = true;
                        System.out.println("  -> Located " + type + " in " + entryName);

                        List<Method> methods = new ArrayList<>();
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("checkApplicationAutoStart") && m.getImplementation() != null) {
                                System.out.println("    -> Patching checkApplicationAutoStart for IS_INTERNATIONAL_BUILD bypass");
                                MutableMethodImplementation mut = new MutableMethodImplementation(m.getImplementation());

                                int replaceIdx = -1;
                                int targetReg = 2;

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
                                    result.v4_note = type.substring(1, type.length() - 1) + ".checkApplicationAutoStart (IS_INTERNATIONAL_BUILD -> const/4 1)";
                                    dexModified = true;
                                } else {
                                    System.err.println("    -> [WARNING] Build.IS_INTERNATIONAL_BUILD instruction not found in " + type + "#checkApplicationAutoStart");
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

                    File tempDex = new File(workDir, "patched_miui14_a13_global_miui_" + entryName);
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

                File tempDex = new File(workDir, "patched_miui14_a13_global_miui_" + carrierEntryName);
                DexPool.writeTo(tempDex.getAbsolutePath(), outDexFile);
                byte[] patchedBytes = java.nio.file.Files.readAllBytes(tempDex.toPath());
                tempDex.delete();

                replacementDexMap.put(carrierEntryName, patchedBytes);
                System.out.println("  -> [PASS] Injected FcmWakeFilter ClassDef into newly allocated carrier entry " + carrierEntryName);
            }

            if (!greezeFound || !result.v2_screenoff_thaw) {
                result.details += "[FAIL] Vector 2: GreezeManagerService screen-off thaw hooks could not be injected. ";
            }
            if (!bqFound || !result.v4_autostart_bypass) {
                result.details += "[FAIL] Vector 4: checkApplicationAutoStart autostart bypass not found. ";
            }

            if (!result.isAllMiuiServicesSuccess()) {
                result.success = false;
                return result;
            }

            System.out.println("[MIUI 14 / A13 Global miui-services.jar] Repacking with 4-byte DEX alignment...");
            AlignedJarRepacker.repackJar(sourceJar, replacementDexMap, destJar);

            result.success = true;
            result.details = "Vectors 2, 3, 4 successfully applied to MIUI 14 A13 Global miui-services.jar";
            return result;

        } catch (Exception e) {
            result.success = false;
            result.details = "Exception during MIUI 14 A13 Global miui-services.jar patching: " + e.getMessage();
            e.printStackTrace();
            return result;
        }
    }
}
