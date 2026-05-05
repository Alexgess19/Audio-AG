const { app, BrowserWindow } = require('electron');
app.whenReady().then(() => {
    let win = new BrowserWindow({
        webPreferences: { nodeIntegration: true, contextIsolation: false }
    });
    win.webContents.on('console-message', (e, level, msg) => {
        console.log('[RENDERER]', msg);
    });
    win.loadFile('renderer/index.html');
    setTimeout(() => app.quit(), 3000);
});
