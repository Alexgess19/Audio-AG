const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('RadioAPI', {
  getAudioApps: () => ipcRenderer.invoke('get-audio-apps'),
  getAudioDevices: () => ipcRenderer.invoke('get-audio-devices'),
  setAppVolume: (appName, volume) => ipcRenderer.invoke('set-app-volume', { appName, volume }),
  getSystemVolume: () => ipcRenderer.invoke('get-system-volume'),
  setSystemVolume: (volume) => ipcRenderer.invoke('set-system-volume', { volume }),
  checkVirtualDevice: () => ipcRenderer.invoke('check-virtual-device'),
  setupVirtualPatch: () => ipcRenderer.invoke('setup-virtual-patch'),
  installProDriver: () => ipcRenderer.invoke('install-pro-driver'),
  invoke: (channel, data) => ipcRenderer.invoke(channel, data),
  platform: process.platform,
  // Niveles de audio por proceso (AudioTapHelper)
  onAudioLevel: (callback) => ipcRenderer.on('audio-level', (_event, data) => callback(data)),
  offAudioLevel: () => ipcRenderer.removeAllListeners('audio-level'),
});
