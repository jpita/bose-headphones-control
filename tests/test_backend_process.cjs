const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const test = require('node:test');

const { createBackendStopper } = require('../electron/backend-process.cjs');

test('stops the backend once with SIGTERM and clears the reference', () => {
  const child = new EventEmitter();
  child.killed = false;
  const signals = [];
  child.kill = (signal) => {
    signals.push(signal);
    child.killed = true;
  };

  let backend = child;
  const stop = createBackendStopper(
    () => backend,
    () => { backend = undefined; },
  );

  assert.equal(stop(), true);
  assert.deepEqual(signals, ['SIGTERM']);
  assert.equal(backend, undefined);
  assert.equal(stop(), false);
  assert.deepEqual(signals, ['SIGTERM']);
});

test('does nothing when no live backend exists', () => {
  const stopMissing = createBackendStopper(() => undefined, () => {});
  assert.equal(stopMissing(), false);

  const child = new EventEmitter();
  child.killed = true;
  child.kill = () => assert.fail('kill should not be called');
  const stopKilled = createBackendStopper(() => child, () => {});
  assert.equal(stopKilled(), false);
});
