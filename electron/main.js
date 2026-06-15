
import { app, BrowserWindow } from "electron";
import path from "node:path";
import { fork } from "child_process";

const PORT = 3000;
let backend;

async function waitForServer() {
  for (let i = 0; i < 60; i++) {
    try {
      const res = await fetch(`http://localhost:${PORT}/api/state`);
      if (res.ok) return true;
    } catch {}
    await new Promise((r) => setTimeout(r, 1000));
  }
  return false;
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1400,
    height: 900,
    autoHideMenuBar: true,
  });
  win.loadURL(`http://localhost:${PORT}`);
}

app.whenReady().then(async () => {
  const serverPath = path.join(app.getAppPath(), "server.js");

  backend = fork(serverPath, {
    cwd: app.getAppPath(),
    env: { ...process.env, PORT: String(PORT) },
    silent: false,
  });

  backend.on("exit", (code) => {
    if (code !== 0 && code !== null) {
      console.error(`Backend exited with code ${code}, restarting...`);
      // In production, implement restart logic here
    }
  });

  const ready = await waitForServer();
  if (!ready) {
    console.error("Backend failed to start after 60s");
    app.quit();
    return;
  }

  createWindow();
});

app.on("window-all-closed", () => {
  if (backend) backend.kill();
  if (process.platform !== "darwin") app.quit();
});

app.on("before-quit", () => {
  if (backend) backend.kill();
});
