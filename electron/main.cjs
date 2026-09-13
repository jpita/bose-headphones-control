const { app, BrowserWindow, dialog } = require('electron');
const { spawn } = require('node:child_process');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const { createBackendStopper } = require('./backend-process.cjs');

let backend;
let mainWindow;
const stopBackend = createBackendStopper(
  () => backend,
  () => { backend = undefined; },
);

function reservePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen({ host: '127.0.0.1', port: 0 }, () => {
      const { port } = server.address();
      server.close((error) => error ? reject(error) : resolve(port));
    });
  });
}

function backendCommand() {
  if (app.isPackaged) {
    if (process.platform === 'linux') {
      return {
        command: process.env.BOSE_UI_PYTHON || 'python3',
        args: [path.join(process.resourcesPath, 'linux-backend', 'server.py'), '--no-browser'],
      };
    }
    return {
      command: path.join(process.resourcesPath, 'backend', 'bose-panel'),
      args: ['--no-browser'],
    };
  }

  const python = process.env.BOSE_UI_PYTHON || path.join(app.getAppPath(), '.venv', 'bin', 'python');
  return { command: python, args: [path.join(app.getAppPath(), 'server.py'), '--no-browser'] };
}

function waitForServer(url, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const request = http.get(url, (response) => {
        response.resume();
        if (response.statusCode === 200) return resolve();
        retry(new Error(`Backend returned HTTP ${response.statusCode}`));
      });
      request.on('error', retry);
      request.setTimeout(1000, () => request.destroy(new Error('Backend timed out')));
    };
    const retry = (error) => {
      if (Date.now() >= deadline) return reject(error);
      setTimeout(attempt, 150);
    };
    attempt();
  });
}

async function startBackend() {
  const port = await reservePort();
  const { command, args } = backendCommand();
  const env = {
    ...process.env,
    BOSE_UI_HOST: '127.0.0.1',
    BOSE_UI_PORT: String(port),
    BOSE_UI_PARENT_PID: String(process.pid),
  };

  backend = spawn(command, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let backendError = '';
  const backendFailed = new Promise((resolve, reject) => {
    backend.once('error', (error) => {
      reject(new Error(`${error.message}\n\nExpected backend: ${command}`));
    });
    backend.once('exit', (code, signal) => {
      const detail = backendError.trim();
      reject(new Error(detail || `Bluetooth service stopped (${code ?? signal}).`));
    });
  });
  backend.stderr.on('data', (chunk) => {
    backendError += chunk.toString();
    console.error(`[backend] ${chunk}`);
  });
  backend.stdout.on('data', (chunk) => console.info(`[backend] ${chunk}`));

  const url = `http://127.0.0.1:${port}/`;
  await Promise.race([waitForServer(url), backendFailed]);
  return url;
}

function createWindow(url) {
  mainWindow = new BrowserWindow({
    width: 1240,
    height: 900,
    minWidth: 900,
    minHeight: 650,
    title: 'Bose Headphones Control',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  mainWindow.loadURL(url);
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (mainWindow?.isMinimized()) mainWindow.restore();
    mainWindow?.show();
    mainWindow?.focus();
  });

  app.whenReady().then(async () => {
    try {
      createWindow(await startBackend());
    } catch (error) {
      dialog.showErrorBox('Cannot start Bose Headphones Control', error.message);
      app.quit();
    }
  });
}

app.on('window-all-closed', () => app.quit());
app.on('before-quit', stopBackend);
app.on('will-quit', stopBackend);
process.on('SIGTERM', () => {
  stopBackend();
  app.quit();
});
