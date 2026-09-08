package com.hyperos.fcm.patcher.test;

import com.android.tools.smali.dexlib2.AccessFlags;
import com.android.tools.smali.dexlib2.iface.Method;
import com.android.tools.smali.dexlib2.iface.MethodParameter;
import com.android.tools.smali.dexlib2.immutable.ImmutableMethod;
import com.android.tools.smali.dexlib2.immutable.ImmutableMethodParameter;
import com.hyperos.fcm.patcher.common.DexUtils;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * Unit tests for parameter register resolution.
 *
 * <p>These cover the failure mode that is invisible to every structural check the patcher
 * performs. A vector that computes a parameter register by hand - {@code registerCount - 4}
 * for the first of four parameters, say - is right only while every parameter is
 * single-width. One {@code long} or {@code double} earlier in the signature shifts each
 * register after it, so the injected instruction reads the wrong half of a wide value or
 * an unrelated parameter. The index stays inside the frame, so bounds checking passes and
 * linkage resolves; the class is rejected only when ART verifies it while starting
 * system_server, which presents as a device that never finishes booting.
 *
 * <p>No fixtures or device required: the signatures are synthesised in memory.
 */
public class DexUtilsRegisterTest {

    private static int failures = 0;

    public static void main(String[] args) {
        System.out.println("== DexUtils parameter register resolution ==");

        // Instance method, all single-width. This is the shape the hand-rolled arithmetic
        // was written against, so old and new must agree.
        Method allNarrow = method(false, "Landroid/content/ComponentName;", "I", "I", "I");
        expect("instance, 4 narrow params: paramRegCount", 5, DexUtils.paramRegCount(allNarrow));
        expect("instance, 4 narrow params: param 0", 8, DexUtils.paramRegister(allNarrow, 12, 0));
        expect("instance, 4 narrow params: matches registerCount - 4", 12 - 4,
                DexUtils.paramRegister(allNarrow, 12, 0));

        // Same arity, one wide parameter. registerCount - 4 now lands on the low half of
        // the long instead of the ComponentName - the bug this test exists for.
        Method withWide = method(false, "Landroid/content/ComponentName;", "J", "I", "I");
        expect("instance, wide param present: param 0", 7, DexUtils.paramRegister(withWide, 12, 0));
        expectNot("instance, wide param present: differs from registerCount - 4", 12 - 4,
                DexUtils.paramRegister(withWide, 12, 0));
        expect("instance, wide param present: param after the long", 9,
                DexUtils.paramRegister(withWide, 12, 2));

        // Static methods have no p0, so the whole frame shifts by one.
        Method staticOne = method(true, "Ljava/lang/String;");
        expect("static, single param sits last", 4, DexUtils.paramRegister(staticOne, 5, 0));

        // Trailing parameter, the assumption vector 18 makes.
        Method endsWithString = method(false, "I", "Ljava/lang/String;");
        int last = DexUtils.lastParamIndex(endsWithString);
        expect("trailing String: index", 1, last);
        expect("trailing String: is a String", 1, DexUtils.paramTypeIs(endsWithString, last, "Ljava/lang/String;") ? 1 : 0);
        expect("trailing String: register is registerCount - 1", 7, DexUtils.paramRegister(endsWithString, 8, last));

        // A trailing wide parameter occupies the last two registers, so registerCount - 1
        // is its high half. The type check has to reject this before the register is used.
        Method endsWithWide = method(false, "Ljava/lang/String;", "J");
        int lastWide = DexUtils.lastParamIndex(endsWithWide);
        expect("trailing long: rejected by the type check", 0,
                DexUtils.paramTypeIs(endsWithWide, lastWide, "Ljava/lang/String;") ? 1 : 0);

        // Out of range and empty signatures resolve to -1 rather than a plausible register.
        Method noParams = method(false);
        expect("no parameters: lastParamIndex", -1, DexUtils.lastParamIndex(noParams));
        expect("no parameters: paramRegister", -1, DexUtils.paramRegister(noParams, 4, 0));
        expect("index past the end", -1, DexUtils.paramRegister(allNarrow, 12, 9));
        expect("negative index", -1, DexUtils.paramRegister(allNarrow, 12, -1));

        if (failures > 0) {
            System.err.println("\n[FAIL] " + failures + " assertion(s) failed.");
            System.exit(1);
        }
        System.out.println("\n[PASS] All parameter register assertions hold.");
        System.exit(0);
    }

    private static Method method(boolean isStatic, String... paramTypes) {
        List<MethodParameter> params = new ArrayList<>();
        for (String t : paramTypes) {
            params.add(new ImmutableMethodParameter(t, Collections.emptySet(), null));
        }
        return new ImmutableMethod(
                "Lcom/example/Target;",
                "probe",
                params,
                "V",
                isStatic ? AccessFlags.STATIC.getValue() : 0,
                Collections.emptySet(),
                Collections.emptySet(),
                null);
    }

    private static void expect(String what, int expected, int actual) {
        if (expected == actual) {
            System.out.println("  [ok]   " + what + " = " + actual);
        } else {
            System.err.println("  [FAIL] " + what + ": expected " + expected + ", got " + actual);
            failures++;
        }
    }

    private static void expectNot(String what, int unexpected, int actual) {
        if (unexpected != actual) {
            System.out.println("  [ok]   " + what + " (" + actual + " != " + unexpected + ")");
        } else {
            System.err.println("  [FAIL] " + what + ": expected anything but " + unexpected);
            failures++;
        }
    }
}
