#!/bin/bash

# Configuración
IDENTIFIER="com.radiomixer.audio.ultimate.v6"
VERSION="5.0.0" 
DRIVER_SOURCE="./driver/RadioMixer.driver"
APP_SOURCE="./dist/mac-arm64/Audio AG.app"
PKG_NAME="RadioMixer_Definitive_Installer.pkg"

echo "--- Generador de Instalador (Método Blindado) ---"

# 1. Limpieza total
rm -rf ./build_final
mkdir -p ./build_final/payload
mkdir -p ./build_final/scripts

# 2. Empaquetar la app y driver como tar.gz para cegar a macOS Installer
tar -czf ./build_final/payload/app.tar.gz -C "./dist/mac-arm64" "Audio AG.app"
tar -czf ./build_final/payload/driver.tar.gz -C "./driver" "RadioMixer.driver"

# 3. Forzar permisos correctos en el payload
chmod -R 755 ./build_final/payload

# 4. Crear el script de PRE-instalación (cierra la app si está abierta)
cat <<'PREEOF' > ./build_final/scripts/preinstall
#!/bin/bash

# Verificar si Audio AG está corriendo (usando pgrep -fi para ser más robusto con el nombre del proceso)
if pgrep -fi "Audio AG" > /dev/null 2>&1; then
    echo "Audio AG está corriendo. Intentando cerrar..."
    # Intentar cierre suave primero
    osascript -e 'tell application "Audio AG" to quit' 2>/dev/null
    sleep 2
    # Forzar cierre si sigue vivo
    pkill -fi "Audio AG" 2>/dev/null || true
    sleep 1
fi

exit 0
PREEOF
chmod +x ./build_final/scripts/preinstall

# 5. Crear el script de POST-instalación (El que hace el trabajo real)
cat <<'EOF' > ./build_final/scripts/postinstall
#!/bin/bash

# A) Limpiar versiones anteriores del sistema
rm -rf "/Applications/Audio AG.app"
rm -rf "/Library/Audio/Plug-Ins/HAL/RadioMixer.driver"

# B) Mover los archivos desde el paquete temporal a sus lugares definitivos
tar -xzf "$2/app.tar.gz" -C "/Applications/"
tar -xzf "$2/driver.tar.gz" -C "/Library/Audio/Plug-Ins/HAL/"

# C) Reiniciar motor de audio
launchctl kickstart -kp system/com.apple.audio.coreaudiod
killall coreaudiod

# D) Abrir la app
sleep 1
open "/Applications/Audio AG.app"

exit 0
EOF
chmod +x ./build_final/scripts/postinstall

# 6. Construir el paquete base (el payload se instala en una ruta temporal)
echo "Construyendo paquete base..."
pkgbuild --root ./build_final/payload \
         --identifier "$IDENTIFIER" \
         --version "$VERSION" \
         --scripts ./build_final/scripts \
         --install-location "/private/tmp/radiomixer_installer" \
         ./build_final/component.pkg

# 7. Crear el instalador de distribución final
echo "Empaquetando distribución final..."
productbuild --package ./build_final/component.pkg "$PKG_NAME"

# 8. IMPORTANTE: Borrar carpetas temporales para que el proyecto quede limpio
echo "Limpiando archivos temporales..."
rm -rf ./build_final
rm -rf ./dist

echo "------------------------------------------------"
echo "¡LISTO! Prueba este nuevo instalador: $PKG_NAME"
echo "------------------------------------------------"
