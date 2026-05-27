#!/bin/bash
# ============================================================
# uninstall.sh
# Script de desinstalación completa para Estudio Ag
# ============================================================

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Estudio Ag - Desinstalador Oficial         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "🔐 Se requieren privilegios de Administrador para remover los drivers de audio."
    echo "   Por favor, introduce tu contraseña de macOS si se te solicita."
    echo ""
    sudo "$0" "$@"
    exit $?
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "🛑 1. Cerrando aplicación y servicios activos..."
if [ -n "$SUDO_USER" ]; then
    sudo -u "$REAL_USER" osascript -e 'tell application "Estudio Ag" to quit' 2>/dev/null || true
    sudo -u "$REAL_USER" osascript -e 'tell application "Audio AG" to quit' 2>/dev/null || true
fi
sleep 1
pkill -fi "Estudio Ag" 2>/dev/null || true
pkill -fi "EstudioAg" 2>/dev/null || true
pkill -fi "Audio AG" 2>/dev/null || true
pkill -fi "RadioMixerNative" 2>/dev/null || true
echo "   [OK] Aplicaciones cerradas."

echo "🗑️  2. Eliminando binarios de la aplicación..."
rm -rf "/Applications/Estudio Ag.app"
rm -rf "/Applications/Audio AG.app"
rm -rf "/Applications/Audio AG"
rm -f "/Applications/Desinstalar Estudio Ag.command"
rm -f "/Applications/Desinstalar Audio AG.command"
echo "   [OK] Aplicación removida de /Applications."

echo "🎙️  3. Desinstalando drivers virtuales HAL de CoreAudio..."
DRIVER_PATH="/Library/Audio/Plug-Ins/HAL"
HAS_DRIVERS=false

for DRIVER in AudioAg_Input AudioAg_Output RadioMixer AudioAG_Output; do
    if [ -d "$DRIVER_PATH/${DRIVER}.driver" ]; then
        rm -rf "$DRIVER_PATH/${DRIVER}.driver"
        echo "   [OK] Eliminado: ${DRIVER}.driver"
        HAS_DRIVERS=true
    fi
done

if [ "$HAS_DRIVERS" = false ]; then
    echo "   [Info] No se encontraron drivers HAL instalados en el sistema."
fi

echo "🧹 4. Limpiando archivos de configuración, preferencias y cachés locales..."
if [ -d "$REAL_HOME" ]; then
    rm -rf "$REAL_HOME/Library/Application Support/Estudio Ag"
    rm -rf "$REAL_HOME/Library/Application Support/Audio AG"
    rm -rf "$REAL_HOME/Library/Application Support/EstudioAg"
    rm -rf "$REAL_HOME/Library/Application Support/RadioMixerNative"

    rm -rf "$REAL_HOME/Library/Preferences/com.herboradio.mixer.plist"
    rm -rf "$REAL_HOME/Library/Preferences/com.audioag.ultimate.plist"
    rm -rf "$REAL_HOME/Library/Preferences/com.audioag.ultimate.v6.plist"
    rm -rf "$REAL_HOME/Library/Preferences/com.estudioag.ultimate.v1.plist"
    rm -rf "$REAL_HOME/Library/Preferences/Alexgess19.EstudioAg.plist"
    rm -rf "$REAL_HOME/Library/Preferences/Alexgess19.RadioMixerNative.plist"

    rm -rf "$REAL_HOME/Library/Caches/com.herboradio.mixer"
    rm -rf "$REAL_HOME/Library/Caches/Alexgess19.EstudioAg"
    rm -rf "$REAL_HOME/Library/Caches/Alexgess19.RadioMixerNative"

    sudo -u "$REAL_USER" defaults delete Alexgess19.EstudioAg 2>/dev/null || true
    sudo -u "$REAL_USER" defaults delete Alexgess19.RadioMixerNative 2>/dev/null || true
    sudo -u "$REAL_USER" defaults delete com.herboradio.mixer 2>/dev/null || true

    echo "   [OK] Preferencias del usuario '$REAL_USER' completamente depuradas."
fi

if [ "$HAS_DRIVERS" = true ]; then
    echo "🔄 5. Reiniciando motor CoreAudio del sistema..."
    killall coreaudiod 2>/dev/null || true
    launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || true
    echo "   [OK] CoreAudio reiniciado con éxito."
else
    echo "🔄 5. Saltando reinicio de CoreAudio (no se modificaron drivers)."
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  🎉 ¡DESINSTALACIÓN COMPLETADA CON ÉXITO!    ║"
echo "║     Estudio Ag ha sido removido.             ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
