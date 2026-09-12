function createBackendStopper(getBackend, clearBackend) {
  let stopping = false;

  return function stopBackend() {
    const backend = getBackend();
    if (stopping || !backend || backend.killed) return false;

    stopping = true;
    backend.removeAllListeners('error');
    backend.kill('SIGTERM');
    clearBackend();
    return true;
  };
}

module.exports = { createBackendStopper };
