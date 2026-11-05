const { app, BrowserWindow, ipcMain, shell, dialog, Menu } = require('electron');
const path = require('path');

let win;
app.setAppUserModelId('com.rashid.jellyjump');
Menu.setApplicationMenu(null);
// نبيّن عنوان الشبكة المحلية الحقيقي حتى الاتصال على نفس الواي فاي يكون مباشر وأسرع
app.commandLine.appendSwitch('disable-features', 'WebRtcHideLocalIpsWithMdns');

function create() {
  win = new BrowserWindow({
    width: 1100,
    height: 720,
    minWidth: 760,
    minHeight: 520,
    title: 'Jelly Jump',
    backgroundColor: '#1b1033',
    icon: path.join(__dirname, 'build', 'icon.png'),
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false,
      backgroundThrottling: false, // النقل يكمل بسرعة حتى لو النافذة مصغّرة
    },
  });
  win.loadFile('index.html');
  // لما تصغّر النافذة يرجع للعبة
  win.on('minimize', () => win.webContents.send('lock'));
  win.on('hide', () => win.webContents.send('lock'));
}

ipcMain.handle('pick', async (_e, folder) => {
  const r = await dialog.showOpenDialog(win, {
    properties: folder ? ['openDirectory'] : ['openFile', 'multiSelections'],
  });
  return r.canceled ? [] : r.filePaths;
});
ipcMain.on('open-path', (_e, p) => shell.openPath(p));
ipcMain.on('show-item', (_e, p) => shell.showItemInFolder(p));
ipcMain.on('focus', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });

app.whenReady().then(create);
app.on('window-all-closed', () => app.quit());
