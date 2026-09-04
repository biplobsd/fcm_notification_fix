package com.hyperos.fcm.patcher.hyperos.os3.android16.cn;

import com.android.tools.smali.dexlib2.Opcode;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.builder.BuilderInstruction;
import com.android.tools.smali.dexlib2.builder.Label;
import com.android.tools.smali.dexlib2.builder.MutableMethodImplementation;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction11n;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction11x;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction21t;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction22c;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction22x;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction35c;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.DexFile;
import com.android.tools.smali.dexlib2.iface.Field;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MultiDexContainer;
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.TwoRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.reference.FieldReference;
import com.android.tools.smali.dexlib2.iface.reference.MethodReference;
import com.android.tools.smali.dexlib2.iface.reference.Reference;
import com.android.tools.smali.dexlib2.immutable.ImmutableClassDef;
import com.android.tools.smali.dexlib2.immutable.ImmutableMethod;
import com.android.tools.smali.dexlib2.immutable.reference.ImmutableFieldReference;
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

                        // Inject FcmWakeFilter into the same DEX entry if found
                        if (fcmFilterClassDef != null) {
                            classesList.add(fcmFilterClassDef);
                            System.out.println("  -> [PASS] Injected FcmWakeFilter ClassDef alongside BroadcastController into " + entryName);
                        }
                    } else if (type.equals("Lcom/android/server/notification/NotificationAttentionHelper;")) {
                        System.out.println("  -> Located NotificationAttentionHelper in " + entryName);

                        List<Method> methods = new ArrayList<>();
                        for (Method m : cd.getMethods()) {
                            if (m.getName().equals("shouldMuteNotificationLocked") && m.getImplementation() != null) {
                                MutableMethodImplementation mut = new MutableMethodImplementation(m.getImplementation());
                                int totalRegs = mut.getRegisterCount();
                                int recordReg = totalRegs - 3;
                                Label stockLabel = mut.newLabelForIndex(0);

                                ImmutableMethodReference getSbnRef = new ImmutableMethodReference(
                                    "Lcom/android/server/notification/NotificationRecord;", "getSbn",
                                    Collections.emptyList(), "Landroid/service/notification/StatusBarNotification;");
                                ImmutableMethodReference getPkgRef = new ImmutableMethodReference(
                                    "Landroid/service/notification/StatusBarNotification;", "getPackageName",
                                    Collections.emptyList(), "Ljava/lang/String;");
                                ImmutableMethodReference bypassRef = new ImmutableMethodReference(
                                    "Lcom/android/server/am/FcmWakeFilter;", "shouldBypassAlertRateLimit",
                                    Collections.singletonList("Ljava/lang/String;"), "Z");

                                int cur = 0;
                                mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, recordReg, 0, 0, 0, 0, getSbnRef));
                                mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 0));
                                mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, 0, 0, 0, 0, 0, getPkgRef));
                                mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 0));
                                mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 1, 0, 0, 0, 0, 0, bypassRef));
                                mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT, 0));
                                mut.addInstruction(cur++, new BuilderInstruction21t(Opcode.IF_EQZ, 0, stockLabel));
                                mut.addInstruction(cur++, new BuilderInstruction11n(Opcode.CONST_4, 0, 0)); // return 0 (MUTE_REASON_NOT_MUTED)
                                mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.RETURN, 0));

                                    methods.add(new ImmutableMethod(
                                        m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                        m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), mut));
                                    result.v5_group_alert_fix = true;
                                    result.v5_note = "NotificationAttentionHelper.shouldMuteNotificationLocked (Group Alert & Cooldown Bypass)";
                                    dexModified = true;
                                    System.out.println("    -> [PASS] Injected shouldBypassAlertRateLimit preamble into shouldMuteNotificationLocked");
                            } else if (m.getName().equals("buzzBeepBlinkLocked") && m.getImplementation() != null) {
                                MutableMethodImplementation mut = new MutableMethodImplementation(m.getImplementation());
                                List<BuilderInstruction> insns = mut.getInstructions();

                                int soundMoveIdx = -1;
                                int vibMoveIdx = -1;
                                boolean afterSoundKey = false;
                                boolean afterVibKey = false;

                                for (int i = 0; i < insns.size(); i++) {
                                    BuilderInstruction ins = insns.get(i);
                                    String str = "";
                                    if (ins instanceof com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction) {
                                        str = ((com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction) ins).getReference().toString();
                                    }
                                    if (str.contains("mSoundNotificationKey")) {
                                        afterSoundKey = true;
                                    } else if (str.contains("mVibrateNotificationKey")) {
                                        afterVibKey = true;
                                    }

                                    if (afterSoundKey && !afterVibKey && soundMoveIdx == -1) {
                                        if (ins instanceof TwoRegisterInstruction &&
                                            (ins.getOpcode() == Opcode.MOVE_FROM16 || ins.getOpcode() == Opcode.MOVE || ins.getOpcode() == Opcode.MOVE_16)) {
                                            soundMoveIdx = i;
                                        }
                                    }

                                    if (afterVibKey && vibMoveIdx == -1) {
                                        if (ins instanceof TwoRegisterInstruction &&
                                            (ins.getOpcode() == Opcode.MOVE_FROM16 || ins.getOpcode() == Opcode.MOVE || ins.getOpcode() == Opcode.MOVE_16)) {
                                            vibMoveIdx = i;
                                        }
                                    }
                                }

                                if (soundMoveIdx != -1 && vibMoveIdx != -1) {
                                    System.out.println("    -> Injecting FcmWakeFilter.shouldCancelEffectsOnUpdate into buzzBeepBlinkLocked (soundIdx=" + soundMoveIdx + ", vibIdx=" + vibMoveIdx + ")");
                                    ImmutableMethodReference wrapRef = new ImmutableMethodReference(
                                        "Lcom/android/server/am/FcmWakeFilter;", "shouldCancelEffectsOnUpdate",
                                        Collections.singletonList("Z"), "Z");

                                    // Inject for vib first (higher index so sound index remains unchanged)
                                    TwoRegisterInstruction vibMove = (TwoRegisterInstruction) insns.get(vibMoveIdx);
                                    int srcRegVib = vibMove.getRegisterB();
                                    mut.addInstruction(vibMoveIdx, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 1, srcRegVib, 0, 0, 0, 0, wrapRef));
                                    mut.addInstruction(vibMoveIdx + 1, new BuilderInstruction11x(Opcode.MOVE_RESULT, srcRegVib));

                                    // Inject for sound
                                    TwoRegisterInstruction soundMove = (TwoRegisterInstruction) insns.get(soundMoveIdx);
                                    int srcRegSound = soundMove.getRegisterB();
                                    mut.addInstruction(soundMoveIdx, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 1, srcRegSound, 0, 0, 0, 0, wrapRef));
                                    mut.addInstruction(soundMoveIdx + 1, new BuilderInstruction11x(Opcode.MOVE_RESULT, srcRegSound));

                                    methods.add(new ImmutableMethod(
                                        m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                        m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), mut));
                                    result.v7_anti_mute_update = true;
                                    result.v7_note = "NotificationAttentionHelper.buzzBeepBlinkLocked (Anti-Mute On Update)";
                                    dexModified = true;
                                    System.out.println("    -> [PASS] Hooked buzzBeepBlinkLocked sound & vibration abort race with FcmWakeFilter");
                                } else {
                                    System.err.println("    -> [WARNING] sound/vib move instructions not found in buzzBeepBlinkLocked");
                                    methods.add(m);
                                }
                            } else if (m.getName().equals("playSound") && m.getImplementation() != null) {
                                MutableMethodImplementation mut = new MutableMethodImplementation(m.getImplementation());
                                List<BuilderInstruction> insns = mut.getInstructions();

                                int checkPlayIdx = -1;
                                int deniedIdx = -1;
                                for (int i = 0; i < insns.size(); i++) {
                                    BuilderInstruction ins = insns.get(i);
                                    if (ins instanceof ReferenceInstruction) {
                                        String ref = ((ReferenceInstruction) ins).getReference().toString();
                                        if (ref.contains("NotifAttentionHelper")) {
                                            checkPlayIdx = i + 1; // if-nez v3
                                        } else if (ref.contains("isDeniedPlaySound")) {
                                            deniedIdx = i + 2; // if-eqz v0
                                        }
                                    }
                                }

                                if (checkPlayIdx != -1 && deniedIdx != -1) {
                                    int recordReg = mut.getRegisterCount() - 2;
                                    int shouldPlayReg = ((OneRegisterInstruction) insns.get(checkPlayIdx)).getRegisterA();
                                    int deniedReg = ((OneRegisterInstruction) insns.get(deniedIdx)).getRegisterA();

                                    ImmutableMethodReference getSbnRef = new ImmutableMethodReference(
                                        "Lcom/android/server/notification/NotificationRecord;", "getSbn",
                                        Collections.emptyList(), "Landroid/service/notification/StatusBarNotification;");
                                    ImmutableMethodReference getPkgRef = new ImmutableMethodReference(
                                        "Landroid/service/notification/StatusBarNotification;", "getPackageName",
                                        Collections.emptyList(), "Ljava/lang/String;");
                                    ImmutableMethodReference bypassRef = new ImmutableMethodReference(
                                        "Lcom/android/server/am/FcmWakeFilter;", "shouldBypassAlertRateLimit",
                                        Collections.singletonList("Ljava/lang/String;"), "Z");

                                    // 1. Hook deniedIdx first (so checkPlayIdx doesn't shift)
                                    Label contDenied = mut.newLabelForIndex(deniedIdx);
                                    int cur = deniedIdx;
                                    mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, recordReg, 0, 0, 0, 0, getSbnRef));
                                    mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 0));
                                    mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, 0, 0, 0, 0, 0, getPkgRef));
                                    mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 0));
                                    mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 1, 0, 0, 0, 0, 0, bypassRef));
                                    mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT, 0));
                                    mut.addInstruction(cur++, new BuilderInstruction21t(Opcode.IF_EQZ, 0, contDenied));
                                    mut.addInstruction(cur++, new BuilderInstruction11n(Opcode.CONST_4, deniedReg, 0)); // deniedReg = 0 (false = not denied)

                                    // 2. Hook checkPlayIdx
                                    Label contPlay = mut.newLabelForIndex(checkPlayIdx);
                                    cur = checkPlayIdx;
                                    mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, recordReg, 0, 0, 0, 0, getSbnRef));
                                    mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 0));
                                    mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, 0, 0, 0, 0, 0, getPkgRef));
                                    mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 0));
                                    mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_STATIC, 1, 0, 0, 0, 0, 0, bypassRef));
                                    mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT, 0));
                                    mut.addInstruction(cur++, new BuilderInstruction21t(Opcode.IF_EQZ, 0, contPlay));
                                    mut.addInstruction(cur++, new BuilderInstruction11n(Opcode.CONST_4, shouldPlayReg, 1)); // shouldPlayReg = 1 (true = should play)

                                    methods.add(new ImmutableMethod(
                                        m.getDefiningClass(), m.getName(), m.getParameters(), m.getReturnType(),
                                        m.getAccessFlags(), m.getAnnotations(), m.getHiddenApiRestrictions(), mut));
                                    result.v14_playsound_unthrottle = true;
                                    result.v14_note = "NotificationAttentionHelper.playSound (Focus & isDenied Gate Bypass)";
                                    dexModified = true;
                                    System.out.println("    -> [PASS] Hooked NotificationAttentionHelper.playSound with unthrottled focus and denied bypass");
                                } else {
                                    System.err.println("    -> [WARNING] target instructions not found in playSound");
                                    methods.add(m);
                                }
                            } else {
                                methods.add(m);
                            }
                        }

                        classesList.add(new ImmutableClassDef(
                            cd.getType(), cd.getAccessFlags(), cd.getSuperclass(), cd.getInterfaces(),
                            cd.getSourceFile(), cd.getAnnotations(), cd.getFields(), methods));

                        if (fcmFilterClassDef != null) {
                            boolean alreadyPresent = false;
                            for (ClassDef c : classesList) {
                                if (c.getType().equals("Lcom/android/server/am/FcmWakeFilter;")) {
                                    alreadyPresent = true;
                                    break;
                                }
                            }
                            if (!alreadyPresent) {
                                classesList.add(fcmFilterClassDef);
                                System.out.println("  -> [PASS] Injected FcmWakeFilter ClassDef alongside NotificationAttentionHelper into " + entryName);
                            }
                        }
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

                    File tempDex = new File(workDir, "patched_hyperos3_a16_cn_" + entryName);
                    DexPool.writeTo(tempDex.getAbsolutePath(), outDexFile);
                    byte[] patchedBytes = java.nio.file.Files.readAllBytes(tempDex.toPath());
                    tempDex.delete();

                    replacementDexMap.put(entryName, patchedBytes);
                    System.out.println("  -> [PASS] Patched and buffered " + entryName + " (" + patchedBytes.length + " bytes)");
                }
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
