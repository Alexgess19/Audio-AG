# Audio-AG

Driver para macOS que permite enrutar múltiples fuentes de audio (micrófonos, aplicaciones) a una salida virtual con mezcla independiente, control de EQ, niveles, pan y funciones de radio profesionales.

## Características Principales
- **Driver Virtual Audio AG Output**: Dispositivo de audio virtual de 2 canales con nombre personalizado.
- **Control Físico**: Conexión directa con drivers físicos (ShureLink, SoundSource, etc.) mediante Midi.
- **3 Canales Físicos + 4 Canales Virtuales**: Gestión integral de todas las fuentes de audio.
- **Mezcla Profesional**: Control independiente de volumen, pan, mute, solo y PFL (Pre-Fader Listen) por canal.
- **Edición de Audio**: Ecualizador paramétrico (4 bandas) con preseteos (Pop, Rock, Jazz, Vocal, Flat) y medición en tiempo real.
- **Masterización**: Bus maestro con control de volumen, mute, solo, PFL,VU Meter y limiter.
- **Monitoreo Avanzado**: Sync de monitores (Studio/Phones) y modo Offline.
- **Persistencia**: Guardado automático de configuraciones (frecuencias EQ, niveles, mappings).

## Instalación del Driver

### Opción 1: Ejecutar Script Automático (Recomendado)

Desde la carpeta raíz del proyecto:
```bash
./build_audioag_driver.sh
```

### Opción 2: Instalación Manual

1. **Compilar BlackHole**: Sigue las instrucciones oficiales de [BlackHole](https://existentialaudio.com/product/blackhole).
2. **Copiar el Driver**: Mueve `BlackHole.driver` a la carpeta de drivers de audio:
   ```bash
   sudo cp -R /path/to/BlackHole.driver /Library/Audio/Plug-Ins/HAL/
   ```
3. **Reiniciar CoreAudio**:
   ```bash
   sudo killall coreaudiod
   ```
4. **Verificar**:
   ```bash
   auval -pk com.audioag.output.driver
   ```

## Requisitos de Software
- macOS 13.0+
- Xcode 14+ (para compilación)

## Licencia
BlackHole: [MIT License](https://github.com/ExistentialAudio/BlackHole/blob/main/LICENSE)
Audio AG Driver: [Commercial License](LICENSE)
