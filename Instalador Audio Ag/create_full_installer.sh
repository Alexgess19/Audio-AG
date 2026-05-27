#!/bin/bash
# ============================================================
# create_full_installer.sh
# Compila, firma ad-hoc con entitlements y empaqueta la suite 
# Estudio Ag completa (App nativa + Drivers virtuales HAL).
# Produce el instalador final: EstudioAg_Installer.pkg
# ============================================================
set -e

IDENTIFIER="com.estudioag.ultimate.v1"
VERSION="1.0.0"
PKG_NAME="EstudioAg_Installer.pkg"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build_final"
PAYLOAD_DIR="$BUILD_DIR/payload"
SCRIPTS_DIR="$BUILD_DIR/scripts"

SRC_PROJECT_DIR="$PROJECT_ROOT/EstudioAg/EstudioAg"
ENTITLEMENTS_PATH="$SRC_PROJECT_DIR/EstudioAg/EstudioAg.entitlements"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Estudio Ag - Creador de Instalador         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

echo "🧹 1. Limpiando directorios de compilación y cachés..."
rm -rf "$BUILD_DIR"
rm -rf ~/Library/Developer/Xcode/DerivedData/EstudioAg-*
rm -rf "$SRC_PROJECT_DIR/build"
rm -f "$PROJECT_ROOT/$PKG_NAME"
mkdir -p "$PAYLOAD_DIR"
mkdir -p "$SCRIPTS_DIR"

echo "🏗️  2. Compilando aplicación nativa 'EstudioAg' en modo Release..."
cd "$SRC_PROJECT_DIR"

TMP_BUILD_OUT="$PROJECT_ROOT/build_app"
rm -rf "$TMP_BUILD_OUT"
mkdir -p "$TMP_BUILD_OUT"

xcodebuild -project "EstudioAg.xcodeproj" \
           -scheme "EstudioAg" \
           -configuration Release \
           CONFIGURATION_BUILD_DIR="$TMP_BUILD_OUT" \
           build \
           2>&1 | grep -E "error:|warning:|BUILD |Compiling|Linking|FAILED|succeeded" | head -60

APP_COMPILED="$TMP_BUILD_OUT/EstudioAg.app"
if [ ! -d "$APP_COMPILED" ]; then
    echo "❌ ERROR: No se pudo compilar EstudioAg.app"
    exit 1
fi
echo "   [OK] Compilación finalizada con éxito."

echo "🔐 3. Renombrando e inyectando entitlements a la aplicación..."
APP_TARGET_NAME="$TMP_BUILD_OUT/Estudio Ag.app"
mv "$APP_COMPILED" "$APP_TARGET_NAME"

PLIST_PATH="$APP_TARGET_NAME/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'Estudio Ag requiere acceso al micrófono para capturar tus entradas físicas de audio.'" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription 'Estudio Ag requiere acceso al micrófono para capturar tus entradas físicas de audio.'" "$PLIST_PATH" 2>/dev/null || true

/usr/libexec/PlistBuddy -c "Add :NSScreenCaptureUsageDescription string 'Estudio Ag requiere acceso para capturar y retransmitir el sonido de tus aplicaciones (Spotify, Navegadores, etc.).'" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSScreenCaptureUsageDescription 'Estudio Ag requiere acceso para capturar y retransmitir el sonido de tus aplicaciones (Spotify, Navegadores, etc.).'" "$PLIST_PATH" 2>/dev/null || true

echo "🔍 Buscando certificado oficial 'Apple Development' en tu Llavero..."
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | cut -d'"' -f2)

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "   [OK] ¡Certificado detectado!: '$SIGNING_IDENTITY'"
else
    SIGNING_IDENTITY="-"
    echo "   [!] No se encontró certificado Apple Development en el Llavero. Usando firma Ad-Hoc (-)"
fi

echo "   Firmando bundle 'Estudio Ag.app'..."
codesign --force --options runtime --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS_PATH" "$APP_TARGET_NAME"
echo "   [OK] Firma con Hardened Runtime aplicada con éxito."

echo "📂 Estructurando payload para /Applications..."
cp "$PROJECT_ROOT/Desinstalador Audio Ag/uninstall.sh" "$TMP_BUILD_OUT/Desinstalar Estudio Ag.command"
chmod +x "$TMP_BUILD_OUT/Desinstalar Estudio Ag.command"

echo "📦 4. Comprimiendo payloads..."
tar -czf "$PAYLOAD_DIR/app.tar.gz" -C "$TMP_BUILD_OUT" "Estudio Ag.app" "Desinstalar Estudio Ag.command"

cd "$PROJECT_ROOT"
if [ ! -d "./driver/AudioAg_Input.driver" ] || [ ! -d "./driver/AudioAg_Output.driver" ]; then
    echo "❌ ERROR: No se encontraron los drivers virtuales en ./driver (AudioAg_Input.driver o AudioAg_Output.driver)"
    exit 1
fi
tar -czf "$PAYLOAD_DIR/driver.tar.gz" -C "./driver" "AudioAg_Input.driver" "AudioAg_Output.driver"
echo "   [OK] Payloads empaquetados."

echo "📝 5. Escribiendo script de preinstall..."
cat <<'PREEOF' > "$SCRIPTS_DIR/preinstall"
#!/bin/bash
if pgrep -fi "Estudio Ag" > /dev/null 2>&1; then
    echo "Estudio Ag está en ejecución. Cerrando de forma segura..."
    osascript -e 'tell application "Estudio Ag" to quit' 2>/dev/null || true
    sleep 2
    pkill -fi "Estudio Ag" 2>/dev/null || true
    pkill -fi "EstudioAg" 2>/dev/null || true
    sleep 1
fi
exit 0
PREEOF
chmod +x "$SCRIPTS_DIR/preinstall"

echo "📝 6. Escribiendo script de postinstall..."
cat <<'EOF' > "$SCRIPTS_DIR/postinstall"
#!/bin/bash
echo "🚚 Extrayendo binarios del sistema..."

rm -rf "/Applications/Estudio Ag.app"
rm -rf "/Applications/Audio AG.app"
rm -rf "/Applications/Audio AG"
rm -rf "/Library/Audio/Plug-Ins/HAL/AudioAg_Input.driver"
rm -rf "/Library/Audio/Plug-Ins/HAL/AudioAg_Output.driver"
rm -rf "/Library/Audio/Plug-Ins/HAL/RadioMixer.driver"
rm -rf "/Library/Audio/Plug-Ins/HAL/AudioAG_Output.driver"

echo "🧹 Purgando cachés de permisos obsoletos en TCC..."
tccutil reset ScreenCapture "Alexgess19.EstudioAg" 2>/dev/null || true
tccutil reset Microphone "Alexgess19.EstudioAg" 2>/dev/null || true
tccutil reset ScreenCapture "Alexgess19.RadioMixerNative" 2>/dev/null || true
tccutil reset Microphone "Alexgess19.RadioMixerNative" 2>/dev/null || true

tar -xzf "$2/app.tar.gz" -C "/Applications/"
tar -xzf "$2/driver.tar.gz" -C "/Library/Audio/Plug-Ins/HAL/"

chown -R root:wheel "/Library/Audio/Plug-Ins/HAL/AudioAg_Input.driver"
chmod -R 755 "/Library/Audio/Plug-Ins/HAL/AudioAg_Input.driver"
chown -R root:wheel "/Library/Audio/Plug-Ins/HAL/AudioAg_Output.driver"
chmod -R 755 "/Library/Audio/Plug-Ins/HAL/AudioAg_Output.driver"

echo "🔄 Recargando demonio de CoreAudio..."
killall coreaudiod 2>/dev/null || true
launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || true

sleep 1.5
GUI_USER=$(stat -f '%Su' /dev/console)
if [ -n "$GUI_USER" ] && [ "$GUI_USER" != "root" ]; then
    sudo -u "$GUI_USER" open "/Applications/Estudio Ag.app"
else
    open "/Applications/Estudio Ag.app"
fi

exit 0
EOF
chmod +x "$SCRIPTS_DIR/postinstall"

echo "🛠️  7. Generando paquete componente..."
pkgbuild --root "$PAYLOAD_DIR" \
         --identifier "$IDENTIFIER" \
         --version "$VERSION" \
         --scripts "$SCRIPTS_DIR" \
         --install-location "/private/tmp/estudioag_temp" \
         "$BUILD_DIR/component.pkg" \
         >/dev/null

echo "📦 8. Compilando instalador final '$PKG_NAME'..."
DIST_DIR="$PROJECT_ROOT/Estudio Ag Suite"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
productbuild --package "$BUILD_DIR/component.pkg" "$DIST_DIR/$PKG_NAME" >/dev/null

cp "$PROJECT_ROOT/manual_tecnico_estudio_ag.md" "$DIST_DIR/"

echo "🧹 9. Limpiando residuos temporales..."
rm -rf "$BUILD_DIR"
rm -rf "$TMP_BUILD_OUT"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  🎉 ¡INSTALADOR COMPILADO CORRECTAMENTE!      ║"
echo "║  Carpeta: Estudio Ag Suite                   ║"
echo "║  Archivos: $PKG_NAME y manual técnico        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
