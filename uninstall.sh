#!/bin/bash
echo "Iniciando desinstalación total de Audio AG..."

# 1. Cerrar la app si está abierta
pkill -i "Audio AG"

# 2. Eliminar archivos de aplicación
rm -rf "/Applications/Audio AG.app"

# 3. Eliminar configuraciones y caché
rm -rf "$HOME/Library/Application Support/Audio AG"
rm -rf "$HOME/Library/Preferences/com.herboradio.mixer.plist"
rm -rf "$HOME/Library/Caches/com.herboradio.mixer"

# 4. Nota sobre el dispositivo virtual
echo "Limpieza completada."
echo "Nota: El dispositivo 'Audio AG' en Audio MIDI Setup debe eliminarse manualmente seleccionándolo y pulsando el botón '-'."
