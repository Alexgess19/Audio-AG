/**
 * main.js - Lógica del Proceso Principal de Electron
 * Este archivo gestiona la ventana de la aplicación y la comunicación de bajo nivel con macOS.
 */
const { app, BrowserWindow, ipcMain, systemPreferences, dialog } = require('electron');
const { exec, spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

let mainWindow;
let tapHelper = null; // Proceso AudioTapHelper

// Configuración de Electron para permitir reproducción de audio sin interacción previa del usuario
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

/**
 * Crea la ventana principal de la aplicación.
 * Define el tamaño, estilo 'glassmorphism' y carga el archivo HTML del mezclador.
 */
function createWindow() {
  try {
    mainWindow = new BrowserWindow({
      width: 1400, height: 860, minWidth: 1100, minHeight: 700,
      backgroundColor: '#f8fafc', titleBarStyle: 'hidden',
      trafficLightPosition: { x: 12, y: 11 },
      webPreferences: { 
        nodeIntegration: false, 
        contextIsolation: true, 
        preload: path.join(__dirname, 'preload.js'),
        backgroundThrottling: false
      },
      title: 'Audio AG - Pro Mixer'
    });
    mainWindow.setMenuBarVisibility(false);
    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));
  } catch (e) {
    console.error('[Main] Fallo al crear ventana:', e);
  }
}

app.whenReady().then(async () => {
  if (process.platform === 'darwin') {
      const status = systemPreferences.getMediaAccessStatus('microphone');
      if (status !== 'granted') {
          await systemPreferences.askForMediaAccess('microphone');
      }
  }
  createWindow();
  startTapHelper();
});

function startTapHelper() {
  const helperPath = path.join(__dirname, 'helpers', 'AudioTapHelper');
  if (!fs.existsSync(helperPath)) {
    console.warn('[TapHelper] Binario no encontrado:', helperPath);
    return;
  }
  tapHelper = spawn(helperPath, [], { stdio: ['ignore', 'pipe', 'pipe'] });

  let lineBuffer = '';
  tapHelper.stdout.on('data', (chunk) => {
    lineBuffer += chunk.toString();
    const lines = lineBuffer.split('\n');
    lineBuffer = lines.pop(); // guardar línea incompleta
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const level = JSON.parse(trimmed);
        mainWindow?.webContents.send('audio-level', level);
      } catch (_) {}
    }
  });

  tapHelper.stderr.on('data', (d) => console.log('[TapHelper]', d.toString().trim()));
  tapHelper.on('exit', (code) => {
    console.log('[TapHelper] Salió con código:', code);
    tapHelper = null;
  });
  console.log('[TapHelper] Iniciado, PID:', tapHelper.pid);
}

ipcMain.handle('fix-permissions', async () => {
    if (process.platform === 'darwin') {
        exec('tccutil reset Microphone', () => {});
        return await systemPreferences.askForMediaAccess('microphone');
    }
    return true;
});

// ──────────────────────────────────────────────
//  IPC: Detección Universal con Protecciones
// ──────────────────────────────────────────────
ipcMain.handle('get-audio-apps', async () => {
  return new Promise((resolve) => {
    try {
      if (process.platform !== 'darwin') return resolve([]);
      
      // Comando más agresivo para detectar apps con ventana y sonido
      const script = `osascript -e 'tell application "System Events" to get name of every application process whose background only is false'`;
      exec(script, (err, stdout) => {
        if (err) return resolve([]);
        
        const names = stdout.split(',').map(n => n.trim());
        const systemExcludes = ['Finder', 'Dock', 'Audio AG', 'ControlCenter', 'NotificationCenter', 'LoginWindow', 'SystemUIServer', 'System Events'];
        
        const apps = names
          .filter(name => !systemExcludes.includes(name))
          .map(name => ({
            name, pid: 0, hasAudio: true, volume: 80, icon: getAppEmoji(name)
          }));
          
        resolve(apps);
      });
    } catch (e) {
      console.error('[IPC] Error get-audio-apps:', e);
      resolve([]);
    }
  });
});

ipcMain.handle('get-audio-devices', async () => {
  return new Promise((resolve) => {
    try {
      exec(`system_profiler SPAudioDataType -json 2>/dev/null`, (err, stdout) => {
        if (err) return resolve([]);
        try {
          const data = JSON.parse(stdout);
          const devices = [];
          data.SPAudioDataType.forEach(category => {
            const items = category._items || [];
            items.forEach(item => {
              devices.push({
                name: item._name,
                deviceId: item.coreaudio_device_id || item._name,
                kind: item.coreaudio_device_input === 'Yes' ? 'audioinput' : 'audiooutput',
                label: item._name,
                isDefault: !!item.coreaudio_default_audio_input_device || !!item.coreaudio_default_audio_output_device,
              });
            });
          });
          resolve(devices);
        } catch (e) { resolve([]); }
      });
    } catch (e) { resolve([]); }
  });
});

ipcMain.handle('set-app-volume', async (event, { appName, volume }) => {
  try {
    const vol = Math.round(volume * 100);
    const script = `try\ntell application "${appName}" to set sound volume to ${vol}\nreturn "ok"\nend try`;
    exec(`osascript -e '${script}'`, (err, stdout) => {
      if (err || stdout.trim() !== 'ok') {
        const sysScript = `tell application "System Events" to set volume of (first process whose name is "${appName}") to ${vol / 100}`;
        exec(`osascript -e '${sysScript}'`);
      }
    });
  } catch (e) { console.error('Error set-app-volume:', e); }
  return { success: true };
});

ipcMain.handle('get-system-volume', async () => {
  return new Promise((resolve) => {
    try {
      exec(`osascript -e 'output volume of (get volume settings)'`, (err, stdout) => {
        resolve({ volume: err ? 75 : parseInt(stdout.trim()) });
      });
    } catch (e) { resolve({ volume: 75 }); }
  });
});

ipcMain.handle('set-system-volume', async (event, { volume }) => {
  try {
    const vol = Math.round(volume);
    exec(`osascript -e 'set volume output volume ${vol}'`);
  } catch (e) {}
  return { success: true };
});

ipcMain.handle('check-virtual-device', async () => {
  return new Promise((resolve) => {
    try {
      exec(`system_profiler SPAudioDataType 2>/dev/null | grep -i -E "audio ag|blackhole|radio remix"`, (err, stdout) => {
        resolve({ found: !err && stdout.trim().length > 0, name: 'Audio AG Virtual' });
      });
    } catch (e) { resolve({ found: false }); }
  });
});

ipcMain.handle('install-pro-driver', async () => {
    // setupProDriver(); // No definido en este scope
    return { success: true };
});

ipcMain.handle('show-save-dialog', async (event, options) => {
    return await dialog.showSaveDialog(mainWindow, options);
});

// Guarda chunks del WebM temporal en la carpeta temp del sistema
ipcMain.handle('save-file-chunk', async (event, { filePath, buffer }) => {
    try {
        const buf = Buffer.from(buffer);
        if (buf.length === 0) {
            // Primer llamada: limpiar/crear el archivo
            fs.writeFileSync(filePath, Buffer.alloc(0));
        } else {
            fs.appendFileSync(filePath, buf);
        }
        return { success: true };
    } catch (e) {
        console.error('Error saving chunk:', e);
        return { success: false, error: e.message };
    }
});

// Convierte el WebM temporal al formato final usando ffmpeg-static
ipcMain.handle('convert-recording', async (event, { tempPath, finalPath, format }) => {
    return new Promise((resolve) => {
        let ffmpegBin;
        try {
            ffmpegBin = require('ffmpeg-static');
        } catch (e) {
            return resolve({ success: false, error: 'ffmpeg-static no encontrado: ' + e.message });
        }

        const args = ['-y', '-i', tempPath];

        if (format === 'mp3') {
            args.push('-vn', '-ar', '44100', '-ac', '2', '-b:a', '192k', finalPath);
        } else if (format === 'mp4') {
            // MP4 con video negro (para compatibilidad máxima)
            args.push('-vn', '-acodec', 'aac', '-b:a', '192k', finalPath);
        } else if (format === 'wav') {
            args.push('-vn', '-ar', '48000', '-ac', '2', '-acodec', 'pcm_s16le', finalPath);
        } else if (format === 'ogg') {
            args.push('-vn', '-acodec', 'libvorbis', '-q:a', '6', finalPath);
        } else {
            // Copia directa (webm)
            args.push('-c', 'copy', finalPath);
        }

        console.log('[FFmpeg] Convirtiendo:', args.join(' '));
        const proc = spawn(ffmpegBin, args);

        proc.stderr.on('data', (d) => console.log('[FFmpeg]', d.toString()));

        proc.on('close', (code) => {
            // Eliminar el archivo temporal
            try { fs.unlinkSync(tempPath); } catch (_) {}
            if (code === 0) {
                resolve({ success: true });
            } else {
                resolve({ success: false, error: `ffmpeg terminó con código ${code}` });
            }
        });

        proc.on('error', (err) => {
            try { fs.unlinkSync(tempPath); } catch (_) {}
            resolve({ success: false, error: err.message });
        });
    });
});

function getAppEmoji(name) {
  const map = { Spotify: '🎵', Music: '🎶', VLC: '🔺', Chrome: '🌐', Safari: '🧭', Firefox: '🦊', Zoom: '📹', Discord: '💬', Slack: '💼', YouTube: '📺', WhatsApp: '📞' };
  for (const [key, emoji] of Object.entries(map)) if (name.toLowerCase().includes(key.toLowerCase())) return emoji;
  return '🔊';
}

app.on('window-all-closed', () => {
  if (tapHelper) { tapHelper.kill('SIGTERM'); tapHelper = null; }
  if (process.platform !== 'darwin') app.quit();
});
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
