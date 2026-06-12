import { app, BrowserWindow } from "electron";
import { spawn } from "child_process";

let backend;

async function waitForServer() {
  for (let i = 0; i < 60; i++) {
    try {
      const res = await fetch(
        "http://localhost:3000/api/state"
      );

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
    autoHideMenuBar: true
  });

  win.loadURL("http://localhost:3000");
}

app.whenReady().then(async () => {
  backend = spawn(
    process.execPath,
    ["server.js"],
    {
      cwd: app.getAppPath(),
      shell: true,
      stdio: "inherit"
    }
  );

  const ready = await waitForServer();

  if (!ready) {
    console.error("Backend failed to start");
    app.quit();
    return;
  }

  createWindow();
});

app.on("window-all-closed", () => {
  if (backend) backend.kill();
  app.quit();
});