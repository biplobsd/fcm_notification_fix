package com.hyperos.fcm.patcher.common;

import com.android.tools.smali.dexlib2.AccessFlags;
import com.android.tools.smali.dexlib2.DexFileFactory;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.iface.ClassDef;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MultiDexContainer;

import java.io.File;

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
}
