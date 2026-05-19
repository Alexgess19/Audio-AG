#!/bin/bash
# ============================================================
# build_audioag_driver.sh
# Compila un binario BlackHole con identidad "Audio AG Output"
# y lo instala como driver HAL en macOS
# ============================================================
set -e

DRIVER_NAME="AudioAG_Output"
DEVICE_DISPLAY_NAME="Audio AG Output"
DEVICE_UID="AudioAG_Output_UID"
BUNDLE_ID="com.audioag.output.driver"
FACTORY_UUID="f4a7c9d2-e1b0-4a3f-8c7d-9e8f0a1b2c3d"
NUM_CHANNELS=2
HAL_PATH="/Library/Audio/Plug-Ins/HAL"
BUILD_DIR="/tmp/BlackHole_AudioAG_Build"
SRC_DIR="/tmp/BlackHole_AudioAG"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_BUNDLE="$PROJECT_DIR/driver/${DRIVER_NAME}.driver"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Audio AG Output Driver Builder v1.0        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── 1. Verificar fuente de BlackHole ──────────────────────────
if [ ! -d "$SRC_DIR" ]; then
    echo "📥 Clonando BlackHole..."
    git clone --depth=1 https://github.com/ExistentialAudio/BlackHole.git "$SRC_DIR"
else
    echo "✅ Fuente BlackHole encontrada en $SRC_DIR"
fi

# ── 2. Patch: actualizar plist con el UUID correcto ────────────
echo "🔧 Parcheando BlackHole.plist con UUID: $FACTORY_UUID"
PLIST_PATH="$SRC_DIR/BlackHole/BlackHole.plist"
# Reemplazar UUID del factory en el plist de origen
/usr/libexec/PlistBuddy -c "Delete :CFPlugInFactories" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFPlugInFactories dict" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFPlugInFactories:$FACTORY_UUID string BlackHole_Create" "$PLIST_PATH"

/usr/libexec/PlistBuddy -c "Delete :CFPlugInTypes" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFPlugInTypes dict" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFPlugInTypes:443ABAB8-E7B3-491A-B985-BEB9187030DB array" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :CFPlugInTypes:443ABAB8-E7B3-491A-B985-BEB9187030DB:0 string $FACTORY_UUID" "$PLIST_PATH"

# ── 3. Compilar con xcodebuild pasando defines custom ─────────
echo ""
echo "🔨 Compilando driver con Xcode..."
echo "   Nombre del dispositivo : \"$DEVICE_DISPLAY_NAME\""
echo "   UID del dispositivo    : \"$DEVICE_UID\""
echo "   Bundle ID              : \"$BUNDLE_ID\""
echo "   Canales                : $NUM_CHANNELS"
echo ""

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild \
    -project "$SRC_DIR/BlackHole.xcodeproj" \
    -scheme BlackHole \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    PRODUCT_NAME="$DRIVER_NAME" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    GCC_PREPROCESSOR_DEFINITIONS='$(inherited) NUM_CHANNELS=2 kDriver_Name="\"Audio AG Output\"" kDevice_UID="\"AudioAG_Output_UID\"" kDevice2_UID="\"AudioAG_Output_2_UID\"" kDevice_ModelUID="\"AudioAG_Output_ModelUID\"" kBox_UID="\"AudioAG_Output_Box_UID\"" kManufacturer_Name="\"Audio AG\""' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    2>&1 | grep -E "error:|warning:|BUILD |Compiling|Linking|FAILED|succeeded" | head -60

echo ""
echo "🔍 Buscando bundle compilado..."
COMPILED_BUNDLE=$(find "$BUILD_DIR" -name "${DRIVER_NAME}.driver" -type d 2>/dev/null | head -1)

if [ -z "$COMPILED_BUNDLE" ]; then
    # Buscar con nombre genérico BlackHole.driver
    COMPILED_BUNDLE=$(find "$BUILD_DIR" -name "*.driver" -type d 2>/dev/null | head -1)
fi

if [ -z "$COMPILED_BUNDLE" ]; then
    echo "❌ ERROR: No se encontró el bundle compilado en $BUILD_DIR"
    find "$BUILD_DIR" -name "*.driver" 2>/dev/null
    exit 1
fi

echo "✅ Bundle compilado: $COMPILED_BUNDLE"

# ── 4. Actualizar bundle en el proyecto ───────────────────────
echo ""
echo "📦 Actualizando driver en el proyecto..."
COMPILED_BINARY=$(find "$COMPILED_BUNDLE/Contents/MacOS" -type f | head -1)

if [ -z "$COMPILED_BINARY" ]; then
    echo "❌ ERROR: No se encontró binario en el bundle compilado"
    exit 1
fi

echo "   Binario compilado: $COMPILED_BINARY"

# Verificar que el nombre del dispositivo está correcto en el binario
if strings "$COMPILED_BINARY" | grep -q "Audio AG Output"; then
    echo "✅ El binario contiene 'Audio AG Output' correctamente"
else
    echo "⚠️  Advertencia: 'Audio AG Output' no encontrado en strings del binario"
    strings "$COMPILED_BINARY" | grep -i "audio\|blackhole\|mixer" | head -10
fi

# Copiar binario al driver bundle del proyecto
mkdir -p "$DRIVER_BUNDLE/Contents/MacOS"
cp "$COMPILED_BINARY" "$DRIVER_BUNDLE/Contents/MacOS/$DRIVER_NAME"
echo "✅ Binario copiado a $DRIVER_BUNDLE/Contents/MacOS/$DRIVER_NAME"

# ── 5. Firmar el driver ────────────────────────────────────────
echo ""
echo "🖋️  Firmando driver con ad-hoc signature..."
codesign -f -s - "$DRIVER_BUNDLE" 2>&1 && echo "✅ Firmado correctamente"

# ── 6. Instalar en el sistema ─────────────────────────────────
echo ""
echo "🚀 Instalando en $HAL_PATH..."
sudo rm -rf "$HAL_PATH/$DRIVER_NAME.driver"
sudo cp -R "$DRIVER_BUNDLE" "$HAL_PATH/"
sudo chown -R root:wheel "$HAL_PATH/$DRIVER_NAME.driver"
sudo chmod -R 755 "$HAL_PATH/$DRIVER_NAME.driver"

# ── 7. Reiniciar CoreAudio ────────────────────────────────────
echo ""
echo "🔄 Reiniciando CoreAudio..."
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod
sleep 2

# ── 8. Verificar resultado ────────────────────────────────────
echo ""
echo "🔍 Verificando dispositivos de audio..."
sleep 1
RESULT=$(system_profiler SPAudioDataType 2>/dev/null | grep -A3 "Audio AG")

if [ -n "$RESULT" ]; then
    echo "🎉 ¡ÉXITO! El dispositivo 'Audio AG Output' aparece en el sistema:"
    echo "$RESULT"
else
    echo "⚠️  El dispositivo aún no aparece en system_profiler."
    echo "   Intenta: sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod"
    echo "   O reinicia la Mac para forzar la carga del driver."
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   ✅ Proceso completado                      ║"
echo "╚══════════════════════════════════════════════╝"
