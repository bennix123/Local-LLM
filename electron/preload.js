
// Preload script for Electron — currently minimal.
// Extend with main-process APIs (file dialog, native menus, etc.) as needed.
const { contextBridge } = require("electron");

contextBridge.exposeInMainWorld("electronAPI", {
  platform: process.platform,
});
