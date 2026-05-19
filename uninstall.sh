#!/bin/bash
# ============================================================
# uninstall.sh
# Script de desinstalación completa y limpia para Audio AG Suite
# Elimina la aplicación, drivers HAL virtuales y limpia cachés.
# Requiere privilegios de Administrador (sudo) para remover drivers.
# ============================================================

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Audio AG Suite - Desinstalador Oficial     ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# 1. Comprobar privilegios de administrador para la parte del sistema
if [ "$EUID" -ne 0 ]; then
    echo "🔐 Se requieren privilegios de Administrador para remover los drivers de audio."
    echo "   Por favor, introduce tu contraseña de macOS si se te solicita."
    echo ""
    # Relanzar el script usando sudo
    sudo "$0" "$@"
    exit $?
fi

# Guardar el usuario real para limpiar sus carpetas locales (~ / $HOME de sudo es /var/root)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "🛑 1. Cerrando aplicación y servicios activos..."
# Intentar cierre suave vía AppleScript si la sesión gráfica del usuario está activa
if [ -n "$SUDO_USER" ]; then
    sudo -u "$REAL_USER" osascript -e 'tell application "Audio AG" to quit' 2>/dev/null || true
fi
sleep 1
# Forzar el cierre definitivo de cualquier proceso huérfano
pkill -fi "Audio AG" 2>/dev/null || true
pkill -fi "RadioMixerNative" 2>/dev/null || true
echo "   [OK] Aplicaciones cerradas."

echo "🗑️  2. Eliminando binarios de la aplicación..."
rm -rf "/Applications/Audio AG.app"
rm -rf "/Applications/Audio AG"
rm -f "/Applications/Desinstalar Audio AG.command"
echo "   [OK] Aplicación removida de /Applications."

echo "🎙️  3. Desinstalando drivers virtuales HAL de CoreAudio..."
# Limpiar ambos drivers posibles en el directorio del sistema
DRIVER_PATH="/Library/Audio/Plug-Ins/HAL"
HAS_DRIVERS=false

if [ -d "$DRIVER_PATH/RadioMixer.driver" ]; then
    rm -rf "$DRIVER_PATH/RadioMixer.driver"
    echo "   [OK] Eliminado: RadioMixer.driver"
    HAS_DRIVERS=true
fi

if [ -d "$DRIVER_PATH/AudioAG_Output.driver" ]; then
    rm -rf "$DRIVER_PATH/AudioAG_Output.driver"
    echo "   [OK] Eliminado: AudioAG_Output.driver"
    HAS_DRIVERS=true
fi

if [ "$HAS_DRIVERS" = false ]; then
    echo "   [Info] No se encontraron drivers HAL instalados en el sistema."
fi

echo "🧹 4. Limpiando archivos de configuración, preferencias y cachés locales..."
# Usar la ruta del usuario real para borrar sus preferencias y evitar dejar basura
if [ -d "$REAL_HOME" ]; then
    # Application Support
    rm -rf "$REAL_HOME/Library/Application Support/Audio AG"
    rm -rf "$REAL_HOME/Library/Application Support/RadioMixerNative"
    
    # Plists y Preferencias
    rm -rf "$REAL_HOME/Library/Preferences/com.herboradio.mixer.plist"
    rm -rf "$REAL_HOME/Library/Preferences/com.audioag.ultimate.plist"
    rm -rf "$REAL_HOME/Library/Preferences/com.audioag.ultimate.v6.plist"
    rm -rf "$REAL_HOME/Library/Preferences/Alexgess19.RadioMixerNative.plist"
    
    # Caches
    rm -rf "$REAL_HOME/Library/Caches/com.herboradio.mixer"
    rm -rf "$REAL_HOME/Library/Caches/Alexgess19.RadioMixerNative"
    
    # Asegurar que defaults limpie el registro de persistencia del sistema
    sudo -u "$REAL_USER" defaults delete Alexgess19.RadioMixerNative 2>/dev/null || true
    sudo -u "$REAL_USER" defaults delete com.herboradio.mixer 2>/dev/null || true
    
    echo "   [OK] Preferencias del usuario '$REAL_USER' completamente depuradas."
fi

# 5. Reiniciar CoreAudio para aplicar los cambios de drivers en caliente
if [ "$HAS_DRIVERS" = true ]; then
    echo "🔄 5. Reiniciando motor CoreAudio del sistema..."
    # killall es rápido, kickstart es el estándar moderno y seguro de macOS para no dejar colgado el daemon
    killall coreaudiod 2>/dev/null || true
    launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || true
    echo "   [OK] CoreAudio reiniciado con éxito. Los dispositivos virtuales ya no aparecerán en Configuración MIDI."
else
    echo "🔄 5. Saltando reinicio de CoreAudio (no se modificaron drivers)."
fi

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  🎉 ¡DESINSTALACIÓN COMPLETADA CON ÉXITO!    ║"
echo "║     Audio AG Suite ha sido removido.        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
