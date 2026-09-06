package com.hyperos.fcm.patcher.common;

import com.android.tools.smali.dexlib2.DexFileFactory;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.Field;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MultiDexContainer;
import com.android.tools.smali.dexlib2.iface.instruction.FiveRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.Instruction;
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.RegisterRangeInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.ThreeRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.instruction.TwoRegisterInstruction;
import com.android.tools.smali.dexlib2.iface.reference.FieldReference;
import com.android.tools.smali.dexlib2.iface.reference.MethodReference;
import com.android.tools.smali.dexlib2.iface.reference.Reference;
import com.android.tools.smali.dexlib2.iface.reference.TypeReference;

import java.io.File;
import java.util.*;

/**
 * Validates structural integrity, register safety, and referential linkage across repacked Multi-DEX archives.
 * Catches:
 * 1. Dangling class, method, or field references (prevents NoClassDefFoundError / NoSuchMethodError).
 * 2. Multi-DEX duplicate class definition collisions (prevents ClassFormatError).
 * 3. Dalvik register index violations and format overruns (prevents ART VerifyError).
 * 4. Dalvik 64K table section overflows (prevents dex header parse aborts).
 */
public class LinkageVerifier {

    public static boolean verifyJarLinkage(File jarFile, String targetPrefix) {
        if (jarFile == null || !jarFile.exists()) {
            System.err.println("[LinkageVerifier] Error: Target JAR does not exist: " + jarFile);
            return false;
        }

        try {
            MultiDexContainer<? extends DexBackedDexFile> container =
                DexFileFactory.loadDexContainer(jarFile, Opcodes.getDefault());

            Set<String> definedClasses = new HashSet<>();
            Set<String> definedMethods = new HashSet<>();
            Set<String> definedFields = new HashSet<>();
            Map<String, String> classToDexMap = new HashMap<>();
            List<String> violations = new ArrayList<>();

            // Phase 1: Structural cataloging, Duplicate ClassDef check, and 64K Table bounds
            for (String entryName : container.getDexEntryNames()) {
                MultiDexContainer.DexEntry<? extends DexBackedDexFile> entry = container.getEntry(entryName);
                if (entry == null) continue;
                DexBackedDexFile df = entry.getDexFile();

                // 64K Table Section Bounds Check
                int methodCount = df.getMethodSection().size();
                int fieldCount = df.getFieldSection().size();
                int typeCount = df.getTypeSection().size();
                if (methodCount > 65535) {
                    violations.add("TABLE OVERFLOW in " + entryName + ": method section size ("
                        + methodCount + ") exceeds Dalvik 16-bit limit (65535)");
                }
                if (fieldCount > 65535) {
                    violations.add("TABLE OVERFLOW in " + entryName + ": field section size ("
                        + fieldCount + ") exceeds Dalvik 16-bit limit (65535)");
                }
                if (typeCount > 65535) {
                    violations.add("TABLE OVERFLOW in " + entryName + ": type section size ("
                        + typeCount + ") exceeds Dalvik 16-bit limit (65535)");
                }

                for (ClassDef cd : df.getClasses()) {
                    String classType = cd.getType();
                    String prevDex = classToDexMap.put(classType, entryName);
                    if (prevDex != null && !prevDex.equals(entryName)) {
                        violations.add("DUPLICATE CLASS DEFINITION: " + classType
                            + " is defined in multiple DEX entries (" + prevDex + " and " + entryName + ")");
                    }

                    definedClasses.add(classType);

                    for (Method m : cd.getMethods()) {
                        StringBuilder sb = new StringBuilder(classType).append("->").append(m.getName()).append("(");
                        for (CharSequence pt : m.getParameterTypes()) {
                            sb.append(pt.toString());
                        }
                        sb.append(")").append(m.getReturnType());
                        definedMethods.add(sb.toString());
                    }

                    for (Field f : cd.getFields()) {
                        definedFields.add(classType + "->" + f.getName() + ":" + f.getType());
                    }
                }
            }

            // Phase 2: Dalvik Register Bounds and ART Verifier Emulation
            for (String entryName : container.getDexEntryNames()) {
                MultiDexContainer.DexEntry<? extends DexBackedDexFile> entry = container.getEntry(entryName);
                if (entry == null) continue;
                DexBackedDexFile df = entry.getDexFile();

                for (ClassDef cd : df.getClasses()) {
                    for (Method m : cd.getMethods()) {
                        if (m.getImplementation() == null) continue;

                        int maxReg = m.getImplementation().getRegisterCount();
                        for (Instruction ins : m.getImplementation().getInstructions()) {
                            // Verify register operand bounds against allocated code item registerCount
                            if (ins instanceof OneRegisterInstruction) {
                                int rA = ((OneRegisterInstruction) ins).getRegisterA();
                                if (rA >= maxReg) {
                                    violations.add("REGISTER OVERFLOW in " + cd.getType() + "->" + m.getName()
                                        + ": register v" + rA + " >= registerCount (" + maxReg + ")");
                                }
                            }
                            if (ins instanceof TwoRegisterInstruction) {
                                int rB = ((TwoRegisterInstruction) ins).getRegisterB();
                                if (rB >= maxReg) {
                                    violations.add("REGISTER OVERFLOW in " + cd.getType() + "->" + m.getName()
                                        + ": register v" + rB + " >= registerCount (" + maxReg + ")");
                                }
                            }
                            if (ins instanceof ThreeRegisterInstruction) {
                                int rC = ((ThreeRegisterInstruction) ins).getRegisterC();
                                if (rC >= maxReg) {
                                    violations.add("REGISTER OVERFLOW in " + cd.getType() + "->" + m.getName()
                                        + ": register v" + rC + " >= registerCount (" + maxReg + ")");
                                }
                            }
                            if (ins instanceof FiveRegisterInstruction) {
                                FiveRegisterInstruction fri = (FiveRegisterInstruction) ins;
                                int rc = fri.getRegisterCount();
                                if (rc > 0 && fri.getRegisterC() >= maxReg) {
                                    violations.add("REGISTER OVERFLOW in " + cd.getType() + "->" + m.getName()
                                        + ": registerC v" + fri.getRegisterC() + " >= " + maxReg);
                                }
                                if (rc > 1 && fri.getRegisterD() >= maxReg) {
                                    violations.add("REGISTER OVERFLOW in " + cd.getType() + "->" + m.getName()
                                        + ": registerD v" + fri.getRegisterD() + " >= " + maxReg);
                                }
                                if (rc > 2 && fri.getRegisterE() >= maxReg) {
                                    violations.add("REGISTER OVERFLOW in " + cd.getType() + "->" + m.getName()
                                        + ": registerE v" + fri.getRegisterE() + " >= " + maxReg);
                                }
                                if (rc > 3 && fri.getRegisterF() >= maxReg) {
                                    violations.add("REGISTER OVERFLOW in " + cd.getType() + "->" + m.getName()
                                        + ": registerF v" + fri.getRegisterF() + " >= " + maxReg);
                                }
                                if (rc > 4 && fri.getRegisterG() >= maxReg) {
                                    violations.add("REGISTER OVERFLOW in " + cd.getType() + "->" + m.getName()
                                        + ": registerG v" + fri.getRegisterG() + " >= " + maxReg);
                                }
                            }
                            if (ins instanceof RegisterRangeInstruction) {
                                RegisterRangeInstruction rri = (RegisterRangeInstruction) ins;
                                int start = rri.getStartRegister();
                                int count = rri.getRegisterCount();
                                if (count > 0 && (start + count) > maxReg) {
                                    violations.add("RANGE OVERFLOW in " + cd.getType() + "->" + m.getName()
                                        + ": v" + start + "..v" + (start + count - 1) + " exceeds registerCount (" + maxReg + ")");
                                }
                            }

                            // Phase 3: Inspect all instructions referencing targetPrefix (Linkage)
                            if (ins instanceof ReferenceInstruction) {
                                Reference ref = ((ReferenceInstruction) ins).getReference();

                                if (ref instanceof TypeReference) {
                                    String type = ((TypeReference) ref).getType();
                                    if (matchesTarget(type, targetPrefix) && !definedClasses.contains(type)) {
                                        violations.add("Method " + cd.getType() + "->" + m.getName()
                                            + " references MISSING CLASS: " + type);
                                    }
                                } else if (ref instanceof MethodReference) {
                                    MethodReference mr = (MethodReference) ref;
                                    String defClass = mr.getDefiningClass();
                                    if (matchesTarget(defClass, targetPrefix)) {
                                        if (!definedClasses.contains(defClass)) {
                                            violations.add("Method " + cd.getType() + "->" + m.getName()
                                                + " references method on MISSING CLASS: " + defClass);
                                        } else {
                                            StringBuilder sb = new StringBuilder(defClass).append("->").append(mr.getName()).append("(");
                                            for (CharSequence pt : mr.getParameterTypes()) {
                                                sb.append(pt.toString());
                                            }
                                            sb.append(")").append(mr.getReturnType());
                                            if (!definedMethods.contains(sb.toString())) {
                                                violations.add("Method " + cd.getType() + "->" + m.getName()
                                                    + " references UNDEFINED METHOD: " + sb.toString());
                                            }
                                        }
                                    }
                                } else if (ref instanceof FieldReference) {
                                    FieldReference fr = (FieldReference) ref;
                                    String defClass = fr.getDefiningClass();
                                    if (matchesTarget(defClass, targetPrefix)) {
                                        if (!definedClasses.contains(defClass)) {
                                            violations.add("Method " + cd.getType() + "->" + m.getName()
                                                + " references field on MISSING CLASS: " + defClass);
                                        } else {
                                            String fieldSig = defClass + "->" + fr.getName() + ":" + fr.getType();
                                            if (!definedFields.contains(fieldSig)) {
                                                violations.add("Method " + cd.getType() + "->" + m.getName()
                                                    + " references UNDEFINED FIELD: " + fieldSig);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (!violations.isEmpty()) {
                System.err.println("=================================================");
                System.err.println("[!] FATAL LINKAGE & INTEGRITY CHECK FAILED: " + jarFile.getName());
                System.err.println("    " + violations.size() + " critical bytecode/structural violation(s) detected!");
                for (String v : violations) {
                    System.err.println("    -> " + v);
                }
                System.err.println("=================================================");
                return false;
            }

            System.out.println("  -> [PASS] Bytecode linkage & structural integrity verified for " + jarFile.getName());
            return true;

        } catch (Exception e) {
            System.err.println("[LinkageVerifier] Exception during linkage verification: " + e.getMessage());
            e.printStackTrace();
            return false;
        }
    }

    private static boolean matchesTarget(String type, String targetPrefix) {
        if (type == null || targetPrefix == null) return false;
        String cleanPrefix = targetPrefix.endsWith(";") ? targetPrefix.substring(0, targetPrefix.length() - 1) : targetPrefix;
        return type.equals(cleanPrefix + ";") || type.startsWith(cleanPrefix + "$");
    }
}
