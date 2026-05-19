#!/bin/bash
set -e

PROJECT_DIR="/Users/alex/Proyectos anexos/radio-mixer/RadioMixerNative/RadioMixerNative"
OUTPUT_DIR="/Users/alex/Proyectos anexos/radio-mixer/dist"
APP_NAME="RadioMixerNative"

echo "🧹 Limpiando compilaciones anteriores..."
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/$APP_NAME.app"
rm -rf "$OUTPUT_DIR/AudioAG_Console.pkg"

echo "🏗️ Compilando aplicación nativa en modo Release..."
cd "$PROJECT_DIR"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release CONFIGURATION_BUILD_DIR="$OUTPUT_DIR" clean build | grep -A 5 error || true

echo "🔐 Inyectando permisos de privacidad (Micrófono y Captura)..."
PLIST_PATH="$OUTPUT_DIR/$APP_NAME.app/Contents/Info.plist"

# Inyectar permisos si no existen en el Info.plist resultante
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'Audio AG requiere acceso al micrófono para transmitir tu voz.'" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription 'Audio AG requiere acceso al micrófono para transmitir tu voz.'" "$PLIST_PATH" 2>/dev/null || true

/usr/libexec/PlistBuddy -c "Add :NSScreenCaptureUsageDescription string 'Audio AG requiere acceso para capturar el audio de aplicaciones.'" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSScreenCaptureUsageDescription 'Audio AG requiere acceso para capturar el audio de aplicaciones.'" "$PLIST_PATH" 2>/dev/null || true

echo "✍️ Firmando aplicación (Ad-Hoc)..."
codesign --force --deep --sign - "$OUTPUT_DIR/$APP_NAME.app"

echo "📦 Empaquetando en un instalador PKG..."
cd "$OUTPUT_DIR"
pkgbuild --component "$APP_NAME.app" --install-location "/Applications" "AudioAG_Console.pkg"

echo "✅ ¡Empaquetado completo!"
echo "El instalador se encuentra en: $OUTPUT_DIR/AudioAG_Console.pkg"
