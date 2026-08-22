package com.hyperos.fcm.patcher;

import com.android.tools.smali.dexlib2.Opcode;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.builder.BuilderInstruction;
import com.android.tools.smali.dexlib2.builder.Label;
import com.android.tools.smali.dexlib2.builder.MutableMethodImplementation;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction11x;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction21c;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction21s;
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
import com.android.tools.smali.dexlib2.immutable.reference.ImmutableStringReference;
import com.android.tools.smali.dexlib2.writer.pool.DexPool;
import com.android.tools.smali.dexlib2.DexFileFactory;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.util.*;

public class ServicesPatcher {

    public static class PatchResult {
        public boolean success = false;
        public String details = "";
    }

    public static PatchResult patchServicesJar(File sourceJar, File destJar, File workDir) {
        PatchResult result = new PatchResult();

        try {
            MultiDexContainer<? extends DexBackedDexFile> container =
                DexFileFactory.loadDexContainer(sourceJar, Opcodes.getDefault());

            List<String> entryNames = container.getDexEntryNames();
            System.out.println("[services.jar] Scanning Multi-DEX container (" + entryNames.size() + " DEX entries)...");

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

                                System.out.println("  -> Injecting C2DM wake flag into " + m.getName() + " (Intent reg: v" + intentReg + ")");

                                Label endLabel = mut.newLabelForIndex(0);

                                ImmutableMethodReference getActionRef = new ImmutableMethodReference(
                                    "Landroid/content/Intent;", "getAction", Collections.emptyList(), "Ljava/lang/String;");
                                ImmutableMethodReference equalsRef = new ImmutableMethodReference(
                                    "Ljava/lang/String;", "equals", Collections.singletonList("Ljava/lang/Object;"), "Z");
                                ImmutableMethodReference addFlagsRef = new ImmutableMethodReference(
                                    "Landroid/content/Intent;", "addFlags", Collections.singletonList("I"), "Landroid/content/Intent;");
                                ImmutableStringReference c2dmStr = new ImmutableStringReference("com.google.android.c2dm.intent.RECEIVE");

                                int cur = 0;
                                // 1. move-object/from16 v0, intentReg
                                mut.addInstruction(cur++, new BuilderInstruction22x(Opcode.MOVE_OBJECT_FROM16, 0, intentReg));
                                // 2. if-eqz v0, :endLabel
                                mut.addInstruction(cur++, new BuilderInstruction21t(Opcode.IF_EQZ, 0, endLabel));
                                // 3. invoke-virtual {v0}, Intent->getAction()String
                                mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 1, 0, 0, 0, 0, 0, getActionRef));
                                // 4. move-result-object v1
                                mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT_OBJECT, 1));
                                // 5. if-eqz v1, :endLabel
                                mut.addInstruction(cur++, new BuilderInstruction21t(Opcode.IF_EQZ, 1, endLabel));
                                // 6. const-string v2, "com.google.android.c2dm.intent.RECEIVE"
                                mut.addInstruction(cur++, new BuilderInstruction21c(Opcode.CONST_STRING, 2, c2dmStr));
                                // 7. invoke-virtual {v2, v1}, String->equals(Object)Z
                                mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 2, 2, 1, 0, 0, 0, equalsRef));
                                // 8. move-result v1
                                mut.addInstruction(cur++, new BuilderInstruction11x(Opcode.MOVE_RESULT, 1));
                                // 9. if-eqz v1, :endLabel
                                mut.addInstruction(cur++, new BuilderInstruction21t(Opcode.IF_EQZ, 1, endLabel));
                                // 10. const/16 v1, 0x20 (FLAG_INCLUDE_STOPPED_PACKAGES)
                                mut.addInstruction(cur++, new BuilderInstruction21s(Opcode.CONST_16, 1, 0x20));
                                // 11. invoke-virtual {v0, v1}, Intent->addFlags(I)Intent
                                mut.addInstruction(cur++, new BuilderInstruction35c(Opcode.INVOKE_VIRTUAL, 2, 0, 1, 0, 0, 0, addFlagsRef));

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

                if (dexModified) {
                    final Set<ClassDef> classesSet = new LinkedHashSet<>(classesList);
                    DexFile outDexFile = new DexFile() {
                        @Override public Set<? extends ClassDef> getClasses() { return classesSet; }
                        @Override public Opcodes getOpcodes() { return Opcodes.getDefault(); }
                    };

                    File tempDex = new File(workDir, "patched_" + entryName);
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

            System.out.println("[services.jar] Repacking with 4-byte DEX alignment...");
            AlignedJarRepacker.repackJar(sourceJar, replacementDexMap, destJar);

            result.success = true;
            result.details = "Vector 1 (C2DM Wake-on-Push Flag) successfully applied";
            return result;

        } catch (Exception e) {
            result.success = false;
            result.details = "Exception during services.jar patching: " + e.getMessage();
            e.printStackTrace();
            return result;
        }
    }
}
