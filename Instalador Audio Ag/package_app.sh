#!/bin/bash
set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$PROJECT_ROOT/EstudioAg/EstudioAg"
OUTPUT_DIR="$PROJECT_ROOT/dist"
APP_NAME="EstudioAg"

echo "🧹 Limpiando compilaciones anteriores..."
mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR/$APP_NAME.app"
rm -rf "$OUTPUT_DIR/EstudioAg_Console.pkg"

echo "🏗️ Compilando aplicación nativa en modo Release..."
cd "$PROJECT_DIR"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release CONFIGURATION_BUILD_DIR="$OUTPUT_DIR" clean build \
    2>&1 | grep -E "error:|warning:|BUILD |FAILED|succeeded" | head -30

echo "🔐 Inyectando permisos de privacidad..."
PLIST_PATH="$OUTPUT_DIR/$APP_NAME.app/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'Estudio Ag requiere acceso al micrófono para transmitir tu voz.'" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription 'Estudio Ag requiere acceso al micrófono para transmitir tu voz.'" "$PLIST_PATH" 2>/dev/null || true

/usr/libexec/PlistBuddy -c "Add :NSScreenCaptureUsageDescription string 'Estudio Ag requiere acceso para capturar el audio de aplicaciones.'" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSScreenCaptureUsageDescription 'Estudio Ag requiere acceso para capturar el audio de aplicaciones.'" "$PLIST_PATH" 2>/dev/null || true

echo "✍️ Firmando aplicación (Ad-Hoc)..."
codesign --force --deep --sign - "$OUTPUT_DIR/$APP_NAME.app"

echo "📦 Empaquetando en un instalador PKG..."
cd "$OUTPUT_DIR"
pkgbuild --component "$APP_NAME.app" --install-location "/Applications" "EstudioAg_Console.pkg"

echo "✅ ¡Empaquetado completo!"
echo "El instalador se encuentra en: $OUTPUT_DIR/EstudioAg_Console.pkg"
