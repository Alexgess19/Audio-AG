/**
 * renderer.js - Consola de Radio v7.3 (Estabilidad Total)
 */
let mixerContainer, hardwareContainer, outputSelect, monitorSelect, engineStatusBadge, bhStatus;

// Motores de Audio Duales
let audioContextAir, audioContextPFL;
let masterGainAir, masterGainPFL;

// Grabación
let masterStreamDestREC = null;
let mediaRecorder = null;
let recordingFilePath = '';

// Almacenamiento de nodos
let hardwareNodes = {};
let appNodes = {};
let channelSettings = {};
let levelData = {}; // Niveles en tiempo real por PID: { pid, name, rms, db, pct, cat }
let categoryFaders = { music: 0.8, browser: 0.8, comms: 0.8, other: 0.8 };
let appFaders = {}; // Volumen individual de cada app (fader_individual)
let viewMode = 'process'; // 'process' o 'category'

window.pttFaderAir = null; window.pttFaderPFL = null;
window.pttGateAir = null; window.pttGatePFL = null;

/**
 * init(): Punto de entrada. Prioriza la interfaz sobre el motor de audio.
 */
window.addEventListener('DOMContentLoaded', async () => {
    mixerContainer = document.getElementById('mixer-channels');
    hardwareContainer = document.getElementById('hardware-inputs');
    outputSelect = document.getElementById('master-device');
    monitorSelect = document.getElementById('monitor-device');
    engineStatusBadge = document.getElementById('engine-status');
    bhStatus = document.getElementById('bh-status');

    console.log('[Init] Arrancando interfaz...');
    
    // 1. Configurar botones
    setupListeners();

    // 2. Intentar arrancar motores y dispositivos en paralelo
    startAudioEngine().then(() => {
        // 3. Dibujar canales base ahora que el motor existe
        createSystemChannel();
        loadDevices();
        setInterval(syncApps, 5000);
    }).catch(err => {
        console.error('[Init] Error crítico de audio:', err);
    });
});

function setupListeners() {
    window.addEventListener('click', () => {
        if (audioContextAir?.state === 'suspended') audioContextAir.resume();
        if (audioContextPFL?.state === 'suspended') audioContextPFL.resume();
        updateEngineStatus();
    }, { once: true });

    document.getElementById('btn-reconnect')?.addEventListener('click', () => {
        loadDevices();
        syncApps();
    });

    // ─── Grabación ───────────────────────────────────────────────────
    const recFormatSel  = document.getElementById('rec-format');
    const recPathInput  = document.getElementById('rec-path');
    const btnRec        = document.getElementById('btn-rec');
    const recStatus     = document.getElementById('rec-status');

    // Al cambiar formato, si ya hay ruta guardada, actualizar la extensión
    recFormatSel?.addEventListener('change', () => {
        if (recordingFilePath) {
            const ext = recFormatSel.value;
            recordingFilePath = recordingFilePath.replace(/\.[^.]+$/, `.${ext}`);
            recPathInput.value = recordingFilePath.split('/').pop();
        }
    });

    const selectRecPath = async () => {
        if (mediaRecorder && mediaRecorder.state === 'recording') return;
        const fmt = recFormatSel?.value || 'mp3';
        const filterMap = {
            mp3:  [{ name: 'Audio MP3',  extensions: ['mp3']  }, { name: 'Todos', extensions: ['*'] }],
            mp4:  [{ name: 'Audio MP4',  extensions: ['mp4']  }, { name: 'Todos', extensions: ['*'] }],
            wav:  [{ name: 'Audio WAV',  extensions: ['wav']  }, { name: 'Todos', extensions: ['*'] }],
            ogg:  [{ name: 'Audio OGG',  extensions: ['ogg']  }, { name: 'Todos', extensions: ['*'] }],
            webm: [{ name: 'Audio WebM', extensions: ['webm'] }, { name: 'Todos', extensions: ['*'] }],
        };
        const result = await window.RadioAPI.invoke('show-save-dialog', {
            title: 'Guardar Grabación Como',
            defaultPath: `grabacion_radio.${fmt}`,
            filters: filterMap[fmt] || filterMap.mp3
        });
        if (!result.canceled && result.filePath) {
            recordingFilePath = result.filePath;
            recPathInput.value = recordingFilePath.split('/').pop();
            if (recStatus) recStatus.textContent = `Guardar en: ${recordingFilePath}`;
        }
    };

    recPathInput?.addEventListener('click', selectRecPath);

    btnRec?.addEventListener('click', async () => {
        // DETENER grabación
        if (mediaRecorder && mediaRecorder.state === 'recording') {
            if (recStatus) recStatus.textContent = '⏳ Finalizando y convirtiendo...';
            mediaRecorder.stop();
            return;
        }

        // Verificar que se haya seleccionado una ruta
        if (!recordingFilePath) {
            await selectRecPath();
            if (!recordingFilePath) return;
        }

        startRecording(btnRec, recPathInput, recStatus, recFormatSel?.value || 'mp3');
    });

    document.getElementById('btn-fix-perms')?.addEventListener('click', async () => {
        await window.RadioAPI.invoke('fix-permissions');
        alert('Permisos reiniciados. Por favor, cierra la aplicación, vuelve a abrirla y ACEPTA el permiso de micrófono cuando macOS lo pregunte.');
    });

    outputSelect?.addEventListener('change', async (e) => {
        if (!e.target.value) return;
        try {
            if (audioContextAir && audioContextAir.setSinkId) {
                await audioContextAir.setSinkId(e.target.value);
            }
            updateEngineStatus();
        } catch (e) { console.error('Error OutAir:', e); }
    });

    monitorSelect?.addEventListener('change', async (e) => {
        if (!e.target.value) return;
        try {
            if (audioContextPFL && audioContextPFL.setSinkId) {
                await audioContextPFL.setSinkId(e.target.value);
            }
            updateEngineStatus();
        } catch (e) { console.error('Error OutPFL:', e); }
    });

    document.getElementById('view-mode-select')?.addEventListener('change', (e) => {
        viewMode = e.target.value;
        const processMixer = document.getElementById('mixer-channels');
        const categoryMixer = document.getElementById('category-mixer');
        if (viewMode === 'process') {
            processMixer.style.display = 'grid';
            categoryMixer.style.display = 'none';
        } else {
            processMixer.style.display = 'none';
            categoryMixer.style.display = 'grid';
            renderCategoryMixer();
        }
    });

    // Escuchar niveles de audio del TapHelper
    window.RadioAPI.onAudioLevel((data) => {
        levelData[data.pid] = data;
        updateVUFromTap(data);
        if (viewMode === 'category') updateCategoryLevels();
    });
}

async function startAudioEngine() {
    if (audioContextAir) return;
    audioContextAir = new (window.AudioContext || window.webkitAudioContext)({ latencyHint: 'interactive' });
    audioContextPFL = new (window.AudioContext || window.webkitAudioContext)({ latencyHint: 'interactive' });

    masterGainAir = audioContextAir.createGain();
    masterGainAir.connect(audioContextAir.destination);
    
    masterStreamDestREC = audioContextAir.createMediaStreamDestination();
    masterGainAir.connect(masterStreamDestREC);

    masterGainPFL = audioContextPFL.createGain();
    masterGainPFL.connect(audioContextPFL.destination);

    // Nodos PTT
    window.pttFaderAir = audioContextAir.createGain();
    window.pttGateAir = audioContextAir.createGain();
    window.pttFaderAir.connect(window.pttGateAir);
    window.pttGateAir.connect(masterGainAir);
    window.pttGateAir.gain.value = 0;

    window.pttFaderPFL = audioContextPFL.createGain();
    window.pttGatePFL = audioContextPFL.createGain();
    window.pttFaderPFL.connect(window.pttGatePFL);
    window.pttGatePFL.connect(masterGainPFL);
    window.pttGatePFL.gain.value = 0;

    startVUMeters();
    audioContextAir.onstatechange = updateEngineStatus;
    updateEngineStatus();
}

function startRecording(btnRec, recPathInput, recStatus, format) {
    try {
        // Archivo temporal en la misma carpeta que el destino final
        const dir = recordingFilePath.split('/').slice(0, -1).join('/');
        const timestamp = Date.now();
        const tempPath = `${dir}/.rec_temp_${timestamp}.webm`;

        // Inicializar el archivo temporal
        window.RadioAPI.invoke('save-file-chunk', { filePath: tempPath, buffer: new Uint8Array(0) });

        mediaRecorder = new MediaRecorder(masterStreamDestREC.stream, {
            mimeType: 'audio/webm;codecs=opus'
        });

        mediaRecorder.ondataavailable = async (e) => {
            if (e.data.size > 0) {
                const arrayBuffer = await e.data.arrayBuffer();
                await window.RadioAPI.invoke('save-file-chunk', {
                    filePath: tempPath,
                    buffer: new Uint8Array(arrayBuffer)
                });
            }
        };

        mediaRecorder.onstop = async () => {
            if (recStatus) recStatus.textContent = '⏳ Convirtiendo a ' + format.toUpperCase() + '...';

            const result = await window.RadioAPI.invoke('convert-recording', {
                tempPath,
                finalPath: recordingFilePath,
                format
            });

            btnRec.textContent = '⏺ REC';
            btnRec.style.background = '#ef4444';
            if (recPathInput) recPathInput.style.pointerEvents = 'auto';

            if (result.success) {
                if (recStatus) recStatus.textContent = `✅ Guardado: ${recordingFilePath.split('/').pop()}`;
            } else {
                if (recStatus) recStatus.textContent = `❌ Error: ${result.error}`;
                console.error('[REC] Error de conversión:', result.error);
            }
        };

        mediaRecorder.start(1000); // un chunk por segundo

        btnRec.textContent = '⏹ STOP';
        btnRec.style.background = '#10b981';
        if (recPathInput) recPathInput.style.pointerEvents = 'none';
        if (recStatus) recStatus.textContent = `⏺ Grabando en ${format.toUpperCase()}...`;

    } catch (e) {
        console.error('Error al iniciar grabación:', e);
        if (recStatus) recStatus.textContent = `❌ No se pudo iniciar: ${e.message}`;
    }
}

async function loadDevices() {
    try {
        const devices = await navigator.mediaDevices.enumerateDevices();
        const outputs = devices.filter(d => d.kind === 'audiooutput' && d.deviceId !== 'default');
        
        if (outputSelect) {
            outputSelect.innerHTML = outputs.map(d => `<option value="${d.deviceId}">${d.label || 'Salida'}</option>`).join('');
            if (outputs.length > 0) {
                outputSelect.value = outputs[0].deviceId;
                if (audioContextAir && audioContextAir.setSinkId) audioContextAir.setSinkId(outputs[0].deviceId);
            }
        }
        if (monitorSelect) {
            monitorSelect.innerHTML = outputs.map(d => `<option value="${d.deviceId}">${d.label || 'Monitor'}</option>`).join('');
            if (outputs.length > 1) {
                monitorSelect.value = outputs[1].deviceId;
                if (audioContextPFL && audioContextPFL.setSinkId) audioContextPFL.setSinkId(outputs[1].deviceId);
            } else if (outputs.length > 0) {
                monitorSelect.value = outputs[0].deviceId;
                if (audioContextPFL && audioContextPFL.setSinkId) audioContextPFL.setSinkId(outputs[0].deviceId);
            }
        }

        const inputs = devices.filter(d => d.kind === 'audioinput' && d.deviceId !== 'default');
        
        // Cargar Micrófonos Reales
        inputs.forEach(input => {
            const lbl = input.label.toLowerCase();
            if (!lbl.includes('audio ag') && !lbl.includes('blackhole') && !lbl.includes('radio mixer') && !lbl.includes('radio remix')) {
                createChannelStrip(input.label, '🎙️', hardwareContainer, true, input.deviceId);
            } else {
                window.radioMixerDeviceId = input.deviceId;
                connectRadioMixer();
            }
        });
    } catch (e) { console.error('Device Load Error:', e); }
}

async function connectRadioMixer() {
    try {
        const stream = await navigator.mediaDevices.getUserMedia({
            audio: { deviceId: { exact: window.radioMixerDeviceId }, echoCancellation: false }
        });
        const sourceAir = audioContextAir.createMediaStreamSource(stream);
        const sourcePFL = audioContextPFL.createMediaStreamSource(stream);
        sourceAir.connect(window.pttFaderAir);
        sourcePFL.connect(window.pttFaderPFL);
        window.radioMixerSourceAir = sourceAir;
        window.radioMixerSourcePFL = sourcePFL;
        if (bhStatus) bhStatus.textContent = 'Virtual Patch: OK';
    } catch (e) {
        console.error('Connect Radio Mixer Error:', e);
        if (bhStatus) bhStatus.textContent = 'Patch Error: ' + e.message;
    }
}

function createChannelStrip(name, icon, parent, isHardware = true, deviceId = null, isGeneral = false) {
    const channelId = name.replace(/\s+/g, '-').toUpperCase();
    if (document.getElementById(channelId) || !parent) return;

    const strip = document.createElement('div');
    strip.className = 'channel-strip';
    strip.id = channelId;
    
    strip.innerHTML = `
        <div class="channel-name-block">
            <span class="name-text">${icon} ${name.toUpperCase()}</span>
            <small class="status-text" id="status-${channelId}">MUTE</small>
        </div>
        <div class="channel-body" style="align-items: center; padding-top: 5px;">
            <div class="control-col" style="flex-direction: row; gap: 5px; min-width: 90px;">
                <button class="btn-on-air" id="pfl-${channelId}" style="flex:1; padding: 4px; font-size: 0.55rem;">PFL</button>
                <button class="btn-on-air" id="live-${channelId}" style="flex:1; padding: 4px; font-size: 0.55rem;">LIVE</button>
            </div>
            <div class="unified-fader">
                <div class="fader-wrapper">
                    <div class="vu-bg"></div>
                    <div class="vu-fill" id="vu-${channelId}"></div>
                    <input type="range" class="fader-input" min="0" max="100" value="80" id="fader-${channelId}">
                </div>
                <div class="db-display" id="db-${channelId}">-inf dB</div>
            </div>
        </div>
    `;

    parent.appendChild(strip);

    const fader = strip.querySelector('.fader-input');
    const liveBtn = document.getElementById(`live-${channelId}`);
    const pflBtn = document.getElementById(`pfl-${channelId}`);
    const vuFillEl = document.getElementById(`vu-${channelId}`);
    const dbDisplayEl = document.getElementById(`db-${channelId}`);

    if (audioContextAir) {
        const nodes = createAudioNodes(isHardware, deviceId, isGeneral, channelId);
        
        // Initial setup
        if (nodes) {
            const v = parseFloat(fader.value) / 100;
            if (nodes.fAir) nodes.fAir.gain.value = v;
            if (nodes.fPFL) nodes.fPFL.gain.value = v;
            if (!isHardware && !isGeneral) {
                appFaders[name] = v;
            }
        }

        fader.addEventListener('input', (e) => {
            const v = parseFloat(e.target.value) / 100;
            if (nodes) {
                nodes.fAir.gain.setTargetAtTime(v, audioContextAir.currentTime, 0.03);
                nodes.fPFL.gain.setTargetAtTime(v, audioContextPFL.currentTime, 0.03);
            }
            if (!isHardware && !isGeneral) {
                // Lógica de Bus de Agrupación (Multiplicativa)
                appFaders[name] = v;
                updateAppVolume(name);
            }
        });

        if (liveBtn) {
            liveBtn.addEventListener('click', () => {
                const act = liveBtn.classList.toggle('active');
                if (nodes) nodes.gAir.gain.setTargetAtTime(act ? 1 : 0, audioContextAir.currentTime, 0.05);
                const statusEl = document.getElementById(`status-${channelId}`);
                if (statusEl) {
                    statusEl.textContent = act ? 'ON AIR' : 'MUTE';
                    statusEl.style.color = act ? '#dc2626' : '#94a3b8';
                }
            });
        }

        if (pflBtn) {
            pflBtn.addEventListener('click', () => {
                const act = pflBtn.classList.toggle('active');
                // Distintivo visual para PFL (Naranja/Amarillo)
                pflBtn.style.backgroundColor = act ? '#f59e0b' : '';
                pflBtn.style.color = act ? '#fff' : '';
                pflBtn.style.borderColor = act ? '#d97706' : '';
                
                if (nodes) nodes.gPFL.gain.setTargetAtTime(act ? 1 : 0, audioContextPFL.currentTime, 0.05);
            });
        }

        if (nodes) {
            startChannelVU(channelId, nodes.ana, vuFillEl, dbDisplayEl);
        }
    }
}

function createAudioNodes(isHardware, deviceId, isGeneral, id) {
    if (isGeneral) {
        const ana = audioContextAir.createAnalyser();
        window.pttFaderAir.connect(ana);
        // El canal AUDIO GENERAL debe estar siempre abierto por defecto
        window.pttGateAir.gain.value = 1;
        window.pttGatePFL.gain.value = 1;
        const obj = { fAir: window.pttFaderAir, fPFL: window.pttFaderPFL, gAir: window.pttGateAir, gPFL: window.pttGatePFL, ana };
        appNodes[id] = obj;
        return obj;
    }

    // Canales de app: no tienen stream Web Audio propio (el audio llega por el driver
    // virtual al bus de sistema). Creamos un analyser compartido del bus de entrada
    // para que el VU muestre actividad proporcional al mix del sistema.
    if (!isHardware && !isGeneral) {
        const ana = audioContextAir.createAnalyser();
        ana.fftSize = 256;
        window.pttFaderAir.connect(ana);
        // Nodos ficticios de ganancia (sin efecto real en el audio — el control es
        // via AppleScript), pero necesarios para que el fader listener no crashee.
        const fAir = audioContextAir.createGain();
        const fPFL = audioContextPFL.createGain();
        const gAir = audioContextAir.createGain();
        const gPFL = audioContextPFL.createGain();
        const obj = { fAir, fPFL, gAir, gPFL, ana, isAppProxy: true };
        appNodes[id] = obj;
        return obj;
    }

    const fAir = audioContextAir.createGain();
    const gAir = audioContextAir.createGain();
    const ana = audioContextAir.createAnalyser();
    fAir.connect(gAir); fAir.connect(ana); gAir.connect(masterGainAir); gAir.gain.value = 0;

    const fPFL = audioContextPFL.createGain();
    const gPFL = audioContextPFL.createGain();
    fPFL.connect(gPFL); gPFL.connect(masterGainPFL); gPFL.gain.value = 0;

    const obj = { fAir, fPFL, gAir, gPFL, ana };
    hardwareNodes[id] = obj;

    const connect = () => {
        if (isHardware && deviceId) {
            // Habilitamos filtros WebRTC para aislar la voz y evitar acoples/ecos acústicos
            navigator.mediaDevices.getUserMedia({ audio: { deviceId: { exact: deviceId }, echoCancellation: true, autoGainControl: true, noiseSuppression: true } }).then(s => {
                const sourceAir = audioContextAir.createMediaStreamSource(s);
                const sourcePFL = audioContextPFL.createMediaStreamSource(s);
                sourceAir.connect(fAir);
                sourcePFL.connect(fPFL);
            }).catch(err => {
                console.error(`Error connecting hardware ${id}:`, err);
            });
        }
    };
    connect();
    return obj;
}

function createSystemChannel() {
    createChannelStrip('AUDIO GENERAL', '⚙️', mixerContainer, false, null, true);
    // Activar botón LIVE automáticamente al inicio
    const channelId = 'AUDIO-GENERAL';
    const liveBtn = document.getElementById(`live-${channelId}`);
    if (liveBtn && !liveBtn.classList.contains('active')) {
        liveBtn.classList.add('active');
        const statusEl = document.getElementById(`status-${channelId}`);
        if (statusEl) {
            statusEl.textContent = 'ON AIR';
            statusEl.style.color = '#dc2626';
        }
    }
}

async function syncApps() {
    try {
        const apps = await window.RadioAPI.getAudioApps();
        apps.forEach(app => createChannelStrip(app.name, app.icon, mixerContainer, false));
    } catch (e) {}
}

function updateEngineStatus() {
    if (!engineStatusBadge || !audioContextAir) return;
    const state = audioContextAir.state.toUpperCase();
    engineStatusBadge.textContent = `ENGINE: ${state}`;
    engineStatusBadge.style.background = state === 'RUNNING' ? '#dcfce7' : '#fee2e2';
}

function startVUMeters() {
    const aAir = audioContextAir.createAnalyser();
    masterGainAir.connect(aAir);
    startChannelVU('MASTER', aAir, document.getElementById('master-vu-left'), document.getElementById('master-db'));

    const aPFL = audioContextPFL.createAnalyser();
    masterGainPFL.connect(aPFL);
    startChannelVU('PFL', aPFL, document.getElementById('pfl-master-vu'), document.getElementById('pfl-master-db'));
}

function startChannelVU(id, analyser, vuEl, dbEl) {
    if (!vuEl) return;
    const data = new Uint8Array(analyser.frequencyBinCount);
    const update = () => {
        analyser.getByteTimeDomainData(data);
        let sum = 0;
        for (let i = 0; i < data.length; i++) {
            const f = (data[i] - 128) / 128;
            sum += f * f;
        }
        const rms = Math.sqrt(sum / data.length);
        const db = 20 * Math.log10(rms || 0.00001);
        const pct = Math.max(0, Math.min(100, (db + 60) * 1.66));
        // Todos los faders son horizontales ahora, usamos width
        vuEl.style.width = `${pct}%`;
        if (dbEl) dbEl.textContent = `${Math.round(db)} dB`;
        requestAnimationFrame(update);
    };
    update();
}

// --- NUEVAS FUNCIONES PARA NIVELES Y CATEGORÍAS ---

/**
 * Actualiza el VU y dB de un canal basado en los datos del TapHelper.
 * Busca el canal por nombre (normalizado).
 */
function updateVUFromTap(data) {
    const channelId = data.name.replace(/\s+/g, '-').toUpperCase();
    const vuFill = document.getElementById(`vu-${channelId}`);
    const dbDisplay = document.getElementById(`db-${channelId}`);
    
    if (vuFill && dbDisplay) {
        vuFill.style.width = `${data.pct}%`;
        dbDisplay.textContent = `${data.db} dB`;
        // Color basado en nivel
        if (data.db > -3) vuFill.style.background = '#ef4444'; // Clip
        else if (data.db > -12) vuFill.style.background = '#f59e0b'; // Warning
        else vuFill.style.background = '#10b981'; // OK
    }
}

/**
 * Calcula el nivel máximo de cada categoría y actualiza la vista de categorías.
 */
function updateCategoryLevels() {
    const cats = { music: -96, browser: -96, comms: -96, other: -96 };
    const pcts = { music: 0, browser: 0, comms: 0, other: 0 };
    
    for (const pid in levelData) {
        const item = levelData[pid];
        if (cats[item.cat] !== undefined) {
            cats[item.cat] = Math.max(cats[item.cat], item.db);
            pcts[item.cat] = Math.max(pcts[item.cat], item.pct);
        }
    }
    
    for (const cat in cats) {
        const vuFill = document.getElementById(`vu-CAT-${cat.toUpperCase()}`);
        const dbDisplay = document.getElementById(`db-CAT-${cat.toUpperCase()}`);
        if (vuFill && dbDisplay) {
            vuFill.style.width = `${pcts[cat]}%`;
            dbDisplay.textContent = `${cats[cat]} dB`;
        }
    }
}

/**
 * Renderiza los 4 faders de categoría en el contenedor correspondiente.
 */
function renderCategoryMixer() {
    const container = document.getElementById('category-mixer');
    if (!container) return;
    container.innerHTML = '';
    
    const catConfigs = [
        { id: 'music', name: 'MÚSICA', icon: '🎵' },
        { id: 'browser', name: 'NAVEGADORES', icon: '🌐' },
        { id: 'comms', name: 'COMUNICACIONES', icon: '💬' },
        { id: 'other', name: 'OTROS', icon: '🔊' }
    ];
    
    catConfigs.forEach(cat => {
        const channelId = `CAT-${cat.id.toUpperCase()}`;
        const strip = document.createElement('div');
        strip.className = 'channel-strip';
        strip.innerHTML = `
            <div class="channel-name-block">
                <span class="name-text">${cat.icon} ${cat.name}</span>
            </div>
            <div class="channel-body" style="align-items: center; padding-top: 5px;">
                <div class="unified-fader">
                    <div class="fader-wrapper">
                        <div class="vu-bg"></div>
                        <div class="vu-fill" id="vu-${channelId}"></div>
                        <input type="range" class="fader-input" min="0" max="100" value="${categoryFaders[cat.id] * 100}" id="fader-${channelId}">
                    </div>
                    <div class="db-display" id="db-${channelId}">-inf dB</div>
                </div>
            </div>
        `;
        container.appendChild(strip);
        
        const fader = strip.querySelector('.fader-input');
        fader.addEventListener('input', (e) => {
            const v = parseFloat(e.target.value) / 100;
            categoryFaders[cat.id] = v;
            
            // Al mover el fader de categoría, actualizamos TODAS las apps de esa categoría
            for (const pid in levelData) {
                if (levelData[pid].cat === cat.id) {
                    updateAppVolume(levelData[pid].name);
                }
            }
        });
    });
}

/**
 * Calcula y aplica el volumen final (individual * categoría) a una app.
 */
function updateAppVolume(appName) {
    const individual = appFaders[appName] !== undefined ? appFaders[appName] : 0.8;
    
    // Buscar a qué categoría pertenece esta app
    let category = 'other';
    for (const pid in levelData) {
        if (levelData[pid].name === appName) {
            category = levelData[pid].cat;
            break;
        }
    }
    
    const multiplier = categoryFaders[category];
    const finalVolume = individual * multiplier;
    
    console.log(`[Mixer] ${appName} (Cat: ${category}): ${individual} * ${multiplier} = ${finalVolume}`);
    window.RadioAPI.invoke('set-app-volume', { appName, volume: finalVolume });
}

