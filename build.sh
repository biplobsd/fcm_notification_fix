#!/usr/bin/env bash
# ==============================================================================
# HyperOS FCM Surgical Fix - Portable Flashable Module Builder
# Builds self-contained, lightweight on-device patching zip locally or in CI.
# ==============================================================================
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "================================================="
echo " Building HyperOS FCM On-The-Fly KernelSU Module "
echo "================================================="

# 1. Resolve Android SDK Tools
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"

if [ ! -d "$ANDROID_SDK" ]; then
    echo "[!] ERROR: Android SDK directory not found at $ANDROID_SDK"
    echo "    Please set ANDROID_HOME or ANDROID_SDK_ROOT environment variable."
    exit 1
fi

D8_BIN=$(find "$ANDROID_SDK/build-tools" -name d8 -type f 2>/dev/null | sort -V | tail -n 1)
ANDROID_JAR=$(find "$ANDROID_SDK/platforms" -name android.jar -type f 2>/dev/null | sort -V | tail -n 1)

if [ -z "$D8_BIN" ] || [ ! -x "$D8_BIN" ]; then
    echo "[!] ERROR: d8 tool not found in $ANDROID_SDK/build-tools"
    exit 1
fi

if [ -z "$ANDROID_JAR" ] || [ ! -f "$ANDROID_JAR" ]; then
    echo "[!] ERROR: android.jar not found in $ANDROID_SDK/platforms"
    exit 1
fi

echo "[*] Android SDK: $ANDROID_SDK"
echo "[*] Using D8: $D8_BIN"
echo "[*] Using Platform: $ANDROID_JAR"

# 2. Resolve Library Dependencies (smali-dexlib2 & guava)
DEPS_DIR="$DIR/.deps"
mkdir -p "$DEPS_DIR"

DEXLIB2_VER="3.0.9"
GUAVA_VER="33.4.0-jre"

# Check if SDK has smali jars, otherwise fetch from Maven Central
DEXLIB2_JAR=$(find "$ANDROID_SDK/cmdline-tools" -name "smali-dexlib2-*.jar" -type f 2>/dev/null | head -n 1)
UTIL_JAR=$(find "$ANDROID_SDK/cmdline-tools" -name "smali-util-*.jar" -type f 2>/dev/null | head -n 1)
GUAVA_JAR=$(find "$ANDROID_SDK/cmdline-tools" -name "guava-*.jar" -type f 2>/dev/null | head -n 1)

if [ -z "$DEXLIB2_JAR" ]; then
    DEXLIB2_JAR="$DEPS_DIR/smali-dexlib2-$DEXLIB2_VER.jar"
    if [ ! -f "$DEXLIB2_JAR" ]; then
        echo "[*] Downloading smali-dexlib2-$DEXLIB2_VER.jar from Maven Central..."
        curl -sSL "https://repo1.maven.org/maven2/com/android/tools/smali/smali-dexlib2/$DEXLIB2_VER/smali-dexlib2-$DEXLIB2_VER.jar" -o "$DEXLIB2_JAR"
    fi
fi

if [ -z "$UTIL_JAR" ]; then
    UTIL_JAR="$DEPS_DIR/smali-util-$DEXLIB2_VER.jar"
    if [ ! -f "$UTIL_JAR" ]; then
        echo "[*] Downloading smali-util-$DEXLIB2_VER.jar from Maven Central..."
        curl -sSL "https://repo1.maven.org/maven2/com/android/tools/smali/smali-util/$DEXLIB2_VER/smali-util-$DEXLIB2_VER.jar" -o "$UTIL_JAR"
    fi
fi

if [ -z "$GUAVA_JAR" ]; then
    GUAVA_JAR="$DEPS_DIR/guava-$GUAVA_VER.jar"
    if [ ! -f "$GUAVA_JAR" ]; then
        echo "[*] Downloading guava-$GUAVA_VER.jar from Maven Central..."
        curl -sSL "https://repo1.maven.org/maven2/com/google/guava/guava/$GUAVA_VER/guava-$GUAVA_VER.jar" -o "$GUAVA_JAR"
    fi
fi

CP="$DEXLIB2_JAR:$UTIL_JAR:$GUAVA_JAR"

BUILD_TMP="/tmp/fcm_patcher_build_$$"
mkdir -p "$BUILD_TMP"
mkdir -p "$DIR/module/tools"
mkdir -p "$DIR/out"

cleanup() {
    rm -rf "$BUILD_TMP"
}
trap cleanup EXIT

# 3. Compile Java Patcher Sources
echo "[1/4] Compiling Java bytecode patcher sources..."
javac --release 17 -cp "$CP" "$DIR/src/com/hyperos/fcm/patcher/"*.java -d "$BUILD_TMP"

# 4. Dex with Android SDK d8
echo "[2/4] Dexing patcher engine & libraries into patcher.jar (d8)..."
"$D8_BIN" --min-api 26 --lib "$ANDROID_JAR" \
    "$BUILD_TMP"/com/hyperos/fcm/patcher/*.class \
    "$DEXLIB2_JAR" \
    "$UTIL_JAR" \
    "$GUAVA_JAR" \
    --output "$DIR/module/tools/patcher.jar"

PATCHER_SIZE=$(ls -lh "$DIR/module/tools/patcher.jar" | awk '{print $5}')
echo "  -> Compiled module/tools/patcher.jar ($PATCHER_SIZE)"

# 5. Set Execution Permissions
chmod +x "$DIR/module/customize.sh" 2>/dev/null || true
chmod +x "$DIR/module/post-fs-data.sh" 2>/dev/null || true
chmod +x "$DIR/module/service.sh" 2>/dev/null || true

# 6. Package Flashable Module ZIP into out/
OUT_DIR="$DIR/out"
MODULE_VER=$(grep "^version=" "$DIR/module/module.prop" | cut -d= -f2 | tr -d '\r')
[ -z "$MODULE_VER" ] && MODULE_VER="v1.0"
ZIP_NAME="HyperOS_FCM_OnTheFly_Fix-${MODULE_VER}.zip"
FINAL_ZIP="$OUT_DIR/$ZIP_NAME"
rm -f "$FINAL_ZIP"


echo "[3/4] Packaging flashable KernelSU/Magisk module zip into out/$ZIP_NAME..."
cd "$DIR/module"
zip -r9 "$FINAL_ZIP" . -x "*.DS_Store" "*__MACOSX*"
cd "$DIR"

ZIP_SIZE=$(ls -lh "$FINAL_ZIP" | awk '{print $5}')
echo "  -> Created: $FINAL_ZIP ($ZIP_SIZE)"

# 7. Generate SHA256 Checksum
if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OUT_DIR" && sha256sum "$ZIP_NAME" > "$ZIP_NAME.sha256")
    echo "  -> SHA256: $(cat "$FINAL_ZIP.sha256" | awk '{print $1}')"
fi

# 8. Copy to local Downloads for user convenience if exists
DOWNLOADS_DIR="$HOME/Downloads"
if [ -d "$DOWNLOADS_DIR" ]; then
    cp -f "$FINAL_ZIP" "$DOWNLOADS_DIR/$ZIP_NAME"
    echo "[4/4] Copied flashable zip to $DOWNLOADS_DIR/$ZIP_NAME"
fi

echo "================================================="
echo " BUILD SUCCESSFUL!"
echo " Flashable Zip: $FINAL_ZIP ($ZIP_SIZE)"
echo " Flash on device via KernelSU Manager or APatch / Magisk."
echo "================================================="
