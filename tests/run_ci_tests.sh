#!/usr/bin/env bash
# ==============================================================================
# Automated CI & Local Test Runner for HyperOS FCM Bytecode Patcher
# Verifies all ROM archetypes in test matrix with multi-DEX structural validation
# ==============================================================================
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "================================================="
echo " Starting Automated FCM Patcher CI Test Suite    "
echo "================================================="

# 1. Resolve Java / JDK Environment
if [ -z "$JAVA_HOME" ] || [ ! -x "$JAVA_HOME/bin/javac" ]; then
    if [ -f "$HOME/.sdkman/bin/sdkman-init.sh" ]; then
        source "$HOME/.sdkman/bin/sdkman-init.sh" 2>/dev/null || true
    fi
    if [ -f "/usr/local/sdkman/bin/sdkman-init.sh" ]; then
        source "/usr/local/sdkman/bin/sdkman-init.sh" 2>/dev/null || true
    fi
fi

if ! command -v javac &>/dev/null; then
    for probe in /usr/local/sdkman/candidates/java/*/bin \
                 $HOME/.sdkman/candidates/java/*/bin \
                 /usr/lib/jvm/java-*-openjdk*/bin \
                 /usr/lib/jvm/default-java/bin; do
        if [ -x "$probe/javac" ]; then
            export PATH="$probe:$PATH"
            export JAVA_HOME="$(cd "$probe/.." && pwd)"
            break
        fi
    done
fi

if ! command -v javac &>/dev/null || ! command -v java &>/dev/null; then
    echo "[!] ERROR: JDK (javac/java) not found on PATH."
    echo "    Please ensure JDK 17+ is installed or set JAVA_HOME."
    exit 1
fi

DEPS_DIR="$DIR/.deps"
mkdir -p "$DEPS_DIR"
DEXLIB2_VER="3.0.9"
GUAVA_VER="33.4.0-jre"

download_dep() {
    local url="$1"
    local dest="$2"
    if [ -f "$dest" ]; then
        local sz=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null || echo 0)
        if [ "$sz" -lt 1000 ]; then
            rm -f "$dest"
        fi
    fi
    if [ ! -f "$dest" ]; then
        echo "[*] Downloading $(basename "$dest")..."
        curl -sSL "$url" -o "$dest"
    fi
}

download_dep "https://dl.google.com/dl/android/maven2/com/android/tools/smali/smali-dexlib2/$DEXLIB2_VER/smali-dexlib2-$DEXLIB2_VER.jar" "$DEPS_DIR/smali-dexlib2-$DEXLIB2_VER.jar"
download_dep "https://dl.google.com/dl/android/maven2/com/android/tools/smali/smali-util/$DEXLIB2_VER/smali-util-$DEXLIB2_VER.jar" "$DEPS_DIR/smali-util-$DEXLIB2_VER.jar"
download_dep "https://repo1.maven.org/maven2/com/google/guava/guava/$GUAVA_VER/guava-$GUAVA_VER.jar" "$DEPS_DIR/guava-$GUAVA_VER.jar"

CP="$DEPS_DIR/smali-dexlib2-$DEXLIB2_VER.jar:$DEPS_DIR/smali-util-$DEXLIB2_VER.jar:$DEPS_DIR/guava-$GUAVA_VER.jar"

# 2. Resolve Android Platform Jar
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
ANDROID_JAR=$(find "$ANDROID_SDK/platforms" -name android.jar -type f 2>/dev/null | sort -V | tail -n 1)

if [ -z "$ANDROID_JAR" ] || [ ! -f "$ANDROID_JAR" ]; then
    echo "[!] Warning: android.jar not found in SDK platforms. Using fallback stub compilation."
    download_dep "https://repo1.maven.org/maven2/com/google/android/android/4.1.1.4/android-4.1.1.4.jar" "$DEPS_DIR/android-stub.jar"
    if [ -f "$DEPS_DIR/android-stub.jar" ]; then
        ANDROID_CP="$CP:$DEPS_DIR/android-stub.jar"
    else
        ANDROID_CP="$CP"
    fi
else
    echo "[*] Using Android SDK Platform: $ANDROID_JAR"
    ANDROID_CP="$CP:$ANDROID_JAR"
fi

# 3. Compile Java Sources
BUILD_CLASSES="$DIR/out/classes"
mkdir -p "$BUILD_CLASSES"
find "$DIR/src" "$DIR/tests/src" -name "*.java" > "$DIR/out/sources.txt"

echo "[1/4] Compiling Java bytecode patcher & test suite sources..."
JAVAC_FLAGS=()
if javac --help 2>&1 | grep -q -- "--release"; then
    if javac --release 8 -version &>/dev/null; then
        JAVAC_FLAGS=("--release" "8" "-Xlint:-options")
    elif javac --release 11 -version &>/dev/null; then
        JAVAC_FLAGS=("--release" "11")
    elif javac --release 17 -version &>/dev/null; then
        JAVAC_FLAGS=("--release" "17")
    fi
fi
if [ ${#JAVAC_FLAGS[@]} -eq 0 ]; then
    if javac -source 8 -target 8 -version &>/dev/null; then
        JAVAC_FLAGS=("-source" "8" "-target" "8" "-Xlint:-options")
    fi
fi

javac "${JAVAC_FLAGS[@]}" -cp "$ANDROID_CP" @"$DIR/out/sources.txt" -d "$BUILD_CLASSES"

# 4. Ensure patcher.jar is built
PATCHER_JAR="$DIR/module/tools/patcher.jar"
if [ ! -f "$PATCHER_JAR" ]; then
    if [ -n "$ANDROID_JAR" ] && command -v d8 &>/dev/null; then
        echo "[2/4] Building module/tools/patcher.jar..."
        "$DIR/build.sh"
    else
        echo "[2/4] Packaging fallback test patcher.jar..."
        mkdir -p "$DIR/module/tools"
        jar cf "$PATCHER_JAR" -C "$BUILD_CLASSES" .
    fi
else
    echo "[2/4] Using pre-built $PATCHER_JAR"
fi

# 5. Verify Fixtures directory exists
FIXTURES_DIR="${1:-$DIR/tests/fixtures}"
mkdir -p "$FIXTURES_DIR"

# 6. Execute Test Suite
echo "[3/4] Executing Patcher Integration Test Suite across: $FIXTURES_DIR"
STAGE_OUT="/tmp/fcm_test_runs_$$"
mkdir -p "$STAGE_OUT"

cleanup() {
    rm -rf "$STAGE_OUT"
}
trap cleanup EXIT

java -cp "$ANDROID_CP:$BUILD_CLASSES" com.hyperos.fcm.patcher.test.PatcherIntegrationTest \
    "$FIXTURES_DIR" \
    "$PATCHER_JAR" \
    "$STAGE_OUT"

TEST_STATUS=$?

echo "================================================="
if [ $TEST_STATUS -eq 0 ]; then
    echo " ALL TARGET FIXTURES PASSED TEST VALIDATION! ✓"
else
    echo " TEST SUITE FAILED! ✗"
fi
echo "================================================="

# 7. Generate GitHub Step Summary if running in GitHub Actions
if [ -n "$GITHUB_STEP_SUMMARY" ]; then
    TARGET_LABEL="$(basename "$FIXTURES_DIR")"
    if [ "$TARGET_LABEL" = "fixtures" ]; then
        TARGET_LABEL="All ROM Fixtures"
    fi
    cat <<EOF >> "$GITHUB_STEP_SUMMARY"
### 🧪 HyperOS FCM Patcher Verification: \`$TARGET_LABEL\`
- **Result**: $([ $TEST_STATUS -eq 0 ] && echo "PASS ✓" || echo "FAIL ✗")
- **Target Path**: \`$FIXTURES_DIR\`
- **Verified**: FCM Wake Filter (0x20), Screen-OFF Greeze Thaw, GMS Neutralizer, AutoStart Bypass, Anti-Mute, 4-byte DEX alignment, and Multi-DEX Linkage Referential Integrity.
EOF
fi

exit $TEST_STATUS
