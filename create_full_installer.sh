#!/bin/bash
# ============================================================
# create_full_installer.sh
# Compila, firma ad-hoc con entitlements y empaqueta la suite 
# Audio AG completa (App nativa + Drivers virtuales HAL).
# Produce el instalador final: AudioAG_Installer.pkg
# ============================================================
set -e

# Configuración
IDENTIFIER="com.audioag.ultimate.v6"
VERSION="6.0.0"
PKG_NAME="AudioAG_Installer.pkg"

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_ROOT/build_final"
PAYLOAD_DIR="$BUILD_DIR/payload"
SCRIPTS_DIR="$BUILD_DIR/scripts"

SRC_PROJECT_DIR="$PROJECT_ROOT/RadioMixerNative/RadioMixerNative"
ENTITLEMENTS_PATH="$SRC_PROJECT_DIR/RadioMixerNative/RadioMixerNative.entitlements"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Audio AG Suite - Creador de Instalador     ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# 1. Limpieza total de carpetas temporales anteriores
echo "🧹 1. Limpiando directorios de compilación y cachés..."
rm -rf "$BUILD_DIR"
rm -rf ~/Library/Developer/Xcode/DerivedData/RadioMixerNative-*
rm -rf "$SRC_PROJECT_DIR/build"
rm -f "$PROJECT_ROOT/$PKG_NAME"
mkdir -p "$PAYLOAD_DIR"
mkdir -p "$SCRIPTS_DIR"

# 2. Compilar la aplicación en modo Release
echo "🏗️  2. Compilando aplicación nativa 'RadioMixerNative' en modo Release..."
cd "$SRC_PROJECT_DIR"

# Limpiar y compilar en una ruta temporal controlada dentro del workspace
# (Evita restricciones de sandboxing de Xcode al limpiar carpetas en /tmp)
TMP_BUILD_OUT="$PROJECT_ROOT/build_app"
rm -rf "$TMP_BUILD_OUT"
mkdir -p "$TMP_BUILD_OUT"

xcodebuild -project "RadioMixerNative.xcodeproj" \
           -scheme "RadioMixerNative" \
           -configuration Release \
           CONFIGURATION_BUILD_DIR="$TMP_BUILD_OUT" \
           build \
           2>&1 | grep -E "error:|warning:|BUILD |Compiling|Linking|FAILED|succeeded" | head -60

APP_COMPILED="$TMP_BUILD_OUT/RadioMixerNative.app"
if [ ! -d "$APP_COMPILED" ]; then
    echo "❌ ERROR: No se pudo compilar RadioMixerNative.app"
    exit 1
fi
echo "   [OK] Compilación finalizada con éxito."

# 3. Renombrar y firmar ad-hoc con entitlements de privacidad
echo "🔐 3. Renombrando e inyectando entitlements a la aplicación..."
APP_TARGET_NAME="$TMP_BUILD_OUT/Audio AG.app"
mv "$APP_COMPILED" "$APP_TARGET_NAME"

PLIST_PATH="$APP_TARGET_NAME/Contents/Info.plist"

# Asegurar textos de descripción en los diálogos de solicitud de permisos
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'Audio AG requiere acceso al micrófono para capturar tus entradas físicas de audio.'" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription 'Audio AG requiere acceso al micrófono para capturar tus entradas físicas de audio.'" "$PLIST_PATH" 2>/dev/null || true

/usr/libexec/PlistBuddy -c "Add :NSScreenCaptureUsageDescription string 'Audio AG requiere acceso para capturar y retransmitir el sonido de tus aplicaciones (Spotify, Navegadores, etc.).'" "$PLIST_PATH" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSScreenCaptureUsageDescription 'Audio AG requiere acceso para capturar y retransmitir el sonido de tus aplicaciones (Spotify, Navegadores, etc.).'" "$PLIST_PATH" 2>/dev/null || true

# Buscar identidad de firma válida en el Llavero del usuario (solución definitiva al bucle de permisos)
echo "🔍 Buscando certificado oficial 'Apple Development' en tu Llavero..."
SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -n 1 | cut -d'"' -f2)

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "   [OK] ¡Certificado detectado!: '$SIGNING_IDENTITY'"
else
    SIGNING_IDENTITY="-"
    echo "   [!] No se encontró certificado Apple Development en el Llavero. Usando firma Ad-Hoc (-)"
fi

# Firmar con entitlements nativos y habilitar Hardened Runtime (--options runtime)
echo "   Firmando bundle 'Audio AG.app'..."
codesign --force --options runtime --sign "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS_PATH" "$APP_TARGET_NAME"
echo "   [OK] Firma con Hardened Runtime aplicada con éxito."

# Crear la estructura de payloads para /Applications (sin subcarpeta, directa a /Applications/)
echo "📂 Estructurando payload para /Applications (sin subcarpeta)..."
# Copiar el desinstalador directamente al directorio raíz del payload temporal
cp "$PROJECT_ROOT/uninstall.sh" "$TMP_BUILD_OUT/Desinstalar Audio AG.command"
chmod +x "$TMP_BUILD_OUT/Desinstalar Audio AG.command"

# 4. Empaquetar la app y los drivers HAL en payloads cegados (tar.gz)
echo "📦 4. Comprimiendo payloads (método blindado para macOS)..."
# Comprimir los binarios sueltos para que se extraigan directamente en /Applications/
tar -czf "$PAYLOAD_DIR/app.tar.gz" -C "$TMP_BUILD_OUT" "Audio AG.app" "Desinstalar Audio AG.command"

# Comprimir ambos drivers del directorio del proyecto si existen
cd "$PROJECT_ROOT"
if [ ! -d "./driver/RadioMixer.driver" ] || [ ! -d "./driver/AudioAG_Output.driver" ]; then
    echo "❌ ERROR: No se encontraron los drivers virtuales en ./driver (RadioMixer.driver o AudioAG_Output.driver)"
    exit 1
fi
tar -czf "$PAYLOAD_DIR/driver.tar.gz" -C "./driver" "RadioMixer.driver" "AudioAG_Output.driver"
echo "   [OK] Payloads empaquetados herméticamente."

# 5. Crear el script de PRE-instalación (Cierra cualquier versión corriendo)
echo "📝 5. Escribiendo script de preinstall..."
cat <<'PREEOF' > "$SCRIPTS_DIR/preinstall"
#!/bin/bash
# Pre-instalador de la Suite Audio AG

if pgrep -fi "Audio AG" > /dev/null 2>&1; then
    echo "Audio AG está en ejecución. Cerrando de forma segura..."
    osascript -e 'tell application "Audio AG" to quit' 2>/dev/null || true
    sleep 2
    pkill -fi "Audio AG" 2>/dev/null || true
    pkill -fi "RadioMixerNative" 2>/dev/null || true
    sleep 1
fi
exit 0
PREEOF
chmod +x "$SCRIPTS_DIR/preinstall"

# 6. Crear el script de POST-instalación (Instala app, instala drivers y refresca CoreAudio)
echo "📝 6. Escribiendo script de postinstall..."
cat <<'EOF' > "$SCRIPTS_DIR/postinstall"
#!/bin/bash
# Post-instalador de la Suite Audio AG

echo "🚚 Extrayendo binarios del sistema..."

# A) Limpieza física de cualquier versión obsoleta
rm -rf "/Applications/Audio AG.app"
rm -rf "/Applications/Audio AG"
rm -rf "/Library/Audio/Plug-Ins/HAL/RadioMixer.driver"
rm -rf "/Library/Audio/Plug-Ins/HAL/AudioAG_Output.driver"

# A2) Purgar cachés de permisos obsoletos en TCC para evitar conflictos de firmas previas
echo "🧹 Purgando cachés de permisos obsoletos en TCC..."
tccutil reset ScreenCapture "Alexgess19.RadioMixerNative" 2>/dev/null || true
tccutil reset Microphone "Alexgess19.RadioMixerNative" 2>/dev/null || true

# B) Descomprimir en directorios definitivos del sistema
tar -xzf "$2/app.tar.gz" -C "/Applications/"
tar -xzf "$2/driver.tar.gz" -C "/Library/Audio/Plug-Ins/HAL/"

# C) Ajustar permisos de los drivers copiados (Root ownership obligatorio en HAL)
chown -R root:wheel "/Library/Audio/Plug-Ins/HAL/RadioMixer.driver"
chmod -R 755 "/Library/Audio/Plug-Ins/HAL/RadioMixer.driver"
chown -R root:wheel "/Library/Audio/Plug-Ins/HAL/AudioAG_Output.driver"
chmod -R 755 "/Library/Audio/Plug-Ins/HAL/AudioAG_Output.driver"

# D) Reiniciar y refrescar el demonio CoreAudio (Muestra de inmediato los dispositivos virtuales)
echo "🔄 Recargando demonio de CoreAudio en caliente..."
killall coreaudiod 2>/dev/null || true
launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || true

# E) Abrir automáticamente la consola para el usuario
sleep 1.5
# Detectar el usuario de la sesión GUI para abrir la app bajo su contexto gráfico
GUI_USER=$(stat -f '%Su' /dev/console)
if [ -n "$GUI_USER" ] && [ "$GUI_USER" != "root" ]; then
    sudo -u "$GUI_USER" open "/Applications/Audio AG.app"
else
    open "/Applications/Audio AG.app"
fi

exit 0
EOF
chmod +x "$SCRIPTS_DIR/postinstall"

# 7. Construir paquete componente temporal
echo "🛠️  7. Generando paquete componente..."
pkgbuild --root "$PAYLOAD_DIR" \
         --identifier "$IDENTIFIER" \
         --version "$VERSION" \
         --scripts "$SCRIPTS_DIR" \
         --install-location "/private/tmp/audioag_temp" \
         "$BUILD_DIR/component.pkg" \
         >/dev/null

# 8. Empaquetar distribución comercial final (.pkg instalable directo)
echo "📦 8. Compilando instalador final '$PKG_NAME'..."
DIST_DIR="$PROJECT_ROOT/Audio AG Suite"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
productbuild --package "$BUILD_DIR/component.pkg" "$DIST_DIR/$PKG_NAME" >/dev/null

# Copiar el manual técnico a la carpeta de distribución
cp "$PROJECT_ROOT/manual_tecnico_audio_ag.md" "$DIST_DIR/"

# 9. Limpiar deshechos temporales
echo "🧹 9. Limpiando residuos temporales..."
rm -rf "$BUILD_DIR"
rm -rf "$TMP_BUILD_OUT"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  🎉 ¡INSTALADOR COMPILADO CORRECTAMENTE!      ║"
echo "║  Carpeta: Audio AG Suite                     ║"
echo "║  Archivos: $PKG_NAME y manual_tecnico...     ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
