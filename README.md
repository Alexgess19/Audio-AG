# Estudio Ag

Consola de audio profesional para macOS que permite enrutar múltiples fuentes de audio (micrófonos, aplicaciones) a salidas virtuales con mezcla independiente, control de EQ, niveles, pan y funciones de broadcast.

## Características Principales
- **Driver virtual Estudio Ag Output**: Dispositivo de audio virtual de 2 canales para monitoreo PFL.
- **Driver virtual Estudio Ag Input (AudioAg_Input)**: Dispositivo de transmisión para enviar la mezcla al aire.
- **Control Físico**: Conexión directa con drivers físicos (ShureLink, SoundSource, etc.) mediante MIDI.
- **3 Canales Físicos + 4 Canales Virtuales**: Gestión integral de todas las fuentes de audio.
- **Mezcla Profesional**: Control independiente de volumen, pan, mute, solo y PFL por canal.
- **Edición de Audio**: Ecualizador paramétrico con preseteos y medición en tiempo real.
- **Masterización**: Bus maestro con control de volumen, mute, solo, PFL, VU Meter y limiter.

## Estructura del Proyecto

| Carpeta | Descripción |
|---------|-------------|
| `EstudioAg/` | Aplicación nativa (Xcode / SwiftUI) |
| `Instalador Audio Ag/` | Scripts para crear el instalador PKG |
| `Desinstalador Audio Ag/` | Script de desinstalación completa |
| `Estudio Ag Suite/` | Salida de distribución (PKG + manual) |
| `driver/` | Drivers HAL (`AudioAg_Input`, `AudioAg_Output`) |

## Instalación

### Instalador completo (app + drivers)

```bash
./Instalador\ Audio\ Ag/create_full_installer.sh
```

El instalador se genera en `Estudio Ag Suite/EstudioAg_Installer.pkg`.

### Recompilar driver de salida

```bash
./build_audioag_driver.sh
```

## Requisitos
- macOS 13.0+
- Xcode 14+

## Licencia
BlackHole: [MIT License](https://github.com/ExistentialAudio/BlackHole/blob/main/LICENSE)
