const { app, BrowserWindow, screen } = require("electron");
const fs = require("node:fs");
const bridge = require("./layer.node");

app.setPath("userData", process.env.RAWMASTER_LF_PROFILE);
app.commandLine.appendSwitch("remote-debugging-port", "0");
app.commandLine.appendSwitch("disable-background-networking");
app.commandLine.appendSwitch("disable-renderer-backgrounding");
app.commandLine.appendSwitch("disable-backgrounding-occluded-windows");
app.setActivationPolicy("prohibited");

let window;
app.whenReady().then(async () => {
  const area = screen.getPrimaryDisplay().workArea;
  window = new BrowserWindow({
    show: false, focusable: false, skipTaskbar: true, frame: false,
    x: area.x + 2, y: area.y + 2,
    width: Math.min(area.width - 4, 1780), height: Math.min(area.height - 4, 1090),
    webPreferences: { backgroundThrottling: false, contextIsolation: true, sandbox: true, nodeIntegration: false }
  });
  const id = bridge.configure(window.getNativeWindowHandle());
  window.showInactive();
  bridge.configure(window.getNativeWindowHandle());
  fs.writeFileSync(process.env.RAWMASTER_LF_WINDOW, JSON.stringify({
    id, bounds: window.getBounds(), chrome: process.versions.chrome, electron: process.versions.electron
  }));
  await window.loadURL(process.env.RAWMASTER_LF_ORIGIN);
}).catch(error => {
  console.error(error);
  app.exit(1);
});
