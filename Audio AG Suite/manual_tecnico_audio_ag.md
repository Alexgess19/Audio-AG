# 📻 Manual Técnico y de Usuario — Audio AG Suite
## Consola de Transmisión Profesional de Baja Latencia para macOS

¡Bienvenido a la documentación oficial de **Audio AG Suite**! Este manual técnico detalla la arquitectura del sistema, el flujo de señales de audio, los pipelines de automatización y la guía de operación del software para que puedas sacarle el máximo partido en entornos de radiodifusión en vivo de nivel profesional.

---

## 🖥️ 1. Requerimientos Mínimos del Sistema

Para garantizar el funcionamiento fluido y la baja latencia del motor de procesamiento en tiempo real, tu Mac debe cumplir con los siguientes requisitos mínimos:

* **Sistema Operativo**: macOS 13.0 (Ventura) o posterior.
  * *Razón*: La API **ScreenCaptureKit** (utilizada para capturar el audio de aplicaciones individuales como Spotify o navegadores de forma nativa) fue introducida por Apple en macOS Ventura y no está disponible en versiones anteriores. Se recomienda encarecidamente macOS 14 (Sonoma) o macOS 15 (Sequoia) para una estabilidad óptima.
* **Procesador**: 
  * **Apple Silicon** (M1, M2, M3, M4 o variantes Pro/Max/Ultra) soportado de forma 100% nativa (Arquitectura ARM64).
  * **Intel Core i5** de 4 núcleos o superior (Arquitectura x86_64).
* **Memoria RAM**: 8 GB mínimo (Se recomiendan 16 GB o más si ejecutas simultáneamente software de streaming pesado, DAWs o múltiples pestañas de navegador con audio).
* **Espacio en Disco**: 50 MB de espacio libre para la aplicación y los controladores virtuales.
* **Hardware de Entrada/Salida**: Cualquier interfaz de audio física, micrófono USB o altavoces integrados compatibles con **CoreAudio** (el estándar nativo de Apple).

---

## 💻 2. Arquitectura del Sistema e Ingeniería

La arquitectura de **Audio AG Suite** está diseñada en torno a la optimización extrema del procesamiento de señales en tiempo real (DSP) y el aislamiento de subprocesos para garantizar un flujo continuo y determinista de audio de calidad broadcast en macOS.

```
+------------------------------------+      +------------------------------------+
|         Fuentes de Entrada         |      |     Procesamiento en Tiempo Real   |
|                                    |      |               RT-CORE              |
|  [Micrófono / Línea Física]        |      |                                    |
|              |                     |      |    [EQ Paramétrico de Precisión]   |
|              v                     |      |                  |                 |
|    HardwareCaptureManager          |      |                  v                 |
|              |                     |      |     [Gate & Limiter Dynamics]      |
|              v                     |      |                  |                 |
|    [Mono-to-Stereo Duplex] --------+----->|                  v                 |
|                                    |      |          [Master Bus Sum] <--------+
|  [Aplicaciones: Spotify/Chrome]    |      |                                    |
|              |                     |      +-----------------+------------------+
|              v                     |                        |
|     ScreenCaptureKit               |                        |
|              |                     |                        v
|              v                     |              +---------+----------+
|     [Lock-Free Ring Buffer] -------+              |  Ruteo de Salidas  |
|                                                   |                    |
|                                                   |     [ON AIR]       |
|                                                   |  (Radio Mixer)     |
|                                                   |                    |
|                                                   |     [PFL Monitor]  |
|                                                   | (Audio AG Output)  |
|                                                   +--------------------+
```

### ⚡ 2.1 Motor RT-CORE de Baja Latencia
En la radiodifusión en vivo, la latencia debe situarse idealmente por debajo de los 20ms para evitar efectos de desfase acústico perceptibles por el locutor. **Audio AG Suite** implementa un motor híbrido optimizado:
* **Separación de Hilos (Decoupling)**: El hilo de procesamiento de audio en tiempo real se ejecuta con prioridad crítica de CoreAudio, totalmente aislado de los hilos de renderizado de la interfaz gráfica (SwiftUI). Las actualizaciones de medición (VU Meters) se envían a través de un store de telemetría ligero (`VUTelemetryStore`) para evitar re-renders innecesarios.
* **Búferes Circulares Libres de Bloqueo (Lock-Free Ring Buffers)**: Toda la transferencia de audio de las aplicaciones capturadas se gestiona mediante punteros atómicos sin bloqueos mutex. Esto garantiza cero fluctuaciones (*jitter*) e impide que el hilo de procesamiento de audio experimente esperas que provoquen sobrecargas en CoreAudio (evitando los famosos errores de `IOWorkLoop skipping cycle due to overload`).
* **Sincronización de Tasa de Muestreo (Sample Rate Parity)**: El motor trabaja de forma nativa a **48kHz** con búferes estándar de **512 / 1024 frames**, ofreciendo un balance óptimo entre eficiencia y baja latencia de ida y vuelta (~10.7ms).

---

## 🎛️ 3. Drivers Virtuales HAL de CoreAudio

La consola utiliza dos controladores virtuales de audio de tipo HAL (Hardware Abstraction Layer) compilados en C++ nativo. Estos drivers funcionan como puertos de hardware virtuales y residen en `/Library/Audio/Plug-Ins/HAL/`:

1. **`Radio Mixer` (Driver de Transmisión)**:
   * **Propósito**: Es el bus principal **"AL AIRE"**. Todo el audio mezclado (micrófono, música, llamadas) se envía a este dispositivo virtual cuando la emisión está activa.
   * **Identificador Único (UUID)**: Configurado exclusivamente para evitar colisiones en CoreAudio.
2. **`Audio AG Output` (Driver de Monitoreo PFL)**:
   * **Propósito**: Funciona como el bus secundario de **Monitoreo PFL (Pre-Fader Listen)**. Permite escuchar música o aplicaciones de forma local en tus audífonos *antes* de enviarlas a la transmisión pública.

---

## 🎙️ 4. Flujo de Procesamiento y DSP

### 4.1 Captura de Micrófonos (Hardware)
El componente `HardwareCaptureManager` interactúa con los micrófonos físicos del equipo.
* **Duplicación Mono-a-Estéreo**: Si se selecciona un micrófono de 1 solo canal (como el interno de la MacBook o interfaces mono), el motor duplica automáticamente el búfer al canal izquierdo y derecho en tiempo real para evitar que la voz del locutor se escuche de un solo lado.
* **Aislamiento de Voz**: Integra opciones avanzadas de CoreAudio para suprimir el ruido ambiental del estudio en caso necesario.

### 4.2 Captura de Aplicaciones (`ScreenCaptureKit`)
`AppCaptureManager` utiliza la API de Apple de alto rendimiento para capturar audio de procesos individuales (Spotify, Chrome, Zoom, etc.):
* **Filtrado Inteligente de Procesos**: Filtra procesos huérfanos del sistema y unifica las firmas de aplicación (ej. evita duplicados como "Spotify Helper" concentrando todo en "Spotify").
* **Captura Blindada sin Video**: Configura la captura de pantalla a una resolución microscópica (16x16 px a 1 FPS) para desactivar la carga de la GPU y capturar exclusivamente el flujo de audio de forma ultra-eficiente.

### 4.3 Cadena de Audio DSP por Canal
Cada canal cuenta con su propia suite de procesamiento acústico:
1. **EQ Paramétrico de Precisión**: Un ecualizador paramétrico multibanda que permite moldear el brillo, presencia y profundidad de las voces o la música.
2. **Procesador de Dinámica (Gate / Limiter)**:
   * **Gate**: Umbral de puerta de ruido para silenciar el micrófono automáticamente cuando el locutor no está hablando, eliminando el ruido de fondo.
   * **Limiter**: Limitador de pico para evitar saturaciones o distorsión digital (*clipping*) cuando el locutor habla demasiado fuerte.

---

## 📦 5. Pipeline de Instalación, Firma y Seguridad

Para garantizar una instalación limpia sin conflictos del sistema y resolver de forma permanente las estrictas políticas de privacidad de macOS Sonoma y Sequoia, se diseñó un pipeline de despliegue industrial robusto:

### 5.1 Firma Digital con Hardened Runtime (CRÍTICO 🔐)
macOS bloquea permanentemente la persistencia de permisos en aplicaciones que capturan pantallas o audio del sistema (ScreenCaptureKit) si estas no tienen un entorno seguro certificado.
* **Detección Dinámica**: El script `create_full_installer.sh` busca automáticamente en tu Llavero local un certificado válido del Apple Developer Program (`Apple Development`).
* **Firma Homologada**: Firma la aplicación bundle utilizando tu identidad oficial e inyecta los privilegios de privacidad requeridos (`com.apple.security.device.audio-input`, etc.).
* **Hardened Runtime**: Agrega la bandera de seguridad `--options runtime` de Apple para habilitar el entorno de ejecución endurecido. Esto le garantiza a macOS que la app es de confianza y **cura definitivamente el bucle infinito de solicitud de permisos**.

### 5.2 Proceso de Instalación Hermético (`create_full_installer.sh`)
El instalador empaqueta la aplicación junto con los scripts de pre/post-instalación en un archivo nativo `.pkg` de macOS:
1. **Fase de Pre-instalación**: Limpia versiones corruptas anteriores y descarga los drivers CoreAudio temporales.
2. **Fase de Despliegue**: Copia la aplicación en `/Applications/Audio AG/` y coloca los drivers HAL en el directorio del sistema.
3. **Fase de Post-instalación**: Ejecuta `killall coreaudiod` para reiniciar el demonio del sistema de audio y hacer que los drivers estén activos de inmediato sin necesidad de reiniciar la computadora.

---

## 🧭 6. Guía de Operación e Interfaz

La consola presenta un diseño premium con un tema oscuro optimizado para ambientes de cabina con poca luz.

### 6.1 Los Controles Principales

#### 🔴 Botón "AL AIRE" / "FUERA DE AIRE"
* **FUERA DE AIRE (Gris)**: La salida del bus de emisión pública está silenciada. Puedes seguir escuchando los canales localmente en tu monitor PFL.
* **AL AIRE (Rojo Brillante)**: La transmisión general está habilitada y todo el audio mezclado se envía al driver virtual `Radio Mixer`.
* **⏱️ Display de Transmisión (HH:MM:SS)**: Al estar "AL AIRE", se despliega de inmediato un contador digital retro-iluminado que mide con absoluta precisión el tiempo exacto que lleva la transmisión activa. Implementado con `TimelineView` nativo para consumir **cero recursos de CPU**.

#### 🎚️ Master Faders
* **MASTER BUS**: Controla el volumen de salida general que se envía a la transmisión pública (Salida al Aire).
* **PFL BUS**: Controla el nivel del monitor local en tus audífonos físicos de estudio.

---

### 6.2 Ajuste de Canales y DSP de Micrófonos

#### 📈 Ecualización Multibanda
Haz clic en el indicador del ecualizador del canal del locutor para abrir el ecualizador de precisión. Ajusta las bandas deslizando las barras de frecuencia (con soporte de rueda de scroll para ajustes micro-métricos).

#### 🎚️ Ajuste de Dinámica (Gate / Limiter)
Utiliza el **RangeSlider** gráfico de dos perillas de color:
* **Perilla Naranja (Gate - Izquierda)**: Deslízala para establecer el umbral mínimo (en dB) por debajo del cual el micrófono se mantendrá muteado.
* **Perilla Celeste (Limiter - Derecha)**: Deslízala para fijar el límite máximo de volumen de salida, impidiendo picos ensordecedores.
* **Zona Activa**: La barra de color degradado entre ambas perillas representa la ventana dinámica segura de tu transmisión.

---

## 🛠️ 7. Diagnóstico y Resolución de Problemas (Troubleshooting)

### 7.1 macOS sigue solicitando permisos en bucle
Si instalaste múltiples compilaciones de prueba anteriores, la base de datos de privacidad de macOS (TCC) puede tener un registro de firmas en conflicto:
1. Cierra **Audio AG** por completo (`Cmd + Q`).
2. Abre la **Terminal** y limpia el registro de ScreenCaptureKit ejecutando:
   ```bash
   tccutil reset ScreenCapture
   ```
3. Ejecuta el nuevo instalador actualizado: [**`AudioAG_Installer.pkg`**](file:///Users/alex/Proyectos%20anexos/radio-mixer/AudioAG_Installer.pkg)
4. Abre la consola, ve a *Configuración del Sistema > Privacidad y seguridad > Grabación de pantalla*, apaga y **vuelve a encender el interruptor de "Audio AG"** para asegurar que registre tu nueva firma oficial de desarrollador.
5. Cierra y vuelve a abrir la app. No te lo volverá a pedir nunca más.

### 7.2 Sobrecargas de Audio ("IOWorkLoop Skipping Cycles")
Si los registros muestran sobrecargas del sistema:
* **Causa**: Varias aplicaciones pesadas o interfaces de audio externas están trabajando a diferentes frecuencias de muestreo (ej. algunas a 44.1kHz y otras a 48kHz), forzando resampleos excesivos.
* **Solución**: Abre la aplicación integrada de macOS **Configuración de Audio MIDI** y asegúrate de que todos tus dispositivos físicos y virtuales (`Radio Mixer`, `Audio AG Output`, Bocinas y Micrófonos) estén configurados de forma estándar a **48,000 Hz (48kHz)**.

---

## 📂 8. Ficheros Clave del Proyecto

Para facilitar futuras actualizaciones, aquí tienes la estructura de los ficheros fuente más importantes:

* 🎛️ **[AudioEngine.swift](file:///Users/alex/Proyectos%20anexos/radio-mixer/RadioMixerNative/RadioMixerNative/RadioMixerNative/Models/AudioEngine.swift)**: El núcleo DSP, la configuración de buses en tiempo real y el inicio del motor de audio.
* 🎙️ **[AppCaptureManager.swift](file:///Users/alex/Proyectos%20anexos/radio-mixer/RadioMixerNative/RadioMixerNative/RadioMixerNative/Models/AppCaptureManager.swift)**: La lógica de captura asíncrona de aplicaciones vía ScreenCaptureKit.
* 🎚️ **[Components.swift](file:///Users/alex/Proyectos%20anexos/radio-mixer/RadioMixerNative/RadioMixerNative/RadioMixerNative/Views/Components.swift)**: Elementos de UI reutilizables (RangeSliders, perillas interactivas, scroll nativo).
* ⚙️ **[create_full_installer.sh](file:///Users/alex/Proyectos%20anexos/radio-mixer/create_full_installer.sh)**: Script automatizado de compilación, firma y creación del instalador del sistema.

---
*Manual técnico desarrollado para la Consola Profesional de Transmisión Audio AG Suite. Todos los derechos reservados. 📻*
