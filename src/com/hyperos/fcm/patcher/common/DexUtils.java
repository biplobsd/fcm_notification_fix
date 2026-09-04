package com.hyperos.fcm.patcher.common;

import com.android.tools.smali.dexlib2.AccessFlags;
import com.android.tools.smali.dexlib2.DexFileFactory;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MultiDexContainer;

import java.io.File;
import java.util.List;

/**
 * Common DEX scanning and inspection utilities.
 */
public class DexUtils {

    public static ClassDef findClassInJarOrClasspath(File patcherJar, String targetType) {
        if (patcherJar != null && patcherJar.exists()) {
            try {
                MultiDexContainer<? extends DexBackedDexFile> container =
                    DexFileFactory.loadDexContainer(patcherJar, Opcodes.getDefault());
                for (String entry : container.getDexEntryNames()) {
                    DexBackedDexFile df = container.getEntry(entry).getDexFile();
                    for (ClassDef cd : df.getClasses()) {
                        if (cd.getType().equals(targetType)) {
                            return cd;
                        }
                    }
                }
            } catch (Exception e) {
                System.err.println("Warning: Could not read class from patcherJar: " + e.getMessage());
            }
        }

        String cp = System.getProperty("java.class.path");
        if (cp != null) {
            for (String path : cp.split(File.pathSeparator)) {
                File f = new File(path);
                if (f.exists() && (f.getName().endsWith(".jar") || f.getName().endsWith(".dex") || f.getName().endsWith(".apk"))) {
                    try {
                        MultiDexContainer<? extends DexBackedDexFile> container =
                            DexFileFactory.loadDexContainer(f, Opcodes.getDefault());
                        for (String entry : container.getDexEntryNames()) {
                            DexBackedDexFile df = container.getEntry(entry).getDexFile();
                            for (ClassDef cd : df.getClasses()) {
                                if (cd.getType().equals(targetType)) {
                                    return cd;
                                }
                            }
                        }
                    } catch (Exception ignored) {
                    }
                }
            }
        }
        return null;
    }

    public static boolean containerHasClass(File jarFile, String classType) {
        if (jarFile == null || !jarFile.exists()) {
            return false;
        }
        try {
            MultiDexContainer<? extends DexBackedDexFile> container =
                DexFileFactory.loadDexContainer(jarFile, Opcodes.getDefault());
            for (String entry : container.getDexEntryNames()) {
                DexBackedDexFile df = container.getEntry(entry).getDexFile();
                for (ClassDef cd : df.getClasses()) {
                    if (cd.getType().equals(classType)) {
                        return true;
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return false;
    }

    public static int paramRegCount(Method m) {
        int count = AccessFlags.STATIC.isSet(m.getAccessFlags()) ? 0 : 1; // p0 exists only for instance methods
        for (CharSequence pt : m.getParameterTypes()) {
            String s = pt.toString();
            count += (s.equals("J") || s.equals("D")) ? 2 : 1;
        }
        return count;
    }

    public static final int MAX_SAFE_METHOD_COUNT = 65000;

    /**
     * Selects the most optimal carrier DEX entry for injecting auxiliary classes (e.g. FcmWakeFilter).
     * Prevents 16-bit method/type reference table overflow (64K limit).
     *
     * 1. Evaluates all existing DEX entries and identifies the one with the maximum headroom (lowest method count).
     * 2. If the best entry has <= MAX_SAFE_METHOD_COUNT (65,000), it is selected as the carrier.
     * 3. If all existing DEX entries are near capacity (> 65,000 methods), allocates a new DEX entry name
     *    (e.g., classes2.dex or classes3.dex).
     */
    public static String selectCarrierDexEntry(MultiDexContainer<? extends DexBackedDexFile> container) {
        List<String> entryNames;
        try {
            entryNames = container.getDexEntryNames();
        } catch (Exception e) {
            return "classes.dex";
        }
        if (entryNames == null || entryNames.isEmpty()) {
            return "classes.dex";
        }

        String bestEntry = null;
        int minMethods = Integer.MAX_VALUE;
        int maxDexIndex = 1;

        for (String entryName : entryNames) {
            if (!entryName.endsWith(".dex")) continue;

            int dexIndex = 1;
            if (entryName.equals("classes.dex")) {
                dexIndex = 1;
            } else if (entryName.startsWith("classes") && entryName.endsWith(".dex")) {
                try {
                    String numStr = entryName.substring(7, entryName.length() - 4);
                    dexIndex = Integer.parseInt(numStr);
                } catch (NumberFormatException ignored) {}
            }
            if (dexIndex > maxDexIndex) {
                maxDexIndex = dexIndex;
            }

            try {
                MultiDexContainer.DexEntry<? extends DexBackedDexFile> entry = container.getEntry(entryName);
                if (entry != null) {
                    DexBackedDexFile df = entry.getDexFile();
                    int methodCount = df.getMethodSection().size();
                    if (methodCount < minMethods) {
                        minMethods = methodCount;
                        bestEntry = entryName;
                    }
                }
            } catch (Exception ignored) {}
        }

        if (bestEntry != null && minMethods <= MAX_SAFE_METHOD_COUNT) {
            return bestEntry;
        }

        int nextIndex = maxDexIndex + 1;
        return nextIndex == 1 ? "classes.dex" : ("classes" + nextIndex + ".dex");
    }
}
