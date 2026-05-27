#!/bin/bash
# ============================================================
# build_audioag_driver.sh
# Compila un binario BlackHole con identidad "Estudio Ag Output"
# y lo instala como driver HAL en macOS
# ============================================================
set -e

DRIVER_NAME="AudioAg_Output"
DEVICE_DISPLAY_NAME="Estudio Ag Output"
DEVICE_UID="AudioAg_Output_UID"
BUNDLE_ID="com.estudioag.output.driver"
FACTORY_UUID="f4a7c9d2-e1b0-4a3f-8c7d-9e8f0a1b2c3d"
NUM_CHANNELS=2
HAL_PATH="/Library/Audio/Plug-Ins/HAL"
BUILD_DIR="/tmp/BlackHole_EstudioAg_Build"
SRC_DIR="/tmp/BlackHole_EstudioAg"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_BUNDLE="$PROJECT_DIR/driver/${DRIVER_NAME}.driver"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Estudio Ag Output Driver Builder v1.0      ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

if [ ! -d "$SRC_DIR" ]; then
    echo "📥 Clonando BlackHole..."
    git clone --depth=1 https://github.com/ExistentialAudio/BlackHole.git "$SRC_DIR"
else
    echo "✅ Fuente BlackHole encontrada en $SRC_DIR"
fi

echo "🔧 Parcheando BlackHole.plist con UUID: $FACTORY_UUID"
PLIST_PATH="$SRC_DIR/BlackHole/BlackHole.plist"
/usr/libexec/PlistBuddy -c "Delete :CFPlugInFactories" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFPlugInFactories dict" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFPlugInFactories:$FACTORY_UUID string BlackHole_Create" "$PLIST_PATH"

/usr/libexec/PlistBuddy -c "Delete :CFPlugInTypes" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFPlugInTypes dict" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFPlugInTypes:443ABAB8-E7B3-491A-B985-BEB9187030DB array" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFPlugInTypes:443ABAB8-E7B3-491A-B985-BEB9187030DB:0 string $FACTORY_UUID" "$PLIST_PATH"

echo ""
echo "🔨 Compilando driver con Xcode..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild \
    -project "$SRC_DIR/BlackHole.xcodeproj" \
    -scheme BlackHole \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    PRODUCT_NAME="$DRIVER_NAME" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    GCC_PREPROCESSOR_DEFINITIONS='$(inherited) NUM_CHANNELS=2 kDriver_Name="\"Estudio Ag Output\"" kDevice_UID="\"AudioAg_Output_UID\"" kDevice2_UID="\"AudioAg_Output_2_UID\"" kDevice_ModelUID="\"AudioAg_Output_ModelUID\"" kBox_UID="\"AudioAg_Output_Box_UID\"" kManufacturer_Name="\"Estudio Ag\""' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    2>&1 | grep -E "error:|warning:|BUILD |Compiling|Linking|FAILED|succeeded" | head -60

COMPILED_BUNDLE=$(find "$BUILD_DIR" -name "${DRIVER_NAME}.driver" -type d 2>/dev/null | head -1)
if [ -z "$COMPILED_BUNDLE" ]; then
    COMPILED_BUNDLE=$(find "$BUILD_DIR" -name "*.driver" -type d 2>/dev/null | head -1)
fi

if [ -z "$COMPILED_BUNDLE" ]; then
    echo "❌ ERROR: No se encontró el bundle compilado en $BUILD_DIR"
    exit 1
fi

COMPILED_BINARY=$(find "$COMPILED_BUNDLE/Contents/MacOS" -type f | head -1)
mkdir -p "$DRIVER_BUNDLE/Contents/MacOS"
cp "$COMPILED_BINARY" "$DRIVER_BUNDLE/Contents/MacOS/$DRIVER_NAME"
codesign -f -s - "$DRIVER_BUNDLE" 2>&1 && echo "✅ Firmado correctamente"

echo ""
echo "🚀 Instalando en $HAL_PATH..."
sudo rm -rf "$HAL_PATH/$DRIVER_NAME.driver"
sudo cp -R "$DRIVER_BUNDLE" "$HAL_PATH/"
sudo chown -R root:wheel "$HAL_PATH/$DRIVER_NAME.driver"
sudo chmod -R 755 "$HAL_PATH/$DRIVER_NAME.driver"

sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
echo "✅ Proceso completado"
